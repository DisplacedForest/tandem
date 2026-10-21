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
        try require(fresh.pinned == [.projects, .pulse, .memory], "Pinning appends after the existing pins")
        fresh.toggle(.projects)
        try require(fresh.pinned == [.pulse, .memory], "Unpinning removes only that section")
        try require(!fresh.isPinned(.projects) && fresh.isPinned(.memory), "Pin state reports per section")

        let relaunched = SidebarPins(defaults: defaults)
        try require(relaunched.pinned == [.pulse, .memory], "Pins survive a relaunch")

        fresh.toggle(.pulse)
        fresh.toggle(.memory)
        try require(SidebarPins(defaults: defaults).pinned.isEmpty, "An empty pin set is remembered rather than reset to the defaults")

        defaults.set(["memory", "bogus", "projects"], forKey: SidebarPins.key)
        try require(SidebarPins(defaults: defaults).pinned == [.memory, .projects], "Unknown stored names are dropped and the stored order is kept")
        defaults.set(["pulse", "memory", "pulse"], forKey: SidebarPins.key)
        try require(SidebarPins(defaults: defaults).pinned == [.pulse, .memory], "Duplicate stored names collapse to the first")

        defaults.set(["projects", "pulse"], forKey: SidebarPins.key)
        let windowA = SidebarPins(defaults: defaults)
        let windowB = SidebarPins(defaults: defaults)
        windowA.toggle(.memory)
        windowB.toggle(.artifacts)
        try require(SidebarPins(defaults: defaults).pinned == [.projects, .pulse, .memory, .artifacts], "Two windows toggling in turn keep both pins on disk")
        try require(windowA.pinned == windowB.pinned && windowA.pinned == [.projects, .pulse, .memory, .artifacts], "Both windows show the merged pin set")

        windowA.move(.artifacts, before: .projects)
        try require(windowA.pinned == [.artifacts, .projects, .pulse, .memory], "A pin moves before the target")
        windowA.move(.projects, before: .memory)
        try require(windowA.pinned == [.artifacts, .pulse, .projects, .memory], "Moving later shifts the rows between")
        windowA.moveToEnd(.artifacts)
        try require(windowA.pinned == [.pulse, .projects, .memory, .artifacts], "Moving to the end appends")
        windowA.move(.pulse, before: .pulse)
        windowA.move(.scheduled, before: .pulse)
        windowA.moveToEnd(.integrations)
        try require(windowA.pinned == [.pulse, .projects, .memory, .artifacts], "Moves onto self or with an unpinned section change nothing")
        try require(SidebarPins(defaults: defaults).pinned == [.pulse, .projects, .memory, .artifacts], "The arranged order survives a relaunch")
        try require(windowB.pinned == windowA.pinned, "The other window follows the arranged order")

        try require(windowA.accept(dropped: ["memory"], before: .pulse), "Dropping a pinned section on another is accepted")
        try require(windowA.pinned == [.memory, .pulse, .projects, .artifacts], "The accepted drop moved the section")
        try require(!windowA.accept(dropped: ["scheduled"], before: .pulse), "Dropping an unpinned section is refused")
        try require(!windowA.accept(dropped: ["scheduled"], before: nil), "Dropping an unpinned section on More is refused")
        try require(!windowA.accept(dropped: ["pulse"], before: .pulse), "Dropping a section on itself is refused")
        try require(!windowA.accept(dropped: ["bogus"], before: nil), "Unknown payloads are refused")
        try require(!windowA.accept(dropped: [], before: nil), "Empty payloads are refused")
        try require(windowA.accept(dropped: ["memory"], before: nil), "Dropping a pinned section on More is accepted")
        try require(windowA.pinned == [.pulse, .projects, .artifacts, .memory], "Refused drops left the order alone and the last drop moved Memory to the end")
        try require(SidebarPins.shared === SidebarPins.shared, "The app shares one pin model across windows")
    }
}
