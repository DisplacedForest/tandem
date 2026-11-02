import Foundation

struct NativeDotServiceOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String
    let toolIDs: Set<String>
}

extension ChatStore {
    var isDotPaused: Bool { dotProfile.isPaused }

    func loadDotProfile() {
        if let local = repository as? LocalChatRepository {
            let store = NativeDotProfileStore(database: local.database)
            nativeDotProfileStore = store
            do {
                dotProfile = try store.load() ?? NativeDotProfile()
            } catch {
                dotProfile = NativeDotProfile(connectedToolIDs: [], state: .paused, setupCompleted: true)
                chatConfigurationError = "\(assistantName)'s goal and settings couldn't load: \(error.localizedDescription) Scheduled work is paused and no services are connected until the settings are saved again."
            }
        } else {
            nativeDotProfileStore = nil
            dotProfile = NativeDotProfile()
        }
        dotProfileLoaded = true
    }

    func saveDotProfile(_ mutate: (inout NativeDotProfile) -> Void) {
        var next = dotProfile
        mutate(&next)
        next.goal = NativeDotProfile.clean(next.goal)
        next.updatedAt = Date()
        do {
            try nativeDotProfileStore?.save(next)
        } catch {
            chatConfigurationError = "\(assistantName)'s settings couldn't be saved: \(error.localizedDescription)"
            return
        }
        dotProfile = next
    }

    func completeDotSetup(goal: String, connectedToolIDs: Set<String>?) {
        saveDotProfile {
            $0.goal = goal
            $0.connectedToolIDs = connectedToolIDs
            $0.setupCompleted = true
        }
    }

    func skipDotSetup() {
        saveDotProfile { $0.setupCompleted = true }
    }

    func setDotState(_ state: NativeDotState) {
        guard dotProfile.state != state else { return }
        if dotProfile.state == .paused && state == .active {
            skipMissedDotRuns(now: Date())
        }
        saveDotProfile { $0.state = state }
    }

    func skipMissedDotRuns(now: Date) {
        guard let store = nativeScheduleStore else { return }
        for var schedule in (try? store.all()) ?? [] where schedule.owner == .dot && schedule.enabled {
            guard let due = schedule.nextRunAt, due <= now else { continue }
            schedule.advance(after: now, from: due)
            do { try store.save(schedule) } catch {
                scheduleError = "A schedule couldn't move to its next time: \(error.localizedDescription)"
            }
        }
        reloadSchedules()
    }

    func turnConsentedToolIDs(conversationID: String, mentions: Set<String>) -> Set<String> {
        let enabled = enabledNativeToolIDs
        guard isVeraThread(conversationID) else { return enabled.union(mentions) }
        var global = enabled
        for server in nativeMCP?.servers ?? [] {
            for tool in server.tools where nativeMCP?.authority.access.allowed(tool, scope: "focused") == true {
                global.insert(tool.id)
            }
        }
        return dotToolIDs(base: enabled.union(mentions.intersection(global)))
    }

    func turnDotContext(_ turn: NativeConversationTurn) -> String? {
        if let stored = turn.dotContext { return stored }
        guard isVeraThread(turn.conversationID) else { return nil }
        let text = turn.history.first(where: { $0.id == turn.userMessageID })?.text ?? ""
        return dotContext(for: turn.conversationID, requestText: text)
    }

    var dotHeaderRules: String {
        NativeDotContext.headerSummary(resolver: ruleResolver(for: veraThreadID ?? "", requestText: ""))
    }

    func memorySourceIsLive(_ source: NativeMemoryTurnSource?, generation: Int, wasVeraThread: Bool) -> Bool {
        guard let source else { return true }
        if wasVeraThread && generation != dotResetGeneration { return false }
        if conversations.contains(where: { $0.id == source.conversationID }) { return true }
        if let local = repository as? LocalChatRepository {
            return (try? local.conversationExists(source.conversationID)) ?? false
        }
        return ((try? repository?.listConversations()) ?? []).contains { $0.id == source.conversationID }
    }

    func dotToolIDs(base: Set<String>) -> Set<String> {
        dotProfile.toolIDs(base: base)
    }

    func dotContext(for conversationID: String, requestText: String) -> String? {
        guard isVeraThread(conversationID) else { return nil }
        return NativeDotContext.render(name: assistantName, goal: dotProfile.goal,
                                       resolver: ruleResolver(for: conversationID, requestText: requestText))
    }

