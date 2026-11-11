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

    static let quoteMarks: Set<Character> = ["\"", "\u{201C}", "\u{201D}", "\u{201E}", "\u{00AB}", "\u{00BB}", "\u{2039}", "\u{203A}"]

    static func own(_ raw: String) -> String {
        let characters = Array(raw.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'"))
        let count = characters.count
        func wordy(_ index: Int) -> Bool {
            index >= 0 && index < count && (characters[index].isLetter || characters[index].isNumber)
        }
        func lineStart(_ index: Int) -> Bool {
            var cursor = index - 1
            while cursor >= 0, !characters[cursor].isNewline {
                if !characters[cursor].isWhitespace { return false }
                cursor -= 1
            }
            return true
        }
        func opens(_ index: Int) -> Bool {
            let character = characters[index]
            if quoteMarks.contains(character) { return true }
            if character == "'" { return !(wordy(index - 1) && wordy(index + 1)) }
            if character == ">" { return lineStart(index) }
            if character == "`" || character == "~" {
                return index + 2 < count && characters[index + 1] == character && characters[index + 2] == character
            }
            return false
        }
        guard let first = characters.indices.first(where: opens) else { return String(characters) }
        return String(characters[..<first])
    }

    var isEmpty: Bool { current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && earlier.isEmpty }

    var texts: [String] { [current] + earlier }

    static func joins(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "@._-+".contains(character)
    }

    static func leads(_ character: Character) -> Bool {
        joins(character) || "!#$%&'*/=?^`{|}~".contains(character)
    }

    static func holds(_ text: String, _ value: String, strict: Bool = false) -> Bool {
        let needle = value.lowercased()
        guard !needle.isEmpty else { return false }
        let haystack = text.lowercased()
        var start = haystack.startIndex
        while let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
            let before = range.lowerBound == haystack.startIndex ? nil : haystack[haystack.index(before: range.lowerBound)]
            let after = range.upperBound == haystack.endIndex ? nil : haystack[range.upperBound]
            let trailing = after.map { joins($0) && !ends(haystack, at: range.upperBound) } ?? false
            if !(strict ? fused(haystack, before: range.lowerBound) : (before.map(joins) ?? false)) && !trailing { return true }
            start = haystack.index(after: range.lowerBound)
        }
        return false
    }

    static func fused(_ text: String, before index: String.Index) -> Bool {
        var cursor = index
        var marks = 0
        while cursor > text.startIndex, text[text.index(before: cursor)] == "`" {
            cursor = text.index(before: cursor)
            marks += 1
        }
        guard cursor > text.startIndex else { return false }
        let previous = text[text.index(before: cursor)]
        return marks > 0 ? !previous.isWhitespace : leads(previous)
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
            return texts.contains { Self.holds($0, target.value, strict: true) }
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
