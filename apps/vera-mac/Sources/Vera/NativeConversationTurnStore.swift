import Foundation

@MainActor
final class NativeTurnExecution {
    let record: NativeConversationTurn
    var task: Task<Void, Never>?
    var deadline: Task<Void, Never>?
    var continuation: CheckedContinuation<Bool, Never>?
    var finalization: (state: NativeConversationTurn.State, message: Message, ordinal: Int)?

    init(_ record: NativeConversationTurn) { self.record = record }
}

extension ChatStore {
    var turnRepository: (any NativeConversationTurnRepository)? { repository as? any NativeConversationTurnRepository }
    var currentTurnProfile: String {
        let config = currentNativeConfig
        let configuredProfile = nativeTaskConfiguration?.settings().activeProfile
        let profileID = nativeTaskEnrollment?.profileID ?? configuredProfile?.id
        let identity = profileID ?? (config?.apiKey?.isEmpty == false ? Self.turnProcessIdentity : "direct")
        let api = nativeTaskEngine.base.map { NativeConversationTurn.fingerprint(NativeChatConfig(
            baseURL: $0, apiKey: nil, model: "capabilities", chatTemplateKwargs: nil)) } ?? "no-capabilities"
        return [NativeConversationTurn.fingerprint(config), identity, api].joined(separator: ":")
    }

    func turnProfile(for route: MessageRouteNote?) -> String {
        guard route?.route == .bridged, let bridge = effectiveBridgeConfig else { return currentTurnProfile }
        let binding = NativeConversationTurn.fingerprint(NativeChatConfig(baseURL: bridge.baseURL, apiKey: nil,
            model: bridge.model, chatTemplateKwargs: nil))
        return currentTurnProfile + ":bridge:" + binding + (bridge.apiKey?.isEmpty == false ? Self.turnProcessIdentity : "")
    }

    var pendingProfileAvailable: Bool { currentNativeConfig != nil }

    func prepareTurnDispatch(_ activity: NativeToolActivity, turn: NativeConversationTurn) async -> Bool {
        guard await turnCurrency(turn) == .current, turnAllowsDispatch(turn, activity: activity),
              let attempt = turn.attempt else { return false }
        do {
            try turnRepository?.markTurnDispatch(turn.id, attempt: attempt, activity: activity)
            return true
        } catch { return false }
    }

    func turnLocation(_ turn: NativeConversationTurn) -> (conversation: Int, user: Int, reply: Int)? {
        guard let ci = conversations.firstIndex(where: { $0.id == turn.conversationID }),
              let ui = conversations[ci].messages.firstIndex(where: { $0.id == turn.userMessageID }),
              let ri = conversations[ci].messages.firstIndex(where: { $0.id == turn.assistantMessageID }) else { return nil }
        return (ci, ui, ri)
    }

    func turnOwned(_ turn: NativeConversationTurn) -> Bool {
        guard let attempt = turn.attempt else { return false }
        return turnExecutions[turn.id]?.record.attempt == attempt && !Task.isCancelled
    }

    func turnCurrency(_ turn: NativeConversationTurn) async -> NativeTurnCurrency {
        guard turnOwned(turn), let attempt = turn.attempt, let turnRepository else { return .superseded }
        let id = turn.id
        let currency = await Task.detached(priority: .userInitiated) {
            turnRepository.turnCurrency(id, attempt: attempt)
        }.value
        return turnOwned(turn) ? currency : .superseded
    }

    func ensureTurnCurrent(_ turn: NativeConversationTurn) async throws {
        guard await turnCurrency(turn) != .superseded else { throw CancellationError() }
    }

    func setTurnStatus(_ status: String?, turn: NativeConversationTurn) {
        guard turnOwned(turn) else { return }
        turnStatuses[turn.assistantMessageID] = status
    }

    func reloadConversationTurns() {
        do { conversationTurns = try turnRepository?.conversationTurns() ?? [] }
        catch { chatConfigurationError = "Saved answers couldn't load. Try again." }
    }

