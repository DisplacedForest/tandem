import Foundation

@MainActor
enum AppLocationsSelftest {
    static func run() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-locations-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try checkDecision(scratch)
        try checkCleanup(scratch.appendingPathComponent("cleanup", isDirectory: true))
        try checkResolver(scratch)
        try checkCreatedThisLaunch(scratch.appendingPathComponent("created", isDirectory: true))
        try checkTrap(scratch)
        try checkLaunchPlan()
    }

    static func checkDecision(_ scratch: URL) throws {
        let require = NativeTaskFixture.require
        let database = scratch.appendingPathComponent("pair/vera.sqlite")
        let folder = scratch.appendingPathComponent("pair/attachments", isDirectory: true)
        let allowed = StartupCleanup.Inputs(
            overrideInEffect: false, runsFromAppBundle: true, database: database, databaseCreatedThisLaunch: false, mentionedFileCount: 2,
            folder: folder, folderHasFiles: true, resolvedDatabase: database, resolvedFolder: folder)
        try require(StartupCleanup.decide(allowed) != nil, "The clean-up runs for the app's own existing database and its folder")
        var withOverride = allowed
        withOverride.overrideInEffect = true
        try require(StartupCleanup.decide(withOverride) == nil, "Any override turns the clean-up off")
        var looseBuild = allowed
        looseBuild.runsFromAppBundle = false
        try require(StartupCleanup.decide(looseBuild) == nil, "A build that isn't a packaged app never runs the clean-up")
        try require(!StartupCleanup.runsFromAppBundle(.main), "The test binary itself is not a packaged app")
        var createdNow = allowed
        createdNow.databaseCreatedThisLaunch = true
        try require(StartupCleanup.decide(createdNow) == nil, "A database created in this launch turns the clean-up off")
        var mentionsNothing = allowed
        mentionsNothing.mentionedFileCount = 0
        try require(StartupCleanup.decide(mentionsNothing) == nil, "A database that mentions no files over a folder with files turns the clean-up off")
        var mentionsNothingEmptyFolder = mentionsNothing
        mentionsNothingEmptyFolder.folderHasFiles = false
        try require(StartupCleanup.decide(mentionsNothingEmptyFolder) != nil, "An empty folder with a database that mentions nothing has nothing to protect")
        var otherFolder = allowed
        otherFolder.folder = scratch.appendingPathComponent("elsewhere/attachments", isDirectory: true)
        try require(StartupCleanup.decide(otherFolder) == nil, "A folder that wasn't resolved with the database turns the clean-up off")
        var otherDatabase = allowed
        otherDatabase.database = scratch.appendingPathComponent("elsewhere/vera.sqlite")
        try require(StartupCleanup.decide(otherDatabase) == nil, "A database that isn't the default one turns the clean-up off")
        let fixtureLocations = AppLocations.resolve(environment: [:], home: scratch, applicationSupport: scratch, headlessRoot: nil)
        try require(StartupCleanup.overrideInEffect(locations: fixtureLocations, fixture: false, environment: [:]),
                    "A headless run always counts as an override")
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
        store.sweepOrphans(keeping: try reopened.referencedAttachmentFileNames(), permit: allowed)
        let expected = Set(names.prefix(2) + ["kept-folder", "link.png"])
        try require(try listing() == expected, "Only the three unmentioned regular files are removed: \(try listing().sorted())")
        try require(FileManager.default.fileExists(atPath: subfolder.appendingPathComponent("inside.txt").path), "A sub folder and its contents stay")
        try require(FileManager.default.fileExists(atPath: target.path), "A symbolic link and the file it points to stay")
    }

    static func permit(_ repository: LocalChatRepository, database: URL, folder: URL) throws -> StartupCleanup? {
        StartupCleanup.decide(StartupCleanup.Inputs(
            overrideInEffect: false, runsFromAppBundle: true, database: URL(fileURLWithPath: repository.database.path),
            databaseCreatedThisLaunch: repository.createdThisLaunch,
            mentionedFileCount: try repository.referencedAttachmentFileNames().count,
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
        try require(!AppLocations.current.dataLocations.contains(where: AppLocations.isInsideRealDataFolder), "No location this run resolves is inside the real data folder")
    }

    static func checkLaunchPlan() throws {
        let require = NativeTaskFixture.require
        try require(LaunchPlan.mode([]) == .app, "A plain start opens the app")
        try require(LaunchPlan.mode(["-NSDocumentRevisionsDebugMode", "YES"]) == .app && LaunchPlan.mode(["-psn_0_12345"]) == .app,
                    "System arguments with one hyphen still open the app")
        try require(LaunchPlan.mode(["--selftests"]) == .refused("--selftests"), "A misspelled option is refused")
        try require(LaunchPlan.mode(["--shot"]) == .refused("--shot"), "A shot without a path is refused")
        try require(LaunchPlan.mode(["--view", "chat"]) == .refused("--view"), "An option on its own is refused")
        try require(LaunchPlan.mode(["--shot", "out.png", "--view", "chat"]) == .run("--shot"), "A shot is recognized")
        try require(LaunchPlan.mode(["--selftest"]) == .run("--selftest"), "The selftest is recognized")
        try require(LaunchPlan.mode(["--pi-native-selftest", "--task-card-shot"]) == .run("--pi-native-selftest"), "An isolated mode is recognized")
        try require(LaunchPlan.mode(["--pi-unknown"]) == .refused("--pi-unknown"), "An unknown isolated mode is refused")
        try require(LaunchPlan.mode(["--selftest", "--dump-context"]) == .run("--selftest"), "Modes keep the order the entry point checks them in")
        try require(LaunchPlan.mode(["--openrouter-smoke", "--credential-status"]) == .run("--openrouter-smoke"), "The credential status smoke is recognized")
        try require(LaunchPlan.mode(["--credential-reauthorization"]) == .run(LaunchPlan.credentialMode), "The credential helper is recognized")
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
