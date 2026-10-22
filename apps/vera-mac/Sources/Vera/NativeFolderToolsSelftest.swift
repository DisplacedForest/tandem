import Foundation

@MainActor
extension SelfTest {
    static func runNativeFolderTools() async throws {
        let require = NativeTaskFixture.require
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("vera-folder-tools-\(UUID().uuidString)", isDirectory: true)
        let inside = base.appendingPathComponent("granted", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try manager.createDirectory(at: inside.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        try "alpha\nbeta\ngamma\n".write(to: inside.appendingPathComponent("notes/one.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 3]).write(to: inside.appendingPathComponent("image.png"))
        try manager.createSymbolicLink(at: inside.appendingPathComponent("escape-file"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try manager.createSymbolicLink(at: inside.appendingPathComponent("escape-dir"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: inside.appendingPathComponent("loop"), withDestinationURL: inside.appendingPathComponent("notes"))

        let grant = try FolderGrant.make(url: inside)
        try require(grant.name == "granted" && grant.path == inside.resolvingSymlinksInPath().path && grant.bookmark != nil, "A grant records the real path, name and a bookmark")
        do {
            _ = try FolderGrant.make(url: inside.appendingPathComponent("notes/one.txt"))
            throw NativeTaskFixture.Failure.assertion("A file cannot be granted")
        } catch is NativeFolderAccessError {}
        let encoded = FolderGrant.encode([grant])
        try require(FolderGrant.decode(encoded) == [grant] && FolderGrant.decode(nil).isEmpty && FolderGrant.decode("junk").isEmpty, "Grants round-trip through JSON and bad input decodes empty")

        let access = NativeFolderAccess(grants: [grant])
        let root = grant.path
        try require(try access.resolve(root + "/notes/one.txt") == root + "/notes/one.txt", "A path inside the grant resolves")
        try require(try access.resolve("notes/one.txt") == root + "/notes/one.txt", "A relative path resolves against the single grant")
        try require(try access.resolve(root + "/loop/one.txt") == root + "/notes/one.txt", "A symlink that stays inside resolves to its target")
        try require(try access.resolve(root + "/notes/new.txt", mustExist: false) == root + "/notes/new.txt", "A new file under an existing folder resolves")
        for escape in [outside.path + "/secret.txt", root + "/../outside/secret.txt", root + "/escape-file", root + "/escape-dir/secret.txt",
                       root + "/escape-dir", "~/Desktop", "/etc/hosts", root + "/notes/../../outside/secret.txt"] {
            do {
                _ = try access.resolve(escape, mustExist: false)
                throw NativeTaskFixture.Failure.assertion("Escape must be refused: \(escape)")
            } catch let error as NativeFolderAccessError {
                guard case .outsideGrants(let named) = error, !named.isEmpty else { throw NativeTaskFixture.Failure.assertion("Escape names the path: \(escape)") }
            }
        }
        do {
            _ = try access.resolve(root + "/missing/deeper.txt")
            throw NativeTaskFixture.Failure.assertion("Missing paths are reported")
        } catch NativeFolderAccessError.notFound {}
        let two = NativeFolderAccess(grants: [grant, try FolderGrant.make(url: outside)])
        do {
            _ = try two.resolve("notes/one.txt")
            throw NativeTaskFixture.Failure.assertion("Relative paths need a single grant")
        } catch NativeFolderAccessError.relativeWithoutAnchor {}
        try require(try two.resolve(outside.path + "/secret.txt").hasSuffix("/outside/secret.txt"), "A second grant opens its own folder")
        try require(NativeFolderAccess(grants: []).roots.isEmpty, "No grants means no roots")
        let gone = FolderGrant(path: base.appendingPathComponent("vanished").path, name: "vanished", bookmark: nil)
        try require(NativeFolderAccess(grants: [gone]).roots.isEmpty, "A grant whose folder is gone contributes no root")

        let ledger = NativeFileChangeLedger()
        let listed = try NativeFolderTools.list(root, hidden: false)
        guard case .object(let listing) = listed, case .array(let entries)? = listing["entries"] else { throw NativeTaskFixture.Failure.assertion("Listing shape") }
        let names = entries.compactMap { entry -> String? in
            guard case .object(let fields) = entry, case .string(let name)? = fields["name"] else { return nil }
            return name
        }
        try require(names == ["escape-dir", "escape-file", "image.png", "loop", "notes"], "Listing is sorted and typed: \(names)")
        let read = try NativeFolderTools.read(root + "/notes/one.txt", startLine: 2, maximumBytes: 1024)
        guard case .object(let readFields) = read, case .string(let content)? = readFields["content"], case .bool(let more)? = readFields["more"] else {
            throw NativeTaskFixture.Failure.assertion("Read shape")
        }
        try require(content == "beta\ngamma\n" && more == false, "Read returns from the requested line: \(content)")
        let big = String(repeating: "line of text\n", count: 20_000)
        try big.write(to: inside.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        let capped = try NativeFolderTools.read(root + "/big.txt", startLine: 1, maximumBytes: 2048)
        guard case .object(let cappedFields) = capped, case .string(let cappedText)? = cappedFields["content"], case .bool(let cappedMore)? = cappedFields["more"],
              case .number(let endLine)? = cappedFields["end_line"] else { throw NativeTaskFixture.Failure.assertion("Capped read shape") }
        try require(cappedText.utf8.count <= 2048 && cappedMore && endLine < 20_000, "Reads stop at the byte cap and say more remains")
        do {
            _ = try NativeFolderTools.read(root + "/image.png", startLine: 1, maximumBytes: 1024)
            throw NativeTaskFixture.Failure.assertion("Binary files are refused")
        } catch NativeFolderAccessError.binary {}
        let found = try NativeFolderTools.search(root: root, query: "GAMMA", limit: 10)
        guard case .object(let searchFields) = found, case .array(let matches)? = searchFields["matches"] else { throw NativeTaskFixture.Failure.assertion("Search shape") }
        try require(matches.count == 1, "Search is case-insensitive and skips binaries and symlinks: \(matches.count)")
        let limited = try NativeFolderTools.search(root: root, query: "line of text", limit: 5)
        guard case .object(let limitedFields) = limited, case .array(let limitedMatches)? = limitedFields["matches"] else { throw NativeTaskFixture.Failure.assertion("Search cap shape") }
        try require(limitedMatches.count == 5 && limitedFields["truncated"] == .bool(true), "Search results are capped and say so")

        let written = await NativeToolCallContext.$activityID.withValue("call-1") {
            try? await NativeFolderTools.write(root + "/notes/two.txt", content: "one\ntwo\n", ledger: ledger)
        }
        try require(written != nil && (try String(contentsOf: inside.appendingPathComponent("notes/two.txt"), encoding: .utf8)) == "one\ntwo\n", "Write creates the file")
        let created = await ledger.take("call-1")
        try require(created.count == 1 && created[0].kind == .created && created[0].before == nil && created[0].after == "one\ntwo\n", "The write is recorded as a creation")
        try require(await ledger.take("call-1").isEmpty, "A taken change is gone")
        let edited = await NativeToolCallContext.$activityID.withValue("call-2") {
            try? await NativeFolderTools.edit(root + "/notes/two.txt", old: "two", new: "three", all: false, ledger: ledger)
        }
        try require(edited != nil && (try String(contentsOf: inside.appendingPathComponent("notes/two.txt"), encoding: .utf8)) == "one\nthree\n", "Edit replaces the exact text")
        let editChange = await ledger.take("call-2")
        try require(editChange.count == 1 && editChange[0].kind == .edited && editChange[0].before == "one\ntwo\n" && editChange[0].after == "one\nthree\n", "The edit records before and after")
        do {
            _ = try await NativeFolderTools.edit(root + "/notes/one.txt", old: "a", new: "x", all: false, ledger: ledger)
            throw NativeTaskFixture.Failure.assertion("Ambiguous edits are refused")
        } catch let error as NativeToolError {
            try require(error.localizedDescription.contains("appears"), "Ambiguity names the count")
        }
        do {
            _ = try await NativeFolderTools.edit(root + "/notes/one.txt", old: "zeta", new: "x", all: false, ledger: ledger)
            throw NativeTaskFixture.Failure.assertion("Missing text is refused")
        } catch is NativeToolError {}
        _ = try await NativeFolderTools.edit(root + "/notes/one.txt", old: "a", new: "A", all: true, ledger: ledger)
        try require((try String(contentsOf: inside.appendingPathComponent("notes/one.txt"), encoding: .utf8)) == "AlphA\nbetA\ngAmmA\n", "replace_all replaces every occurrence")
        do {
            _ = try await NativeFolderTools.move(from: root + "/notes/two.txt", to: root + "/notes/one.txt", ledger: ledger)
            throw NativeTaskFixture.Failure.assertion("Moves never overwrite")
        } catch NativeFolderAccessError.exists {}
        _ = try await NativeFolderTools.move(from: root + "/notes/two.txt", to: root + "/renamed.txt", ledger: ledger)
        try require(manager.fileExists(atPath: root + "/renamed.txt") && !manager.fileExists(atPath: root + "/notes/two.txt"), "Move renames within the grant")
        do {
            _ = try await NativeFolderTools.move(from: root + "/notes", to: root + "/notes/sub", ledger: ledger)
            throw NativeTaskFixture.Failure.assertion("A folder cannot move into itself")
        } catch is NativeToolError {}
        _ = try await NativeFolderTools.makeDirectory(root + "/made/deep", ledger: ledger)
        var isDirectory: ObjCBool = false
        try require(manager.fileExists(atPath: root + "/made/deep", isDirectory: &isDirectory) && isDirectory.boolValue, "Folders are created with parents")
        do {
            _ = try await NativeFolderTools.write(root + "/image.png", content: "text", ledger: ledger)
            throw NativeTaskFixture.Failure.assertion("Binary files are not overwritten")
        } catch NativeFolderAccessError.binary {}

        let grantsBox = NativeFolderGrantSource()
        grantsBox.set([grant], for: "conversation")
        let definitions = NativeFolderTools.definitions(grants: { grantsBox.grants(for: "conversation") }, ledger: ledger)
        try require(Set(definitions.map(\.name)) == NativeFolderTools.toolNames && definitions.allSatisfy { $0.id == NativeFolderTools.toolID && $0.confirmation == .none },
                    "Seven file tools share one consent id and never ask per file")
        let registry = NativeToolRegistry(definitions: definitions)
        try require(registry.active(enabledIDs: [NativeFolderTools.toolID]).count == 7, "Tools are advertised with a grant")
        try require(ChatStore.builtInToolNames.isSuperset(of: NativeFolderTools.toolNames), "File tool names are reserved from capability tools")
        let catalog = NativeChatToolCatalog.tools(veraAPIConfigured: false)
        try require(catalog.contains { $0.id == NativeFolderTools.toolID && $0.available }, "The Tools tab lists the file tools")

        let loopRounds: [[NativeChatStreamSnapshot]] = [
            NativeWebToolsSelftest.call("w1", NativeFolderTools.writeName, "{\"path\":\"\(root)/notes/loop.txt\",\"content\":\"hello\\n\"}"),
            NativeWebToolsSelftest.call("w2", NativeFolderTools.readName, "{\"path\":\"\(outside.path)/secret.txt\"}"),
            NativeWebToolsSelftest.call("w3", NativeFolderTools.editName, "{\"path\":\"\(root)/notes/loop.txt\",\"old_text\":\"hello\",\"new_text\":\"goodbye\"}"),
            NativeWebToolsSelftest.reply("Done."),
        ]
        let (final, _) = try await NativeWebToolsSelftest.loop(registry, rounds: loopRounds, enabled: [NativeFolderTools.toolID])
        let activities = final?.activities ?? []
        try require(activities.count == 3 && activities[0].state == .succeeded && activities[2].state == .succeeded, "Writes and edits run without asking")
        let refusal = activities[1].result?.replacingOccurrences(of: "\\/", with: "/") ?? ""
        try require(activities[1].state == .failed && refusal.contains(outside.path + "/secret.txt") && refusal.contains("outside every folder"),
                    "An outside path is refused with the path in the tool result: \(refusal)")
        let first = await ledger.take("w1")
        let third = await ledger.take("w3")
        try require(first.count == 1 && first[0].kind == .created && third.count == 1 && third[0].before == "hello\n" && third[0].after == "goodbye\n",
                    "Each tool call's change is recorded under its call id")
        grantsBox.set([], for: "conversation")
        let (revoked, _) = try await NativeWebToolsSelftest.loop(registry, rounds: [
            NativeWebToolsSelftest.call("r1", NativeFolderTools.readName, "{\"path\":\"\(root)/notes/one.txt\"}"), NativeWebToolsSelftest.reply("ok"),
        ], enabled: [NativeFolderTools.toolID])
        try require(revoked?.activities.first?.state == .failed && revoked?.activities.first?.result?.contains("No folder has been granted") == true,
                    "A call after revocation fails and says why")

        let repository = try LocalChatRepository(inMemory: true)
        var conversation = Conversation(id: UUID().uuidString, title: "Grants", messages: [], updatedAt: Date(), grants: [grant])
        try repository.saveConversation(conversation)
        try require(try repository.listConversations().first(where: { $0.id == conversation.id })?.grants == [grant], "Grants persist on the conversation")
        conversation.grants = []
        try repository.saveConversation(conversation)
        try require(try repository.listConversations().first(where: { $0.id == conversation.id })?.grants.isEmpty == true, "Revoked grants persist as empty")
        let reply = Message(role: .assistant, text: "", displayBlocks: [.fileChange(NativeFileChange(path: root + "/x.txt", kind: .edited, before: "a\nb\n", after: "a\nc\n"))])
        try repository.saveMessage(reply, conversationID: conversation.id, ordinal: 0)
        let reloaded = try repository.messages(conversationID: conversation.id).first
        guard case .fileChange(let saved)? = reloaded?.displayBlocks.first else { throw NativeTaskFixture.Failure.assertion("File change blocks survive reload") }
        try require(saved.before == "a\nb\n" && saved.after == "a\nc\n" && saved.kind == .edited, "The diff content survives reload")

        let hunks = NativeLineDiff.hunks(before: "one\ntwo\nthree\nfour\nfive\nsix\nseven\n", after: "one\ntwo\nthree\nFOUR\nfive\nsix\nseven\n", context: 1)
        try require(hunks.count == 1 && hunks[0].lines == [.same("three"), .removed("four"), .added("FOUR"), .same("five")], "Diff hunks show changed lines with context: \(hunks)")
        try require(NativeLineDiff.summary(before: "a\nb", after: "a\nc\nd") == "+2 -1" && NativeLineDiff.summary(before: "x", after: "x") == "No line changes", "Diff summaries count lines")
        let capped2 = NativeFileChange(path: "/tmp/big", kind: .created, after: String(repeating: "x", count: NativeFileChange.contentCap + 10))
        try require(capped2.truncated && capped2.after?.utf8.count == NativeFileChange.contentCap, "Recorded content is capped")
        try require(NativeFolderTools.grantNote([grant])?.contains(grant.path) == true && NativeFolderTools.grantNote([]) == nil, "The prompt note lists granted paths")
        print("  native folder tools OK (grants, bookmarks, path guard, symlink escapes, list, read caps, binary, search caps, write, edit, move, mkdir, ledger, advertisement, scripted loop, revocation, persistence, diff)")
    }
}
