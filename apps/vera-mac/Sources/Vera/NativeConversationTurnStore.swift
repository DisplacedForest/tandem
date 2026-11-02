import Foundation

@MainActor
enum NativeTurnCheckpointOutcome: Sendable { case saved, failed, superseded }

struct NativeTurnFinalizationRequest: Sendable {
    let id: UUID
    let attempt: UUID
    let state: NativeConversationTurn.State
    let message: Message
    let ordinal: Int
}

enum NativeTurnFinalizationOutcome: Sendable { case finished, superseded, unconfirmed }

struct NativeTurnFinalizationResult: Sendable {
    let attempt: UUID
    let outcome: NativeTurnFinalizationOutcome
}

struct NativeTurnScheduleRead: Sendable {
    let token: [Int64]
    let headers: [UUID: NativeConversationTurnHeader]?
    let updates: [NativeConversationTurn]
    let finalized: [UUID: NativeTurnFinalizationResult]
}

final class NativeTurnExecution {
    let record: NativeConversationTurn
    var task: Task<Void, Never>?
    var deadline: Task<Void, Never>?
    var continuation: CheckedContinuation<Bool, Never>?
    var finalization: (state: NativeConversationTurn.State, message: Message, ordinal: Int)?
    var checkpoint: Task<Void, Never>?
    var pendingCheckpoint: (message: Message, ordinal: Int)?
    var checkpointFailingSince: Date?

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
        guard await turnCurrency(turn) == .current, turnAllowsDispatch(turn, activity: activity) else { return false }
        return await markTurnDispatchOffMain(activity, turn: turn)
    }

    func markTurnDispatchOffMain(_ activity: NativeToolActivity, turn: NativeConversationTurn) async -> Bool {
        guard let attempt = turn.attempt, let turnRepository else { return false }
        let id = turn.id
        let marked = await Task.detached(priority: .userInitiated) {
            do { try turnRepository.markTurnDispatch(id, attempt: attempt, activity: activity); return true } catch { return false }
        }.value
        return marked && turnOwned(turn)
    }

    static let saveWaitingStatus = "Waiting to save this answer."
    static let checkpointGraceSeconds: TimeInterval = {
        let raw = ProcessInfo.processInfo.environment["VERA_TURN_CHECKPOINT_GRACE_SECONDS"].flatMap(Double.init)
        return raw.map { max(1, $0) } ?? 10
    }()

    func scheduleTurnCheckpoint(_ turn: NativeConversationTurn, message: Message, ordinal: Int) {
        guard turnOwned(turn), let execution = turnExecutions[turn.id], turnRepository != nil else { return }
        execution.pendingCheckpoint = (message, ordinal)
        guard execution.checkpoint == nil else { return }
        execution.checkpoint = Task { [weak self] in await self?.flushTurnCheckpoints(turn) }
    }

    func turnCheckpointStalled(_ turn: NativeConversationTurn) -> Bool {
        guard let since = turnExecutions[turn.id]?.checkpointFailingSince else { return false }
        return Date().timeIntervalSince(since) >= Self.checkpointGraceSeconds
    }

    private func flushTurnCheckpoints(_ turn: NativeConversationTurn) async {
        defer { turnExecutions[turn.id]?.checkpoint = nil }
        while turnOwned(turn), let execution = turnExecutions[turn.id], let pending = execution.pendingCheckpoint,
              let turnRepository {
            execution.pendingCheckpoint = nil
            let outcome = await Task.detached(priority: .utility) { () -> NativeTurnCheckpointOutcome in
                do { try turnRepository.checkpointTurn(turn, message: pending.message, ordinal: pending.ordinal); return .saved }
                catch is CancellationError { return .superseded }
                catch { return .failed }
            }.value
            guard turnOwned(turn), let live = turnExecutions[turn.id] else { return }
            switch outcome {
            case .saved:
                live.checkpointFailingSince = nil
            case .failed:
                if live.checkpointFailingSince == nil { live.checkpointFailingSince = Date() }
                if live.pendingCheckpoint == nil { live.pendingCheckpoint = pending }
                return
            case .superseded:
                live.pendingCheckpoint = nil
                return
            }
        }
    }

    func awaitTurnCheckpoint(_ turn: NativeConversationTurn) async {
        guard let execution = turnExecutions[turn.id] else { return }
        execution.pendingCheckpoint = nil
        await execution.checkpoint?.value
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
        guard !suspendsTurnScheduling, turnRepository != nil, repository != nil else { return }
        if isSchedulingTurns { turnSchedulingRerun = true; return }
        isSchedulingTurns = true
        Task { [weak self] in
            guard let self else { return }
            await self.runTurnSchedulingTick()
            self.isSchedulingTurns = false
            if self.turnSchedulingRerun {
                self.turnSchedulingRerun = false
                self.scheduleConversationTurns()
            }
        }
    }

    func runTurnSchedulingTick() async {
        guard !suspendsTurnScheduling, let turnRepository, let repository else { return }
        let unfinished = conversationTurns.filter { $0.state == .pending || $0.state == .running }
        let watching = Set(unfinished.map(\.id)).union(turnExecutions.keys)
        let previous = Dictionary(uniqueKeysWithValues: unfinished.map { ($0.id, $0) })
        let previousToken = conversationTurnToken
        let previousHeaders = conversationTurnHeaders
        let dirtyEmpty = dirtyTurnConversations.isEmpty
        let finalizations: [NativeTurnFinalizationRequest] = turnExecutions.compactMap { id, execution in
            guard let finalization = execution.finalization, let attempt = execution.record.attempt else { return nil }
            return NativeTurnFinalizationRequest(id: id, attempt: attempt, state: finalization.state,
                                                 message: finalization.message, ordinal: finalization.ordinal)
        }
        let read: NativeTurnScheduleRead?
        do {
            read = try await Task.detached(priority: .userInitiated) { () -> NativeTurnScheduleRead? in
                let token = try turnRepository.conversationTurnChangeToken()
                if watching.isEmpty && dirtyEmpty && token == previousToken && finalizations.isEmpty { return nil }
                var finalized: [UUID: NativeTurnFinalizationResult] = [:]
                for request in finalizations {
                    switch turnRepository.turnCurrency(request.id, attempt: request.attempt) {
                    case .current:
                        do {
                            try turnRepository.finishTurn(request.id, attempt: request.attempt, state: request.state,
                                                          message: request.message, ordinal: request.ordinal)
                            finalized[request.id] = NativeTurnFinalizationResult(attempt: request.attempt, outcome: .finished)
                        } catch {
                            finalized[request.id] = NativeTurnFinalizationResult(attempt: request.attempt, outcome: .unconfirmed)
                        }
                    case .superseded:
                        finalized[request.id] = NativeTurnFinalizationResult(attempt: request.attempt, outcome: .superseded)
                    case .unconfirmed:
                        finalized[request.id] = NativeTurnFinalizationResult(attempt: request.attempt, outcome: .unconfirmed)
                    }
                }
                var headers: [UUID: NativeConversationTurnHeader]?
                var watched = watching
                if token != previousToken {
                    let current = Dictionary(uniqueKeysWithValues: try turnRepository.conversationTurnHeaders().map { ($0.id, $0) })
                    headers = current
                    watched.formUnion(current.values.filter { previousHeaders[$0.id] != $0 }.map(\.id))
                }
                let updates = try turnRepository.pollConversationTurns(watching: watched)
                return NativeTurnScheduleRead(token: token, headers: headers, updates: updates, finalized: finalized)
            }.value
        } catch {
            chatConfigurationError = "Saved answers couldn't refresh. Try again."
            return
        }
        guard let read, !suspendsTurnScheduling else { return }
        for (id, result) in read.finalized {
            guard let execution = turnExecutions[id], execution.record.attempt == result.attempt, execution.finalization != nil else { continue }
            switch result.outcome {
            case .finished, .superseded:
                turnExecutions[id] = nil
                turnStatuses[execution.record.assistantMessageID] = nil
            case .unconfirmed:
                turnStatuses[execution.record.assistantMessageID] = Self.savePendingStatus
            }
        }
        let changed = read.token != conversationTurnToken
        conversationTurnToken = read.token
        if let headers = read.headers { conversationTurnHeaders = headers }
        let updateIDs = Set(read.updates.map(\.id))
        conversationTurns.removeAll { watching.contains($0.id) && !updateIDs.contains($0.id) }
        for update in read.updates {
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
        let affected = Set(read.updates.filter { changed || previous[$0.id]?.state != $0.state || previous[$0.id]?.attempt != $0.attempt }
            .map(\.conversationID))
        synchronizeTurnMessages(conversationIDs: affected)
        for turn in conversationTurns where turn.state == .pending {
            guard !suspendsTurnScheduling, turnExecutions.count < NativeConversationTurn.maximumActive else { break }
            guard turnExecutions[turn.id] == nil, conversationTurns.first(where: { $0.id == turn.id })?.state == .pending else { continue }
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
                let interrupted = message
                let turnID = turn.id
                let ordinal = location.reply
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try turnRepository.finishTurn(turnID, attempt: nil, state: .interrupted, message: interrupted, ordinal: ordinal)
                    }.value
                    guard !suspendsTurnScheduling, let current = turnLocation(turn) else { continue }
                    conversations[current.conversation].messages[current.reply] = interrupted
                    if let index = conversationTurns.firstIndex(where: { $0.id == turn.id }) { conversationTurns[index].state = .interrupted }
                } catch { chatConfigurationError = "The saved answer couldn't update. Try again." }
                continue
            }
            let turnID = turn.id
            let attempt = UUID()
            do {
                let claimed = try await Task.detached(priority: .userInitiated) {
                    try turnRepository.claimTurn(turnID, attempt: attempt)
                }.value
                guard let claimed, !suspendsTurnScheduling, turnExecutions[claimed.id] == nil,
                      turnExecutions.count < NativeConversationTurn.maximumActive else { continue }
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

    func cancelToolRun(_ messageID: UUID) {
        stopAnswer(messageID, reason: "Canceled.", toolCanceled: true)
    }

    func stopAnswer(_ messageID: UUID, reason: String = "Stopped.", toolCanceled: Bool = false) {
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
            let canceled = toolCanceled || message.toolActivities[index].isCancelableRun
            message.toolActivities[index].state = canceled ? .canceled : .failed
            message.toolActivities[index].result = canceled
                ? "{\"error\":\"Canceled by the user\"}"
                : "{\"error\":\"Stopped before a result was confirmed\"}"
            message.toolActivities[index].progress = nil
        }
        do {
            try turnRepository.finishTurn(turn.id, attempt: turn.attempt, state: .stopped, message: message, ordinal: location.reply)
            conversations[location.conversation].messages[location.reply] = message
            if let index = conversationTurns.firstIndex(where: { $0.id == turn.id }) { conversationTurns[index].state = .stopped }
        } catch {
            chatConfigurationError = "This answer couldn't be stopped. Try again."
            return
        }
        recordCanvasArtifacts(message.artifacts, conversationID: turn.conversationID, messageID: messageID.uuidString,
                              revising: artifactRevisionTarget(messageID: turn.userMessageID.uuidString))
        resolveTurnConfirmation(messageID, approved: false)
        turnDeclineSource.clear(turn: turn.id)
        turnCommandReasonSource.clear(prefix: Self.scopedBlockID("", turn: turn))
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

    func stoppableAnswer(in conversationID: String) -> UUID? {
        let unfinished = conversationTurns.filter { $0.conversationID == conversationID && ($0.state == .pending || $0.state == .running) }
        return (unfinished.first { $0.state == .running } ?? unfinished.first)?.assistantMessageID
    }

    static let savePendingStatus = "Waiting to save this answer."

    func answerNote(_ messageID: UUID) -> String? {
        turnStatuses[messageID] == Self.savePendingStatus ? Self.savePendingStatus : nil
    }

    func isQueuedAnswer(_ messageID: UUID) -> Bool {
        conversationTurns.contains { $0.assistantMessageID == messageID && $0.state == .pending }
    }

    static func scopedBlockID(_ id: String, turn: NativeConversationTurn) -> String {
        (turn.attempt ?? turn.id).uuidString.lowercased() + ":" + id
    }

    func awaitTurnConfirmation(_ activity: NativeToolActivity, turn: NativeConversationTurn) async -> Bool {
        guard await turnCurrency(turn) == .current, let execution = turnExecutions[turn.id] else { return false }
        if turnDeclineSource.contains(NativeToolRequestKey.canonical(name: activity.name, request: activity.request), turn: turn.id) { return false }
        if activity.toolID == NativeCommandTools.toolID, activity.name == NativeCommandTools.runName,
           let command = NativeCommandTools.command(inRequest: activity.request),
           NativeCommandClassifier.classify(command, grants: grants(for: turn.conversationID)) == .commands,
           conversationRules(for: turn.conversationID).isApproved(command: command) {
            guard turnOwned(turn) else { return false }
            turnCommandReasonSource.set(.conversationPrefix, for: Self.scopedBlockID(activity.id, turn: turn))
            return true
        }
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
        resolveTurnConfirmation(messageID, decision: approved ? .approve : .decline, requestID: requestID, token: token)
    }

    func resolveTurnConfirmation(_ messageID: UUID, decision: NativeToolDecision, requestID: String? = nil, token: UUID? = nil) {
        guard let turn = conversationTurns.first(where: { $0.assistantMessageID == messageID }),
              let execution = turnExecutions[turn.id],
              requestID == nil || turnConfirmations[messageID]?.id == requestID,
              token == nil || turnConfirmationTokens[messageID] == token,
              let continuation = execution.continuation else { return }
        execution.continuation = nil
        turnConfirmationTokens[messageID] = nil
        let request = turnConfirmations.removeValue(forKey: messageID)
        if pendingToolConfirmation?.id == request?.id { pendingToolConfirmation = nil }
        let owned = turnOwned(execution.record)
        if let request, request.toolID == NativeCommandTools.toolID, request.name == NativeCommandTools.runName,
           let command = NativeCommandTools.command(inRequest: request.request) {
            switch decision {
            case .approve:
                turnCommandReasonSource.set(.userApproved, for: Self.scopedBlockID(request.id, turn: execution.record))
            case .approveSimilar:
                if owned { approveCommandPrefix(command, conversationID: turn.conversationID) }
                turnCommandReasonSource.set(.userApproved, for: Self.scopedBlockID(request.id, turn: execution.record))
            case .decline:
                let turnGrants = grants(for: turn.conversationID)
                let directory = NativeCommandTools.directory(inRequest: request.request) ?? (turnGrants.count == 1 ? turnGrants[0].path : "")
                attachDisplayBlock(.commandRun(NativeCommandRun(id: Self.scopedBlockID(request.id, turn: execution.record), command: command, directory: directory, outcome: .declined)), turn: execution.record)
            }
        }
        if let request, decision == .decline {
            turnDeclineSource.record(NativeToolRequestKey.canonical(name: request.name, request: request.request), turn: turn.id)
        }
        continuation.resume(returning: decision.approved && owned)
    }
}

extension ChatStore {
    func finishTurnOffMain(_ turn: NativeConversationTurn, state: NativeConversationTurn.State, message: Message, ordinal: Int,
                           conversation: Conversation) async throws {
        guard let turnRepository, let repository else { return }
        let id = turn.id
        let attempt = turn.attempt
        try await Task.detached(priority: .userInitiated) {
            try turnRepository.finishTurn(id, attempt: attempt, state: state, message: message, ordinal: ordinal)
            try repository.saveConversation(conversation)
        }.value
        guard turnOwned(turn) else { throw CancellationError() }
    }
}
