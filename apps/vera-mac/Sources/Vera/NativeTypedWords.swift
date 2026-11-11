import Foundation

struct NativeTypedWords: Hashable, Sendable {
    var current: String
    var earlier: [String]
    var said = ""

    static let none = NativeTypedWords(current: "", earlier: [])
    static let limit = 64

    init(current: String, earlier: [String]) {
        self.current = current
        self.earlier = earlier
    }

    init(typed current: String?, earlier: [String] = []) {
        said = current ?? ""
        self.current = current.map(Self.own) ?? ""
        self.earlier = earlier.suffix(Self.limit).map(Self.own)
    }

    static func own(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        for pattern in NativeTurnToolAuthority.literalPatterns {
            while let range = text.range(of: pattern, options: .regularExpression) {
                let length = text.distance(from: range.lowerBound, to: range.upperBound)
                guard length > 0 else { break }
                text.replaceSubrange(range, with: String(repeating: " ", count: length))
            }
        }
        return text
    }

    var isEmpty: Bool { current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && earlier.isEmpty }

    var texts: [String] { [current] + earlier }

    static func joins(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "@._-+".contains(character)
    }

    static func holds(_ text: String, _ value: String) -> Bool {
        let needle = value.lowercased()
        guard !needle.isEmpty else { return false }
        let haystack = text.lowercased()
        var start = haystack.startIndex
        while let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
            let before = range.lowerBound == haystack.startIndex ? nil : haystack[haystack.index(before: range.lowerBound)]
            let after = range.upperBound == haystack.endIndex ? nil : haystack[range.upperBound]
            let trailing = after.map { joins($0) && !ends(haystack, at: range.upperBound) } ?? false
            if !(before.map(joins) ?? false) && !trailing { return true }
            start = haystack.index(after: range.lowerBound)
        }
        return false
    }

    static func ends(_ text: String, at index: String.Index) -> Bool {
        guard text[index] == "." else { return false }
        let next = text.index(after: index)
        return next == text.endIndex || !(text[next].isLetter || text[next].isNumber)
    }

    func names(_ target: NativeRuleTarget, inCurrentOnly: Bool = false) -> Bool {
        let texts = inCurrentOnly ? [current] : self.texts
        switch target.kind {
        case .recipient, .service:
            return texts.contains { Self.holds($0, target.value) }
        case .folder:
            let name = URL(fileURLWithPath: target.value).lastPathComponent
            return texts.contains { Self.holds($0, target.value) || (!name.isEmpty && name != "/" && Self.holds($0, name)) }
        case .commandPrefix:
            let command = target.value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !command.isEmpty else { return false }
            return texts.contains { text in
                let spaced = text.replacingOccurrences(of: "`", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return Self.holds(spaced, command)
            }
        }
    }

    func names(all targets: [NativeRuleTarget], inCurrentOnly: Bool = false) -> Bool {
        !targets.isEmpty && targets.allSatisfy { names($0, inCurrentOnly: inCurrentOnly) }
    }
}