    func synchronizeTurnMessages(conversationIDs ids: Set<String>) {
        dirtyTurnConversations.formUnion(ids)
        guard let repository else { return }
        let ids = dirtyTurnConversations
        let ownedMessages = Set(turnExecutions.values.flatMap { [$0.record.userMessageID, $0.record.assistantMessageID] })
        do {
            let headers = ids.contains { id in !conversations.contains { $0.id == id } }
                ? try repository.listConversations() : []
            for id in ids {
                if !conversations.contains(where: { $0.id == id }), let header = headers.first(where: { $0.id == id }) {
                    conversations.append(header)
                }
                guard let index = conversations.firstIndex(where: { $0.id == id }) else {
                    dirtyTurnConversations.remove(id)
                    continue
                }
                let live = Dictionary(uniqueKeysWithValues: conversations[index].messages.map { ($0.id, $0) })
                conversations[index].messages = try repository.messages(conversationID: id).map { stored in
                    if ownedMessages.contains(stored.id), var current = live[stored.id] {
                        current.displayBlocks = stored.displayBlocks
                        return current
                    }
                    var value = stored
                    if live[stored.id]?.answered == true {
                        value.answered = true
                        value.answerText = live[stored.id]?.answerText
                    }
                    return value
                }
                dirtyTurnConversations.remove(id)
            }
        } catch { chatConfigurationError = "Saved answers couldn't refresh. Your accepted messages are still saved." }
    }

