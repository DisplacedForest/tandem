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
                dotProfile = NativeDotProfile()
                chatConfigurationError = "\(assistantName)'s goal and settings couldn't load: \(error.localizedDescription)"
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
        saveDotProfile { $0.state = state }
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
        var summary = NativeDotRemovalSummary(hasGoal: dotProfile.hasGoal)
        summary.artifacts = artifactLibrary.count
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
        discardVeraThread()
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
