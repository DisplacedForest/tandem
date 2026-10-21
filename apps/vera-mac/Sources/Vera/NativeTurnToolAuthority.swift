import Foundation

struct NativeTurnToolAuthority: Equatable, Sendable {
    let allowsTools: Bool
    let allowsResearch: Bool

    init(_ request: String, mentions: Set<String> = []) {
        let text = Self.instructions(request)
        let noTools = Self.matches(text, #"\b(?:do\s+not|must\s+not|don't|dont|never)\s+(?:use|call|run|invoke)\s+(?:(?:any|external)\s+)?(?:tools?|functions?)\b|\b(?:no|without)\s+(?:(?:using|calling|invoking)\s+)?(?:(?:any|external)\s+)?(?:tools?|functions?)\b"#)
        let noResearch = Self.matches(text, #"\b(?:do\s+not|must\s+not|don't|dont|never)\s+(?:(?:start|run|do|perform|conduct)\s+)?(?:(?:new|background|deep)\s+)*(?:research|investigat\w*)\b|\bno\s+(?:new\s+)?(?:(?:background|deep)\s+)?(?:research|investigation)\b"#)
        let action = #"(?:(?:start|run|launch|begin|do|perform|conduct)\s+(?:a\s+)?)?(?:(?:new|separate|background|deep)\s+)*(?:research|investigate|investigation)\b"#
        let start = #"(?:^|[.!?\n])\s*(?:(?:private|separately|also|now)\s*[:,]?\s*)*"#
        let explicit = Self.matches(text, start + #"(?:please|can\s+you|could\s+you|would\s+you|i\s+want\s+you\s+to|i\s+would\s+like\s+you\s+to)\s+"# + action)
            || Self.matches(text, start + action + #"\s+(?!(?:is|was|means|can|should|does|has|had)\b)"#)
        allowsTools = !noTools
        allowsResearch = !noTools && !noResearch && (explicit || mentions.contains(NativeWebTools.researchToolID))
    }

    func filter(_ ids: Set<String>) -> Set<String> {
        guard allowsTools else { return [] }
        return allowsResearch ? ids : ids.subtracting([NativeWebTools.researchToolID, NativeTaskTools.toolID])
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
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
                end = characters[runEnd...].firstIndex(of: "\n") ?? characters.count
            }
            for position in index..<end where characters[position] != "\n" { characters[position] = " " }
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

    private static func instructions(_ raw: String) -> String {
        literalMask(raw)
    }
}
