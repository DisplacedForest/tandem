import AppKit
import Carbon.HIToolbox

struct CompanionShortcut: Equatable, Hashable, Codable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = CompanionShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey))
    static let configKey = "companion_shortcut"

    private static let modifierTokens: [(String, UInt32, String)] = [
        ("control", UInt32(controlKey), "Control"),
        ("option", UInt32(optionKey), "Option"),
        ("shift", UInt32(shiftKey), "Shift"),
        ("command", UInt32(cmdKey), "Command"),
    ]

    private static let keyNames: [(String, UInt32, String)] = [
        ("space", UInt32(kVK_Space), "Space"), ("return", UInt32(kVK_Return), "Return"), ("tab", UInt32(kVK_Tab), "Tab"),
        ("escape", UInt32(kVK_Escape), "Escape"), ("delete", UInt32(kVK_Delete), "Delete"),
        ("up", UInt32(kVK_UpArrow), "Up Arrow"), ("down", UInt32(kVK_DownArrow), "Down Arrow"),
        ("left", UInt32(kVK_LeftArrow), "Left Arrow"), ("right", UInt32(kVK_RightArrow), "Right Arrow"),
        ("home", UInt32(kVK_Home), "Home"), ("end", UInt32(kVK_End), "End"),
        ("pageup", UInt32(kVK_PageUp), "Page Up"), ("pagedown", UInt32(kVK_PageDown), "Page Down"),
        ("f1", UInt32(kVK_F1), "F1"), ("f2", UInt32(kVK_F2), "F2"), ("f3", UInt32(kVK_F3), "F3"), ("f4", UInt32(kVK_F4), "F4"),
        ("f5", UInt32(kVK_F5), "F5"), ("f6", UInt32(kVK_F6), "F6"), ("f7", UInt32(kVK_F7), "F7"), ("f8", UInt32(kVK_F8), "F8"),
        ("f9", UInt32(kVK_F9), "F9"), ("f10", UInt32(kVK_F10), "F10"), ("f11", UInt32(kVK_F11), "F11"), ("f12", UInt32(kVK_F12), "F12"),
        ("a", UInt32(kVK_ANSI_A), "A"), ("b", UInt32(kVK_ANSI_B), "B"), ("c", UInt32(kVK_ANSI_C), "C"), ("d", UInt32(kVK_ANSI_D), "D"),
        ("e", UInt32(kVK_ANSI_E), "E"), ("f", UInt32(kVK_ANSI_F), "F"), ("g", UInt32(kVK_ANSI_G), "G"), ("h", UInt32(kVK_ANSI_H), "H"),
        ("i", UInt32(kVK_ANSI_I), "I"), ("j", UInt32(kVK_ANSI_J), "J"), ("k", UInt32(kVK_ANSI_K), "K"), ("l", UInt32(kVK_ANSI_L), "L"),
        ("m", UInt32(kVK_ANSI_M), "M"), ("n", UInt32(kVK_ANSI_N), "N"), ("o", UInt32(kVK_ANSI_O), "O"), ("p", UInt32(kVK_ANSI_P), "P"),
        ("q", UInt32(kVK_ANSI_Q), "Q"), ("r", UInt32(kVK_ANSI_R), "R"), ("s", UInt32(kVK_ANSI_S), "S"), ("t", UInt32(kVK_ANSI_T), "T"),
        ("u", UInt32(kVK_ANSI_U), "U"), ("v", UInt32(kVK_ANSI_V), "V"), ("w", UInt32(kVK_ANSI_W), "W"), ("x", UInt32(kVK_ANSI_X), "X"),
        ("y", UInt32(kVK_ANSI_Y), "Y"), ("z", UInt32(kVK_ANSI_Z), "Z"),
        ("0", UInt32(kVK_ANSI_0), "0"), ("1", UInt32(kVK_ANSI_1), "1"), ("2", UInt32(kVK_ANSI_2), "2"), ("3", UInt32(kVK_ANSI_3), "3"),
        ("4", UInt32(kVK_ANSI_4), "4"), ("5", UInt32(kVK_ANSI_5), "5"), ("6", UInt32(kVK_ANSI_6), "6"), ("7", UInt32(kVK_ANSI_7), "7"),
        ("8", UInt32(kVK_ANSI_8), "8"), ("9", UInt32(kVK_ANSI_9), "9"),
        ("minus", UInt32(kVK_ANSI_Minus), "Minus"), ("equal", UInt32(kVK_ANSI_Equal), "Equals"),
        ("comma", UInt32(kVK_ANSI_Comma), "Comma"), ("period", UInt32(kVK_ANSI_Period), "Period"), ("slash", UInt32(kVK_ANSI_Slash), "Slash"),
        ("semicolon", UInt32(kVK_ANSI_Semicolon), "Semicolon"), ("quote", UInt32(kVK_ANSI_Quote), "Quote"),
        ("grave", UInt32(kVK_ANSI_Grave), "Backtick"), ("backslash", UInt32(kVK_ANSI_Backslash), "Backslash"),
        ("leftbracket", UInt32(kVK_ANSI_LeftBracket), "Left Bracket"), ("rightbracket", UInt32(kVK_ANSI_RightBracket), "Right Bracket"),
    ]

    private static let functionKeyCodes: Set<UInt32> = Set(keyNames.filter { $0.0.hasPrefix("f") && $0.0.count <= 3 && Int($0.0.dropFirst()) != nil }.map(\.1))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & UInt32(cmdKey | optionKey | controlKey | shiftKey)
    }

    init?(configValue: String) {
        let tokens = configValue.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let keyToken = tokens.last, let key = Self.keyNames.first(where: { $0.0 == keyToken }) else { return nil }
        var modifiers: UInt32 = 0
        for token in tokens.dropLast() {
            guard let modifier = Self.modifierTokens.first(where: { $0.0 == token }) else { return nil }
            modifiers |= modifier.1
        }
        self.init(keyCode: key.1, modifiers: modifiers)
        guard isValid else { return nil }
    }

    init?(event: NSEvent) {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        let code = UInt32(event.keyCode)
        guard Self.keyNames.contains(where: { $0.1 == code }) else { return nil }
        self.init(keyCode: code, modifiers: modifiers)
        guard isValid else { return nil }
    }

    var isValid: Bool {
        guard Self.keyNames.contains(where: { $0.1 == keyCode }) else { return false }
        if Self.functionKeyCodes.contains(keyCode) { return true }
        return modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    var configValue: String {
        (Self.modifierTokens.filter { modifiers & $0.1 != 0 }.map(\.0) + [Self.keyNames.first { $0.1 == keyCode }?.0 ?? "space"]).joined(separator: "+")
    }

    var displayName: String {
        (Self.modifierTokens.filter { modifiers & $0.1 != 0 }.map(\.2) + [Self.keyNames.first { $0.1 == keyCode }?.2 ?? "Space"]).joined(separator: " ")
    }

    static func enabledSystemShortcuts() -> [CompanionShortcut] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let entries = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int, code >= 0 else { return nil }
            return CompanionShortcut(keyCode: UInt32(code), modifiers: UInt32(truncatingIfNeeded: modifiers))
        }
    }

    var symbols: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.keyNames.first { $0.1 == keyCode }?.2 ?? "Space")
        return parts.joined()
    }
}