    func resumeConversationTurns() {
        reloadConversationTurns()
        scheduleConversationTurns()
        if conversationTurnLoop == nil {
            conversationTurnLoop = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    self.scheduleConversationTurns()
                }
            }
        }
    }

    func scheduleConversationTurns() {
        guard !suspendsTurnScheduling, !isSchedulingTurns, let turnRepository, let repository else { return }
        isSchedulingTurns = true
        defer { isSchedulingTurns = false }
        let unfinished = conversationTurns.filter { $0.state == .pending || $0.state == .running }
        var watching = Set(unfinished.map(\.id)).union(turnExecutions.keys)
        let previous = Dictionary(uniqueKeysWithValues: unfinished.map { ($0.id, $0) })
        let token: [Int64]
        let updates: [NativeConversationTurn]
        var headers = conversationTurnHeaders
        do {
            token = try turnRepository.conversationTurnChangeToken()
            if watching.isEmpty && dirtyTurnConversations.isEmpty && token == conversationTurnToken { return }
            drainTurnFinalizations()
            if token != conversationTurnToken {
                headers = Dictionary(uniqueKeysWithValues: try turnRepository.conversationTurnHeaders().map { ($0.id, $0) })
                watching.formUnion(headers.values.filter { conversationTurnHeaders[$0.id] != $0 }.map(\.id))
            }
            updates = try turnRepository.pollConversationTurns(watching: watching)
        } catch {
            chatConfigurationError = "Saved answers couldn't refresh. Try again."
            return
        }
        let changed = token != conversationTurnToken
        conversationTurnToken = token
        conversationTurnHeaders = headers
        let updateIDs = Set(updates.map(\.id))
        conversationTurns.removeAll { watching.contains($0.id) && !updateIDs.contains($0.id) }
        for update in updates {
            if let index = conversationTurns.firstIndex(where: { $0.id == update.id }) { conversationTurns[index] = update }
            else { conversationTurns.append(update) }
        }
        conversationTurns.sort { $0.createdAt < $1.createdAt }
        for (id, execution) in turnExecutions {
            let saved = conversationTurns.first(where: { $0.id == id })
            if saved?.state != .running || saved?.attempt != execution.record.attempt {
                resolveTurnConfirmation(execution.record.assistantMessageID, approved: false)
                execution.task?.cancel()
                execution.deadline?.cancel()
                turnExecutions[id] = nil
                turnStatuses[execution.record.assistantMessageID] = nil
            }
        }
        generating = !turnExecutions.isEmpty
        let affected = Set(updates.filter { changed || previous[$0.id]?.state != $0.state || previous[$0.id]?.attempt != $0.attempt }
            .map(\.conversationID))
        synchronizeTurnMessages(conversationIDs: affected)
        for turn in conversationTurns where turn.state == .pending {
            guard turnExecutions.count < NativeConversationTurn.maximumActive else { break }
            if let ci = conversations.firstIndex(where: { $0.id == turn.conversationID }), conversations[ci].messages.isEmpty {
                conversations[ci].messages = (try? repository.messages(conversationID: turn.conversationID)) ?? []
            }
            guard let location = turnLocation(turn) else { continue }
            let currentProfile = turnProfile(for: turn.history.last?.routeNote)
            let missing = turn.history.filter { $0.routeNote?.route != .withheld }.flatMap(\.attachments).contains {
                $0.isImage && attachmentStore.requestDataURL(for: $0) == nil
            }
            if turn.profile != currentProfile || !isLive || !pendingProfileAvailable || missing {
                var message = conversations[location.conversation].messages[location.reply]
                message.state = .interrupted
                message.failure = missing ? "An attachment is missing. Restore it before retrying this answer."
                    : "This saved message needs its original settings. Send a new message to use the current settings."
                do {
                    try turnRepository.finishTurn(turn.id, attempt: nil, state: .interrupted, message: message, ordinal: location.reply)
                    conversations[location.conversation].messages[location.reply] = message
                    if let index = conversationTurns.firstIndex(where: { $0.id == turn.id }) { conversationTurns[index].state = .interrupted }
                } catch { chatConfigurationError = "The saved answer couldn't update. Try again." }
                continue
            }
            do {
                guard let claimed = try turnRepository.claimTurn(turn.id, attempt: UUID()) else { continue }
                if let index = conversationTurns.firstIndex(where: { $0.id == claimed.id }) { conversationTurns[index] = claimed }
                turnExecutions[claimed.id] = NativeTurnExecution(claimed)
                generating = true
                performTurn(claimed)
            } catch {
                chatConfigurationError = "The saved answer couldn't start. Try again."
            }
        }
    }

    func finishTurnExecution(_ turn: NativeConversationTurn) {
        guard let execution = turnExecutions[turn.id], execution.record.attempt == turn.attempt else { return }
        execution.deadline?.cancel()
        execution.task = nil
        resolveTurnConfirmation(turn.assistantMessageID, approved: false)
        if let location = turnLocation(turn) {
            var message = conversations[location.conversation].messages[location.reply]
            if message.state == .streaming {
                message.state = .interrupted
                message.failure = "This answer stopped before it could finish saving. Check it before retrying."
                conversations[location.conversation].messages[location.reply] = message
            }
            execution.finalization = (message.state == .complete ? .complete : .interrupted, message, location.reply)
        }
        scheduleConversationTurns()
    }

    func drainTurnFinalizations() {
        guard let turnRepository else { return }
        for (id, execution) in turnExecutions {
            guard let finalization = execution.finalization, let attempt = execution.record.attempt else { continue }
            do {
                switch turnRepository.turnCurrency(id, attempt: attempt) {
                case .current:
                    try turnRepository.finishTurn(id, attempt: attempt, state: finalization.state,
                        message: finalization.message, ordinal: finalization.ordinal)
                case .superseded:
                    break
                case .unconfirmed:
                    turnStatuses[execution.record.assistantMessageID] = "Waiting to save this answer."
                    continue
                }
                turnExecutions[id] = nil
                turnStatuses[execution.record.assistantMessageID] = nil
            } catch {
                turnStatuses[execution.record.assistantMessageID] = "Waiting to save this answer."
            }
        }
    }

    func stopAnswer(_ messageID: UUID, reason: String = "Stopped.") {
        reloadConversationTurns()
        guard let turn = conversationTurns.first(where: { $0.assistantMessageID == messageID }),
              turn.state == .running || turn.state == .pending,
              let location = turnLocation(turn), let turnRepository else { return }
        var message = conversations[location.conversation].messages[location.reply]
        message.state = .interrupted
        message.failure = reason
        if reason == "Stopped.", turn.mayHaveEffect {
            message.failure = "Stopped. An action already sent may have completed; check it before trying again."
        }
        for index in message.toolActivities.indices where message.toolActivities[index].state == .pending {
            message.toolActivities[index].state = .failed
            message.toolActivities[index].result = "{\"error\":\"Stopped before a result was confirmed\"}"
        }
        do {
            try turnRepository.finishTurn(turn.id, attempt: turn.attempt, state: .stopped, message: message, ordinal: location.reply)
            conversations[location.conversation].messages[location.reply] = message
        } catch {
            chatConfigurationError = "This answer couldn't be stopped. Try again."
            return
        }
        resolveTurnConfirmation(messageID, approved: false)
        let execution = turnExecutions.removeValue(forKey: turn.id)
        execution?.task?.cancel()
        execution?.deadline?.cancel()
        turnStatuses[messageID] = nil
        generating = !turnExecutions.isEmpty
        scheduleConversationTurns()
    }

    func retryAnswer(_ messageID: UUID) {
        reloadConversationTurns()
        if !conversationTurns.contains(where: { $0.assistantMessageID == messageID }) {
            _ = enrollLegacyAnswer(messageID)
            return
        }
        guard let turn = conversationTurns.first(where: { $0.assistantMessageID == messageID }),
              let location = turnLocation(turn) else { return }
        let message = conversations[location.conversation].messages[location.reply]
        guard !turn.mayHaveEffect else {
            chatConfigurationError = "Check whether the earlier action completed, then send a new message. It won't be replayed automatically."
            return
        }
        do {
            try turnRepository?.retryTurn(turn.id, profile: turnProfile(for: turn.history.last?.routeNote))
            conversations[location.conversation].messages[location.reply].state = .streaming
            conversations[location.conversation].messages[location.reply].failure = nil
            scheduleConversationTurns()
        } catch { chatConfigurationError = error.localizedDescription }
    }

    func answerStatus(_ messageID: UUID) -> String? {
        if let status = turnStatuses[messageID] { return status }
        guard let turn = conversationTurns.first(where: { $0.assistantMessageID == messageID }) else { return nil }
        switch turn.state {
        case .pending: return "Waiting to answer"
        case .running: return "Working on this answer"
        default: return nil
        }
    }

    func canStopAnswer(_ messageID: UUID) -> Bool {
        conversationTurns.contains { $0.assistantMessageID == messageID && ($0.state == .pending || $0.state == .running) }
    }

    func awaitTurnConfirmation(_ activity: NativeToolActivity, turn: NativeConversationTurn) async -> Bool {
        guard await turnCurrency(turn) == .current, let execution = turnExecutions[turn.id] else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard turnOwned(turn), execution.continuation == nil else {
                    continuation.resume(returning: false)
                    return
                }
                execution.continuation = continuation
                turnConfirmationTokens[turn.assistantMessageID] = UUID()
                turnConfirmations[turn.assistantMessageID] = NativeToolConfirmationRequest(activity: activity)
                pendingToolConfirmation = turnConfirmations[turn.assistantMessageID]
                setTurnStatus("Waiting for your approval", turn: turn)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.turnExecutions[turn.id]?.record.attempt == turn.attempt else { return }
                self?.resolveTurnConfirmation(turn.assistantMessageID, approved: false)
            }
        }
    }

    func resolveTurnConfirmation(_ messageID: UUID, approved: Bool, requestID: String? = nil, token: UUID? = nil) {
        guard let turn = conversationTurns.first(where: { $0.assistantMessageID == messageID }),
              let execution = turnExecutions[turn.id],
              requestID == nil || turnConfirmations[messageID]?.id == requestID,
              token == nil || turnConfirmationTokens[messageID] == token,
              let continuation = execution.continuation else { return }
        execution.continuation = nil
        turnConfirmationTokens[messageID] = nil
        let request = turnConfirmations.removeValue(forKey: messageID)
        if pendingToolConfirmation?.id == request?.id { pendingToolConfirmation = nil }
        continuation.resume(returning: approved && turnOwned(execution.record))
    }
}
