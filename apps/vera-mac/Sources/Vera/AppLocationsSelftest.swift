import Foundation

@MainActor
enum AppLocationsSelftest {
    static func run() throws {
        guard let runRoot = AppLocations.headlessRoot else { throw NativeTaskFixture.Failure.assertion("This check runs inside a headless run") }
        let scratch = runRoot.appendingPathComponent("tandem-locations-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try checkDecision(scratch)
        try checkNoProductionPermit(scratch)
        try checkCleanup(scratch.appendingPathComponent("cleanup", isDirectory: true))
        try checkStrictReferences(scratch.appendingPathComponent("strict", isDirectory: true))
        try checkResolver(scratch)
        try checkStandardFolderSpellings(scratch.appendingPathComponent("spellings", isDirectory: true))
        try checkCreatedThisLaunch(scratch.appendingPathComponent("created", isDirectory: true))
        try checkTrap(scratch)
        try checkSettingTrap(scratch.appendingPathComponent("setting-trap", isDirectory: true))
        try checkScratchRoots(scratch.appendingPathComponent("roots", isDirectory: true))
        try checkLegacyImport(scratch.appendingPathComponent("legacy", isDirectory: true))
        try checkLaunchPlan()
    }

    static func checkDecision(_ scratch: URL) throws {
        let require = NativeTaskFixture.require
        let database = scratch.appendingPathComponent("pair/vera.sqlite")
        let folder = scratch.appendingPathComponent("pair/attachments", isDirectory: true)
        let allowed = StartupCleanup.Inputs(
            overrideInEffect: false, runsFromAppBundle: true, database: database, databaseCreatedThisLaunch: false, mentionedFileCount: 2,
            folder: folder, folderHasFiles: true, resolvedDatabase: database, resolvedFolder: folder)
        try require(StartupCleanup.rulesAllow(allowed), "The clean-up runs for the app's own existing database and its folder")
        var withOverride = allowed
        withOverride.overrideInEffect = true
        try require(StartupCleanup.rulesAllow(withOverride) == false, "Any override turns the clean-up off")
        var looseBuild = allowed
        looseBuild.runsFromAppBundle = false
        try require(StartupCleanup.rulesAllow(looseBuild) == false, "A build that isn't a packaged app never runs the clean-up")
        var createdNow = allowed
        createdNow.databaseCreatedThisLaunch = true
        try require(StartupCleanup.rulesAllow(createdNow) == false, "A database created in this launch turns the clean-up off")
        var mentionsNothing = allowed
        mentionsNothing.mentionedFileCount = 0
        try require(StartupCleanup.rulesAllow(mentionsNothing) == false, "A database that mentions no files over a folder with files turns the clean-up off")
        var mentionsNothingEmptyFolder = mentionsNothing
        mentionsNothingEmptyFolder.folderHasFiles = false
        try require(StartupCleanup.rulesAllow(mentionsNothingEmptyFolder), "An empty folder with a database that mentions nothing has nothing to protect")
        var otherFolder = allowed
        otherFolder.folder = scratch.appendingPathComponent("elsewhere/attachments", isDirectory: true)
        try require(StartupCleanup.rulesAllow(otherFolder) == false, "A folder that wasn't resolved with the database turns the clean-up off")
        var otherDatabase = allowed
        otherDatabase.database = scratch.appendingPathComponent("elsewhere/vera.sqlite")
        try require(StartupCleanup.rulesAllow(otherDatabase) == false, "A database that isn't the default one turns the clean-up off")
    }

    static func checkCleanup(_ root: URL) throws {
        let require = NativeTaskFixture.require
        let database = root.appendingPathComponent("vera.sqlite")
        let folder = root.appendingPathComponent("attachments", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let names = (1...5).map { "file-\($0).png" }
        for name in names { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
        let subfolder = folder.appendingPathComponent("kept-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: subfolder.appendingPathComponent("inside.txt"))
        let target = outside.appendingPathComponent("target.txt")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.png"), withDestinationURL: target)
        let all = Set(names + ["kept-folder", "link.png"])
        func listing() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) }

        let fresh = try LocalChatRepository(url: database, artifactDirectory: folder, projectsDirectory: root.appendingPathComponent("projects", isDirectory: true))
        try require(fresh.createdThisLaunch, "A new database reports that it was created now")
        let freshPermit = try permit(fresh, database: database, folder: folder)
        try require(freshPermit == nil, "A new database never permits the clean-up")
        try require(try listing() == all, "A new database removes nothing")

        let mentionedNothing = try LocalChatRepository(url: database, artifactDirectory: folder, projectsDirectory: root.appendingPathComponent("projects", isDirectory: true))
        try require(!mentionedNothing.createdThisLaunch, "A reopened database reports that it already existed")
        try require(try permit(mentionedNothing, database: database, folder: folder) == nil, "A database that mentions nothing never permits the clean-up")
        try require(try listing() == all, "A database that mentions nothing removes nothing")

        let conversation = Conversation(id: "cleanup", title: "Clean-up", messages: [], updatedAt: Date())
        try mentionedNothing.saveConversation(conversation)
        let attachments = names.prefix(2).map { MessageAttachment(name: $0, ext: "PNG", isImage: true, fileName: $0, mime: "image/png", byteSize: 10) }
        try mentionedNothing.saveMessage(Message(role: .user, text: "Two files", attachments: Array(attachments)), conversationID: conversation.id, ordinal: 0)

        let reopened = try LocalChatRepository(url: database, artifactDirectory: folder, projectsDirectory: root.appendingPathComponent("projects", isDirectory: true))
        guard let allowed = try permit(reopened, database: database, folder: folder) else {
            throw NativeTaskFixture.Failure.assertion("An existing database that mentions two files permits the clean-up")
        }
        let elsewhere = NativeAttachmentStore(directory: outside)
        elsewhere.sweepOrphans(keeping: [], permit: allowed)
        try require(FileManager.default.fileExists(atPath: target.path), "A permit for one folder removes nothing in another")

        let store = NativeAttachmentStore(directory: folder)
        store.sweepOrphans(keeping: try reopened.strictReferencedAttachmentFileNames(), permit: allowed)
        let expected = Set(names.prefix(2) + ["kept-folder", "link.png"])
        try require(try listing() == expected, "Only the three unmentioned regular files are removed: \(try listing().sorted())")
        try require(FileManager.default.fileExists(atPath: subfolder.appendingPathComponent("inside.txt").path), "A sub folder and its contents stay")
        try require(FileManager.default.fileExists(atPath: target.path), "A symbolic link and the file it points to stay")
    }

    static func permit(_ repository: LocalChatRepository, database: URL, folder: URL) throws -> StartupCleanup? {
        StartupCleanup.scratchPermitForTests(StartupCleanup.Inputs(
            overrideInEffect: false, runsFromAppBundle: true, database: URL(fileURLWithPath: repository.database.path),
            databaseCreatedThisLaunch: repository.createdThisLaunch,
            mentionedFileCount: try repository.strictReferencedAttachmentFileNames().count,
            folder: folder, folderHasFiles: StartupCleanup.folderHasFiles(folder),
            resolvedDatabase: database, resolvedFolder: folder))
    }

    static func checkResolver(_ scratch: URL) throws {
        let require = NativeTaskFixture.require
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        func inside(_ url: URL, _ folder: URL) -> Bool { url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") }

        let setting = scratch.appendingPathComponent("config", isDirectory: true)
        let withSetting = AppLocations.resolve(environment: [AppLocations.settingName: setting.path], home: home, applicationSupport: support, headlessRoot: nil)
        try require(withSetting.dataLocations.allSatisfy { inside($0, setting) }, "With the setting every data location is inside the config folder")
        try require(withSetting.database.path == URL(fileURLWithPath: setting.path, isDirectory: true).appendingPathComponent("vera.sqlite").path
                    && withSetting.configFile.path == URL(fileURLWithPath: setting.path).appendingPathComponent("config.json").path,
                    "With the setting the database and config file stay where they were")
        let headlessWithSetting = AppLocations.resolve(environment: [AppLocations.settingName: setting.path], home: home, applicationSupport: support,
                                                       headlessRoot: scratch.appendingPathComponent("run", isDirectory: true))
        try require(headlessWithSetting == withSetting, "The setting wins over a headless run")

        let plain = AppLocations.resolve(environment: [:], home: home, applicationSupport: support, headlessRoot: nil)
        let folder = NativeAttachmentStore.supportFolderName
        let oldAttachments = support.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("attachments", isDirectory: true)
        let oldProjects = oldAttachments.deletingLastPathComponent().appendingPathComponent("projects", isDirectory: true)
        let oldIndex = support.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("artifacts.json")
        let oldAssistant = support.appendingPathComponent(folder + "/Assistant", isDirectory: true)
        let oldReports = support.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("reports", isDirectory: true)
        let oldDatabase = home.appendingPathComponent(".vera", isDirectory: true).appendingPathComponent("vera.sqlite")
        let oldConfig = home.appendingPathComponent(".vera/config.json")
        try require(plain.usesStandardLocations && plain.attachments == oldAttachments && plain.projects.path == oldProjects.path
                    && plain.artifactsIndex == oldIndex && plain.assistant.path == oldAssistant.path && plain.reports == oldReports
                    && plain.database.path == oldDatabase.path && plain.configFile.path == oldConfig.path,
                    "Without the setting every location is exactly where it was")
        let namesStandard = AppLocations.resolve(environment: [AppLocations.settingName: home.appendingPathComponent(".vera").path],
                                                 home: home, applicationSupport: support, headlessRoot: nil)
        try require(namesStandard.dataLocations == plain.dataLocations, "A setting that names the standard folder keeps the standard data folders")
        let empty = AppLocations.resolve(environment: [AppLocations.settingName: ""], home: home, applicationSupport: support, headlessRoot: nil)
        try require(empty == plain, "An empty setting counts as unset")

        let run = scratch.appendingPathComponent("run", isDirectory: true)
        let headless = AppLocations.resolve(environment: [:], home: home, applicationSupport: support, headlessRoot: run)
        try require(headless.dataLocations.allSatisfy { inside($0, run) } && headless.database.path == oldDatabase.path,
                    "In a headless run every data location is inside the run's scratch folder")

        guard let root = AppLocations.headlessRoot else { throw NativeTaskFixture.Failure.assertion("This check runs inside a headless run") }
        let current = AppLocations.current
        switch current.situation {
        case .setting(let configured):
            try require(current.dataLocations.allSatisfy { inside($0, configured) }, "With the setting this run keeps its data in the config folder")
        case .headless, .plain:
            try require(current.dataLocations.allSatisfy { inside($0, root) }, "This headless run resolves every data location to its scratch folder")
        }
        try require(NativeAttachmentStore.standardDirectory == current.attachments && LocalChatRepository.standardProjectsDirectory == current.projects
                    && NativePiProduction.defaultRoot == current.assistant && NativeMemoryGate.reportsDirectory == current.reports
                    && ChatStore.artifactsURL == current.artifactsIndex && LocalChatRepository.defaultURL == current.database
                    && ConfigFile.defaultURL == current.configFile, "Every location goes through the one resolver")
    }

    static func checkCreatedThisLaunch(_ folder: URL) throws {
        let require = NativeTaskFixture.require
        let url = folder.appendingPathComponent("vera.sqlite")
        let artifacts = folder.appendingPathComponent("attachments", isDirectory: true)
        let projects = folder.appendingPathComponent("projects", isDirectory: true)
        let first = try LocalChatRepository(url: url, artifactDirectory: artifacts, projectsDirectory: projects)
        try require(first.createdThisLaunch, "A repository opened on a path that didn't exist reports created now")
        let second = try LocalChatRepository(url: url, artifactDirectory: artifacts, projectsDirectory: projects)
        try require(!second.createdThisLaunch, "A reopened repository reports that it already existed")
        let memory = try LocalChatRepository(inMemory: true, artifactDirectory: artifacts, projectsDirectory: projects)
        try require(memory.createdThisLaunch, "An in-memory database always counts as created now")
    }

    static func checkTrap(_ scratch: URL) throws {
        let require = NativeTaskFixture.require
        try require(AppLocations.isHeadless, "The selftest process is a headless run")
        guard let real = AppLocations.realDataFolder else { throw NativeTaskFixture.Failure.assertion("The account home resolves") }
        let realAttachments = real.appendingPathComponent("attachments", isDirectory: true)
        try require(AppLocations.isInsideRealDataFolder(realAttachments), "The trap recognizes the real attachments folder")
        try require(AppLocations.isInsideRealDataFolder(URL(fileURLWithPath: realAttachments.path.uppercased())), "The trap ignores letter case")
        try require(AppLocations.isInsideRealDataFolder(realAttachments.appendingPathComponent("../projects")), "The trap sees through dot segments")
        try require(!AppLocations.isInsideRealDataFolder(scratch.appendingPathComponent("attachments")), "The trap leaves a scratch folder alone")
        try require(!AppLocations.current.dataLocations.contains(where: { AppLocations.isInsideRealDataFolder($0) }), "No location this run resolves is inside the real data folder")
    }

    static func checkNoProductionPermit(_ scratch: URL) throws {
        let require = NativeTaskFixture.require
        let inside = scratch.appendingPathComponent("pair", isDirectory: true)
        func inputs(_ folder: URL) -> StartupCleanup.Inputs {
            StartupCleanup.Inputs(
                overrideInEffect: false, runsFromAppBundle: true, database: folder.appendingPathComponent("vera.sqlite"),
                databaseCreatedThisLaunch: false, mentionedFileCount: 1, folder: folder.appendingPathComponent("attachments", isDirectory: true),
                folderHasFiles: true, resolvedDatabase: folder.appendingPathComponent("vera.sqlite"),
                resolvedFolder: folder.appendingPathComponent("attachments", isDirectory: true))
        }
        try require(StartupCleanup.scratchPermitForTests(inputs(inside)) != nil, "A folder inside this run's scratch root can get a test permit")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-outside-\(UUID().uuidString)", isDirectory: true)
        try require(StartupCleanup.scratchPermitForTests(inputs(outside)) == nil, "A folder outside this run's scratch root never gets a permit")
        try require(StartupCleanup.scratchPermitForTests(inputs(inside), scratchRoot: nil) == nil, "Without a scratch root nothing gets a permit")
        if let real = AppLocations.realDataFolder {
            try require(StartupCleanup.scratchPermitForTests(inputs(real), scratchRoot: real.deletingLastPathComponent()) == nil,
                        "The real data folder never gets a permit, even named as the scratch root's child")
        }
    }

    static func checkStrictReferences(_ root: URL) throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(url: root.appendingPathComponent("vera.sqlite"),
                                                 artifactDirectory: root.appendingPathComponent("attachments", isDirectory: true),
                                                 projectsDirectory: root.appendingPathComponent("projects", isDirectory: true))
        let conversation = Conversation(id: "strict", title: "Strict", messages: [], updatedAt: Date())
        try repository.saveConversation(conversation)
        let attachment = MessageAttachment(name: "kept.png", ext: "PNG", isImage: true, fileName: "kept.png", mime: "image/png", byteSize: 1)
        let message = Message(role: .user, text: "One file", attachments: [attachment])
        try repository.saveMessage(message, conversationID: conversation.id, ordinal: 0)
        try require(try repository.strictReferencedAttachmentFileNames() == ["kept.png"], "A readable record is listed")
        try repository.database.write { db in
            try db.execute(sql: "UPDATE messages SET attachments_json = ?", arguments: ["[{\"name\": "])
        }
        try require(try repository.referencedAttachmentFileNames().isEmpty, "The display listing still skips an unreadable record")
        var threw = false
        do { _ = try repository.strictReferencedAttachmentFileNames() } catch { threw = true }
        try require(threw, "One unreadable record makes the strict listing fail")
    }

    static func checkStandardFolderSpellings(_ root: URL) throws {
        let require = NativeTaskFixture.require
        let home = root.appendingPathComponent("home", isDirectory: true)
        let standard = home.appendingPathComponent(".vera", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: standard, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link-to-config", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: standard)
        let plain = AppLocations.resolve(environment: [:], home: home, applicationSupport: support, headlessRoot: nil)
        func dataFor(_ raw: String) -> [URL] {
            AppLocations.resolve(environment: [AppLocations.settingName: raw], home: home, applicationSupport: support, headlessRoot: nil).dataLocations
        }
        try require(dataFor(link.path) == plain.dataLocations, "A symbolic link to the standard folder keeps the standard data folders")
        try require(dataFor(standard.path + "/") == plain.dataLocations, "A trailing slash keeps the standard data folders")
        try require(dataFor(home.path + "/other/../.vera") == plain.dataLocations, "Dot segments keep the standard data folders")
        let probe = root.appendingPathComponent("case-probe")
        try Data().write(to: probe)
        let caseInsensitive = FileManager.default.fileExists(atPath: root.appendingPathComponent("CASE-PROBE").path)
        if caseInsensitive {
            try require(dataFor(home.appendingPathComponent(".VERA").path) == plain.dataLocations, "Another letter case keeps the standard data folders")
        }
        try require(dataFor(root.appendingPathComponent("elsewhere").path) != plain.dataLocations, "A different folder still moves the data folders")
    }

    static func checkSettingTrap(_ root: URL) throws {
        let require = NativeTaskFixture.require
        let standIn = root.appendingPathComponent("stand-in-real", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: standIn, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: config.appendingPathComponent("data", isDirectory: true), withDestinationURL: standIn)
        let locations = AppLocations.resolve(environment: [AppLocations.settingName: config.path], home: root, applicationSupport: root, headlessRoot: nil)
        try require(locations.dataLocations.allSatisfy { AppLocations.isInsideRealDataFolder($0, realFolder: standIn) },
                    "A data folder that links into the real folder is caught")
        try require(AppLocations.isInsideRealDataFolder(locations.dataRoot, realFolder: standIn), "The data root itself is caught")
        let separate = root.appendingPathComponent("separate", isDirectory: true)
        try require(!AppLocations.isInsideRealDataFolder(separate.appendingPathComponent("data/attachments"), realFolder: standIn),
                    "A separate folder is left alone")
    }

    static func checkScratchRoots(_ root: URL) throws {
        let require = NativeTaskFixture.require
        let home = root.appendingPathComponent("home", isDirectory: true)
        let parent = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try require(AppLocations.isAcceptableScratchParent(parent, home: home), "An ordinary temporary folder is accepted")
        try require(!AppLocations.isAcceptableScratchParent(home, home: home), "The account home is refused")
        try require(!AppLocations.isAcceptableScratchParent(home.appendingPathComponent(".vera/tmp"), home: home), "A folder inside the config folder is refused")
        try require(!AppLocations.isAcceptableScratchParent(AppLocations.dataFolder(home: home).appendingPathComponent("tmp"), home: home),
                    "A folder inside the data folder is refused")
        try require(AppLocations.scratchParent(["TMPDIR": home.path], home: home).path != home.path, "A refused temporary folder falls back")

        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        let gone = finished.processIdentifier
        func makeRoot(in folder: URL, marker: Bool) throws -> URL {
            let name = AppLocations.runPrefix + "\(gone)-\(UUID().uuidString.lowercased())"
            let entry = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
            if marker { try Data(AppLocations.ownerMarker(pid: gone, name: name).utf8).write(to: entry.appendingPathComponent(AppLocations.ownerMarkerName)) }
            return entry
        }
        let abandoned = try makeRoot(in: parent, marker: true)
        let unmarked = try makeRoot(in: parent, marker: false)
        let wrongName = parent.appendingPathComponent(AppLocations.runPrefix + "\(gone)-not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongName, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("link-target", isDirectory: true)
        let targetRoot = try makeRoot(in: root, marker: true)
        try FileManager.default.moveItem(at: targetRoot, to: target)
        let linkName = AppLocations.runPrefix + "\(gone)-\(UUID().uuidString.lowercased())"
        let link = parent.appendingPathComponent(linkName)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try Data(AppLocations.ownerMarker(pid: gone, name: linkName).utf8).write(to: target.appendingPathComponent(AppLocations.ownerMarkerName))
        let protectedRoot = try makeRoot(in: home, marker: true)

        AppLocations.removeAbandonedRoots(in: parent, home: home)
        AppLocations.removeAbandonedRoots(in: home, home: home)
        try require(AppLocations.fileType(abandoned.path) == nil, "A real abandoned root is removed")
        try require(AppLocations.fileType(unmarked.path) == S_IFDIR, "A look-alike folder without a marker survives")
        try require(AppLocations.fileType(wrongName.path) == S_IFDIR, "A folder whose name doesn't parse survives")
        try require(AppLocations.fileType(link.path) == S_IFLNK && AppLocations.fileType(target.path) == S_IFDIR,
                    "A symbolic link named like a root survives along with its target")
        try require(AppLocations.fileType(protectedRoot.path) == S_IFDIR, "Nothing is removed from a protected parent")
        if let current = AppLocations.headlessRoot {
            try require(AppLocations.runOwner(current.lastPathComponent) == getpid(), "This run's own root names this process")
            let marker = try String(contentsOf: current.appendingPathComponent(AppLocations.ownerMarkerName), encoding: .utf8)
            try require(marker == AppLocations.ownerMarker(pid: getpid(), name: current.lastPathComponent), "This run's root carries its owner marker")
        }
    }

    static func checkLegacyImport(_ root: URL) throws {
        let require = NativeTaskFixture.require
        let config = root.appendingPathComponent("config", isDirectory: true)
        let setting = AppLocations.resolve(environment: [AppLocations.settingName: config.path], home: root, applicationSupport: root, headlessRoot: nil)
        let plain = AppLocations.resolve(environment: [:], home: root, applicationSupport: root, headlessRoot: nil)
        let headless = AppLocations.resolve(environment: [:], home: root, applicationSupport: root, headlessRoot: root.appendingPathComponent("run"))
        try require(!ChatStore.legacyImportAllowed(databaseCreatedThisLaunch: true, headless: false, locations: plain, index: plain.artifactsIndex),
                    "A new database skips the import")
        try require(!ChatStore.legacyImportAllowed(databaseCreatedThisLaunch: false, headless: true, locations: headless, index: headless.artifactsIndex),
                    "A headless run skips the import")
        try require(ChatStore.legacyImportAllowed(databaseCreatedThisLaunch: false, headless: false, locations: setting, index: setting.artifactsIndex),
                    "With the setting the import runs on the setting's own index")
        try require(!ChatStore.legacyImportAllowed(databaseCreatedThisLaunch: false, headless: false, locations: setting, index: plain.artifactsIndex),
                    "With the setting an index outside its data folder is skipped")
        try require(ChatStore.legacyImportAllowed(databaseCreatedThisLaunch: false, headless: false, locations: plain, index: plain.artifactsIndex),
                    "The app's own existing database imports")

        try FileManager.default.createDirectory(at: plain.dataRoot, withIntermediateDirectories: true)
        let index = plain.artifactsIndex
        let legacy = [Artifact(id: "note", title: "Note", type: .code, language: "swift", content: "let x = 1")]
        let indexBytes = try JSONEncoder().encode(legacy)
        try indexBytes.write(to: index)
        let newDatabase = try LocalChatRepository(url: root.appendingPathComponent("fresh.sqlite"),
                                                  artifactDirectory: root.appendingPathComponent("attachments", isDirectory: true),
                                                  projectsDirectory: root.appendingPathComponent("projects", isDirectory: true))
        if ChatStore.legacyImportAllowed(databaseCreatedThisLaunch: newDatabase.createdThisLaunch, headless: false, locations: plain, index: index) {
            _ = try ChatStore.importLegacyCanvasLibrary(from: index, into: newDatabase)
        }
        let nothingImported = try newDatabase.listArtifacts().isEmpty
        try require((try? Data(contentsOf: index)) == indexBytes && nothingImported,
                    "A new database leaves the index where it is")

        let backup = plain.dataRoot.appendingPathComponent("artifacts-migrated.json")
        let second = plain.dataRoot.appendingPathComponent("artifacts-migrated-2.json")
        try Data("first".utf8).write(to: backup)
        try Data("second".utf8).write(to: second)
        _ = try ChatStore.importLegacyCanvasLibrary(from: index, into: newDatabase)
        try require((try? Data(contentsOf: backup)) == Data("first".utf8) && (try? Data(contentsOf: second)) == Data("second".utf8),
                    "Existing backups survive byte for byte")
        try require((try? Data(contentsOf: plain.dataRoot.appendingPathComponent("artifacts-migrated-3.json"))) == indexBytes,
                    "The imported index moves to the next free numbered name")
    }

    static func checkLaunchPlan() throws {
        let require = NativeTaskFixture.require
        let isolated: Set<String> = ["--pi-native-selftest"]
        try require(LaunchPlan.mode([], isolatedModes: isolated) == .app, "A plain start opens the app")
        try require(LaunchPlan.mode(["-NSDocumentRevisionsDebugMode", "YES"], isolatedModes: isolated) == .app && LaunchPlan.mode(["-psn_0_12345"], isolatedModes: isolated) == .app,
                    "System arguments with one hyphen still open the app")
        try require(LaunchPlan.mode(["--selftests"], isolatedModes: isolated) == .refused("--selftests"), "A misspelled option is refused")
        try require(LaunchPlan.mode(["--shot"], isolatedModes: isolated) == .refused("--shot"), "A shot without a path is refused")
        try require(LaunchPlan.mode(["--view", "chat"], isolatedModes: isolated) == .refused("--view"), "An option on its own is refused")
        try require(LaunchPlan.mode(["--shot", "out.png", "--view", "chat"], isolatedModes: isolated) == .run("--shot"), "A shot is recognized")
        try require(LaunchPlan.mode(["--selftest"], isolatedModes: isolated) == .run("--selftest"), "The selftest is recognized")
        try require(LaunchPlan.mode(["--pi-native-selftest", "--view"], isolatedModes: isolated) == .run("--pi-native-selftest"), "An isolated mode is recognized")
        try require(LaunchPlan.mode(["--pi-unknown"], isolatedModes: isolated) == .refused("--pi-unknown"), "An unknown isolated mode is refused")
        try require(LaunchPlan.mode(["--selftest", "--dump-context"], isolatedModes: isolated) == .run("--selftest"), "Modes keep the order the entry point checks them in")
        try require(LaunchPlan.mode(["--openrouter-smoke", "--credential-status"], isolatedModes: isolated) == .run("--openrouter-smoke"), "The credential status smoke is recognized")
        try require(LaunchPlan.mode(["--credential-reauthorization"], isolatedModes: isolated) == .run(LaunchPlan.credentialMode), "The credential helper is recognized")
        let selftest = LaunchPlan.Mode.run("--selftest")
        try require(LaunchPlan.isHeadless(selftest, environment: [:]) && LaunchPlan.isHeadless(selftest, environment: ["VERA_TASK_ENGINE_SELFTEST": "1"]),
                    "Selftests are headless runs")
        try require(!LaunchPlan.isHeadless(selftest, environment: ["VERA_IMAGE_LIVE_BASE": "http://image.example"])
                    && !LaunchPlan.isHeadless(selftest, environment: ["VERA_MEMORY_LIVE_BASE": "http://memory.example/v1"]),
                    "The live checks keep their behaviour")
        try require(LaunchPlan.isHeadless(selftest, environment: ["VERA_ATTENTION_SELFTEST": "1", "VERA_IMAGE_LIVE_BASE": "http://image.example"]),
                    "A selftest that runs before the live checks stays headless")
        try require(LaunchPlan.realDataModes.allSatisfy { !LaunchPlan.isHeadless(.run($0), environment: [:]) }, "The live modes keep their behaviour")
        try require(!LaunchPlan.isHeadless(.app, environment: ["VERA_TASK_ENGINE_SELFTEST": "1"]), "A plain start is never headless")
    }
}