@MainActor
final class CompanionHotkey {
    static let conflictMessage = "That shortcut is already taken by another app or the system. Pick a different one."
    static let failureMessage = "The shortcut couldn't be registered. Pick a different one."

    private static var handlers: [UInt32: @MainActor () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    private let handler: @MainActor () -> Void
    private var reference: EventHotKeyRef?
    private var identifier: UInt32 = 0
    private(set) var current: CompanionShortcut?
    var systemShortcuts: () -> [CompanionShortcut] = { CompanionShortcut.enabledSystemShortcuts() }
    var attempt: (CompanionShortcut, EventHotKeyID) -> (OSStatus, EventHotKeyRef?) = { shortcut, hotKeyID in
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &candidate)
        return (status, candidate)
    }

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func register(_ shortcut: CompanionShortcut) -> String? {
        guard shortcut.isValid else { return Self.failureMessage }
        if current == shortcut { return nil }
        if systemShortcuts().contains(shortcut) { return Self.conflictMessage }
        Self.installDispatcherIfNeeded()
        let id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x54444D43), id: id)
        let (status, candidate) = attempt(shortcut, hotKeyID)
        guard status == noErr, let candidate else {
            return status == OSStatus(eventHotKeyExistsErr) ? Self.conflictMessage : Self.failureMessage
        }
        unregister()
        reference = candidate
        identifier = id
        current = shortcut
        Self.handlers[id] = handler
        return nil
    }

    static let noneActiveNote = " No shortcut is active right now."

    static func status(active: CompanionShortcut?, saved: CompanionShortcut) -> String {
        guard let active else { return noneActiveNote }
        return active == saved ? "" : " \(active.displayName) is active instead."
    }

    func apply(_ shortcut: CompanionShortcut?, config: ConfigStore) -> String? {
        if let problem = register(shortcut ?? .default) {
            let message = problem + Self.status(active: current, saved: config.companionShortcut)
            config.companionShortcutProblem = message
            return message
        }
        config.setCompanionShortcut(shortcut)
        try? config.save()
        config.companionActiveShortcut = current
        config.companionShortcutProblem = nil
        return nil
    }

    func start(config: ConfigStore) {
        let saved = config.companionShortcut
        guard let problem = register(saved) else {
            config.companionActiveShortcut = current
            config.companionShortcutProblem = nil
            return
        }
        if saved != .default { _ = register(.default) }
        config.companionActiveShortcut = current
        config.companionShortcutProblem = problem + Self.status(active: current, saved: saved)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        Self.handlers.removeValue(forKey: identifier)
        reference = nil
        identifier = 0
        current = nil
    }

    private static func installDispatcherIfNeeded() {
        guard !installed else { return }
        installed = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            Task { @MainActor in CompanionHotkey.handlers[id]?() }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}

extension Notification.Name {
    static let companionShortcutChanged = Notification.Name("companionShortcutChanged")
}
