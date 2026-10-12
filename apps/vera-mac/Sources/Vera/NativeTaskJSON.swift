import Foundation

struct NativeTaskJSON {
    private let bytes: [UInt8]
    private var index = 0

    static func validate(_ data: Data, maximumBytes: Int = 1048576) throws {
        guard (1...8_000_000).contains(maximumBytes), data.count <= maximumBytes else { throw NativeTaskHTTPError.invalidResponse }
        var scanner = NativeTaskJSON(bytes: Array(data))
        try scanner.value(depth: 0)
        scanner.spaces()
        guard scanner.index == scanner.bytes.count else { throw NativeTaskHTTPError.invalidResponse }
    }

    private mutating func spaces() {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) throws {
        spaces()
        guard index < bytes.count, bytes[index] == byte else { throw NativeTaskHTTPError.invalidResponse }
        index += 1
    }

    private mutating func string() throws -> String {
        spaces()
        let start = index
        try consume(34)
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 92 {
                guard index < bytes.count else { throw NativeTaskHTTPError.invalidResponse }
                index += 1
            } else if byte == 34 {
                guard let text = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else {
                    throw NativeTaskHTTPError.invalidResponse
                }
                return text
            }
        }
        throw NativeTaskHTTPError.invalidResponse
    }

    private mutating func value(depth: Int) throws {
        spaces()
        guard depth < 20, index < bytes.count else { throw NativeTaskHTTPError.invalidResponse }
        switch bytes[index] {
        case 123:
            index += 1
            spaces()
            if index < bytes.count && bytes[index] == 125 { index += 1; return }
            var keys: Set<String> = []
            while true {
                let key = try string()
                guard keys.insert(key).inserted else { throw NativeTaskHTTPError.invalidResponse }
                try consume(58)
                try value(depth: depth + 1)
                spaces()
                if index < bytes.count && bytes[index] == 125 { index += 1; return }
                try consume(44)
            }
        case 91:
            index += 1
            spaces()
            if index < bytes.count && bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1)
                spaces()
                if index < bytes.count && bytes[index] == 93 { index += 1; return }
                try consume(44)
            }
        case 34:
            _ = try string()
        default:
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard start < index else { throw NativeTaskHTTPError.invalidResponse }
        }
    }
}
