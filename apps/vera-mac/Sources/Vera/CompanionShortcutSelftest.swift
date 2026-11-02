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

        let system = CompanionShortcut.enabledSystemShortcuts()
        try check(system.allSatisfy { $0.isValid || $0.modifiers & ~four == 0 },
                  "System shortcuts read back as shortcuts with supported modifiers")

        guard let accepted = CompanionShortcut(configValue: "control+option+j"),
              let taken = CompanionShortcut(configValue: "control+option+k"),
              let reserved = CompanionShortcut(configValue: "control+option+l"),
              let broken = CompanionShortcut(configValue: "control+option+m") else {
            throw NativeTaskFixture.Failure.assertion("registration fixtures parse")
        }
        var fired = 0
        var attempts: [CompanionShortcut] = []
        let hotkey = CompanionHotkey { fired += 1 }
        hotkey.systemShortcuts = { [reserved] }
        hotkey.attempt = { shortcut, _ in
            attempts.append(shortcut)
            switch shortcut {
            case accepted: return (noErr, OpaquePointer(bitPattern: 1))
            case taken: return (OSStatus(eventHotKeyExistsErr), nil)
            default: return (OSStatus(paramErr), nil)
            }
        }
        try check(hotkey.current == nil, "Nothing is registered before the first attempt")
        try check(hotkey.register(accepted) == nil && hotkey.current == accepted, "A free shortcut registers")
        try check(hotkey.register(accepted) == nil && attempts == [accepted], "Registering the same shortcut again is a no-op")
        try check(hotkey.register(taken) == CompanionHotkey.conflictMessage, "A shortcut another app holds reports a conflict")
        try check(hotkey.current == accepted, "A conflict keeps the previous shortcut")
        try check(hotkey.register(reserved) == CompanionHotkey.conflictMessage, "A system shortcut reports a conflict")
        try check(hotkey.current == accepted && !attempts.contains(reserved), "A system shortcut is never attempted")
        try check(hotkey.register(broken) == CompanionHotkey.failureMessage, "Any other registration error reports a failure")
        try check(hotkey.current == accepted, "A failure keeps the previous shortcut")
        let invalid = CompanionShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(shiftKey))
        try check(hotkey.register(invalid) == CompanionHotkey.failureMessage, "An invalid shortcut reports a failure")
        try check(hotkey.current == accepted && !attempts.contains(invalid), "An invalid shortcut is never attempted")
        try check(fired == 0, "Registering never fires the handler")

        print("  companion shortcut: PASS (\(checks) checks, parsing, config, system shortcuts, registration)")
    }
}
