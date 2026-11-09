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
