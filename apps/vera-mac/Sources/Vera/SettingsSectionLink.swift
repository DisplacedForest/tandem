import SwiftUI

enum SettingsSection {
    static func open(_ tab: SettingsTab, select: (SettingsTab) -> Void, open: () -> Void) {
        select(tab)
        open()
    }
}

struct OpenSettingsSection {
    let store: ChatStore
    let openSettings: OpenSettingsAction

    @MainActor
    func callAsFunction(_ tab: SettingsTab) {
        SettingsSection.open(tab, select: { store.settingsTab = $0 }, open: { openSettings() })
    }
}

struct SettingsSectionLink: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.openSettings) private var openSettings
    let tab: SettingsTab
    let title: String

    init(_ title: String, tab: SettingsTab) {
        self.title = title
        self.tab = tab
    }

    var body: some View {
        Button(title) { OpenSettingsSection(store: store, openSettings: openSettings)(tab) }
    }
}

@MainActor
extension SelfTest {
    static func runSettingsSections() throws {
        let require = NativeTaskFixture.require
        var selected = SettingsTab.connection
        var events: [String] = []
        func named(_ tab: SettingsTab) {
            SettingsSection.open(tab, select: { selected = $0; events.append("select \($0.rawValue)") }, open: { events.append("open \(selected.rawValue)") })
        }
        named(.memory)
        try require(selected == .memory && events == ["select memory", "open memory"], "A shortcut that names a section selects it before the window is asked for")
        named(.memory)
        try require(selected == .memory && events.suffix(2) == ["select memory", "open memory"], "Activating the same shortcut again keeps its section")
        selected = .model
        named(.plugins)
        named(.connection)
        try require(selected == .connection && events.suffix(4) == ["select plugins", "open plugins", "select connection", "open connection"],
                    "Each named shortcut reaches its own section whatever was selected before")
        print("  settings sections OK (named section selected before open, repeat, any earlier tab)")
    }
}
