import Carbon.HIToolbox
import Foundation

@MainActor
extension SelfTest {
    static func runCompanionShortcut() throws {
        let require = NativeTaskFixture.require
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            try require(condition, message)
            checks += 1
        }

        let standard = CompanionShortcut.default
        try check(standard.configValue == "option+shift+space", "The default stores as option+shift+space")
        try check(standard.displayName == "Option Shift Space", "The default reads as Option Shift Space")
        try check(standard.symbols == "⌥⇧Space", "The default shows its symbols")
        try check(standard.isValid, "The default is a valid shortcut")
        try check(CompanionShortcut(configValue: "option+shift+space") == standard, "The default parses back to itself")

        for value in ["command+k", "control+option+f", "f5"] {
            guard let parsed = CompanionShortcut(configValue: value) else {
                throw NativeTaskFixture.Failure.assertion("\(value) parses")
            }
            try check(parsed.configValue == value, "\(value) round trips")
            try check(CompanionShortcut(configValue: parsed.configValue) == parsed, "\(value) parses back to the same shortcut")
        }
        try check(CompanionShortcut(configValue: "f5")?.modifiers == 0, "A function key alone carries no modifiers")
        try check(CompanionShortcut(configValue: "command+k")?.displayName == "Command K", "Command K reads plainly")
        try check(CompanionShortcut(configValue: "control+option+f")?.symbols == "⌃⌥F", "Control Option F shows its symbols")

        try check(CompanionShortcut(configValue: "shift+space") == nil, "Shift alone is not enough")
        try check(CompanionShortcut(configValue: "space") == nil, "A plain key is not enough")
        try check(CompanionShortcut(configValue: "option+banana") == nil, "An unknown key is rejected")
        try check(CompanionShortcut(configValue: "hyper+k") == nil, "An unknown modifier is rejected")
        try check(CompanionShortcut(configValue: "") == nil, "An empty value is rejected")
        try check(CompanionShortcut(configValue: "OPTION+SHIFT+SPACE") == standard, "Parsing ignores case")

        let scrambled = CompanionShortcut(configValue: "command+shift+option+control+k")
        try check(scrambled?.configValue == "control+option+shift+command+k", "Modifiers store as control, option, shift, command")
        try check(scrambled?.displayName == "Control Option Shift Command K", "Modifiers read in the same order")
        try check(scrambled?.symbols == "⌃⌥⇧⌘K", "Modifier symbols follow the same order")

        let four = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        let noisy = CompanionShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: four | UInt32(alphaLock) | 0x8000_0000)
        try check(noisy.modifiers == four, "Only the four supported modifiers are kept")
        let capsOnly = CompanionShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(alphaLock))
        try check(capsOnly.modifiers == 0 && !capsOnly.isValid, "Caps Lock alone does not make a shortcut")

        func store(_ value: String?) -> ConfigStore {
            var raw: [String: Any] = [:]
            if let value { raw[CompanionShortcut.configKey] = value }
            return ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { raw }, writeConfiguration: { _ in })
        }
        try check(store(nil).companionShortcut == standard, "An unset shortcut uses the default")
        try check(store("command+j").companionShortcut == CompanionShortcut(configValue: "command+j"), "A stored shortcut is used")
        try check(store("not a shortcut").companionShortcut == standard, "A garbled value falls back to the default")
        try check(store("shift+space").companionShortcut == standard, "An invalid stored shortcut falls back to the default")

        let editable = store(nil)
        editable.setCompanionShortcut(CompanionShortcut(configValue: "control+option+f"))
        try check(editable[CompanionShortcut.configKey] == "control+option+f", "Setting a shortcut stores its value")
        editable.setCompanionShortcut(nil)
        try check(editable[CompanionShortcut.configKey].isEmpty && editable.companionShortcut == standard, "Clearing returns to the default")
        try check(editable.companionShortcutProblem == nil, "No registration problem is reported by default")

        print("  companion shortcut: PASS (\(checks) checks)")
    }
}
