import Foundation

@MainActor
extension SelfTest {
    static func runSidebarPins() throws {
        let require = NativeTaskFixture.require
        let suite = "selftest.sidebar.pins.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw NativeTaskFixture.Failure.assertion("Suite") }
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = SidebarPins(defaults: defaults)
        try require(fresh.pinned == [.projects, .pulse], "A fresh install pins Projects and Pulse")

        fresh.toggle(.memory)
        try require(fresh.pinned == [.projects, .pulse, .memory], "Pinning keeps the fixed section order")
        fresh.toggle(.projects)
        try require(fresh.pinned == [.pulse, .memory], "Unpinning removes only that section")
        try require(!fresh.isPinned(.projects) && fresh.isPinned(.memory), "Pin state reports per section")

        let relaunched = SidebarPins(defaults: defaults)
        try require(relaunched.pinned == [.pulse, .memory], "Pins survive a relaunch")

        fresh.toggle(.pulse)
        fresh.toggle(.memory)
        try require(SidebarPins(defaults: defaults).pinned.isEmpty, "An empty pin set is remembered rather than reset to the defaults")

        defaults.set(["memory", "bogus", "projects"], forKey: SidebarPins.key)
        try require(SidebarPins(defaults: defaults).pinned == [.projects, .memory], "Unknown stored names are dropped and order is normalized")

        defaults.set(["projects", "pulse"], forKey: SidebarPins.key)
        let windowA = SidebarPins(defaults: defaults)
        let windowB = SidebarPins(defaults: defaults)
        windowA.toggle(.memory)
        windowB.toggle(.artifacts)
        try require(SidebarPins(defaults: defaults).pinned == [.projects, .artifacts, .pulse, .memory], "Two windows toggling in turn keep both pins on disk")
        try require(windowA.pinned == windowB.pinned && windowA.pinned == [.projects, .artifacts, .pulse, .memory], "Both windows show the merged pin set")
        try require(SidebarPins.shared === SidebarPins.shared, "The app shares one pin model across windows")
    }
}
