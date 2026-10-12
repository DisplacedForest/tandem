import Foundation

enum NativeToolResultBudget {
    static let defaultBytes = 32_768
    static let researchBytes = 131_072

    private enum Component {
        case key(String)
        case index(Int)
    }
    private struct Target {
        let path: [Component]
        let value: NativeJSONValue
        let bytes: Int
    }

    static func serializedError(_ description: String, maximumBytes: Int) throws -> String {
        let leading = String(description.prefix(500))
        var fields: [String: NativeJSONValue] = ["error": .string(leading)]
        if leading != description {
            fields["truncated"] = .bool(true)
            fields["truncation_reason"] = .string("Tool error exceeded 500 characters; trailing content was omitted.")
        }
        return try serialized(.object(fields), maximumBytes: maximumBytes)
    }

    static func serialized(_ value: NativeJSONValue, maximumBytes: Int) throws -> String {
        guard maximumBytes >= 0 else { throw NativeToolError.failed("The tool result byte budget is invalid") }
        let original = try NativeToolLoop.serializedResult(value)
        if original.utf8.count <= maximumBytes { return original }
        let reason = "Serialized tool result exceeded \(maximumBytes) bytes; trailing content was omitted."
        func render(_ value: NativeJSONValue) throws -> String {
            var fields: [String: NativeJSONValue]
            if case .object(let object) = value { fields = object }
            else { fields = ["result": value] }
            fields["truncated"] = .bool(true)
            fields["truncation_reason"] = .string(reason)
            return try NativeToolLoop.serializedResult(.object(fields))
        }
        var reduced = value
        for _ in 0..<64 {
            let current = try render(reduced)
            if current.utf8.count <= maximumBytes { return current }
            var remaining = 4096
            guard let target = try targets(reduced, path: [], depth: 0, remaining: &remaining).max(by: { $0.bytes < $1.bytes }) else { break }
            let count: Int
            let minimum: Int
            let candidate: (Int) -> NativeJSONValue
            switch target.value {
            case .array(let values):
                count = values.count; minimum = 1
                candidate = { .array(Array(values.prefix($0))) }
            case .string(let text):
                let bytes = Data(text.utf8)
                count = min(bytes.count, maximumBytes); minimum = 0
                candidate = { .string(prefix(bytes, count: $0)) }
            default: throw NativeToolError.failed("The tool result could not be reduced")
            }
            var low = minimum, high = count
            let base = reduced
            while low < high {
                let middle = low + (high - low + 1) / 2
                let trial = replacing(base, path: target.path[...], with: candidate(middle))
                if try render(trial).utf8.count <= maximumBytes { low = middle }
                else { high = middle - 1 }
            }
            if low == minimum, case .string(let text) = target.value,
               try render(replacing(base, path: target.path[...], with: candidate(low))).utf8.count > maximumBytes {
                reduced = replacing(base, path: target.path[...], with: .string(prefix(Data(text.utf8), count: text.utf8.count / 2)))
            } else {
                reduced = replacing(base, path: target.path[...], with: candidate(low))
            }
        }
        let bytes = Data(original.utf8)
        func fallback(_ count: Int) throws -> String {
            try NativeToolLoop.serializedResult(.object([
                "text": .string(prefix(bytes, count: count)),
                "truncated": .bool(true), "truncation_reason": .string(reason),
            ]))
        }
        guard try fallback(0).utf8.count <= maximumBytes else {
            throw NativeToolError.failed("The tool result byte budget cannot hold a truncation notice")
        }
        var low = 0, high = min(bytes.count, maximumBytes)
        while low < high {
            let middle = low + (high - low + 1) / 2
            if try fallback(middle).utf8.count <= maximumBytes { low = middle }
            else { high = middle - 1 }
        }
        return try fallback(low)
    }

    private static func targets(_ value: NativeJSONValue, path: [Component], depth: Int, remaining: inout Int) throws -> [Target] {
        remaining -= 1
        guard depth < 16, remaining >= 0 else { return [] }
        switch value {
        case .string(let text) where !text.isEmpty:
            if case .key(let key) = path.last,
               ["id", "identifier", "url", "uri", "href", "uuid", "source_id"].contains(key.lowercased()) { return [] }
            if let scheme = URL(string: text)?.scheme, !scheme.isEmpty { return [] }
            return [Target(path: path, value: value, bytes: try NativeToolLoop.serializedResult(value).utf8.count)]
        case .array(let values) where values.count > 1:
            return [Target(path: path, value: value, bytes: try NativeToolLoop.serializedResult(value).utf8.count)]
        case .array(let values):
            return try values.enumerated().flatMap { index, value in
                try targets(value, path: path + [.index(index)], depth: depth + 1, remaining: &remaining)
            }
        case .object(let fields):
            var result: [Target] = []
            for key in fields.keys.sorted() {
                guard remaining > 0 else { break }
                result += try targets(fields[key]!, path: path + [.key(key)], depth: depth + 1, remaining: &remaining)
            }
            return result
        default: return []
        }
    }

    private static func replacing(_ value: NativeJSONValue, path: ArraySlice<Component>, with replacement: NativeJSONValue) -> NativeJSONValue {
        guard let first = path.first else { return replacement }
        switch (value, first) {
        case (.object(var fields), .key(let key)):
            guard let child = fields[key] else { return value }
            fields[key] = replacing(child, path: path.dropFirst(), with: replacement)
            return .object(fields)
        case (.array(var values), .index(let index)) where values.indices.contains(index):
            values[index] = replacing(values[index], path: path.dropFirst(), with: replacement)
            return .array(values)
        default: return value
        }
    }

    private static func prefix(_ data: Data, count: Int) -> String {
        var end = min(count, data.count)
        while end > 0 && end < data.count && data[end] & 0xc0 == 0x80 { end -= 1 }
        return String(decoding: data.prefix(end), as: UTF8.self)
    }
}
