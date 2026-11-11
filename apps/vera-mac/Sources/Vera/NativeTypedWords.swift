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

    static let quoteMarks: Set<Unicode.Scalar> = ["\"", "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{00AB}", "\u{00BB}", "\u{2039}", "\u{203A}",
                                                  "\u{2018}", "\u{201A}", "\u{201B}", "\u{FF02}", "\u{FF07}"]
    static let apostrophes: Set<Unicode.Scalar> = ["'", "\u{2019}"]
    static let contractions: Set<String> = ["t", "s", "d", "m", "ll", "re", "ve"]

    static func own(_ raw: String) -> String {
        let scalars = Array(raw.unicodeScalars)
        let count = scalars.count
        func wordy(_ index: Int) -> Bool {
            index >= 0 && index < count && CharacterSet.alphanumerics.contains(scalars[index])
        }
        func lineStart(_ index: Int) -> Bool {
            var cursor = index - 1
            while cursor >= 0, !CharacterSet.newlines.contains(scalars[cursor]) {
                if !CharacterSet.whitespaces.contains(scalars[cursor]) { return false }
                cursor -= 1
            }
            return true
        }
        func contracts(_ index: Int) -> Bool {
            guard wordy(index - 1) else { return false }
            var end = index + 1
            while end < count, end - index <= 3, wordy(end) { end += 1 }
            guard !wordy(end) else { return false }
            return contractions.contains(String(String.UnicodeScalarView(scalars[(index + 1)..<end])).lowercased())
        }
        func opens(_ index: Int) -> Bool {
            let scalar = scalars[index]
            if quoteMarks.contains(scalar) { return true }
            if apostrophes.contains(scalar) { return !contracts(index) }
            if scalar == ">" { return lineStart(index) }
            if scalar == "`" || scalar == "~" {
                return index + 2 < count && scalars[index + 1] == scalar && scalars[index + 2] == scalar
            }
            return false
        }
        guard let opener = scalars.indices.first(where: opens) else { return raw.replacingOccurrences(of: "\u{2019}", with: "'") }
        let cut = scalars[..<opener].firstIndex(where: apostrophes.contains) ?? opener
        return String(String.UnicodeScalarView(scalars[..<cut])).replacingOccurrences(of: "\u{2019}", with: "'")
    }

    var isEmpty: Bool { current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && earlier.isEmpty }

    var texts: [String] { [current] + earlier }

    static func joins(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "@._-+".contains(character)
    }

    static func leads(_ character: Character) -> Bool {
        joins(character) || "!#$%&'*/=?^`{|}~".contains(character)
    }

    static func spans(_ text: String, _ value: String, strict: Bool = false) -> [Range<String.Index>] {
        let needle = value.lowercased()
        guard !needle.isEmpty else { return [] }
        let haystack = text.lowercased()
        guard haystack.count == text.count else { return [] }
        var found: [Range<String.Index>] = []
        var start = haystack.startIndex
        while start < haystack.endIndex, let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
            let before = range.lowerBound == haystack.startIndex ? nil : haystack[haystack.index(before: range.lowerBound)]
            let after = range.upperBound == haystack.endIndex ? nil : haystack[range.upperBound]
            let trailing = after.map { joins($0) && !ends(haystack, at: range.upperBound) } ?? false
            if !(strict ? fused(haystack, before: range.lowerBound) : (before.map(joins) ?? false)) && !trailing { found.append(range) }
            start = haystack.index(after: range.lowerBound)
        }
        return found
    }

    static func holds(_ text: String, _ value: String, strict: Bool = false) -> Bool {
        !spans(text, value, strict: strict).isEmpty
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
