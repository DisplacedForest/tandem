import Foundation

@MainActor
enum CompanionLibraryKeepFixture {
    struct Seeded {
        let store: ChatStore
        let repository: LocalChatRepository
        let directory: URL
    }

    static func store(name: String?) throws -> Seeded {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-keep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try LocalChatRepository(inMemory: true, artifactDirectory: directory)
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository,
                              nativeAssistantName: name, attachmentStore: NativeAttachmentStore(directory: directory),
                              artifactPersistenceEnabled: false)
        store.ensureVeraThread()
        return Seeded(store: store, repository: repository, directory: directory)
    }

    static func save(_ store: ChatStore, title: String, conversationID: String) {
        store.recordTaskArtifacts([NativeDisplayBlock.artifact(NativeResearchArtifact(id: "keep-\(UUID().uuidString)", title: title,
                                                                                      report: "# \(title)\n\nNoted.", sources: []))],
                                  conversationID: conversationID, messageID: UUID().uuidString)
    }

    static func saveOldWay(_ repository: any ArtifactRepository, title: String, conversationID: String, copiedName: String) throws {
        _ = try repository.recordArtifact(ArtifactDraft(kind: .document, title: title, conversationID: conversationID, originTitle: copiedName,
                                                        messageID: nil, sourceKey: "keep-old-\(UUID().uuidString)", data: Data("# \(title)".utf8),
                                                        mime: "text/markdown", fileExtension: "md"), revising: nil)
    }

    static func shown(_ store: ChatStore, filter: String?) -> [String] {
        ArtifactLibrarySelection(conversationFilter: filter)
            .visible(store.artifactRecords, companionName: store.companionName, companionThreadID: store.veraThreadID)
            .map(\.title)
    }

    static func startOver(_ store: ChatStore, name: String?) {
        store.adoptAssistantName(name)
        store.ensureVeraThread()
        guard let thread = store.veraThreadID, let repository = store.artifactRepository else { return }
        save(store, title: "Frost checklist", conversationID: thread)
        try? saveOldWay(repository, title: "Seed order notes", conversationID: thread, copiedName: name ?? "Your companion")
        store.resetDot()
        store.reloadArtifacts()
    }
}

@MainActor
extension SelfTest {
    static func runCompanionLibraryKeep() async throws {
        try libraryKeepFilterTable()
        try libraryKeepSelection()
        try libraryKeepThreadChange()
        for name in ["Ada", nil] as [String?] {
            try libraryKeepReset(name: name)
            try await libraryKeepFailedReset(name: name)
            try await libraryKeepOrder(name: name)
            try await libraryKeepNoCompanion(name: name)
        }
        print("  companion library keep OK (filter table, selection with a kept item, companion conversation gone and back, start over marks kept items, old copies, new thread, panel outputs, ordinary chats, second start over, a failed keep removes nothing, keeping runs before removal, no companion conversation)")
    }

    private struct KeepFailure: LocalizedError {
        var errorDescription: String? { "The disk is full." }
    }

    private final class KeepSighting {
        var conversation = false
        var schedule = false
        var memory = false
        var called = false
    }

    private static func connectedStore(name: String?) async throws -> (ChatStore, LocalChatRepository, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("library-keep-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let repository = try LocalChatRepository(url: folder.appendingPathComponent("vera.sqlite"), artifactDirectory: folder)
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeAssistantName: name,
                              attachmentStore: NativeAttachmentStore(directory: folder), artifactPersistenceEnabled: false)
        await store.connect()
        store.nativeSchedulerLoop?.cancel()
        await store.nativeSchedulerLoop?.value
        store.nativeSchedulerLoop = nil
        store.ensureVeraThread()
        return (store, repository, folder)
    }

    private static let keepGoal = "Keep the greenhouse on track this season."

