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
        var characters = Array(raw.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'"))
        let count = characters.count
        func wordy(_ index: Int) -> Bool {
            index >= 0 && index < count && (characters[index].isLetter || characters[index].isNumber)
        }
        func blank(_ range: ClosedRange<Int>) {
            for index in range where !characters[index].isNewline { characters[index] = " " }
        }
        func lineStart(_ index: Int) -> Bool {
            var cursor = index - 1
            while cursor >= 0, !characters[cursor].isNewline {
                if !characters[cursor].isWhitespace { return false }
                cursor -= 1
            }
            return true
        }
        var index = 0
        while index < count {
            let character = characters[index]
            if character == ">", lineStart(index) {
                var end = index
                while end + 1 < count, !characters[end + 1].isNewline { end += 1 }
                blank(index...end)
                index = end + 1
            } else if character == "`" || character == "~" {
                var run = index
                while run < count, characters[run] == character { run += 1 }
                let length = run - index
                guard length >= 3 else { index = run; continue }
                var end = count - 1
                var cursor = run
                while cursor < count {
                    guard characters[cursor] == character else { cursor += 1; continue }
                    var close = cursor
                    while close < count, characters[close] == character { close += 1 }
                    if close - cursor >= length { end = close - 1; break }
                    cursor = close
                }
                blank(index...end)
                index = end + 1
            } else if character == "\"" || character == "\u{201C}" {
                let closer: Character = character == "\"" ? "\"" : "\u{201D}"
                var end = count - 1
                var cursor = index + 1
                while cursor < count {
                    if characters[cursor] == closer { end = cursor; break }
                    cursor += 1
                }
                blank(index...end)
                index = end + 1
            } else if character == "'", !wordy(index - 1), index + 1 < count, !characters[index + 1].isWhitespace {
                var end = count - 1
                var cursor = count - 1
                while cursor > index {
                    if characters[cursor] == "'", !wordy(cursor + 1) { end = cursor; break }
                    cursor -= 1
                }
                blank(index...end)
                index = end + 1
            } else {
                index += 1
            }
        }
        return String(characters)
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
