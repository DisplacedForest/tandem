import Foundation

@MainActor
extension SelfTest {
    static func runSharedFolderAvailability() async throws {
        let require = NativeTaskFixture.require
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("shared-availability-\(UUID().uuidString.lowercased())", isDirectory: true)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        var locked: [String] = []
        defer {
            for path in locked { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
            try? manager.removeItem(at: base)
        }
        func folder(_ name: String) throws -> URL {
            let url = base.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func mode(_ path: String, _ value: Int) throws {
            try manager.setAttributes([.posixPermissions: value], ofItemAtPath: path)
            locked.append(path)
        }
        func tool(_ name: String, _ grants: [FolderGrant]) throws -> NativeToolDefinition {
            let definitions = NativeFolderTools.definitions(grants: { grants }, ledger: NativeFileChangeLedger(), alwaysAvailable: true)
            guard let found = definitions.first(where: { $0.name == name }) else { throw NativeTaskFixture.Failure.assertion("Missing tool \(name)") }
            return found
        }
        func failure(_ name: String, _ grants: [FolderGrant], _ arguments: [String: NativeJSONValue]) async throws -> String {
            do {
                _ = try await tool(name, grants).execute(arguments)
            } catch {
                return error.localizedDescription
            }
            throw NativeTaskFixture.Failure.assertion("\(name) should have failed")
        }
        func located(_ access: NativeFolderAccess, _ path: String) -> NativeFolderAccessError? {
            do { _ = try access.locate(path); return nil } catch { return error as? NativeFolderAccessError }
        }
        let nothing = "No folder has been shared with this chat."

        try require(located(NativeFolderAccess(grants: []), "/anything/at/all.txt") == .noGrants
                    && NativeFolderAccessError.noGrants.errorDescription == nothing,
                    "A chat with nothing shared still says nothing is shared")
        let unsharedRead = try await failure(NativeFolderTools.readName, [], ["path": .string("notes.txt")])
        try require(unsharedRead == nothing, "The read tool says nothing is shared when nothing is: \(unsharedRead)")

        let scratch = try FolderGrant.make(url: try folder("tandem-scratch"))
        try require(scratch.availability == .usable && NativeFolderAccess(grants: [scratch]).roots == [scratch], "A folder on disk is usable")
        let target = scratch.path + "/check.txt"
        _ = try await tool(NativeFolderTools.writeName, [scratch]).execute(["path": .string(target), "content": .string("exact words\n")])
        try require(try String(contentsOfFile: target, encoding: .utf8) == "exact words\n"
                    && (try manager.contentsOfDirectory(atPath: scratch.path)) == ["check.txt"],
                    "A newly shared folder gets the requested file with its exact content and nothing else")

        try manager.removeItem(atPath: scratch.path)
        let gone = NativeFolderAccess(grants: [scratch])
        let missingSentence = "The shared folder tandem-scratch can't be found. It was at \(scratch.path) and may have been moved, renamed or deleted. It's still shared with this chat. Put it back, or choose it again in Settings, Rules."
        try require(scratch.availability == .missing && gone.roots.isEmpty && gone.unavailable.count == 1, "A deleted folder is missing, and still counted as shared")
        for path in [target, "check.txt", scratch.path] {
            let error = located(gone, path)
            try require(error == .unavailable(name: "tandem-scratch", path: scratch.path, state: .missing) && error?.errorDescription == missingSentence,
                        "A missing folder is named, never reported as nothing shared: \(path) \(String(describing: error))")
        }
        for (name, arguments) in [(NativeFolderTools.readName, ["path": NativeJSONValue.string(target)]),
                                  (NativeFolderTools.listName, ["path": .string(scratch.path)]),
                                  (NativeFolderTools.searchName, ["query": .string("exact")]),
                                  (NativeFolderTools.writeName, ["path": .string(target), "content": .string("again")]),
                                  (NativeFolderTools.mkdirName, ["path": .string(scratch.path + "/made")])] {
            let said = try await failure(name, [scratch], arguments)
            try require(said == missingSentence, "\(name) names the missing folder: \(said)")
        }
        try require(!manager.fileExists(atPath: scratch.path), "Nothing is created where the missing folder was")
        try require(located(gone, "/somewhere/else.txt") == .outsideGrants("/somewhere/else.txt"), "A path nowhere near the share is still outside it")

        let other = try folder("elsewhere")
        try "private".write(to: other.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try manager.createDirectory(atPath: scratch.path, withIntermediateDirectories: true)
        try require(scratch.availability == .missing && located(NativeFolderAccess(grants: [scratch]), target)?.errorDescription == missingSentence,
                    "A different folder put at the same path is not accepted as the shared one")
        do {
            _ = try NativeFolderIO.openRoot(scratch)
            throw NativeTaskFixture.Failure.assertion("A replaced folder must not open")
        } catch let error as NativeFolderAccessError {
            try require(error == .unavailable(name: "tandem-scratch", path: scratch.path, state: .missing), "Opening a replaced folder says it is missing: \(error)")
        }
        try manager.removeItem(atPath: scratch.path)
        try manager.createSymbolicLink(atPath: scratch.path, withDestinationPath: other.path)
        let linked = try await failure(NativeFolderTools.readName, [scratch], ["path": .string(scratch.path + "/secret.txt")])
        try require(scratch.availability == .missing && linked == missingSentence, "A link put at the saved path does not widen the share: \(linked)")
        try manager.removeItem(atPath: scratch.path)

        let volume = "tandem-selftest-\(UUID().uuidString.prefix(8))"
        let away = FolderGrant(path: "/Volumes/\(volume)/Plans")
        let awaySentence = "The shared folder Plans is on the drive \(volume), which isn't connected. Connect the drive and try again."
        try require(away.availability == .offline(volume) && located(NativeFolderAccess(grants: [away]), "notes.txt")?.errorDescription == awaySentence,
                    "A folder on a drive that isn't connected says so")
        let awayRead = try await failure(NativeFolderTools.readName, [away], ["path": .string(away.path + "/notes.txt")])
        try require(awayRead == awaySentence, "The read tool names the disconnected drive: \(awayRead)")

        let closed = try FolderGrant.make(url: try folder("Receipts"))
        try mode(closed.path, 0)
        let closedSentence = "macOS won't let Tandem open the shared folder Receipts. Choose it again in Settings, Rules to give access."
        let closedRead = try await failure(NativeFolderTools.listName, [closed], ["path": .string(closed.path)])
        try require(closed.availability == .denied && closedRead == closedSentence, "A folder that can't be opened says so: \(closedRead)")
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path)
        try require(closed.availability == .usable, "Access coming back is seen on the next check")

        let fixed = try FolderGrant.make(url: try folder("Archive"))
        try "kept".write(toFile: fixed.path + "/old.txt", atomically: true, encoding: .utf8)
        try mode(fixed.path, 0o555)
        let fixedSentence = "Archive can be read but not changed. The folder or its drive doesn't allow changes."
        guard case .object = try await tool(NativeFolderTools.readName, [fixed]).execute(["path": .string(fixed.path + "/old.txt")]) else {
            throw NativeTaskFixture.Failure.assertion("A folder that refuses changes can still be read")
        }
        let fixedWrite = try await failure(NativeFolderTools.writeName, [fixed], ["path": .string(fixed.path + "/new.txt"), "content": .string("x")])
        try require(fixed.availability == .usable && fixedWrite == fixedSentence && (try manager.contentsOfDirectory(atPath: fixed.path)) == ["old.txt"],
                    "A folder that refuses changes says so and nothing is written: \(fixedWrite)")
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixed.path)

        let kept = try FolderGrant.make(url: try folder("Seedlings"))
        let lost = try FolderGrant.make(url: try folder("Invoices"))
        try manager.removeItem(atPath: lost.path)
        let mixed = NativeFolderAccess(grants: [kept, lost])
        try require(mixed.roots == [kept] && (try mixed.locate(kept.path + "/a.txt")).root == kept, "The usable folder keeps working beside a missing one")
        try require(located(mixed, lost.path + "/a.txt") == .unavailable(name: "Invoices", path: lost.path, state: .missing),
                    "A path under the missing folder names it instead of calling it outside every share")
        try require(located(mixed, "a.txt") == .relativeWithoutAnchor("a.txt"), "A relative path is not quietly pinned to the one usable folder")
        let note = NativeFolderTools.grantNote([kept, lost, away]) ?? ""
        try require(note.contains("- Seedlings: \(kept.path)\n") && note.contains("- Invoices: \(lost.path) (can't be found right now)")
                    && note.contains("(its drive isn't connected right now)"), "The folder note marks the ones that aren't there: \(note)")

        let racing = try FolderGrant.make(url: try folder("Racing"))
        let racingAccess = NativeFolderAccess(grants: [racing])
        let place = try racingAccess.locate(racing.path + "/late.txt")
        try manager.removeItem(atPath: racing.path)
        do {
            _ = try NativeFolderTools.write(place, content: "late", ledger: NativeFileChangeLedger())
            throw NativeTaskFixture.Failure.assertion("A write after the folder vanished must fail")
        } catch let error as NativeFolderAccessError {
            try require(error == .unavailable(name: "Racing", path: racing.path, state: .missing) && !manager.fileExists(atPath: racing.path),
                        "A folder that vanishes between the check and the write is reported missing and nothing is created: \(error)")
        }

        let wandering = try FolderGrant.make(url: try folder("Wandering"))
        let renamed = base.appendingPathComponent("Wandered", isDirectory: true)
        try manager.moveItem(atPath: wandering.path, toPath: renamed.path)
        try require(wandering.availability == .usable && NativeFolderAccess(grants: [wandering]).roots.map(\.path) == [renamed.resolvingSymlinksInPath().path],
                    "A folder renamed on the same drive is still followed")
        let bin = try folder(".Trash")
        let binned = bin.appendingPathComponent("Wandered", isDirectory: true)
        try manager.moveItem(at: renamed, to: binned)
        let binnedWrite = try await failure(NativeFolderTools.writeName, [wandering], ["path": .string("note.txt"), "content": .string("x")])
        try require(wandering.availability == .missing && NativeFolderAccess(grants: [wandering]).roots.isEmpty
                    && binnedWrite.hasPrefix("The shared folder Wandering can't be found.")
                    && (try manager.contentsOfDirectory(atPath: binned.path)).isEmpty,
                    "A folder in the Trash can't be found, and nothing is written into the Trash: \(binnedWrite)")
        try manager.moveItem(at: binned, to: renamed)
        try require(wandering.availability == .usable && NativeFolderAccess(grants: [wandering]).roots.count == 1, "Putting the folder back restores the share")
        let binnedAgain = bin.appendingPathComponent("Wandered", isDirectory: true)
        try manager.moveItem(at: renamed, to: binnedAgain)
        try manager.createSymbolicLink(atPath: renamed.path, withDestinationPath: binnedAgain.path)
        let throughLink = try await failure(NativeFolderTools.writeName, [wandering], ["path": .string("note.txt"), "content": .string("x")])
        try require(wandering.availability == .missing && throughLink.hasPrefix("The shared folder Wandering can't be found.")
                    && (try manager.contentsOfDirectory(atPath: binnedAgain.path)).isEmpty,
                    "A link at the saved place that points into the Trash does not bring the share back: \(throughLink)")
        var followed = wandering
        followed.path = renamed.path
        do {
            _ = try NativeFolderIO.openRoot(followed)
            throw NativeTaskFixture.Failure.assertion("A folder whose real place is the Trash must not open")
        } catch let error as NativeFolderAccessError {
            guard case .unavailable(_, _, .missing) = error else { throw NativeTaskFixture.Failure.assertion("Opening through the link says missing: \(error)") }
        }
        try manager.removeItem(atPath: renamed.path)
        try manager.moveItem(at: binnedAgain, to: renamed)

        let whole = try FolderGrant.make(url: base)
        let underBin = bin.appendingPathComponent("dropped.txt").path
        let binSentence = "\(underBin) is in the Trash, which the file tools leave alone."
        let intoBin = try await failure(NativeFolderTools.writeName, [whole], ["path": .string(underBin), "content": .string("x")])
        let listBin = try await failure(NativeFolderTools.listName, [whole], ["path": .string(bin.path)])
        try require(intoBin == binSentence && listBin == "\(bin.path) is in the Trash, which the file tools leave alone."
                    && !manager.fileExists(atPath: underBin),
                    "Sharing a parent folder does not reach into its Trash: \(intoBin)")

        for spelled in [".trash", ".TRASH", ".Trashes", ".trashes", ".TrAsHeS", ".Tra\u{17F}h", ".tra\u{17F}he\u{17F}", ".\u{FF34}rash"] {
            let asked = base.appendingPathComponent(spelled).appendingPathComponent("dropped.txt").path
            let said = try await failure(NativeFolderTools.writeName, [whole], ["path": .string(asked), "content": .string("x")])
            try require(said == "\(asked) is in the Trash, which the file tools leave alone." && (try manager.contentsOfDirectory(atPath: bin.path)).isEmpty,
                        "Another spelling of the Trash folder's name is refused too: \(said)")
        }
        try "kept".write(to: bin.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
        let recovered = base.appendingPathComponent("Recovered").path
        for spelled in [".Trash", ".trash", ".Tra\u{17F}h"] {
            let from = base.appendingPathComponent(spelled).path
            let moved = try await failure(NativeFolderTools.moveName, [whole], ["from": .string(from), "to": .string(recovered)])
            let made = try await failure(NativeFolderTools.mkdirName, [whole], ["path": .string(from + "/made")])
            try require(moved == "\(from) is in the Trash, which the file tools leave alone." && made == "\(from)/made is in the Trash, which the file tools leave alone."
                        && !manager.fileExists(atPath: recovered) && (try manager.contentsOfDirectory(atPath: bin.path)) == ["kept.txt"],
                        "The Trash folder itself can't be moved out or added to under any spelling: \(moved) / \(made)")
        }
        let intoBinMove = try await failure(NativeFolderTools.moveName, [whole], ["from": .string(base.appendingPathComponent("elsewhere/secret.txt").path), "to": .string(bin.appendingPathComponent("secret.txt").path)])
        try require(intoBinMove.hasSuffix("is in the Trash, which the file tools leave alone.") && manager.fileExists(atPath: base.appendingPathComponent("elsewhere/secret.txt").path),
                    "A move can't land in the Trash folder either: \(intoBinMove)")
        try require(FolderGrant.isTrashEntry(directory: base.path, name: ".Trash") && !FolderGrant.isTrashEntry(directory: base.path, name: "elsewhere")
                    && !FolderGrant.isTrashEntry(directory: base.path, name: "not-there")
                    && FolderGrant.throughTrash(root: base.path, components: [".Trash", "kept.txt"]) && !FolderGrant.throughTrash(root: base.path, components: ["elsewhere", "secret.txt"]),
                    "A name is the Trash folder when it reaches the same folder on disk, however it is spelled")
        try manager.removeItem(at: bin.appendingPathComponent("kept.txt"))
        let wholeRoot = try NativeFolderIO.openRoot(whole)
        do {
            _ = try NativeFolderIO.openDirectory(wholeRoot, ".Trash", display: bin.path)
            throw NativeTaskFixture.Failure.assertion("Opening the Trash folder under a share must fail")
        } catch let error as NativeFolderAccessError {
            try require(error == .inTrash(bin.path), "A folder that really is the Trash is refused when it is opened, whatever was asked for: \(error)")
        }
        do {
            _ = try NativeFolderIO.openDirectory(wholeRoot, ".trash", display: bin.path)
            throw NativeTaskFixture.Failure.assertion("Opening the Trash folder by another spelling must fail")
        } catch let error as NativeFolderAccessError {
            try require(error == .inTrash(bin.path) || error == .notFound(bin.path), "Another spelling never opens the Trash folder: \(error)")
        }

        let bare = try FolderGrant.make(url: try folder("Bare"))
        let unseen = bare.path + "/.Tra\u{200C}sh/child"
        let unseenMade = try await failure(NativeFolderTools.mkdirName, [bare], ["path": .string(unseen)])
        try require(unseenMade == "\(unseen) is in the Trash, which the file tools leave alone." && (try manager.contentsOfDirectory(atPath: bare.path)).isEmpty
                    && FolderGrant.isTrashName(".Tra\u{200C}sh") && FolderGrant.isTrashName(".\u{200D}Trashes") && !FolderGrant.isTrashName(".Trash\u{200C}-notes"),
                    "A name with an unseen character in it that a drive may read as the Trash's name is not created: \(unseenMade)")

        let outer = try FolderGrant.make(url: try folder("Outer"))
        let inner = try FolderGrant.make(url: try folder("Outer/safe"))
        try manager.createDirectory(atPath: outer.path + "/.Trash", withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: outer.path + "/.Trash/back", withDestinationPath: inner.path)
        let roundabout = outer.path + "/.Trash/back/note.txt"
        let roundaboutWrite = try await failure(NativeFolderTools.writeName, [outer, inner], ["path": .string(roundabout), "content": .string("x")])
        try require(roundaboutWrite == "\(roundabout) is in the Trash, which the file tools leave alone." && (try manager.contentsOfDirectory(atPath: inner.path)).isEmpty,
                    "A path that goes through the Trash folder is refused even when a link there leads back into another share: \(roundaboutWrite)")
        _ = try await tool(NativeFolderTools.writeName, [outer, inner]).execute(["path": .string(inner.path + "/note.txt"), "content": .string("direct")])
        try require(try String(contentsOfFile: inner.path + "/note.txt", encoding: .utf8) == "direct", "The same file asked for directly is written")

        let linked = try FolderGrant.make(url: try folder("Linked"))
        try "plain".write(toFile: linked.path + "/notes.txt", atomically: true, encoding: .utf8)
        try manager.linkItem(atPath: linked.path + "/notes.txt", toPath: linked.path + "/.Trash")
        guard case .object = try await tool(NativeFolderTools.readName, [linked]).execute(["path": .string(linked.path + "/notes.txt")]) else {
            throw NativeTaskFixture.Failure.assertion("An ordinary file is read even when a file named like the Trash shares its contents")
        }
        try require(!FolderGrant.isTrashEntry(directory: linked.path, name: "notes.txt") && !FolderGrant.throughTrash(root: linked.path, components: ["notes.txt"]),
                    "Only a folder counts as the Trash folder in the on-disk comparison")

        try require(FolderGrant.inTrash("/home/.TRASH/Plans") && FolderGrant.inTrash("/home/.trashes/501/Plans") && FolderGrant.inTrash("/home/.Tra\u{17F}h/Plans")
                    && !FolderGrant.inTrash("/home/.Trash-notes/Plans") && !FolderGrant.inTrash("/home/Trash/Plans"),
                    "The Trash name is matched whatever its capitals or letter forms, and nothing else is")
        try require(FolderGrant.inTrash("/home/.Trash/Plans") && FolderGrant.inTrash("/Volumes/Storage/.Trashes/501/Plans")
                    && !FolderGrant.inTrash("/home/Trash/Plans") && !FolderGrant.inTrash("/home/.Trash-notes/Plans"),
                    "Only a real Trash folder counts")

        try require(FolderAvailability.missing.rowNote == "Can't be found." && FolderAvailability.offline("x").rowNote == "On a drive that isn't connected."
                    && FolderAvailability.denied.rowNote == "Can't be opened." && FolderAvailability.usable.rowNote == nil,
                    "Row notes read as written")
        try require(FolderAvailability.missing.chipNote("Seedlings") == "Seedlings can't be found"
                    && FolderAvailability.offline("x").chipNote("Seedlings") == "Seedlings is on a drive that isn't connected"
                    && FolderAvailability.denied.chipNote("Seedlings") == "Seedlings can't be opened" && FolderAvailability.usable.chipNote("Seedlings") == nil,
                    "Chip notes read as written and carry no path")
        try require(SharedFolderRows.noted(.literal("Shared with the chat Seed orders"), state: .missing) == .literal("Shared with the chat Seed orders. Can't be found.")
                    && SharedFolderRows.noted(SharedFolderRows.marked(.literal("Shared with the chat Receipts"), readOnly: true), state: .denied)
                        == .literal("Shared with the chat Receipts. Read only. Can't be opened.")
                    && SharedFolderRows.noted(SharedFolderRows.companionSentence, state: .offline("x")).plain(name: "Ada") == "Shared with Ada's thread. On a drive that isn't connected.",
                    "The row's second line carries the state after the place")
        let banned = ["grant", "bookmark", "identity", "inode", "\u{2014}"]
        let sentences = [missingSentence, awaySentence, closedSentence, fixedSentence, SharedFolderRows.chooseAgain, SharedFolderRows.choosePrompt,
                         SharedFolderRows.notMoved, SharedFolderRows.alreadyShared("Seedlings"),
                         NativeFolderAccessError.inTrash("/home/.Trash/a.txt").errorDescription ?? ""]
            + FolderAvailability.notes.compactMap(\.rowNote) + FolderAvailability.notes.compactMap { $0.chipNote("Seedlings") }
        for sentence in sentences {
            for word in banned where sentence.range(of: word, options: .caseInsensitive) != nil && !base.path.localizedCaseInsensitiveContains(word) {
                throw NativeTaskFixture.Failure.assertion("\"\(sentence)\" uses \(word)")
            }
        }
        print("shared folder availability OK")
    }

    static func runSharedFolderAvailabilityStore() throws {
        let require = NativeTaskFixture.require
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("shared-availability-store-\(UUID().uuidString.lowercased())", isDirectory: true)
        let attachments = base.appendingPathComponent("attachments", isDirectory: true)
        try manager.createDirectory(at: attachments, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let repository = SharedFolderFailingRepository(inner: try LocalChatRepository(inMemory: true, artifactDirectory: attachments,
                                                                                      projectsDirectory: base.appendingPathComponent("projects", isDirectory: true)))
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, attachmentStore: NativeAttachmentStore(directory: attachments))
        func folder(_ name: String) throws -> URL {
            let url = base.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func add(_ id: String, _ title: String, _ grants: [FolderGrant], project: String? = nil) throws {
            var conversation = Conversation(id: id, title: title, messages: [], updatedAt: Date())
            conversation.grants = grants
            conversation.projectID = project
            try repository.saveConversation(conversation)
            conversation.isPersisted = true
            store.conversations.insert(conversation, at: 0)
            store.refreshConversationGrants(id)
        }
        func row(_ id: String) -> SharedFolderRow? {
            store.checkSharedFoldersNow()
            return store.sharedFolderRows.first { $0.id == id }
        }
        func access(_ id: String) -> NativeFolderAccess { NativeFolderAccess(grants: store.nativeGrantSource.grants(for: id)) }
        func refused(_ id: String, _ path: String) -> NativeFolderAccessError? {
            do { _ = try access(id).locate(path); return nil } catch { return error as? NativeFolderAccessError }
        }

        let scratch = try FolderGrant.make(url: try folder("tandem-scratch"))
        try add("a-check", "Folder check", [scratch])
        store.selectedID = "a-check"
        let rowID = "chat|a-check|\(scratch.id)"
        try require(row(rowID)?.state == .usable && row(rowID)?.spoken(name: nil) == "Shared with the chat Folder check" && refused("a-check", "a.txt") == nil,
                    "A usable folder reads the same in the row and to the file tools")
        try manager.removeItem(atPath: scratch.path)
        try require(store.sharedFolderRows.first { $0.id == rowID }?.state == .usable && store.folderState(scratch) == .usable
                    && refused("a-check", "a.txt") == .unavailable(name: "tandem-scratch", path: scratch.path, state: .missing),
                    "Before the next check the row still shows the last known state, and the file tools refuse on their own check")
        guard let missing = row(rowID) else { throw NativeTaskFixture.Failure.assertion("A missing folder keeps its row") }
        try require(missing.title == "tandem-scratch" && missing.state == .missing && missing.state.canChooseAgain
                    && missing.spoken(name: nil) == "Shared with the chat Folder check. Can't be found."
                    && store.selectedGrants.map(\.id) == [scratch.id]
                    && refused("a-check", "a.txt") == .unavailable(name: "tandem-scratch", path: scratch.path, state: .missing),
                    "A missing folder keeps its name, its share and its chip, and the row and the file tools agree: \(missing)")
        try require(try repository.inner.listConversations().first { $0.id == "a-check" }?.grants == [scratch], "The saved share is untouched while the folder is missing")

        let taken = try FolderGrant.make(url: try folder("Taken"))
        try add("a-two", "Two folders", [FolderGrant.make(url: try folder("Gone")), taken])
        let twoID = "chat|a-two|\(store.conversations.first { $0.id == "a-two" }!.grants[0].id)"
        try manager.removeItem(at: base.appendingPathComponent("Gone"))
        guard let twoRow = row(twoID) else { throw NativeTaskFixture.Failure.assertion("The second chat's missing folder is listed") }
        try require(!store.chooseAgain(twoRow, url: URL(fileURLWithPath: taken.path).appendingPathComponent("inner-\(UUID().uuidString)"))
                    && store.rulesNotice != nil, "Choosing something that isn't a folder is refused")
        try manager.createDirectory(atPath: taken.path + "/inner", withIntermediateDirectories: true)
        try require(!store.chooseAgain(twoRow, url: URL(fileURLWithPath: taken.path + "/inner")) && store.rulesNotice == SharedFolderRows.alreadyShared("inner")
                    && row(twoID)?.state == .missing, "Choosing a folder inside another share of the same chat is refused")

        let restored = try folder("tandem-scratch-moved")
        repository.failConversations = true
        try require(!store.chooseAgain(missing, url: restored) && store.rulesNotice == SharedFolderRows.notMoved && row(rowID)?.state == .missing
                    && store.conversations.first { $0.id == "a-check" }?.grants == [scratch],
                    "A choice that can't be saved leaves the share as it was and says so")
        repository.failConversations = false
        try require(store.chooseAgain(missing, url: restored) && store.rulesNotice == nil, "Choosing the folder again saves")
        let chosen = store.conversations.first { $0.id == "a-check" }?.grants ?? []
        try require(chosen.count == 1 && chosen[0].id == scratch.id && chosen[0].path == restored.resolvingSymlinksInPath().path && chosen[0].name == "tandem-scratch-moved"
                    && chosen[0].identity != scratch.identity && row(rowID)?.state == .usable && row(rowID)?.title == "tandem-scratch-moved"
                    && refused("a-check", "a.txt") == nil && refused("a-check", scratch.path + "/a.txt") == .outsideGrants(scratch.path + "/a.txt"),
                    "The share now points only at the chosen folder, checked like a new share: \(chosen)")
        try require(try repository.inner.listConversations().first { $0.id == "a-check" }?.grants == chosen, "The chosen folder is saved")

        let guarded = try FolderGrant.make(url: try folder("Guarded"))
        var readOnly = guarded
        readOnly.readOnly = true
        let stray = try FolderGrant.make(url: try folder("Stray"))
        try add("a-guard", "Guarded chat", [readOnly, stray])
        let guardedMoved = base.appendingPathComponent("Guarded moved", isDirectory: true)
        try manager.moveItem(atPath: guarded.path, toPath: guardedMoved.path)
        try manager.createDirectory(at: guardedMoved.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try manager.removeItem(atPath: stray.path)
        guard let strayRow = row("chat|a-guard|\(stray.id)") else { throw NativeTaskFixture.Failure.assertion("The stray folder is listed") }
        try require(row("chat|a-guard|\(readOnly.id)")?.state == .usable, "A renamed read only folder is still followed")
        try require(!store.chooseAgain(strayRow, url: guardedMoved.appendingPathComponent("inner"))
                    && store.rulesNotice == SharedFolderRows.alreadyShared("inner")
                    && store.conversations.first { $0.id == "a-guard" }?.grants == [readOnly, stray],
                    "Choosing a folder inside where a read only share now really is gets refused")

        guard let project = store.createProject(name: "Spring garden") else { throw NativeTaskFixture.Failure.assertion("The project saves") }
        let plans = try FolderGrant.make(url: try folder("Plans"))
        try require(store.saveProjectEdits(project.id, name: project.name, instructions: "", grants: [plans]), "The project folder saves")
        try add("a-member", "Member", [], project: project.id)
        let projectRowID = "project|\(project.id)|\(plans.id)"
        try require(row(projectRowID)?.state == .usable && refused("a-member", "a.txt") == nil, "A chat in the project can use the project's folder")
        try manager.removeItem(atPath: plans.path)
        guard let projectRow = row(projectRowID) else { throw NativeTaskFixture.Failure.assertion("The project's missing folder keeps its row") }
        try require(projectRow.state == .missing && projectRow.spoken(name: nil) == "Shared with the project Spring garden, used by 1 chat. Can't be found."
                    && refused("a-member", "a.txt") == .unavailable(name: "Plans", path: plans.path, state: .missing)
                    && store.project(project.id)?.grants == [plans],
                    "A project's missing folder is named to its chats and kept on the project: \(projectRow)")
        let plansAgain = try folder("Plans again")
        try require(store.chooseAgain(projectRow, url: plansAgain) && row(projectRowID)?.state == .usable && refused("a-member", "a.txt") == nil
                    && store.project(project.id)?.grants.map(\.id) == [plans.id], "Choosing a project's folder again restores it for its chats")
        let editorKept = store.projectFolders(project.id, edited: [plans], opened: [plans.id])
        try require(editorKept.map(\.id) == [plans.id] && editorKept.first?.path == plansAgain.resolvingSymlinksInPath().path,
                    "A project editor that was already open takes the recovered location, not the one it opened with: \(editorKept)")
        let added = try FolderGrant.make(url: try folder("Added in editor"))
        try require(store.projectFolders(project.id, edited: [plans, added], opened: [plans.id]).map(\.id) == [plans.id, added.id]
                    && store.projectFolders(project.id, edited: [FolderGrant(id: "dropped", path: "/nowhere/dropped")], opened: ["dropped"]).isEmpty,
                    "The editor still keeps a folder it added and drops one that was removed elsewhere")
        try manager.removeItem(at: plansAgain)
        guard let again = row(projectRowID) else { throw NativeTaskFixture.Failure.assertion("The project row is still listed") }
        try require(store.stopSharing(again) && row(projectRowID) == nil && refused("a-member", "a.txt") == .noGrants,
                    "Stop sharing works on a missing folder, and the chat then has nothing shared")

        try manager.removeItem(at: restored)
        guard let last = row(rowID) else { throw NativeTaskFixture.Failure.assertion("The chat row is still listed") }
        store.selectedID = "a-two"
        try require(store.stopSharing(last) && row(rowID) == nil && refused("a-check", "a.txt") == .noGrants && store.selectedID == "a-two"
                    && refused("a-two", taken.path + "/a.txt") == nil,
                    "Stopping a missing share from another chat updates the row and the file tools together")
        print("shared folder availability store OK")
    }
}