    private static func seedCompanionWork(_ store: ChatStore, _ repository: LocalChatRepository, thread: String, label: String) throws -> String {
        CompanionLibraryKeepFixture.save(store, title: "Frost checklist", conversationID: thread)
        try CompanionLibraryKeepFixture.saveOldWay(repository, title: "Old note", conversationID: thread, copiedName: label)
        let now = Date()
        try repository.saveMemory(NativeMemoryRecord(id: "keep-memory", title: "Vents", summary: "Vents stick", details: ["Vents stick"],
                                                     group: .areas, category: .goal, bank: "home", durability: .durable, expiry: nil,
                                                     status: .approved, embedding: nil, sourceConversationID: thread, sourceMessageID: nil,
                                                     createdAt: now, updatedAt: now),
                                  decision: .accepted, note: "Fixture")
        var draft = NativeScheduleDraft()
        draft.title = "Weekly greenhouse note"
        draft.instruction = "Write the weekly greenhouse note"
        draft.owner = .dot
        guard let schedule = store.createSchedule(draft) else { throw NativeTaskFixture.Failure.assertion("The companion schedule saves") }
        store.saveDotProfile { $0.goal = keepGoal }
        store.reloadArtifacts()
        return schedule.id
    }

    private static func memoryAlive(_ repository: LocalChatRepository) -> Bool {
        ((try? repository.allMemories()) ?? []).contains { (memory: NativeMemoryRecord) -> Bool in memory.id == "keep-memory" && memory.status != .deleted }
    }

    private static func stored(_ store: ChatStore, _ repository: LocalChatRepository, _ title: String) throws -> ArtifactRecord {
        guard let found = store.artifactRecords.first(where: { $0.title == title }), let record = try repository.artifact(found.id) else {
            throw NativeTaskFixture.Failure.assertion("The \(title) item exists")
        }
        return record
    }

    private static func libraryKeepFailedReset(name: String?) async throws {
        let require = NativeTaskFixture.require
        let label = name ?? "Your companion"
        let (store, repository, folder) = try await connectedStore(name: name)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let thread = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion thread exists") }
        let scheduleID = try seedCompanionWork(store, repository, thread: thread, label: label)
        let frostBefore = try stored(store, repository, "Frost checklist")
        let oldBefore = try stored(store, repository, "Old note")
        store.companionArtifactKeeper = { (_: String) throws -> Void in throw KeepFailure() }
        store.resetDot()
        try require(store.veraThreadID == thread && store.conversations.contains { $0.id == thread },
                    "A failed keep leaves the companion's conversation in place for \(label)")
        let frost = try stored(store, repository, "Frost checklist")
        let old = try stored(store, repository, "Old note")
        try require(frost.conversationID == thread && frost.originTitle == frostBefore.originTitle
                    && old.conversationID == thread && old.originTitle == oldBefore.originTitle && old.originTitle == label,
                    "A failed keep leaves both items' link and stored origin exactly as they were")
        try require(store.schedules.contains { $0.id == scheduleID } && memoryAlive(repository) && store.dotProfile.goal == keepGoal,
                    "A failed keep removes no schedule, memory or goal")
        try require(store.chatConfigurationError == "\(label) couldn't start over: The disk is full. Nothing was removed.",
                    "The failure reads plainly: \(store.chatConfigurationError ?? "nil")")
        try require(store.companionConfigurationError?.lead == CompanionErrorCopy.resetLead, "The failure is kept as the reset error")
        store.companionArtifactKeeper = nil
        store.resetDot()
        guard let fresh = store.veraThreadID, fresh != thread else { throw NativeTaskFixture.Failure.assertion("The retry starts over") }
        for title in ["Frost checklist", "Old note"] {
            let kept = try stored(store, repository, title)
            try require(kept.conversationID == nil && kept.originTitle == CompanionSavedText.marker, "The retry keeps \(title) as the companion's")
        }
        try require(Set(CompanionLibraryKeepFixture.shown(store, filter: fresh)) == ["Frost checklist", "Old note"],
                    "After the retry both items match the companion filter for the new conversation")
        try require(store.companionConfigurationError?.lead != CompanionErrorCopy.resetLead
                    && !(store.chatConfigurationError ?? "").contains("couldn't start over"),
                    "The retry clears the reset error: \(store.chatConfigurationError ?? "nil")")
        try require(!store.schedules.contains { $0.id == scheduleID } && !memoryAlive(repository) && store.dotProfile.goal.isEmpty,
                    "The retry removes what start over removes")
    }

