import Foundation

struct NativeTurnToolAuthority: Equatable, Sendable {
    let allowsTools: Bool
    let allowsResearch: Bool
    let allowsDocument: Bool
    let allowsSchedule: Bool
    let companion: Bool

    var allowsBackground: Bool { allowsResearch || allowsDocument }
    var allowsGeneral: Bool { companion && allowsTools }

    var allowedWorkerTypes: Set<String> {
        var types: Set<String> = []
        if allowsResearch { types.insert("research") }
        if allowsDocument { types.insert("document") }
        if allowsGeneral { types.insert(NativeTaskTools.generalWorkerType) }
        return types
    }

    init(_ request: String, mentions: Set<String> = [], companion: Bool = false) {
        let text = Self.instructions(request)
        let noTools = Self.matches(text, #"\b(?:do\s+not|must\s+not|don't|dont|never)\s+(?:use|call|run|invoke)\s+(?:(?:any|external)\s+)?(?:tools?|functions?)\b|\b(?:no|without)\s+(?:(?:using|calling|invoking)\s+)?(?:(?:any|external)\s+)?(?:tools?|functions?)\b"#)
        let noResearch = Self.matches(text, #"\b(?:do\s+not|must\s+not|don't|dont|never)\s+(?:(?:start|run|do|perform|conduct)\s+)?(?:(?:new|background|deep)\s+)*(?:research|investigat\w*)\b|\bno\s+(?:new\s+)?(?:(?:background|deep)\s+)?(?:research|investigation)\b"#)
        let documentNoun = #"(?:document|report|essay|memo|guide|article|write-?up)"#
        let noDocument = Self.matches(text, #"\b(?:do\s+not|must\s+not|don't|dont|never)\s+(?:write|draft|produce|create|prepare)\s+(?:me\s+|us\s+)?(?:(?:a|an|the|any)\s+)?(?:(?:new|separate|background|long|longer|full|detailed|written)\s+)*"# + documentNoun + #"s?\b"#)
        let noSchedule = Self.matches(text, #"\b(?:do\s+not|must\s+not|don't|dont|never)\s+(?:set\s+up\s+|create\s+|make\s+)?(?:a\s+|any\s+)?(?:schedules?|recurring)\b|\bno\s+(?:new\s+)?schedules?\b"#)
        allowsTools = !noTools
        self.companion = companion
        allowsSchedule = !noTools && !noSchedule
        allowsResearch = !noTools && !noResearch
        allowsDocument = !noTools && !noDocument
    }

    func filter(_ ids: Set<String>) -> Set<String> {
        guard allowsTools else { return [] }
        var kept = ids
        if !allowsBackground {
            if !allowsGeneral { kept.remove(NativeTaskTools.toolID) }
            if !allowsSchedule { kept.remove(NativeWebTools.researchToolID) }
        }
        if !allowsSchedule { kept.remove(NativeScheduleTools.toolID) }
        return kept
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

    private static func instructions(_ raw: String) -> String {
        literalMask(raw)
    }
}