    func dotServiceOptions() -> [NativeDotServiceOption] {
        let enabled = enabledNativeToolIDs
        var options = NativeChatToolCatalog.tools(
            veraAPIConfigured: VeraAPIClient.resolvedBase() != nil,
            imageConfigured: NativeImageTools.resolvedBase() != nil,
            searchConfigured: nativeSearchAvailable(),
            declarations: capabilityDeclarations)
            .filter { $0.available && enabled.contains($0.id) }
            .map { NativeDotServiceOption(id: $0.id, name: $0.name, detail: $0.summary, toolIDs: [$0.id]) }
        for server in nativeMCP?.servers ?? [] {
            let allowed = server.tools.filter { nativeMCP?.authority.access.allowed($0, scope: "focused") == true }
            guard !allowed.isEmpty else { continue }
            let detail = allowed.count == 1 ? "1 tool from this service" : "\(allowed.count) tools from this service"
            options.append(NativeDotServiceOption(id: "service:" + server.id, name: server.configuration.name, detail: detail,
                                                  toolIDs: Set(allowed.map(\.id))))
        }
        return options
    }

    func dotSelectedServices(_ options: [NativeDotServiceOption]) -> Set<String> {
        guard let connected = dotProfile.connectedToolIDs else { return Set(options.map(\.id)) }
        return Set(options.filter { !$0.toolIDs.isDisjoint(with: connected) }.map(\.id))
    }

    func dotConnectedToolIDs(selected: Set<String>, options: [NativeDotServiceOption]) -> Set<String>? {
        if options.allSatisfy({ selected.contains($0.id) }) { return nil }
        return options.filter { selected.contains($0.id) }.reduce(into: Set<String>()) { $0.formUnion($1.toolIDs) }
    }

    func dotRemovalSummary() -> NativeDotRemovalSummary {
        var summary = NativeDotRemovalSummary(hasGoal: dotProfile.hasGoal, services: dotProfile.connectedToolIDs != nil)
        summary.artifacts = veraThreadID.flatMap { try? artifactRepository?.artifactIDs(conversationID: $0).count } ?? 0
        summary.schedules = ((try? nativeScheduleStore?.all()) ?? schedules).filter { $0.owner == .dot }.count
        guard let threadID = veraThreadID else { return summary }
        summary.messages = ((try? repository?.messages(conversationID: threadID)) ?? []).count
        if let memoryRepository = repository as? any NativeMemoryRepository {
            summary.memories = ((try? memoryRepository.allMemories()) ?? [])
                .filter { $0.status != .deleted && $0.sourceConversationID == threadID }.count
            summary.proposals = ((try? memoryRepository.pendingProposals()) ?? [])
                .filter { $0.sourceConversationID == threadID }.count
        }
        return summary
    }

    func resetDot() {
        let threadID = veraThreadID
        let wasShowing = threadID != nil && selectedID == threadID
        dotResetGeneration += 1
        suspendsTurnScheduling = true
        if let threadID {
            for turn in conversationTurns where turn.conversationID == threadID {
                stopAnswer(turn.assistantMessageID)
            }
        }
        for schedule in ((try? nativeScheduleStore?.all()) ?? schedules) where schedule.owner == .dot {
            deleteSchedule(schedule.id)
        }
        if let threadID, let memoryRepository = repository as? any NativeMemoryRepository {
            let note = "Removed when \(assistantName) started over"
            for memory in (try? memoryRepository.allMemories()) ?? []
            where memory.status != .deleted && memory.sourceConversationID == threadID {
                do { try memoryRepository.deleteMemory(memory.id, note: note) } catch {
                    memoryServiceState = .failed("A memory couldn't be removed: \(error.localizedDescription)")
                }
            }
            for proposal in (try? memoryRepository.pendingProposals()) ?? [] where proposal.sourceConversationID == threadID {
                do { try memoryRepository.decideProposal(proposal.id, status: .dismissed, note: note, memoryID: nil) } catch {
                    memoryServiceState = .failed("A suggested memory couldn't be dismissed: \(error.localizedDescription)")
                }
            }
        }
        if let threadID { _ = try? artifactRepository?.resolveArtifacts(conversationID: threadID, choice: .keep) }
        discardVeraThread()
        reloadArtifacts()
        suspendsTurnScheduling = false
        scheduleConversationTurns()
        do { try nativeDotProfileStore?.reset() } catch {
            chatConfigurationError = "\(assistantName)'s settings couldn't be cleared: \(error.localizedDescription)"
        }
        dotProfile = NativeDotProfile()
        ensureVeraThread()
        syncRuleSource()
        reloadNativeMemory()
        if wasShowing || section == .vera {
            openVeraThread()
        } else if selectedID == nil {
            newConversation()
        }
    }
}