    private static func libraryKeepOrder(name: String?) async throws {
        let require = NativeTaskFixture.require
        let label = name ?? "Your companion"
        let (store, repository, folder) = try await connectedStore(name: name)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let thread = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion thread exists") }
        let scheduleID = try seedCompanionWork(store, repository, thread: thread, label: label)
        let sighting = KeepSighting()
        store.companionArtifactKeeper = { [weak store] (id: String) throws -> Void in
            guard let store else { return }
            sighting.called = true
            sighting.conversation = store.conversations.contains { $0.id == id } && ((try? repository.messages(conversationID: id)) != nil)
                && store.veraThreadID == id
            sighting.schedule = ((try? store.nativeScheduleStore?.all()) ?? []).contains { $0.id == scheduleID }
            sighting.memory = memoryAlive(repository)
            _ = try repository.resolveArtifacts(conversationID: id, choice: .keepAsCompanion)
        }
        store.resetDot()
        try require(sighting.called && sighting.conversation && sighting.schedule && sighting.memory,
                    "Keeping runs while the conversation, schedule and memory still exist")
        try require(store.veraThreadID != thread && !store.schedules.contains { $0.id == scheduleID } && !memoryAlive(repository),
                    "Removal follows the keep")
        try require(try stored(store, repository, "Old note").originTitle == CompanionSavedText.marker, "The keep the seam ran marked the items")
    }

