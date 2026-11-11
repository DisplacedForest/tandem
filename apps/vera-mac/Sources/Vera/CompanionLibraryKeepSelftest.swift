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
    static func runCompanionLibraryKeep() throws {
        try libraryKeepFilterTable()
        try libraryKeepSelection()
        for name in ["Ada", nil] as [String?] { try libraryKeepReset(name: name) }
        print("  companion library keep OK (filter table, selection with a kept item, start over marks kept items, old copies, new thread, panel outputs, ordinary chats, second start over)")
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
