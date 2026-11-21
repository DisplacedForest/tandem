import Foundation

struct NativeTurnToolAuthority: Equatable, Sendable {
    let mentions: Set<String>
    let companion: Bool

    var allowsGeneral: Bool { companion }

    var allowedWorkerTypes: Set<String> {
        var types: Set<String> = ["research", "document"]
        if allowsGeneral { types.insert(NativeTaskTools.generalWorkerType) }
        return types
    }

    init(mentions: Set<String> = [], companion: Bool = false) {
        self.mentions = mentions
        self.companion = companion
    }

    static let literalPatterns = [#"(?s)~~~.*?(?:~~~|$)"#, #"(?m)^\s*>.*$"#, #""(?:\\.|[^"\\])*(?:"|$)"#,
                                  #"“[^”\n]*(?:”|$)"#, #"(?<![\p{L}\p{N}])'[^'\n]*'(?![\p{L}\p{N}])"#]

    static func maskBackticks(_ raw: String) -> String {
        var characters = Array(raw)
        var index = 0
        while index < characters.count {
            guard characters[index] == "`" else { index += 1; continue }
            var runEnd = index
            while runEnd < characters.count, characters[runEnd] == "`" { runEnd += 1 }
            let length = runEnd - index
            var cursor = runEnd
            var closing: Int?
            while cursor < characters.count {
                guard characters[cursor] == "`" else { cursor += 1; continue }
                var candidateEnd = cursor
                while candidateEnd < characters.count, characters[candidateEnd] == "`" { candidateEnd += 1 }
                if candidateEnd - cursor == length { closing = candidateEnd; break }
                cursor = candidateEnd
            }
            let end: Int
            if let closing {
                end = closing
            } else if length >= 3 {
                end = characters.count
            } else {
                end = characters[runEnd...].firstIndex(where: \.isNewline) ?? characters.count
            }
            for position in index..<end where !characters[position].isNewline { characters[position] = " " }
            index = end
        }
        return String(characters)
    }

    static func literalMask(_ raw: String) -> String {
        var text = maskBackticks(raw.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'"))
        for pattern in literalPatterns {
            while let range = text.range(of: pattern, options: .regularExpression) {
                let length = text.distance(from: range.lowerBound, to: range.upperBound)
                guard length > 0 else { break }
                text.replaceSubrange(range, with: String(repeating: " ", count: length))
            }
        }
        return text
    }
}