    private static func libraryKeepNoCompanion(name: String?) async throws {
        let require = NativeTaskFixture.require
        let label = name ?? "Your companion"
        let (store, repository, folder) = try await connectedStore(name: name)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let thread = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion thread exists") }
        CompanionLibraryKeepFixture.save(store, title: "Frost checklist", conversationID: thread)
        let doomed = Conversation(id: "keep-none-doomed", title: "Seed swap", messages: [], updatedAt: Date())
        try repository.saveConversation(doomed)
        store.conversations.append(doomed)
        CompanionLibraryKeepFixture.save(store, title: "Swap list", conversationID: doomed.id)
        store.requestDeleteConversation(doomed.id)
        store.confirmDeleteConversation(.keep)
        try await repository.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER keep_fail_companion BEFORE INSERT ON conversations WHEN NEW.origin_type = 'assistant'
                BEGIN SELECT RAISE(ABORT, 'The disk is full.'); END
                """)
        }
        store.resetDot()
        try require(store.veraThreadID == nil, "The replacement conversation could not be created for \(label)")
        let kept = try stored(store, repository, "Frost checklist")
        let swap = try stored(store, repository, "Swap list")
        try require(kept.conversationID == nil && kept.originTitle == CompanionSavedText.marker
                    && swap.conversationID == nil && swap.originTitle == "Seed swap", "Both unlinked items exist with their stored origins")
        try require(store.companionOverviewModel().outputs.isEmpty, "With no companion conversation the panel lists no outputs")
        try await repository.database.write { db in try db.execute(sql: "DROP TRIGGER keep_fail_companion") }
        store.ensureVeraThread()
        guard let fresh = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion conversation comes back") }
        CompanionLibraryKeepFixture.save(store, title: "Vent schedule", conversationID: fresh)
        store.reloadArtifacts()
        try require(store.companionOverviewModel().outputs.map(\.title) == ["Vent schedule"], "Once it is back the panel lists only the new item")
        try require(Set(CompanionLibraryKeepFixture.shown(store, filter: fresh)) == ["Frost checklist", "Vent schedule"],
                    "The companion filter shows the kept and new items but not the deleted chat's")
    }

    private static func libraryKeepThreadChange() throws {
        let require = NativeTaskFixture.require
        let marker = CompanionSavedText.marker
        let old = "keep-old-companion"
        let new = "keep-new-companion"
        let ordinary = "keep-ordinary"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func item(_ id: String, link: String?, origin: String?) -> ArtifactRecord {
            ArtifactRecord(id: id, kind: .document, title: id, conversationID: link, originTitle: origin, createdAt: date, updatedAt: date, versionCount: 1)
        }
        let kept = item("kept", link: nil, origin: marker)
        let deleted = item("deleted-chat", link: nil, origin: "Seed swap")
        let linked = item("ordinary", link: ordinary, origin: "Greenhouse plan")
        let fresh = item("fresh", link: new, origin: marker)
        let records = [kept, deleted, linked, fresh]

        var state = ArtifactLibrarySelection(conversationFilter: old)
        state.companionThreadChanged(from: old, to: nil)
        try require(state.conversationFilter == old && state.holdsCompanionFilter, "Losing the companion conversation keeps the filter and remembers it")
        try require(state.visible([kept, deleted, linked], companionThreadID: nil).map(\.id) == ["kept"],
                    "With no companion conversation the held filter still shows the kept item and hides the others")
        state.companionThreadChanged(from: nil, to: new)
        try require(state.conversationFilter == new && !state.holdsCompanionFilter, "A new companion conversation takes over the held filter")
        try require(state.visible(records, companionThreadID: new).map(\.id) == ["kept", "fresh"], "Kept and new items show together")

        state = ArtifactLibrarySelection(conversationFilter: old)
        state.companionThreadChanged(from: old, to: nil)
        state.conversationFilter = nil
        try require(!state.holdsCompanionFilter, "Clearing the filter clears the flag")
        state.companionThreadChanged(from: nil, to: new)
        try require(state.conversationFilter == nil, "A cleared filter stays cleared when the companion comes back")

        state = ArtifactLibrarySelection(conversationFilter: old)
        state.companionThreadChanged(from: old, to: new)
        try require(state.conversationFilter == new && !state.holdsCompanionFilter, "The direct move from old to new still works")

        for (from, to) in [(old, nil), (nil, new), (old, new), (nil, nil)] as [(String?, String?)] {
            state = ArtifactLibrarySelection(conversationFilter: ordinary)
            state.companionThreadChanged(from: from, to: to)
            try require(state.conversationFilter == ordinary && !state.holdsCompanionFilter,
                        "An ordinary filter is untouched by a companion change from \(from ?? "none") to \(to ?? "none")")
            try require(state.visible(records, companionThreadID: to).map(\.id) == ["ordinary"], "An ordinary filter still shows only its own item")
        }
    }

    private static func libraryKeepFilterTable() throws {
        let require = NativeTaskFixture.require
        let marker = CompanionSavedText.marker
        let companion = "keep-companion"
        let ordinary = "keep-ordinary"
        func item(_ id: String, link: String?, origin: String?) -> ArtifactRecord {
            ArtifactRecord(id: id, kind: .document, title: id, conversationID: link, originTitle: origin,
                           createdAt: Date(), updatedAt: Date(), versionCount: 1)
        }
        let rows: [(String?, ArtifactRecord, Bool)] = [
            (companion, item("linked", link: companion, origin: marker), true),
            (companion, item("elsewhere", link: ordinary, origin: "Greenhouse plan"), false),
            (companion, item("unlinked-marker", link: nil, origin: marker), true),
            (companion, item("unlinked-name", link: nil, origin: "Ada"), false),
            (ordinary, item("linked", link: ordinary, origin: "Greenhouse plan"), true),
            (ordinary, item("elsewhere", link: companion, origin: marker), false),
            (ordinary, item("unlinked-marker", link: nil, origin: marker), false),
            (ordinary, item("unlinked-name", link: nil, origin: "Greenhouse plan"), false),
            (nil, item("linked", link: companion, origin: marker), true),
            (nil, item("elsewhere", link: ordinary, origin: "Greenhouse plan"), true),
            (nil, item("unlinked-marker", link: nil, origin: marker), true),
            (nil, item("unlinked-name", link: nil, origin: "Ada"), true),
        ]
        for (filter, record, expected) in rows {
            let shown = !ArtifactLibrarySelection(conversationFilter: filter).visible([record], companionThreadID: companion).isEmpty
            try require(shown == expected, "Filter \(filter ?? "none") on \(record.id) shows \(expected)")
            if let filter {
                try require(ArtifactLibrarySelection.matches(record, conversation: filter, companionThreadID: companion) == expected,
                            "The match function agrees for \(filter) on \(record.id)")
            }
        }
        try require(!ArtifactLibrarySelection.matches(item("unlinked-marker", link: nil, origin: marker), conversation: companion, companionThreadID: nil),
                    "Without a companion conversation an unlinked marker item matches no filter")
    }

    private static func libraryKeepSelection() throws {
        let require = NativeTaskFixture.require
        let marker = CompanionSavedText.marker
        let companion = "keep-companion"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let kept = ArtifactRecord(id: "kept", kind: .document, title: "Frost checklist", conversationID: nil, originTitle: marker,
                                  createdAt: date, updatedAt: date, versionCount: 1)
        let fresh = ArtifactRecord(id: "fresh", kind: .document, title: "Vent schedule", conversationID: companion, originTitle: marker,
                                   createdAt: date, updatedAt: date, versionCount: 1)
        let other = ArtifactRecord(id: "other", kind: .document, title: "Heating options", conversationID: "keep-ordinary",
                                   originTitle: "Greenhouse plan", createdAt: date, updatedAt: date, versionCount: 1)
        let records = [fresh, kept, other]
        var state = ArtifactLibrarySelection(selectedID: "kept", conversationFilter: companion)
        state.reconcile(records, companionThreadID: companion)
        try require(state.conversationFilter == companion && state.selectedID == "kept"
                    && state.selected(in: records, companionThreadID: companion)?.id == "kept",
                    "Reconcile keeps the companion filter and the kept item selected")
        try require(state.resolved(in: records, companionThreadID: companion)?.id == "kept", "The kept item resolves under the companion filter")
        state = ArtifactLibrarySelection(conversationFilter: companion)
        try require(state.open("kept", in: records, companionThreadID: companion) && state.conversationFilter == companion
                    && state.selectedID == "kept", "Opening a kept item keeps the companion filter")
        state = ArtifactLibrarySelection()
        state.apply(conversation: companion, open: "kept", in: records, companionThreadID: companion)
        try require(state.conversationFilter == companion && state.selectedID == "kept", "Adopting the companion and opening a kept item keep both")
        state = ArtifactLibrarySelection(conversationFilter: companion)
        try require(state.open("other", in: records, companionThreadID: companion) && state.conversationFilter == nil
                    && state.selectedID == "other", "Opening an ordinary chat's item still drops the companion filter")
        state = ArtifactLibrarySelection(selectedID: "kept", conversationFilter: companion)
        state.reconcile(records)
        try require(state.selectedID == "fresh", "Without knowing the companion conversation only linked items match, as before")
    }

    private static func libraryKeepReset(name: String?) throws {
        let require = NativeTaskFixture.require
        let marker = CompanionSavedText.marker
        let label = name ?? "Your companion"
        let seeded = try CompanionLibraryKeepFixture.store(name: name)
        defer { try? FileManager.default.removeItem(at: seeded.directory) }
        let store = seeded.store
        let repository = seeded.repository
        guard let first = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion thread exists") }
        let ordinary = Conversation(id: "keep-ordinary", title: "Greenhouse plan", messages: [], updatedAt: Date())
        let impostor = Conversation(id: "keep-impostor", title: marker, messages: [], updatedAt: Date())
        let doomed = Conversation(id: "keep-doomed", title: "Seed swap", messages: [], updatedAt: Date())
        for conversation in [ordinary, impostor, doomed] {
            try repository.saveConversation(conversation)
            store.conversations.append(conversation)
        }
        CompanionLibraryKeepFixture.save(store, title: "Frost checklist", conversationID: first)
        try CompanionLibraryKeepFixture.saveOldWay(repository, title: "Old note", conversationID: first, copiedName: label)
        CompanionLibraryKeepFixture.save(store, title: "Heating options", conversationID: ordinary.id)
        CompanionLibraryKeepFixture.save(store, title: "Impostor note", conversationID: impostor.id)
        CompanionLibraryKeepFixture.save(store, title: "Swap list", conversationID: doomed.id)
        store.reloadArtifacts()
        func record(_ title: String) throws -> ArtifactRecord {
            guard let found = store.artifactRecords.first(where: { $0.title == title }),
                  let stored = try repository.artifact(found.id) else {
                throw NativeTaskFixture.Failure.assertion("The \(title) item exists")
            }
            return stored
        }
        func companionShown() -> Set<String> { Set(CompanionLibraryKeepFixture.shown(store, filter: store.veraThreadID)) }
        let ordinaryTitles: Set<String> = ["Heating options", "Impostor note", "Swap list"]
        func requireNoOrdinary(_ stage: String) throws {
            try require(companionShown().isDisjoint(with: ordinaryTitles), "No ordinary chat item matches the companion filter \(stage) for \(label)")
        }

        try require(companionShown() == ["Frost checklist", "Old note"], "Before start over the companion filter lists its linked items for \(label)")
        try require(try record("Impostor note").originTitle == "companion", "A chat titled with the marker stores the plain text")
        try requireNoOrdinary("before start over")

        let swapOrigin = try record("Swap list").originTitle
        store.requestDeleteConversation(doomed.id)
        store.confirmDeleteConversation(.keep)
        store.reloadArtifacts()
        let swap = try record("Swap list")
        try require(swap.conversationID == nil && swap.originTitle == swapOrigin && swapOrigin == "Seed swap",
                    "Deleting an ordinary chat with keep leaves its origin exactly as stored: \(swap.originTitle ?? "nil")")
        try requireNoOrdinary("after an ordinary delete")

        store.resetDot()
        guard let second = store.veraThreadID, second != first else {
            throw NativeTaskFixture.Failure.assertion("Start over makes a new companion conversation")
        }
        for title in ["Frost checklist", "Old note"] {
            let kept = try record(title)
            try require(kept.conversationID == nil && kept.originTitle == marker && store.artifactOriginLabel(kept) == label,
                        "\(title) is kept unlinked with the marker and reads \(label): \(kept.originTitle ?? "nil")")
        }
        try require(companionShown() == ["Frost checklist", "Old note"], "Kept items match the companion filter for the new conversation for \(label)")
        try require(CompanionLibraryKeepFixture.shown(store, filter: first).isEmpty, "The discarded conversation id matches nothing")
        try require(store.companionOverviewModel().outputs.isEmpty, "The panel lists nothing after start over although kept items exist")
        try require(try record("Swap list").originTitle == "Seed swap" && (try record("Heating options")).originTitle == "Greenhouse plan",
                    "Start over leaves ordinary origins alone")
        try requireNoOrdinary("after start over")

        CompanionLibraryKeepFixture.save(store, title: "Vent schedule", conversationID: second)
        store.reloadArtifacts()
        try require(companionShown() == ["Frost checklist", "Old note", "Vent schedule"], "The new item and the kept ones show together for \(label)")
        try require(store.companionOverviewModel().outputs.map(\.title) == ["Vent schedule"], "The panel lists only the new item")
        try require(CompanionLibraryKeepFixture.shown(store, filter: ordinary.id) == ["Heating options"], "An ordinary chat's filter is unchanged")
        try requireNoOrdinary("after a new item")

        store.resetDot()
        guard let third = store.veraThreadID, third != second else {
            throw NativeTaskFixture.Failure.assertion("A second start over makes another conversation")
        }
        try require(companionShown() == ["Frost checklist", "Old note", "Vent schedule"], "A second start over keeps both generations in the filter for \(label)")
        let vent = try record("Vent schedule")
        try require(vent.conversationID == nil && vent.originTitle == marker && store.artifactOriginLabel(vent) == label,
                    "The second generation's item is kept with the marker")
        try require(store.companionOverviewModel().outputs.isEmpty, "The panel is empty again after the second start over")
        try require(!store.artifactOriginLine(try record("Heating options")).parts.contains(.name), "An ordinary item never shows the companion's name")
        try requireNoOrdinary("after the second start over")
    }
}
