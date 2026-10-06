import Foundation
import CryptoKit

indirect enum J: Codable, Equatable, Sendable {
    case object([String: J]), array([J]), string(String), number(Decimal), bool(Bool), null
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Decimal.self), !v.isNaN { self = .number(v) }
        else if let v = try? c.decode([String: J].self) { self = .object(v) }
        else if let v = try? c.decode([J].self) { self = .array(v) }
        else { throw Failure.invalidRequest }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> J { if case .object(let o) = self { return o[key] ?? .null }; return .null }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var array: [J]? { if case .array(let v) = self { return v }; return nil }
    var object: [String: J]? { if case .object(let v) = self { return v }; return nil }
    var decimal: Decimal? { if case .number(let v) = self { return v }; return nil }
    var boolean: Bool? { if case .bool(let v) = self { return v }; return nil }
    func data() throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try e.encode(self) }
    func digest() throws -> String { SHA256.hash(data: try data()).map { String(format: "%02x", $0) }.joined() }
    func keys(_ allowed: Set<String>, required: Set<String> = []) throws {
        guard let o = object, Set(o.keys).isSubset(of: allowed), required.isSubset(of: Set(o.keys)) else { throw Failure.invalidRequest }
    }
    static func parse(_ data: Data, limit: Int = 65536) throws -> J {
        guard data.count <= limit else { throw Failure.invalidRequest }
        var scanner = JSONScanner(bytes: Array(data))
        try scanner.value(0)
        scanner.space()
        guard scanner.index == scanner.bytes.count else { throw Failure.invalidRequest }
        return try JSONDecoder().decode(J.self, from: data)
    }
}

struct JSONScanner {
    let bytes: [UInt8]
    var index = 0
    mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
    mutating func take(_ value: UInt8) throws { space(); guard index < bytes.count, bytes[index] == value else { throw Failure.invalidRequest }; index += 1 }
    mutating func string() throws -> String {
        space(); let start = index; try take(34)
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
            if byte == 92 { guard index < bytes.count else { throw Failure.invalidRequest }; index += 1 }
        }
        throw Failure.invalidRequest
    }
    mutating func value(_ depth: Int) throws {
        guard depth < 20 else { throw Failure.invalidRequest }
        space(); guard index < bytes.count else { throw Failure.invalidRequest }
        switch bytes[index] {
        case 123:
            index += 1; space(); var seen = Set<String>()
            if index < bytes.count && bytes[index] == 125 { index += 1; return }
            while true {
                let key = try string(); guard seen.insert(key).inserted else { throw Failure.invalidRequest }
                try take(58); try value(depth + 1); space()
                guard index < bytes.count else { throw Failure.invalidRequest }
                if bytes[index] == 125 { index += 1; return }
                try take(44)
            }
        case 91:
            index += 1; space()
            if index < bytes.count && bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth + 1); space(); guard index < bytes.count else { throw Failure.invalidRequest }
                if bytes[index] == 93 { index += 1; return }; try take(44)
            }
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw Failure.invalidRequest }
        }
    }
}

enum Failure: String, Error, Sendable {
    case invalidRequest = "invalid_request", unauthorized, credentialUnavailable = "credential_unavailable"
    case unavailable, storage, budget, duplicate, uncertain, providerResponse = "provider_response", canceled, redacted, deadline
}

func require(_ condition: @autoclosure () throws -> Bool, _ failure: Failure = .invalidRequest) throws {
    if try !condition() { throw failure }
}
func identifier(_ value: J) throws -> String {
    guard let text = value.string, let id = UUID(uuidString: text), id.uuidString.lowercased() == text else { throw Failure.invalidRequest }
    return text
}
func nanos(_ value: Decimal) throws -> Int64 {
    try require(!value.isNaN && value >= 0 && value <= 1000, .budget)
    var scaled = value * Decimal(1_000_000_000), rounded = Decimal()
    NSDecimalRound(&rounded, &scaled, 0, .up)
    return NSDecimalNumber(decimal: rounded).int64Value
}
func money(_ value: Int64) -> J { .number(Decimal(value) / Decimal(1_000_000_000)) }
func price(_ value: J) throws -> Decimal {
    guard let text = value.string, text.count < 40, text.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
          let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), amount >= 0, amount <= 1000 else { throw Failure.budget }
    return amount
}
