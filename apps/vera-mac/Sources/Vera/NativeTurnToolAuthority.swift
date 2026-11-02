import Foundation

struct NativeTurnToolAuthority: Equatable, Sendable {
    let allowsTools: Bool
    let allowsResearch: Bool
    let allowsDocument: Bool
    let allowsSchedule: Bool

    var allowsBackground: Bool { allowsResearch || allowsDocument }

    var allowedWorkerTypes: Set<String> {
        var types: Set<String> = []
        if allowsResearch { types.insert("research") }
        if allowsDocument { types.insert("document") }
        return types
    }

    init(_ request: String, mentions: Set<String> = []) {
        let text = Self.instructions(request)
        let noTools = Self.matches(text, #"\b(?:do\s+not|must\s+not|don't|dont|never)\s+(?:use|call|run|invoke)\s+(?:(?:any|external)\s+)?(?:tools?|functions?)\b|\b(?:no|without)\s+(?:(?:using|calling|invoking)\s+)?(?:(?:any|external)\s+)?(?:tools?|functions?)\b"#)
        let noResearch = Self.matches(text, #"\b(?:do\s+not|must\s+not|don't|dont|never)\s+(?:(?:start|run|do|perform|conduct)\s+)?(?:(?:new|background|deep)\s+)*(?:research|investigat\w*)\b|\bno\s+(?:new\s+)?(?:(?:background|deep)\s+)?(?:research|investigation)\b"#)
        let documentNoun = #"(?:document|report|essay|memo|guide|article|write-?up)"#
        let noDocument = Self.matches(text, #"\b(?:do\s+not|must\s+not|don't|dont|never)\s+(?:write|draft|produce|create|prepare)\s+(?:me\s+|us\s+)?(?:(?:a|an|the|any)\s+)?(?:(?:new|separate|background|long|longer|full|detailed|written)\s+)*"# + documentNoun + #"s?\b"#)
        let researchAction = #"(?:(?:start|run|launch|begin|do|perform|conduct)\s+(?:a\s+)?)?(?:(?:new|separate|background|deep)\s+)*(?:research|investigate|investigation)\b"#
        let documentAction = #"(?:write|draft|produce|create|prepare)\s+(?:me\s+|us\s+)?(?:(?:a|an|the)\s+)?(?:(?:new|separate|background|long|longer|full|detailed|written)\s+)*"# + documentNoun + #"\b"#
        let start = #"(?:^|[.!?\n])\s*(?:(?:private|separately|also|now)\s*[:,]?\s*)*"#
        let polite = #"(?:please|can\s+you|could\s+you|would\s+you|i\s+want\s+you\s+to|i\s+would\s+like\s+you\s+to)\s+"#
        let after = #"(?:\s+(?!(?:is|was|means|can|should|does|has|had)\b)|\s*(?:[.!?:,;]|$))"#
        let researchExplicit = Self.matches(text, start + polite + researchAction) || Self.matches(text, start + researchAction + after)
        let documentExplicit = Self.matches(text, start + polite + documentAction) || Self.matches(text, start + documentAction + after)
        let noSchedule = Self.matches(text, #"\b(?:do\s+not|must\s+not|don't|dont|never)\s+(?:set\s+up\s+|create\s+|make\s+)?(?:a\s+|any\s+)?(?:schedules?|recurring)\b|\bno\s+(?:new\s+)?schedules?\b"#)
        let scheduleExplicit = Self.schedulesWork(text)
        allowsTools = !noTools
        allowsSchedule = !noTools && !noSchedule && (scheduleExplicit || mentions.contains(NativeScheduleTools.toolID))
        allowsResearch = !noTools && !noResearch && (researchExplicit || mentions.contains(NativeWebTools.researchToolID))
        allowsDocument = !noTools && !noDocument && (documentExplicit || mentions.contains(NativeTaskTools.toolID))
    }

    func filter(_ ids: Set<String>) -> Set<String> {
        guard allowsTools else { return [] }
        var kept = ids
        if !allowsBackground {
            kept.remove(NativeTaskTools.toolID)
            if !allowsSchedule { kept.remove(NativeWebTools.researchToolID) }
        }
        if !allowsSchedule { kept.remove(NativeScheduleTools.toolID) }
        return kept
    }

    static let scheduleIntent = #"\b(?:every\s+(?:day|morning|afternoon|evening|night|weekday|week|month|other\s+day|few\s+hours|\d+\s+(?:hours?|hrs?)|hour|monday|tuesday|wednesday|thursday|friday|saturday|sunday)s?|each\s+(?:day|morning|evening|week|weekday|monday|tuesday|wednesday|thursday|friday|saturday|sunday)|daily|weekly|weekdays|nightly|hourly|recurring|regularly|on\s+a\s+schedule|once\s+a\s+(?:day|week)|(?:on\s+)?(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)s|tomorrow\s+(?:morning|afternoon|evening|night)|later\s+(?:today|tonight|this\s+(?:morning|afternoon|evening))|(?:tomorrow|tonight)\s+at\s+\d{1,2}(?::\d{2})?\s*(?:am|pm|o'clock)?|at\s+\d{1,2}(?::\d{2})?\s*(?:am|pm|o'clock)?\s+(?:tomorrow|tonight|every|each|on)\b)(?:\s+at\s+\d{1,2}(?::\d{2})?\s*(?:am|pm|o'clock)?)?"#
    static let scheduleQuestion = #"^\s*(?:what|why|how|when|where|who|which|whose|is|are|was|were|do|does|did|should|explain|describe|define|tell\s+me\s+(?:what|why|how|when|about))\b"#
    static let scheduleSubject = #"\b(?:why|how|whether|if|that|who|whom|which|what)\b"#
    static let scheduleLead = #"^\s*(?:(?:please|also|and|then|now|can\s+you|could\s+you|would\s+you|will\s+you|i\s+want\s+you\s+to|i'?d\s+like\s+you\s+to|i\s+would\s+like\s+you\s+to|i\s+need\s+you\s+to)\s*,?\s*)*(?:(?:schedule|set\s+up)\s+(?:(?:a|an|the|me|us|some|another)\s+)?)?$"#
    static let scheduleTail = #"^\s*(?:$|[,;:]|(?:and|then|with|please|thanks|starting|beginning|from|until|for|so|to)\b)"#

    static func schedulesWork(_ text: String) -> Bool {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
        for raw in sentences {
            let sentence = raw.trimmingCharacters(in: .whitespaces)
            if matches(sentence, scheduleQuestion) { continue }
            guard let cadence = sentence.range(of: scheduleIntent, options: [.regularExpression, .caseInsensitive]) else { continue }
            let before = String(sentence[sentence.startIndex..<cadence.lowerBound])
            let after = String(sentence[cadence.upperBound...])
            if matches(before, scheduleSubject) { continue }
            if matches(before, scheduleLead) || matches(after, scheduleTail) { return true }
        }
        return false
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
