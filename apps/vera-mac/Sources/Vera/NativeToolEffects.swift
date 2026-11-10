import Foundation

enum NativeToolEffect: String, Codable, Sendable {
    case read
    case write
}

extension NativeToolDefinition {
    static func readOnly(_ definitions: [NativeToolDefinition]) -> [NativeToolDefinition] {
        definitions.filter { $0.effect == .read }
    }

    var isDeclared: Bool {
        effect == .read ? action == nil : action != nil
    }

    func actionClass(for arguments: [String: NativeJSONValue]) -> NativeActionClass? {
        guard effect == .write else { return nil }
        return classify?(arguments) ?? action
    }
}

struct NativeRunOrigin: Equatable, Sendable {
    static let unattendedModes: Set<String> = ["scheduled", "proactive"]
    static let attended = NativeRunOrigin(mode: "manual", scheduleID: nil)

    let mode: String
    let scheduleID: String?

    init(mode: String, scheduleID: String?) {
        self.mode = mode
        self.scheduleID = scheduleID
    }

    init(payload: Data) {
        let fields = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
        let schedule = (fields["schedule_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.init(mode: fields["mode"] as? String ?? (schedule == nil ? "manual" : "scheduled"), scheduleID: schedule)
    }

    var unattended: Bool { scheduleID != nil || Self.unattendedModes.contains(mode) }

    static func validSchedule(_ id: String?) -> Bool {
        guard let id else { return true }
        return !id.isEmpty && id.utf8.count <= 128 && id.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

struct NativeRunCall: Equatable, Sendable {
    let toolID: String
    let function: String
    let effect: NativeToolEffect
}

enum NativeReadOnlyRun {
    static let outcome = "left undone"
    static let reason = "Not allowed: this run was started by a schedule or by Tandem itself, so it is read-only and changes are refused. Carry on with what you can read, and say in your reply what you left undone."

    static func refusal(run: NativeRunOrigin, call: NativeRunCall) -> String? {
        guard run.unattended, call.effect == .write else { return nil }
        return reason
    }

    static func undone(_ titles: [String]) -> String? {
        var seen = Set<String>()
        let unique = titles.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return nil }
        return "Left undone, because scheduled and self-started runs can only read: " + unique.joined(separator: "; ") + "."
    }
}
