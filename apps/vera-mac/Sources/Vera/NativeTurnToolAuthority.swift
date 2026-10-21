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

    private static func instructions(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        for pattern in [#"(?s)```.*?(?:```|$)"#, #"(?s)~~~.*?(?:~~~|$)"#, #"`[^`\n]*(?:`|$)"#,
                        #"(?m)^\s*>.*$"#, #""(?:\\.|[^"\\])*(?:"|$)"#, #"“[^”\n]*(?:”|$)"#,
                        #"(?<![\p{L}\p{N}])'[^'\n]*'(?![\p{L}\p{N}])"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return text
    }
}
