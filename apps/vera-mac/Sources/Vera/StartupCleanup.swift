import Foundation

struct StartupCleanup: Equatable, Sendable {
    struct Inputs: Sendable {
        var overrideInEffect: Bool
        var runsFromAppBundle: Bool
        var database: URL
        var databaseCreatedThisLaunch: Bool
        var mentionedFileCount: Int
        var folder: URL
        var folderHasFiles: Bool
        var resolvedDatabase: URL
        var resolvedFolder: URL
    }

    let databasePath: String
    let folderPath: String

    private init(database: URL, folder: URL) {
        databasePath = Self.path(database)
        folderPath = Self.path(folder)
    }

    static func path(_ url: URL) -> String { url.standardizedFileURL.path }

    static func decide(_ inputs: Inputs) -> StartupCleanup? {
        let databaseIsDefault = path(inputs.database) == path(inputs.resolvedDatabase)
        let folderIsResolvedWithDatabase = path(inputs.folder) == path(inputs.resolvedFolder)
        let pairIsTheResolvedOne = databaseIsDefault && folderIsResolvedWithDatabase
        let databaseExistedBefore = !inputs.databaseCreatedThisLaunch
        let databaseMentionsNothing = inputs.mentionedFileCount == 0
        let emptyDatabaseOverFiles = databaseMentionsNothing && inputs.folderHasFiles
        let ownApp = inputs.runsFromAppBundle && !inputs.overrideInEffect
        guard ownApp, pairIsTheResolvedOne, databaseExistedBefore, !emptyDatabaseOverFiles else { return nil }
        return StartupCleanup(database: inputs.database, folder: inputs.folder)
    }

    static func overrideInEffect(locations: AppLocations, fixture: Bool, environment: [String: String]) -> Bool {
        let locationOverride = !locations.usesStandardLocations
        let headless = AppLocations.isHeadless
        let fixtureHome = environment["CFFIXED_USER_HOME"] != nil
        return locationOverride || headless || fixture || fixtureHome
    }

    static func runsFromAppBundle(_ bundle: Bundle) -> Bool {
        let packaged = bundle.bundleURL.pathExtension == "app"
        let identified = bundle.bundleIdentifier?.isEmpty == false
        return packaged && identified
    }

    static func folderHasFiles(_ folder: URL) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return !entries.isEmpty
    }

    func allows(folder: URL) -> Bool { Self.path(folder) == folderPath }

    func allows(database: URL) -> Bool { Self.path(database) == databasePath }
}
