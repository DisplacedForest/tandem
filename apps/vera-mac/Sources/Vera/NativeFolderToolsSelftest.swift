import Foundation

final class NativeFileChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, NativeFileChange)] = []

    func add(_ activity: String, _ change: NativeFileChange) {
        lock.lock(); defer { lock.unlock() }
        entries.append((activity, change))
    }

    func changes(for activity: String) -> [NativeFileChange] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.0 == activity }.map(\.1)
    }
}

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
        try require(grant.name == "granted" && grant.path == inside.resolvingSymlinksInPath().path && grant.bookmark != nil && grant.identity != nil,
                    "A grant records the real path, name, identity and a bookmark")
        do {
            _ = try FolderGrant.make(url: inside.appendingPathComponent("notes/one.txt"))
            throw NativeTaskFixture.Failure.assertion("A file cannot be granted")
        } catch is NativeFolderAccessError {}
        let encoded = FolderGrant.encode([grant])
        try require(FolderGrant.decode(encoded) == [grant] && FolderGrant.decode(nil).isEmpty && FolderGrant.decode("junk").isEmpty, "Grants round-trip through JSON and bad input decodes empty")

        let access = NativeFolderAccess(grants: [grant])
        let root = grant.path
        try require(try access.locate(root + "/notes/one.txt").components == ["notes", "one.txt"], "A path inside the grant locates")
        try require(try access.locate("notes/one.txt").components == ["notes", "one.txt"], "A relative path locates against the single grant")
        try require(try access.locate(root + "/notes//one.txt/").components == ["notes", "one.txt"], "Double and trailing slashes normalize")
        try require(try access.locate(root + "/notes/new.txt").components == ["notes", "new.txt"], "A new file under an existing folder locates")
        try require(try access.locate(root + "/").components.isEmpty, "The grant root itself locates")
        for escape in [outside.path + "/secret.txt", root + "/../outside/secret.txt", "~/Desktop", "/etc/hosts", root + "/notes/../../outside/secret.txt"] {
            do {
                _ = try access.locate(escape)
                throw NativeTaskFixture.Failure.assertion("Escape must be refused: \(escape)")
            } catch let error as NativeFolderAccessError {
                switch error {
                case .outsideGrants(let named), .invalidPath(let named):
                    try require(named == escape, "Escape names the path: \(escape) \(error)")
                default:
                    throw NativeTaskFixture.Failure.assertion("Escape is refused as outside or invalid: \(escape) \(error)")
                }
            }
        }
        for linked in [root + "/escape-file", root + "/escape-dir/secret.txt", root + "/loop/one.txt", root + "/escape-dir"] {
            let location = try access.locate(linked)
            do {
                _ = try NativeFolderTools.read(location, startLine: 1, maximumBytes: 1024)
                throw NativeTaskFixture.Failure.assertion("Symlinked components are refused at open time: \(linked)")
            } catch NativeFolderAccessError.symlink {} catch NativeFolderAccessError.outsideGrants {}
        }
        do {
            _ = try access.locate(root + "/bad\nname")
            throw NativeTaskFixture.Failure.assertion("Newlines in paths are refused")
        } catch NativeFolderAccessError.invalidPath {}
        do {
            _ = try access.locate(root + "/notes/../one.txt")
            throw NativeTaskFixture.Failure.assertion("Dot segments are refused even when they would stay inside")
        } catch NativeFolderAccessError.invalidPath {}
        let two = NativeFolderAccess(grants: [grant, try FolderGrant.make(url: outside)])
        do {
            _ = try two.locate("notes/one.txt")
            throw NativeTaskFixture.Failure.assertion("Relative paths need a single grant")
        } catch NativeFolderAccessError.relativeWithoutAnchor {}
        try require(try two.locate(outside.path + "/secret.txt").root.name == "outside", "A second grant opens its own folder")
        try require(NativeFolderAccess(grants: []).roots.isEmpty, "No grants means no roots")
        let gone = FolderGrant(path: base.appendingPathComponent("vanished").path, name: "vanished", bookmark: nil)
        try require(NativeFolderAccess(grants: [gone]).roots.isEmpty, "A grant whose folder is gone contributes no root")

        let swapRoot = base.appendingPathComponent("swap", isDirectory: true)
        try manager.createDirectory(at: swapRoot, withIntermediateDirectories: true)
        let swapGrant = try FolderGrant.make(url: swapRoot)
        try manager.moveItem(at: swapRoot, to: base.appendingPathComponent("swap-moved"))
        try manager.createSymbolicLink(at: swapRoot, withDestinationURL: outside)
        let swapped = NativeFolderAccess(grants: [swapGrant])
        try require(swapped.roots.first?.path.hasSuffix("/swap-moved") == true, "A moved grant is found again by its bookmark and identity, not by whatever sits at the old path")
        do {
            _ = try swapped.locate(swapRoot.path + "/secret.txt")
            throw NativeTaskFixture.Failure.assertion("The replacement at the old path is never authorized")
        } catch NativeFolderAccessError.outsideGrants {}
        let forged = FolderGrant(id: swapGrant.id, path: swapGrant.path, name: swapGrant.name, bookmark: nil, identity: swapGrant.identity)
        try require(NativeFolderAccess(grants: [forged]).roots.isEmpty, "Without a bookmark a replaced root is refused outright")

        let recorded = NativeFileChangeRecorder()
        let ledger = NativeFileChangeLedger()
        ledger.attach { activity, change in recorded.add(activity, change) }
        let listed = try NativeFolderTools.list(try access.locate(root), hidden: false)
        guard case .object(let listing) = listed, case .array(let entries)? = listing["entries"] else { throw NativeTaskFixture.Failure.assertion("Listing shape") }
        let names = entries.compactMap { entry -> String? in
            guard case .object(let fields) = entry, case .string(let name)? = fields["name"] else { return nil }
            return name
        }
        try require(names == ["escape-dir", "escape-file", "image.png", "loop", "notes"], "Listing is sorted and typed: \(names)")
        let read = try NativeFolderTools.read(try access.locate(root + "/notes/one.txt"), startLine: 2, maximumBytes: 1024)
        guard case .object(let readFields) = read, case .string(let content)? = readFields["content"], case .bool(let more)? = readFields["more"],
              case .number(let endLine)? = readFields["end_line"] else {
            throw NativeTaskFixture.Failure.assertion("Read shape")
        }
        try require(content == "beta\ngamma" && more == false && endLine == 3, "Read returns from the requested line with honest bounds: \(content) \(endLine)")
        let big = String(repeating: "line of text\n", count: 20_000)
        try big.write(to: inside.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        let capped = try NativeFolderTools.read(try access.locate(root + "/big.txt"), startLine: 1, maximumBytes: 2048)
        guard case .object(let cappedFields) = capped, case .string(let cappedText)? = cappedFields["content"], case .bool(let cappedMore)? = cappedFields["more"],
              case .number(let cappedEnd)? = cappedFields["end_line"] else { throw NativeTaskFixture.Failure.assertion("Capped read shape") }
        try require(cappedText.utf8.count <= 2048 && cappedMore && Int(cappedEnd) == cappedText.components(separatedBy: "\n").count,
                    "Reads stop at the byte cap, say more remains, and end_line matches the delivered lines")
        let continued = try NativeFolderTools.read(try access.locate(root + "/big.txt"), startLine: Int(cappedEnd) + 1, maximumBytes: 2048)
        guard case .object(let continuedFields) = continued, case .number(let continuedStart)? = continuedFields["start_line"] else { throw NativeTaskFixture.Failure.assertion("Continued read shape") }
        try require(Int(continuedStart) == Int(cappedEnd) + 1, "Continuation starts where the previous read ended")
        try (String(repeating: "x", count: 5000) + "\nshort\n").write(to: inside.appendingPathComponent("longline.txt"), atomically: true, encoding: .utf8)
        do {
            _ = try NativeFolderTools.read(try access.locate(root + "/longline.txt"), startLine: 1, maximumBytes: 1024)
            throw NativeTaskFixture.Failure.assertion("An oversized line is reported instead of silently cut")
        } catch let error as NativeToolError {
            try require(error.localizedDescription.contains("longer than"), "Oversized line message")
        }
        do {
            _ = try NativeFolderTools.read(try access.locate(root + "/image.png"), startLine: 1, maximumBytes: 1024)
            throw NativeTaskFixture.Failure.assertion("Binary files are refused")
        } catch NativeFolderAccessError.binary {}
        try "\n\nalpha\n".write(to: inside.appendingPathComponent("blank.txt"), atomically: true, encoding: .utf8)
        guard case .object(let blankFields) = try NativeFolderTools.read(try access.locate(root + "/blank.txt"), startLine: 1, maximumBytes: 1024),
              case .string(let blankText)? = blankFields["content"], case .number(let blankEnd)? = blankFields["end_line"] else { throw NativeTaskFixture.Failure.assertion("Blank read shape") }
        try require(blankText == "\n\nalpha" && blankEnd == 3, "Leading blank lines are kept and counted: \(blankText.debugDescription) \(blankEnd)")
        guard mkfifo(inside.appendingPathComponent("pipe").path, 0o600) == 0 else { throw NativeTaskFixture.Failure.assertion("fifo fixture") }
        do {
            _ = try NativeFolderTools.read(try access.locate(root + "/pipe"), startLine: 1, maximumBytes: 1024)
            throw NativeTaskFixture.Failure.assertion("A named pipe is refused without blocking")
        } catch NativeFolderAccessError.binary {}
        try Data([0xEF, 0xBB, 0xBF] + Array("bom text\n".utf8)).write(to: inside.appendingPathComponent("bom.txt"))
        guard case .object(let bomFields) = try NativeFolderTools.read(try access.locate(root + "/bom.txt"), startLine: 1, maximumBytes: 1024),
              case .string(let bomText)? = bomFields["content"] else { throw NativeTaskFixture.Failure.assertion("BOM read shape") }
        try require(bomText.hasSuffix("bom text"), "A UTF-8 BOM is still text")
        let found = try NativeFolderTools.search(try access.locate(root), query: "GAMMA", limit: 10)
        guard case .object(let searchFields) = found, case .array(let matches)? = searchFields["matches"] else { throw NativeTaskFixture.Failure.assertion("Search shape") }
        try require(matches.count == 1, "Search is case-insensitive and skips binaries and symlinks: \(matches.count)")
        let limited = try NativeFolderTools.search(try access.locate(root), query: "line of text", limit: 5)
        guard case .object(let limitedFields) = limited, case .array(let limitedMatches)? = limitedFields["matches"] else { throw NativeTaskFixture.Failure.assertion("Search cap shape") }
        try require(limitedMatches.count == 5 && limitedFields["truncated"] == .bool(true), "Search results are capped and say so")

        _ = try NativeToolCallContext.$activityID.withValue("call-1") {
            try NativeFolderTools.write(try access.locate(root + "/notes/two.txt"), content: "one\ntwo\n", ledger: ledger)
        }
        try require((try String(contentsOf: inside.appendingPathComponent("notes/two.txt"), encoding: .utf8)) == "one\ntwo\n", "Write creates the file")
        let created = recorded.changes(for: "call-1")
        try require(created.count == 1 && created[0].kind == .created && created[0].before == nil && created[0].after == "one\ntwo\n", "The write is recorded as a creation under its call")
        _ = try NativeToolCallContext.$activityID.withValue("call-2") {
            try NativeFolderTools.edit(try access.locate(root + "/notes/two.txt"), old: "two", new: "three", all: false, ledger: ledger)
        }
        try require((try String(contentsOf: inside.appendingPathComponent("notes/two.txt"), encoding: .utf8)) == "one\nthree\n", "Edit replaces the exact text")
        let editChange = recorded.changes(for: "call-2")
        try require(editChange.count == 1 && editChange[0].kind == .edited && editChange[0].before == "one\ntwo\n" && editChange[0].after == "one\nthree\n", "The edit records before and after")
        let privateFile = inside.appendingPathComponent("private.txt")
        try "keep\n".write(to: privateFile, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateFile.path)
        _ = try NativeFolderTools.edit(try access.locate(root + "/private.txt"), old: "keep", new: "kept", all: false, ledger: ledger)
        let privateMode = (try manager.attributesOfItem(atPath: privateFile.path)[.posixPermissions] as? NSNumber)?.intValue
        try require(privateMode == 0o600 && (try String(contentsOf: privateFile, encoding: .utf8)) == "kept\n", "Editing keeps the file's permissions")
        let longName = String(repeating: "n", count: 240) + ".txt"
        _ = try NativeFolderTools.write(try access.locate(root + "/" + longName), content: "long\n", ledger: ledger)
        try require(manager.fileExists(atPath: root + "/" + longName), "Long but valid file names can be written")
        try require(try manager.contentsOfDirectory(atPath: root).allSatisfy { !$0.hasPrefix(".tandem-") }, "No temporary files are left behind")
        try "first\r\nsecond\r\n".write(to: inside.appendingPathComponent("crlf.txt"), atomically: true, encoding: .utf8)
        _ = try NativeFolderTools.edit(try access.locate(root + "/crlf.txt"), old: "first\r\n", new: "changed\r\n", all: false, ledger: ledger)
        try require((try String(contentsOf: inside.appendingPathComponent("crlf.txt"), encoding: .utf8)) == "changed\r\nsecond\r\n", "Edits keep literal line endings")
        do {
            _ = try NativeFolderTools.edit(try access.locate(root + "/notes/one.txt"), old: "a", new: "x", all: false, ledger: ledger)
            throw NativeTaskFixture.Failure.assertion("Ambiguous edits are refused")
        } catch let error as NativeToolError {
            try require(error.localizedDescription.contains("appears"), "Ambiguity names the count")
        }
        do {
            _ = try NativeFolderTools.edit(try access.locate(root + "/notes/one.txt"), old: "zeta", new: "x", all: false, ledger: ledger)
            throw NativeTaskFixture.Failure.assertion("Missing text is refused")
        } catch is NativeToolError {}
        _ = try NativeFolderTools.edit(try access.locate(root + "/notes/one.txt"), old: "a", new: "A", all: true, ledger: ledger)
        try require((try String(contentsOf: inside.appendingPathComponent("notes/one.txt"), encoding: .utf8)) == "AlphA\nbetA\ngAmmA\n", "replace_all replaces every occurrence")
        do {
            _ = try NativeFolderTools.move(from: try access.locate(root + "/notes/two.txt"), to: try access.locate(root + "/notes/one.txt"), ledger: ledger)
            throw NativeTaskFixture.Failure.assertion("Moves never overwrite")
        } catch NativeFolderAccessError.exists {}
        _ = try NativeFolderTools.move(from: try access.locate(root + "/notes/two.txt"), to: try access.locate(root + "/renamed.txt"), ledger: ledger)
        try require(manager.fileExists(atPath: root + "/renamed.txt") && !manager.fileExists(atPath: root + "/notes/two.txt"), "Move renames within the grant")
        do {
            _ = try NativeFolderTools.move(from: try access.locate(root + "/notes"), to: try access.locate(root + "/notes/sub"), ledger: ledger)
            throw NativeTaskFixture.Failure.assertion("A folder cannot move into itself")
        } catch is NativeToolError {}
        do {
            _ = try NativeFolderTools.move(from: try access.locate(root + "/escape-file"), to: try access.locate(root + "/moved-link"), ledger: ledger)
            throw NativeTaskFixture.Failure.assertion("Symlinks are not moved")
        } catch NativeFolderAccessError.symlink {}
        _ = try NativeToolCallContext.$activityID.withValue("mk-1") {
            try NativeFolderTools.makeDirectory(try access.locate(root + "/made/deep"), ledger: ledger)
        }
        var isDirectory: ObjCBool = false
        try require(manager.fileExists(atPath: root + "/made/deep", isDirectory: &isDirectory) && isDirectory.boolValue, "Folders are created with parents")
        try require(recorded.changes(for: "mk-1").map(\.path) == [root + "/made", root + "/made/deep"], "Each created folder is recorded")
        do {
            _ = try NativeToolCallContext.$activityID.withValue("mk-2") {
                try NativeFolderTools.makeDirectory(try access.locate(root + "/partial/" + String(repeating: "x", count: 300)), ledger: ledger)
            }
            throw NativeTaskFixture.Failure.assertion("An overlong component fails")
        } catch is NativeToolError {}
        try require(recorded.changes(for: "mk-2").map(\.path) == [root + "/partial"], "A parent created before a failure is still recorded")
        do {
            _ = try NativeFolderTools.write(try access.locate(root + "/image.png"), content: "text", ledger: ledger)
            throw NativeTaskFixture.Failure.assertion("Binary files are not overwritten")
        } catch NativeFolderAccessError.binary {}
        do {
            _ = try NativeFolderTools.write(try access.locate(root + "/escape-dir/new.txt"), content: "text", ledger: ledger)
            throw NativeTaskFixture.Failure.assertion("Writing through a symlinked parent is refused at open time")
        } catch NativeFolderAccessError.symlink {} catch NativeFolderAccessError.outsideGrants {}

        let grantsBox = NativeFolderGrantSource()
        grantsBox.set([grant], for: "conversation")
        let definitions = NativeFolderTools.definitions(grants: { grantsBox.grants(for: "conversation") }, ledger: ledger)
        try require(definitions.first(where: { $0.name == NativeFolderTools.readName })?.resultByteBudget == NativeFolderTools.readResultBudget, "Reads keep their own result budget")
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
        let first = recorded.changes(for: "w1")
        let third = recorded.changes(for: "w3")
        try require(first.count == 1 && first[0].kind == .created && third.count == 1 && third[0].before == "hello\n" && third[0].after == "goodbye\n",
                    "Each tool call's change is recorded under its call id")
        grantsBox.set([], for: "conversation")
        try require(registry.active(enabledIDs: [NativeFolderTools.toolID]).isEmpty, "Revoking the last grant stops advertising the tools")
        let always = NativeToolRegistry(definitions: NativeFolderTools.definitions(grants: { grantsBox.grants(for: "conversation") }, ledger: ledger, alwaysAvailable: true))
        let (revoked, _) = try await NativeWebToolsSelftest.loop(always, rounds: [
            NativeWebToolsSelftest.call("r1", NativeFolderTools.readName, "{\"path\":\"\(root)/notes/one.txt\"}"), NativeWebToolsSelftest.reply("ok"),
        ], enabled: [NativeFolderTools.toolID])
        try require(revoked?.activities.first?.state == .failed && revoked?.activities.first?.result?.contains("No folder has been granted") == true,
                    "A call after revocation fails with a refusal the model can read")
        let late = NativeFileChangeLedger()
        late.record(NativeFileChange(path: root + "/late.txt", kind: .created, after: "x"))
        let lateBox = NativeFileChangeRecorder()
        late.attach { activity, change in lateBox.add(activity, change) }
        try require(lateBox.changes(for: "").count == 1, "A change recorded before a sink attaches is delivered when it does")

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
        let lateChange = NativeFileChange(path: root + "/late.txt", kind: .created, after: "late")
        try repository.saveDisplayBlocks(reply.displayBlocks + [.fileChange(lateChange)], messageID: reply.id)
        try require(try repository.messages(conversationID: conversation.id).first?.displayBlocks.count == 2, "A change landing after the turn ended is still saved on the message")

        let hunks = NativeLineDiff.hunks(before: "one\ntwo\nthree\nfour\nfive\nsix\nseven\n", after: "one\ntwo\nthree\nFOUR\nfive\nsix\nseven\n", context: 1)
        try require(hunks.count == 1 && hunks[0].lines == [.same("three"), .removed("four"), .added("FOUR"), .same("five")], "Diff hunks show changed lines with context: \(hunks)")
        try require(NativeLineDiff.summary(before: "a\nb", after: "a\nc\nd") == "+2 -1" && NativeLineDiff.summary(before: "x", after: "x") == "No line changes", "Diff summaries count lines")
        let capped2 = NativeFileChange(path: "/tmp/big", kind: .created, after: String(repeating: "x", count: NativeFileChange.contentCap + 10))
        try require(capped2.truncated && capped2.after == nil && capped2.before == nil, "Oversized content is marked too large instead of diffing a prefix")
        try require(NativeFolderTools.grantNote([grant])?.contains(grant.path) == true && NativeFolderTools.grantNote([]) == nil, "The prompt note lists granted paths")
        print("  native folder tools OK (grants, identity, bookmarks, path guard, symlink refusal, swapped root, list, bounded reads, binary, search caps, write, edit, CRLF, permissions, long names, move, mkdir, ledger, advertisement, scripted loop, revocation, persistence, diff)")
    }
}
