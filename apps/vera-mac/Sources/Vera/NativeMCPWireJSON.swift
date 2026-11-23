import Foundation

nonisolated enum NativeMCPWireJSON {
    static func validate(_ data: Data, maximumBytes: Int = 262144) throws {
        try NativeTaskJSON.validate(data, maximumBytes: maximumBytes)
        for range in numbers(Array(data)) {
            guard isExact(String(decoding: data[data.startIndex.advanced(by: range.lowerBound)..<data.startIndex.advanced(by: range.upperBound)], as: UTF8.self)) else { throw NativeMCPTransportError.malformedResponse }
        }
    }

    static func preserving(_ data: Data, maximumBytes: Int) throws -> Data {
        try NativeTaskJSON.validate(data, maximumBytes: maximumBytes)
        let bytes = Array(data)
        var result = Data(), copied = 0
        for range in numbers(bytes) {
            let token = String(decoding: bytes[range], as: UTF8.self)
            guard !isExact(token) else { continue }
            guard isNumber(token) else { throw NativeMCPTransportError.malformedResponse }
            guard carries(token) else { continue }
            result.append(contentsOf: bytes[copied..<range.lowerBound])
            result.append(34)
            result.append(contentsOf: bytes[range])
            result.append(34)
            copied = range.upperBound
        }
        guard copied > 0 else { return data }
        result.append(contentsOf: bytes[copied...])
        return result
    }

    static func carries(_ token: String) -> Bool {
        guard let first = token.utf8.first, first == 45 || (48...57).contains(first), isNumber(token), !isExact(token) else { return false }
        guard token.contains(where: { ".eE".contains($0) }), let number = Double(token) else { return true }
        guard number.isFinite, abs(number) <= largestExact, number != 0 || !token.contains(where: { "123456789".contains($0) }),
              let exact = Decimal(string: token, locale: Locale(identifier: "en_US_POSIX")) else { return true }
        var whole = Decimal(), source = exact
        NSDecimalRound(&whole, &source, 0, exact < 0 ? .up : .down)
        return whole != Decimal(number.rounded(.towardZero))
    }

    private static func isNumber(_ token: String) -> Bool {
        token.range(of: #"\A-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?\z"#, options: .regularExpression) != nil
    }

    private static let largestExact = 9_007_199_254_740_991.0

    private static func isExact(_ token: String) -> Bool {
        guard token.count <= 100, let number = Double(token), number.isFinite, abs(number) <= largestExact,
              let original = Decimal(string: token, locale: Locale(identifier: "en_US_POSIX")),
              let encoded = Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX")),
              original == encoded else { return false }
        let mantissa = token.lowercased().split(separator: "e")[0]
        let digits = mantissa.filter { $0.isNumber }.drop(while: { $0 == "0" })
        return digits.count <= 16 && (number != 0 || digits.isEmpty)
    }

    private static func numbers(_ bytes: [UInt8]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 34 {
                index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { index += 1; break }
                    index += 1
                }
            } else if bytes[index] == 45 || (48...57).contains(bytes[index]) {
                let start = index
                while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                result.append(start..<index)
            } else { index += 1 }
        }
        return result
    }
}
