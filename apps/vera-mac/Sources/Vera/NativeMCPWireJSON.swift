import Foundation

nonisolated enum NativeMCPWireJSON {
    static func validate(_ data: Data, maximumBytes: Int = 262144) throws {
        try NativeTaskJSON.validate(data, maximumBytes: maximumBytes)
        let bytes = Array(data)
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
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                guard token.count <= 100, let number = Double(token), number.isFinite,
                      abs(number) <= 9_007_199_254_740_991,
                      let original = Decimal(string: token, locale: Locale(identifier: "en_US_POSIX")),
                      let encoded = Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX")),
                      original == encoded else { throw NativeMCPTransportError.malformedResponse }
                let mantissa = token.lowercased().split(separator: "e")[0]
                let digits = mantissa.filter { $0.isNumber }.drop(while: { $0 == "0" })
                guard digits.count <= 16, number != 0 || digits.isEmpty else { throw NativeMCPTransportError.malformedResponse }
            } else { index += 1 }
        }
    }
}
