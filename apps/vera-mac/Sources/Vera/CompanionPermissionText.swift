import Foundation

enum CompanionPermissionText {
    static func question(service: String, action: String, details: String? = nil) -> String {
        var requested = action
        if let details {
            let fields: [String: NativeJSONValue]
            if case .object(let values)? = decoded(details) { fields = values }
            else { fields = savedFields(details) }
            if dispatcher(fields), case .string(let nested)? = fields["name"] { requested = nested }
        }
        return "Allow “\(actionName(requested, service: service))” in \(service)?"
    }

    static func arguments(_ text: String, service: String? = nil) -> String? {
        guard let value = decoded(text) else { return nil }
        let rendered = lines(value, label: nil, service: service)
        return rendered.isEmpty ? nil : rendered.joined(separator: "\n")
    }

    static func savedDetails(_ text: String, service: String? = nil) -> String {
        if let rendered = arguments(text, service: service) { return rendered }
        let source = text.components(separatedBy: "\n")
        let fields = savedFields(text)
        if dispatcher(fields) { return lines(.object(fields), label: nil, service: service).joined(separator: "\n") }
        return source.flatMap { line -> [String] in
            guard let separator = line.firstIndex(of: ":") else { return [line] }
            let label = String(line[..<separator])
            let body = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard let value = decoded(body) else { return [line] }
            return lines(value, label: label, service: service)
        }.joined(separator: "\n")
    }

    private static func savedFields(_ text: String) -> [String: NativeJSONValue] {
        let source = text.components(separatedBy: "\n")
        var fields: [String: NativeJSONValue] = [:]
        for line in source {
            guard let separator = line.firstIndex(of: ":") else { fields = [:]; break }
            let key = String(line[..<separator]).lowercased()
            let body = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard fields[key] == nil else { fields = [:]; break }
            fields[key] = (decoded(body)) ?? .string(body)
        }
        return fields
    }

    private static func decoded(_ text: String) -> NativeJSONValue? {
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else { return nil }
        return try? NativeJSONValue(any: value)
    }

    private static func lines(_ value: NativeJSONValue, label: String?, service: String?) -> [String] {
        switch value {
        case .object(let fields):
            if dispatcher(fields), case .string(let action)? = fields["name"], let inputs = fields["arguments"] {
                return [joined("Action", actionName(action, service: service))] + lines(inputs, label: label, service: service)
            }
            if fields.isEmpty { return [joined(label, "None")] }
            return NativeCompanionWorker.shownOrder(Array(fields.keys)).flatMap { key in
                let name = key.replacingOccurrences(of: "_", with: " ")
                let heading = name.prefix(1).uppercased() + name.dropFirst()
                let path = label.map { $0 + ", " + heading } ?? heading
                return lines(fields[key] ?? .null, label: path, service: service)
            }
        case .array(let values):
            if values.isEmpty { return [joined(label, "None")] }
            return values.enumerated().flatMap { index, value in
                lines(value, label: values.count == 1 ? label : (label.map { $0 + " " } ?? "Item ") + String(index + 1), service: service)
            }
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
               let nested = decoded(trimmed) {
                return lines(nested, label: label, service: service)
            }
            return [joined(label, text.isEmpty ? "Empty" : text)]
        case .bool(let flag): return [joined(label, flag ? "Yes" : "No")]
        case .number: return [joined(label, NativeEffectProposal.canonicalArguments(value))]
        case .null: return [joined(label, "Not set")]
        }
    }

    private static func dispatcher(_ fields: [String: NativeJSONValue]) -> Bool {
        guard Set(fields.keys) == ["name", "arguments"], case .string? = fields["name"] else { return false }
        if case .object? = fields["arguments"] { return true }
        if case .string(let text)? = fields["arguments"],
           let value = decoded(text), case .object = value { return true }
        return false
    }

    private static func actionName(_ raw: String, service: String?) -> String {
        var name = raw.components(separatedBy: "__").last ?? raw
        if let service {
            let words = service.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            let prefixes = [words.joined(), words.compactMap(\.first).map { String($0) }.joined()]
            for prefix in prefixes where !prefix.isEmpty && name.lowercased().hasPrefix(prefix + "_") {
                name = String(name.dropFirst(prefix.count + 1))
                break
            }
        }
        name = name.replacingOccurrences(of: "_", with: " ")
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private static func joined(_ label: String?, _ value: String) -> String {
        label.map { $0 + ": " + value } ?? value
    }
}
