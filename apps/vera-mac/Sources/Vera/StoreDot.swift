import Foundation

struct CompanionConfigurationError: Equatable, Sendable {
    var lead: String
    var detail: String

    var line: CompanionLine { .namedThenText(lead, detail) }
    func plain(name: String?) -> String { line.plain(name: name) }
}

enum CompanionErrorCopy {
    static let loadLead = "{name}'s settings couldn't load: "
    static let loadTail = " Scheduled work is paused and no services are connected until the settings are saved again."
    static let saveLead = "{name}'s settings couldn't be saved: "
    static let clearLead = "{name}'s settings couldn't be cleared: "
    static let threadLead = "{name}'s thread couldn't be created: "
    static let resetLead = "{name} couldn't start over: "
    static let resetTail = " Nothing was removed."
}

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
                resolveCompanionConfigurationError(CompanionErrorCopy.loadLead)
            } catch {
                dotProfile = NativeDotProfile(connectedToolIDs: [], state: .paused, setupCompleted: true)
                reportCompanionConfigurationError(CompanionErrorCopy.loadLead, description: error.localizedDescription,
                                                  tail: CompanionErrorCopy.loadTail)
            }
        } else {
            nativeDotProfileStore = nil
            dotProfile = NativeDotProfile()
        }
        dotProfileLoaded = true
        followServiceReports()
    }

    func saveDotProfile(_ mutate: (inout NativeDotProfile) -> Void) {
        var next = dotProfile
        mutate(&next)
        next.updatedAt = Date()
        do {
            try nativeDotProfileStore?.save(next)
        } catch {
            reportCompanionConfigurationError(CompanionErrorCopy.saveLead, description: error.localizedDescription)
            return
        }
        dotProfile = next
        resolveCompanionConfigurationError(CompanionErrorCopy.saveLead)
    }

    func followServiceReports() {
        serviceReports = nativeMCP?.$servers.sink { [weak self] servers in
            MainActor.assumeIsolated { self?.connectReportedTools(servers) }
        }
    }

    func connectAddedService(_ serverID: String, scopes: Set<String>) {
        guard !scopes.isDisjoint(with: IntegrationsText.companionScopes),
              let saved = try? nativeDotProfileStore?.load(), saved.connectedToolIDs != nil else { return }
        saveDotProfile {
            $0.connectedToolIDs?.remove(Self.leftMarker(serverID))
            $0.connectedToolIDs?.insert(Self.serviceMarker(serverID))
        }
        connectReportedTools(nativeMCP?.servers ?? [])
    }

    func connectReportedTools(_ servers: [NativeMCPServerState]) {
        guard let connected = dotProfile.connectedToolIDs else { return }
        var joined = connected
        for server in servers where server.connected && Self.chosen(server, in: connected) {
            joined.insert(Self.serviceMarker(server.id))
            joined.formUnion(server.tools.map(\.id))
        }
        guard joined != connected else { return }
        saveDotProfile { $0.connectedToolIDs = joined }
    }

    private static func serviceMarker(_ id: String) -> String { "service:" + id }

    private static func leftMarker(_ id: String) -> String { "left:" + id }

    private static func ownedToolIDs(_ server: NativeMCPServerState) -> Set<String> {
        let declared = server.configuration.readTools.union(server.configuration.actTools).map(server.configuration.toolID)
        return Set(server.tools.map(\.id)).union(declared)
    }

    private static func chosen(_ server: NativeMCPServerState, in connected: Set<String>) -> Bool {
        if connected.contains(serviceMarker(server.id)) { return true }
        return !connected.contains(leftMarker(server.id)) && !connected.isDisjoint(with: ownedToolIDs(server))
    }

    func completeDotSetup(connectedToolIDs: Set<String>?) {
        saveDotProfile {
            $0.connectedToolIDs = connectedToolIDs
            $0.setupCompleted = true
        }
    }

    func skipDotSetup() {
        saveDotProfile { $0.setupCompleted = true }
    }

    func setDotState(_ state: NativeDotState) {
        guard dotProfile.state != state else { return }
        let now = Date()
        let resuming = dotProfile.state == .paused && state == .active
        if resuming {
            skipMissedDotRuns(now: now)
        }
        saveDotProfile {
            $0.state = state
            if resuming { $0.resumedAt = now }
        }
    }

    func skipMissedDotRuns(now: Date) {
        guard let store = nativeScheduleStore else { return }
        for var schedule in (try? store.all()) ?? [] where schedule.runsAsCompanion && schedule.enabled {
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
        if let stored = turn.dotContext { return NativeDotContext.retired(stored) }
        guard isVeraThread(turn.conversationID) else { return nil }
        return dotContext(for: turn.conversationID, requestText: typedWords(for: turn).said)
    }

    func memorySourceIsLive(_ source: NativeMemoryTurnSource?, generation: Int, wasVeraThread: Bool) -> Bool {
        guard let source else { return true }
        if wasVeraThread && generation != dotResetGeneration { return false }
        return !discardedConversationIDs.contains(source.conversationID)
    }

    func dotToolIDs(base: Set<String>) -> Set<String> {
        guard let connected = dotProfile.connectedToolIDs else { return base }
        var allowed = dotProfile.toolIDs(base: base)
        for server in nativeMCP?.authority.access.snapshot() ?? [] where connected.contains(Self.leftMarker(server.id)) {
            allowed.subtract(server.tools.map(\.id))
        }
        return allowed
    }

    func dotContext(for conversationID: String, requestText: String) -> String? {
        guard isVeraThread(conversationID) else { return nil }
        return NativeDotContext.render(resolver: ruleResolver(for: conversationID, requestText: requestText))
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
        let left = (nativeMCP?.servers ?? []).filter { connected.contains(Self.leftMarker($0.id)) }.map { Self.serviceMarker($0.id) }
        return Set(options.filter { connected.contains($0.id) || (!left.contains($0.id) && !$0.toolIDs.isDisjoint(with: connected)) }.map(\.id))
    }

    func dotConnectedToolIDs(selected: Set<String>, options: [NativeDotServiceOption]) -> Set<String>? {
        let picked = options.filter { selected.contains($0.id) }
        let visible = Set(options.map(\.id))
        let hidden = (nativeMCP?.servers ?? []).filter { !visible.contains(Self.serviceMarker($0.id)) }
        let saved = dotProfile.connectedToolIDs
        let kept = hidden.filter { server in saved.map { Self.chosen(server, in: $0) } ?? true }
        let unresolved = saved.map { saved in
            hidden.contains { server in
                !Self.chosen(server, in: saved) && !saved.contains(Self.leftMarker(server.id)) && server.configuration.reportsTools && server.tools.isEmpty
            }
        } ?? false
        if picked.count == options.count, kept.count == hidden.count { return nil }
        var result = Set<String>()
        for server in kept {
            result.insert(Self.serviceMarker(server.id))
            result.formUnion(Self.ownedToolIDs(server).intersection(saved ?? []))
        }
        for server in hidden where saved?.contains(Self.leftMarker(server.id)) == true { result.insert(Self.leftMarker(server.id)) }
        if !hidden.isEmpty, let saved {
            var shown = options.reduce(into: Set<String>()) { $0.formUnion($1.toolIDs) }
            for server in nativeMCP?.servers ?? [] { shown.formUnion(Self.ownedToolIDs(server)) }
            result.formUnion(saved.subtracting(shown).filter { id in
                !id.hasPrefix("service:") && !id.hasPrefix("left:") && (unresolved || !id.hasPrefix("mcp_"))
            })
        }
        let servers = nativeMCP?.servers ?? []
        for option in options where option.id.hasPrefix("service:") && !selected.contains(option.id) {
            result.insert(Self.leftMarker(String(option.id.dropFirst("service:".count))))
        }
        for option in picked {
            if option.id.hasPrefix("service:") { result.insert(option.id) }
            result.formUnion(option.toolIDs)
            if let server = servers.first(where: { Self.serviceMarker($0.id) == option.id }) { result.formUnion(server.tools.map(\.id)) }
        }
        return result
    }

    func dotRemovalSummary() -> NativeDotRemovalSummary {
        var summary = NativeDotRemovalSummary(services: dotProfile.connectedToolIDs != nil)
        summary.artifacts = veraThreadID.flatMap { try? artifactRepository?.artifactIDs(conversationID: $0).count } ?? 0
        summary.schedules = ((try? nativeScheduleStore?.all()) ?? schedules).filter(\.runsAsCompanion).count
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

    var resetFailure: CompanionConfigurationError? {
        companionConfigurationError.flatMap { (error: CompanionConfigurationError) -> CompanionConfigurationError? in
            error.lead == CompanionErrorCopy.resetLead ? error : nil
        }
    }

    func acknowledgeResetFailure() {
        resolveCompanionConfigurationError(CompanionErrorCopy.resetLead)
    }

    func keepCompanionArtifacts(threadID: String) throws {
        if let companionArtifactKeeper { return try companionArtifactKeeper(threadID) }
        _ = try artifactRepository?.resolveArtifacts(conversationID: threadID, choice: .keepAsCompanion)
    }

    @discardableResult
    func resetDot() -> Bool {
        let threadID = veraThreadID
        if let threadID {
            do {
                try keepCompanionArtifacts(threadID: threadID)
                resolveCompanionConfigurationError(CompanionErrorCopy.resetLead)
            } catch {
                reloadArtifacts()
                reportCompanionConfigurationError(CompanionErrorCopy.resetLead, description: error.localizedDescription,
                                                  tail: CompanionErrorCopy.resetTail)
                return false
            }
        }
        let viewing = section
        let wasShowing = threadID != nil && selectedID == threadID && (viewing == .vera || viewing == .chat)
        dotResetGeneration += 1
        suspendsTurnScheduling = true
        cancelCompanionWork()
        if let threadID {
            for turn in conversationTurns where turn.conversationID == threadID {
                stopAnswer(turn.assistantMessageID)
            }
        }
        for schedule in ((try? nativeScheduleStore?.all()) ?? schedules) where schedule.runsAsCompanion {
            deleteSchedule(schedule.id)
        }
        if let threadID, let memoryRepository = repository as? any NativeMemoryRepository {
            let note = "Removed when the companion started over"
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
        reloadArtifacts()
        suspendsTurnScheduling = false
        scheduleConversationTurns()
        do {
            try nativeDotProfileStore?.reset()
            resolveCompanionConfigurationError(CompanionErrorCopy.clearLead)
        } catch {
            reportCompanionConfigurationError(CompanionErrorCopy.clearLead, description: error.localizedDescription)
        }
        dotProfile = NativeDotProfile()
        dotProfile.needsIntroduction = true
        do { try nativeDotProfileStore?.save(dotProfile) }
        catch { chatConfigurationError = "The fresh profile couldn't save: \(error.localizedDescription)" }
        ensureVeraThread()
        syncRuleSource()
        reloadNativeMemory()
        if wasShowing || section == .vera {
            openVeraThread()
        } else if selectedID == nil {
            newConversation()
            section = viewing
        }
        return true
    }
}
