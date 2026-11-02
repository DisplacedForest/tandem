import Foundation

final class ArtifactScriptTransport: NativeChatTransport, @unchecked Sendable {
    enum Step: Sendable {
        case reply(String)
        case interrupt(String)
        case fail
        case hold(String)
    }

    private let lock = NSLock()
    private var captured: [[NativeChatMessage]] = []
    private var steps: [Step] = []
    private var held: [AsyncThrowingStream<NativeChatStreamSnapshot, Error>.Continuation] = []

    var histories: [[NativeChatMessage]] { withLock { captured } }

    func queue(_ step: Step) { withLock { steps.append(step) } }

    func releaseHeld() {
        let pending = withLock { () -> [AsyncThrowingStream<NativeChatStreamSnapshot, Error>.Continuation] in
            defer { held = [] }
            return held
        }
        for continuation in pending { continuation.finish() }
    }

    func discoverModels() async throws -> [String] { ["local-model"] }

    func stream(
        messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]
    ) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        let step = withLock { () -> Step in
            captured.append(messages)
            return steps.isEmpty ? .reply("Native reply") : steps.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            switch step {
            case .reply(let content):
                continuation.yield(NativeChatStreamSnapshot(content: content, toolCalls: [], finishReason: "stop"))
                continuation.finish()
            case .interrupt(let content):
                continuation.yield(NativeChatStreamSnapshot(content: content, toolCalls: [], finishReason: nil))
                continuation.finish(throwing: NativeChatClient.ClientError.server("test interruption"))
            case .fail:
                continuation.finish(throwing: NativeChatClient.ClientError.server("test failure"))
            case .hold(let content):
                continuation.yield(NativeChatStreamSnapshot(content: content, toolCalls: [], finishReason: nil))
                self.withLock { self.held.append(continuation) }
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

enum ArtifactProducerSelftest {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    @MainActor
    static func waitForReply(_ store: ChatStore, conversationID: String) async throws {
        for _ in 0..<500 {
            if let reply = store.conversations.first(where: { $0.id == conversationID })?.messages.last,
               reply.role == .assistant, reply.state == .complete || reply.state == .interrupted {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(description: "The reply never finished")
    }

    @MainActor
    static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(description: message)
    }

    @MainActor
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vera-artifact-producers-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalChatRepository(inMemory: true, artifactDirectory: directory)
        let transport = ArtifactScriptTransport()
        let config = NativeChatConfig(
            baseURL: URL(string: "https://model.example/v1")!, apiKey: nil,
            model: "local-model", chatTemplateKwargs: nil)
        let store = ChatStore(
            nativeConfig: config, nativeTransport: transport, repository: repository,
            attachmentStore: NativeAttachmentStore(directory: directory), artifactPersistenceEnabled: false)

        func fileExists(_ version: ArtifactVersion) -> Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(version.fileName).path)
        }

        store.newConversation()
        try check(store.sendText("Plan the trip"), "The first message sends")
        guard let conversationID = store.selectedID else { throw Failure(description: "No conversation is selected") }
        try await waitForReply(store, conversationID: conversationID)
        try check(store.artifactRecords.isEmpty, "A plain reply records no artifact")
        guard let turn = try repository.conversationTurns().last(where: { $0.conversationID == conversationID }) else {
            throw Failure(description: "The accepted turn is missing")
        }
        let messageID = turn.assistantMessageID.uuidString

        let edited = NativeFileChange(
            id: "change-1", path: "/tmp/notes/plan.md", kind: .edited, before: "# Old", after: "# New")
        store.attachDisplayBlock(.fileChange(edited), turn: turn)
        store.attachDisplayBlock(
            .fileChange(NativeFileChange(id: "change-2", path: "/tmp/notes/drafts", kind: .directory)), turn: turn)
        let fileRecords = store.artifactRecords.filter { $0.kind == .fileChange }
        try check(fileRecords.count == 1, "Only the edited file records an artifact")
        try check(fileRecords[0].title == "Edited plan.md" && fileRecords[0].conversationID == conversationID,
                  "The file change keeps its title and chat")
        let fileVersion = store.artifactVersions(fileRecords[0].id).first
        try check(fileVersion?.details.filePath == "/tmp/notes/plan.md" && fileVersion?.details.beforeText == "# Old"
                  && fileVersion?.details.changeKind == .edited, "The file change keeps its path and earlier text")
        try check(fileVersion.flatMap { store.artifactText($0) } == "# New", "The file change stores the new text")
        try check(fileVersion?.sourceKey == "file:change-1" && fileVersion?.fileName.hasSuffix(".md") == true,
                  "The file change uses its change id and extension")
        let oversized = String(repeating: "x", count: NativeFileChange.contentCap + 1)
        store.attachDisplayBlock(
            .fileChange(NativeFileChange(id: "change-3", path: "/tmp/notes/huge.md", kind: .edited,
                                         before: oversized, after: oversized + "y")), turn: turn)
        let huge = store.artifactRecords.first { $0.title == "Edited huge.md" }
        let hugeVersion = huge.flatMap { store.artifactVersions($0.id).first }
        try check(hugeVersion?.details.contentAvailable == false && hugeVersion?.details.truncated == true
                  && hugeVersion?.byteSize == 0 && hugeVersion?.details.filePath == "/tmp/notes/huge.md",
                  "An oversized edit records without its contents")
        try check(fileVersion?.details.contentAvailable == true, "A captured edit marks its contents available")
        store.attachDisplayBlock(
            .fileChange(NativeFileChange(id: "change-4", path: "/tmp/notes/old.txt", kind: .trashed, before: "Old notes")), turn: turn)
        let trashed = store.artifactRecords.first { $0.title == "Moved old.txt to the Trash" }
        try check(trashed.flatMap { store.artifactVersions($0.id).first }.flatMap { store.artifactText($0) } == "Old notes",
                  "A trashed file records its earlier text")

        let research = NativeResearchArtifact(
            id: "research-1", title: "Lisbon guide", report: "# Lisbon",
            sources: [PulseSource(n: 1, title: "Guide", url: "https://example.com/lisbon")])
        let update = NativeTaskMessageUpdate(
            conversationID: conversationID, messageID: turn.assistantMessageID, blocks: [.artifact(research)])
        store.applyNativeTaskUpdates([update])
        store.applyNativeTaskUpdates([update])
        let documents = store.artifactRecords.filter { $0.kind == .document }
        try check(documents.count == 1 && documents[0].versionCount == 1, "A research report records one document version")
        guard let document = documents.first else { throw Failure(description: "The document is missing") }
        let documentVersion = store.artifactVersions(document.id).first
        try check(documentVersion?.details.sources.first?.url == "https://example.com/lisbon"
                  && documentVersion?.mime == "text/markdown", "The document keeps its sources")
        let unchanged = NativeResearchArtifact(id: "research-2", title: "Porto guide", report: "# Porto", sources: [])
        if let ci = store.conversations.firstIndex(where: { $0.id == conversationID }),
           let mi = store.conversations[ci].messages.firstIndex(where: { $0.id == turn.assistantMessageID }) {
            store.conversations[ci].messages[mi].displayBlocks = [.artifact(unchanged)]
        }
        store.applyNativeTaskUpdates([NativeTaskMessageUpdate(
            conversationID: conversationID, messageID: turn.assistantMessageID, blocks: [.artifact(unchanged)])])
        try check(store.artifactRecords.contains { $0.kind == .document && $0.title == "Porto guide" },
                  "A task artifact records even when the visible blocks did not change")

        let imageName = "sunset-image.png"
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: directory.appendingPathComponent(imageName))
        let image = MessageAttachment(
            name: "sunset-over-water-1024x1024.png", ext: "PNG", isImage: true, fileName: imageName, mime: "image/png")
        let activity = NativeToolActivity(
            id: "call-1", toolID: "image", name: NativeImageTools.toolName, title: "Image generation", round: 0,
            request: "{\"prompt\":\"A sunset over water\",\"size\":\"1024x1024\"}", result: nil,
            state: .succeeded, confirmationRequired: false)
        store.recordImageArtifact(image, activity: activity, conversationID: conversationID, messageID: messageID)
        store.recordImageArtifact(image, activity: activity, conversationID: conversationID, messageID: messageID)
        let images = store.artifactRecords.filter { $0.kind == .image }
        try check(images.count == 1 && images[0].title == "sunset-over-water-1024x1024", "An image records once, titled without its extension")
        let imageVersion = images.first.flatMap { store.artifactVersions($0.id).first }
        try check(imageVersion?.details.prompt == "A sunset over water" && imageVersion?.details.imageSize == "1024x1024"
                  && imageVersion?.fileName.hasSuffix(".png") == true, "The image keeps its prompt and size")

        store.recordCanvasArtifacts(
            [Artifact(id: "sketch", title: "Sketch", type: .html, language: "", content: "<p>Hi</p>")],
            conversationID: conversationID, messageID: messageID)
        let canvas = store.artifactRecords.first { $0.kind == .canvas }
        let canvasVersion = canvas.flatMap { store.artifactVersions($0.id).first }
        try check(canvasVersion?.mime == "text/html" && canvasVersion?.fileName.hasSuffix(".html") == true
                  && canvasVersion?.details.canvasType == .html, "A canvas block records with its format")
        try check(ChatStore.codeExtension("swift") == "swift" && ChatStore.codeExtension("objective c") == "txt",
                  "Code canvas pieces use a short language as the extension")

        let revisionNote = store.artifactRevisionNote(target: document.id) ?? ""
        try check(revisionNote.contains("revising the document titled \"Lisbon guide\"") && revisionNote.hasSuffix("# Lisbon"),
                  "The revision note names the document and carries its content")
        store.recordCanvasArtifacts(
            [Artifact(id: "lisbon-guide", title: "Lisbon guide, revised", type: .markdown, language: "", content: "# Lisbon v2")],
            conversationID: conversationID, messageID: "revision-message", revising: document.id)
        let revised = store.artifactRecords.first { $0.id == document.id }
        try check(revised?.versionCount == 2 && revised?.title == "Lisbon guide, revised" && revised?.kind == .document,
                  "A canvas block during a document revision becomes the next document version")
        try check(store.artifactRecords.filter { $0.kind == .canvas }.count == 1, "The revision adds no canvas piece")
        try check(store.artifactVersions(document.id).last.flatMap { store.artifactText($0) } == "# Lisbon v2",
                  "The new version stores the revised text")
        try check(store.artifactVersions(document.id).last?.sourceKey == "canvas:revision-message:0:lisbon-guide",
                  "Canvas source keys carry the block position")
        store.recordCanvasArtifacts(
            [Artifact(id: "twin", title: "Twin A", type: .markdown, language: "", content: "A"),
             Artifact(id: "twin", title: "Twin B", type: .markdown, language: "", content: "B")],
            conversationID: conversationID, messageID: "twin-message")
        try check(store.artifactRecords.filter { $0.title.hasPrefix("Twin") }.count == 2,
                  "Two blocks with the same id in one reply both record")

        guard let revisedRecord = revised else { throw Failure(description: "The revised document is missing") }
        store.reviseArtifact(revisedRecord, change: "  Add a day trip to Sintra  ")
        try await waitForReply(store, conversationID: conversationID)
        let sentPrompt = transport.histories.last?.first?.content ?? ""
        let sentRequest = transport.histories.last?.last?.content ?? ""
        try check(sentPrompt.contains("The user is revising the document titled \"Lisbon guide, revised\"")
                  && sentPrompt.contains("# Lisbon v2"), "The revision turn carries the revision note")
        try check(sentRequest == "Revise \"Lisbon guide, revised\": Add a day trip to Sintra", "The revision request is plain text")
        guard let revisionTurn = try repository.conversationTurns().last(where: { $0.conversationID == conversationID }) else {
            throw Failure(description: "The revision turn is missing")
        }
        try check(store.artifactRevisionTarget(messageID: revisionTurn.userMessageID.uuidString) == nil,
                  "The revision request target clears when the turn finishes")
        try check(store.artifactRevisionTarget(messageID: revisionTurn.assistantMessageID.uuidString) == document.id,
                  "The revision reply keeps its target for late task results")
        try check(store.artifactRecords.first { $0.id == document.id }?.versionCount == 2,
                  "A reply without a revised block adds no version")
        store.applyNativeTaskUpdates([NativeTaskMessageUpdate(
            conversationID: conversationID, messageID: revisionTurn.assistantMessageID,
            blocks: [.artifact(NativeResearchArtifact(id: "research-3", title: "Lisbon guide, with Sintra", report: "# Lisbon v3", sources: []))])])
        try check(store.artifactRecords.first { $0.id == document.id }?.versionCount == 3,
                  "A late task result on the revision reply becomes the next version")

        let pending = NativeResearchArtifact(id: "research-4", title: "Braga guide", report: "# Braga", sources: [])
        _ = try repository.appendDisplayBlock(.artifact(pending), messageID: turn.assistantMessageID)
        let relaunched = ChatStore(
            nativeConfig: nil, nativeTransport: nil, repository: repository,
            attachmentStore: NativeAttachmentStore(directory: directory), artifactPersistenceEnabled: false)
        await relaunched.connect()
        relaunched.select(conversationID)
        try check(relaunched.artifactRecords.contains { $0.kind == .document && $0.title == "Braga guide" },
                  "A task artifact saved before a relaunch records when its chat loads")
        store.reloadArtifacts()

        store.renameConversation(conversationID, title: "Lisbon trip")
        try check(store.artifactRecords.filter { $0.conversationID == conversationID }.allSatisfy { $0.originTitle == "Lisbon trip" },
                  "Renaming the chat updates the origin title")

        let keptCount = store.artifactRecords.filter { $0.conversationID == conversationID }.count
        let keptVersions = store.artifactRecords.flatMap { store.artifactVersions($0.id) }
        store.deleteConversation(conversationID)
        try check(store.pendingConversationDeletion?.id == conversationID
                  && store.pendingConversationDeletion?.artifactCount == keptCount, "Deleting a chat with artifacts asks first")
        try check(store.conversations.contains { $0.id == conversationID }, "The chat stays until the choice is made")
        try check(ContentView.deletionMessage(1).contains("an artifact. You can keep it")
                  && ContentView.deletionMessage(keptCount).contains("\(keptCount) artifacts"), "The choice message pluralizes")
        store.confirmDeleteConversation(.keep)
        try check(!store.conversations.contains { $0.id == conversationID }, "Keeping artifacts still deletes the chat")
        try check(store.artifactRecords.count == keptCount
                  && store.artifactRecords.allSatisfy { $0.conversationID == nil && $0.originTitle == "Lisbon trip" },
                  "Kept artifacts lose the chat link and keep the origin title")
        try check(keptVersions.allSatisfy(fileExists), "Kept artifact files stay on disk")

        store.newConversation()
        try check(store.sendText("Draw a chart"), "The second message sends")
        guard let secondID = store.selectedID, secondID != conversationID else { throw Failure(description: "No second chat") }
        try await waitForReply(store, conversationID: secondID)
        store.recordCanvasArtifacts(
            [Artifact(id: "chart", title: "Chart", type: .svg, language: "", content: "<svg/>")],
            conversationID: secondID, messageID: "chart-message")
        let doomed = store.artifactRecords.filter { $0.conversationID == secondID }
        try check(doomed.count == 1, "The second chat has one artifact")
        let doomedVersions = doomed.flatMap { store.artifactVersions($0.id) }
        store.requestDeleteConversation(secondID)
        try check(store.pendingConversationDeletion?.artifactCount == 1, "The request names one artifact")
        store.confirmDeleteConversation(.delete)
        try check(!store.conversations.contains { $0.id == secondID }, "The second chat is deleted")
        try check(!store.artifactRecords.contains { $0.id == doomed[0].id }, "Deleted artifacts leave the list")
        try check(!doomedVersions.contains(where: fileExists), "Deleted artifact files leave the disk")
        try check(store.artifactRecords.count == keptCount, "Kept artifacts survive the second deletion")

        store.newConversation()
        _ = store.sendText("Hello")
        guard let plainID = store.selectedID else { throw Failure(description: "No third chat") }
        try await waitForReply(store, conversationID: plainID)
        store.deleteConversation(plainID)
        try check(store.pendingConversationDeletion == nil && !store.conversations.contains { $0.id == plainID },
                  "A chat without artifacts deletes without asking")

        let legacyDirectory = directory.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyURL = legacyDirectory.appendingPathComponent("artifacts.json")
        let backupURL = legacyDirectory.appendingPathComponent("artifacts-migrated.json")
        try Data("stale".utf8).write(to: backupURL)
        let legacy = [
            Artifact(id: "landing", title: "Landing page", type: .html, language: "", content: "<h1>Hi</h1>"),
            Artifact(id: "parser", title: "Parser", type: .code, language: "swift", content: "let x = 1"),
        ]
        try JSONEncoder().encode(legacy).write(to: legacyURL)
        let legacyRepository = try LocalChatRepository(inMemory: true, artifactDirectory: directory)
        let imported = try ChatStore.importLegacyCanvasLibrary(from: legacyURL, into: legacyRepository)
        try check(imported == 2, "Both legacy canvas pieces import")
        let importedRecords = try legacyRepository.listArtifacts()
        try check(importedRecords.count == 2 && importedRecords.allSatisfy { $0.kind == .canvas && $0.conversationID == nil },
                  "Legacy pieces land as canvas artifacts with no chat")
        try check(Set(importedRecords.map(\.title)) == ["Landing page", "Parser"], "Legacy titles carry over")
        let parser = try legacyRepository.artifactVersion(sourceKey: "canvas-library:parser")
        try check(parser?.fileName.hasSuffix(".swift") == true && parser?.details.language == "swift", "Legacy code keeps its language")
        try check(!FileManager.default.fileExists(atPath: legacyURL.path), "The legacy library file moves away")
        try check((try? JSONDecoder().decode([Artifact].self, from: Data(contentsOf: backupURL)))?.count == 2,
                  "The backup replaces an older one")
        try check(try ChatStore.importLegacyCanvasLibrary(from: legacyURL, into: legacyRepository) == 0,
                  "A missing legacy library imports nothing")

        try await runRetriesAndStops(store: store, transport: transport, repository: repository, directory: directory)
    }

    @MainActor
    static func runRetriesAndStops(
        store: ChatStore, transport: ArtifactScriptTransport, repository: LocalChatRepository, directory: URL
    ) async throws {
        func latestText(_ record: ArtifactRecord?) -> String? {
            record.flatMap { store.artifactVersions($0.id).last }.flatMap { store.artifactText($0) }
        }
        func lastTurn(_ conversationID: String) throws -> NativeConversationTurn {
            guard let turn = try repository.conversationTurns().last(where: { $0.conversationID == conversationID }) else {
                throw Failure(description: "The turn is missing")
            }
            return turn
        }

        store.newConversation()
        guard let draftChat = store.selectedID else { throw Failure(description: "No draft chat") }
        let first = Artifact(id: "draft", title: "Draft", type: .markdown, language: "", content: "A")
        var second = first
        second.content = "B"
        store.recordCanvasArtifacts([first], conversationID: draftChat, messageID: "retried-message")
        store.recordCanvasArtifacts([second], conversationID: draftChat, messageID: "retried-message")
        store.recordCanvasArtifacts([second], conversationID: draftChat, messageID: "retried-message")
        let drafts = store.artifactRecords.filter { $0.title == "Draft" }
        try check(drafts.count == 1 && drafts[0].versionCount == 2 && latestText(drafts.first) == "B",
                  "A regenerated canvas block with new content becomes the next version, and a repeat adds nothing")

        transport.queue(.interrupt(":::vera-artifact id=\"note\" title=\"Field note\" type=\"markdown\"\n# Note\n:::\nAnd then"))
        try check(store.sendText("Write a field note"), "The interrupted message sends")
        guard let noteChat = store.selectedID else { throw Failure(description: "No note chat") }
        try await waitForReply(store, conversationID: noteChat)
        try check(latestText(store.artifactRecords.first { $0.title == "Field note" }) == "# Note",
                  "An interrupted answer still records its finished canvas block")

        store.newConversation()
        transport.queue(.hold(":::vera-artifact id=\"held\" title=\"Held piece\" type=\"markdown\"\n# Held\n:::\nStill going"))
        try check(store.sendText("Start a long piece"), "The held message sends")
        guard let heldChat = store.selectedID else { throw Failure(description: "No held chat") }
        try await waitUntil("The held block never parsed") {
            store.conversations.first { $0.id == heldChat }?.messages.last?.artifacts.isEmpty == false
        }
        let heldTurn = try lastTurn(heldChat)
        let trashChange = NativeFileChange(
            path: "/tmp/notes/old-draft.md", kind: .trashed, movedFrom: "/Volumes/Notes/.Trash/old-draft.md")
        store.attachDisplayBlock(.fileChange(trashChange), turn: heldTurn)
        let trashedRecord = store.artifactRecords.first { $0.title == "Moved old-draft.md to the Trash" }
        let trashedVersion = trashedRecord.flatMap { store.artifactVersions($0.id).first }
        try check(trashedRecord?.kind == .fileChange && trashedVersion?.details.contentAvailable == false
                  && trashedVersion?.details.movedFrom == "/Volumes/Notes/.Trash/old-draft.md"
                  && trashedVersion?.details.changeKind == .trashed,
                  "A Trash move records without contents and keeps where it went")
        store.stopAnswer(heldTurn.assistantMessageID)
        transport.releaseHeld()
        try check(latestText(store.artifactRecords.first { $0.title == "Held piece" }) == "# Held",
                  "Stopping an answer records its finished canvas block")

        store.newConversation()
        try check(store.sendText("Plan Rome"), "The Rome message sends")
        guard let romeChat = store.selectedID else { throw Failure(description: "No Rome chat") }
        try await waitForReply(store, conversationID: romeChat)
        let romeTurn = try lastTurn(romeChat)
        store.applyNativeTaskUpdates([NativeTaskMessageUpdate(
            conversationID: romeChat, messageID: romeTurn.assistantMessageID,
            blocks: [.artifact(NativeResearchArtifact(id: "rome", title: "Rome guide", report: "# Rome", sources: []))])])
        guard let rome = store.artifactRecords.first(where: { $0.title == "Rome guide" }) else {
            throw Failure(description: "The Rome guide is missing")
        }
        transport.queue(.fail)
        store.reviseArtifact(rome, change: "Add Ostia")
        try await waitForReply(store, conversationID: romeChat)
        let failedTurn = try lastTurn(romeChat)
        try check(store.conversations.first { $0.id == romeChat }?.messages.last?.state == .interrupted,
                  "The failed revision attempt is interrupted")
        try check(store.artifactRevisionTarget(messageID: failedTurn.userMessageID.uuidString) == rome.id,
                  "A failed revision keeps its target")
        let other = ChatStore(
            nativeConfig: nil, nativeTransport: nil, repository: repository,
            attachmentStore: NativeAttachmentStore(directory: directory), artifactPersistenceEnabled: false)
        try check(other.artifactRevisionTarget(messageID: failedTurn.userMessageID.uuidString) == rome.id,
                  "The revision target is durable across stores")
        transport.queue(.reply(":::vera-artifact id=\"rome\" title=\"Rome guide\" type=\"markdown\"\n# Rome with Ostia\n:::\nAdded Ostia."))
        store.retryAnswer(failedTurn.assistantMessageID)
        try await waitUntil("The retried revision never finished") {
            store.conversations.first { $0.id == romeChat }?.messages.last?.state == .complete
        }
        try check((transport.histories.last?.first?.content ?? "").contains("The user is revising the document titled \"Rome guide\""),
                  "The retried attempt still carries the revision note")
        let revisedRome = store.artifactRecords.first { $0.id == rome.id }
        try check(revisedRome?.versionCount == 2 && revisedRome?.kind == .document && latestText(revisedRome) == "# Rome with Ostia",
                  "The retried revision records the next document version")
        try check(store.artifactRevisionTarget(messageID: failedTurn.userMessageID.uuidString) == nil,
                  "A finished revision clears its request target")

        store.newConversation()
        transport.queue(.hold(":::vera-artifact id=\"live\" title=\"Live piece\" type=\"markdown\"\n# Live\n:::\nStill writing"))
        try check(store.sendText("Write a live piece"), "The streaming message sends")
        guard let liveChat = store.selectedID else { throw Failure(description: "No live chat") }
        try await waitUntil("A finished block was not recorded while the answer was still streaming") {
            store.artifactRecords.contains { $0.title == "Live piece" && $0.conversationID == liveChat }
        }
        try check(store.conversations.first { $0.id == liveChat }?.messages.last?.state == .streaming,
                  "The answer is still streaming when its block records")
        let liveFiles = store.artifactRecords.filter { $0.conversationID == liveChat }
            .flatMap { store.artifactVersions($0.id) }.map(\.fileName)
        store.deleteConversation(liveChat)
        try check(store.pendingConversationDeletion?.id == liveChat, "Deleting the streaming chat asks first")
        store.confirmDeleteConversation(.delete)
        transport.releaseHeld()
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(!store.conversations.contains { $0.id == liveChat }, "The streaming chat is deleted")
        try check(!store.artifactRecords.contains { $0.conversationID == liveChat || $0.title == "Live piece" },
                  "Deleting a streaming chat leaves none of its artifacts")
        let listedFiles = Set(store.artifactRecords.flatMap { store.artifactVersions($0.id) }.map(\.fileName))
        try check(!liveFiles.isEmpty && liveFiles.allSatisfy { !listedFiles.contains($0)
                  && !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) },
                  "Deleting a streaming chat removes its artifact files")
    }
}
