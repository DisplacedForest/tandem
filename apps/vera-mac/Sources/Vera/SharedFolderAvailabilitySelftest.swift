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
                         SharedFolderRows.notMoved, SharedFolderRows.alreadyShared("Seedlings")]
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
        func row(_ id: String) -> SharedFolderRow? { store.sharedFolderRows.first { $0.id == id } }
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
