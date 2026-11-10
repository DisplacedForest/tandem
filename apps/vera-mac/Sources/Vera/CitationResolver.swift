import Foundation

struct CitationBlock: Equatable {
    var text: String
    var refs: [Int]
    var isCode: Bool
}

struct ResolvedCitations: Equatable {
    var blocks: [CitationBlock]
    var sources: [PulseSource]
    var recovered: Bool
}

enum CitationResolver {
    struct Scan: Equatable {
        var text: String
        var refs: [Int]
        var markers: [[Int]]
    }

    private struct Fence {
        let mark: Character
        let length: Int
        var quoted = false
    }

    private static let spanLimit = 2000

    private struct Segment {
        var lines: [String]
        var isCode: Bool
    }

    private static let separators = CharacterSet(charactersIn: " \t-\u{2013}:()<>|")
    private static let linkPattern = try? NSRegularExpression(pattern: "\\[([^\\]]*)\\]\\(\\s*<?([^)\\s>]+)>?\\s*\\)")
    private static let httpPattern = try? NSRegularExpression(pattern: "https?://", options: [.caseInsensitive])

    static func resolve(text: String, sources: [PulseSource], allowRecovery: Bool = true) -> ResolvedCitations {
        if !sources.isEmpty {
            let body = withoutMatchingList(text, sources: sources)
            return ResolvedCitations(blocks: blocks(text: body, sources: sources), sources: sources, recovered: false)
        }
        if allowRecovery, let recovered = recover(text) {
            return ResolvedCitations(
                blocks: blocks(text: recovered.body, sources: recovered.sources), sources: recovered.sources, recovered: true)
        }
        return ResolvedCitations(blocks: blocks(text: text, sources: []), sources: [], recovered: false)
    }

    static func blocks(text: String, sources: [PulseSource]) -> [CitationBlock] {
        let known = Set(sources.map(\.n))
        return segments(text).map { segment in
            let joined = segment.lines.joined(separator: "\n")
            guard !segment.isCode, !known.isEmpty else {
                return CitationBlock(text: joined, refs: [], isCode: segment.isCode)
            }
            let result = scan(joined, known: known)
            return CitationBlock(text: result.text, refs: result.refs, isCode: false)
        }
    }

    static func recover(_ text: String) -> (body: String, sources: [PulseSource])? {
        let lines = text.components(separatedBy: "\n")
        let headings = headingIndices(lines)
        guard let last = headings.last else { return nil }
        for earlier in headings.dropLast() {
            if let next = nextNonBlank(lines, after: earlier), entryPrefix(lines[next]) != nil { return nil }
        }
        var entries: [PulseSource] = []
        var numbers = Set<Int>()
        for line in lines[(last + 1)...] where !isBlank(line) {
            guard let prefix = entryPrefix(line),
                  let link = entryLink(prefix.rest),
                  NativeResearchReportSafety.destination(link.url) != nil,
                  numbers.insert(prefix.number).inserted else { return nil }
            entries.append(PulseSource(n: prefix.number, title: link.title, url: link.url))
        }
        guard !entries.isEmpty else { return nil }
        let body = trailingTrimmed(lines[..<last].joined(separator: "\n"))
        let found = scan(body, known: numbers)
        guard !found.markers.isEmpty, found.markers.allSatisfy({ $0.allSatisfy(numbers.contains) }) else { return nil }
        return (body, entries.sorted { $0.n < $1.n })
    }

    static func withoutMatchingList(_ text: String, sources: [PulseSource]) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let last = headingIndices(lines).last else { return text }
        let entries = lines[(last + 1)...].filter { !isBlank($0) }
        var numbered = 0
        for line in entries {
            if let prefix = entryPrefix(line) {
                guard let source = sources.first(where: { $0.n == prefix.number }), entry(prefix.rest, matches: source) else {
                    return text
                }
                numbered += 1
            } else if let rest = bulletRest(line) {
                guard sources.contains(where: { entry(rest, matches: $0) }) else { return text }
            } else {
                return text
            }
        }
        guard numbered > 0 else { return text }
        return trailingTrimmed(lines[..<last].joined(separator: "\n"))
    }

    static func exportText(_ text: String, sources: [PulseSource]) -> String {
        guard !sources.isEmpty else { return text }
        guard !hasWrittenList(text.components(separatedBy: "\n")) else { return text }
        guard !scan(text, known: Set(sources.map(\.n))).refs.isEmpty else { return text }
        let entries = sources.sorted { $0.n < $1.n }.compactMap { source -> String? in
            let url = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard NativeResearchReportSafety.destination(url) != nil else { return nil }
            let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "\(source.n). \(url)" : "\(source.n). \(title) (\(url))"
        }
        guard !entries.isEmpty else { return text }
        return trailingTrimmed(text) + "\n\n## Sources\n\n" + entries.joined(separator: "\n") + "\n"
    }

    static func scan(_ text: String, known: Set<Int>) -> Scan {
        let lines = text.components(separatedBy: "\n")
        var pieces: [String] = []
        var refs = Set<Int>()
        var markers: [[Int]] = []
        var run: [String] = []
        func flush() {
            guard !run.isEmpty else { return }
            let result = scanInline(run.joined(separator: "\n"), known: known)
            pieces.append(result.text)
            refs.formUnion(result.refs)
            markers += result.markers
            run = []
        }
        var index = 0
        while index < lines.count {
            if let fence = fenceOpening(lines[index], maxIndent: Int.max) {
                flush()
                let end = fenceEnd(lines, from: index, fence: fence)
                pieces.append(lines[index...end].joined(separator: "\n"))
                index = end + 1
            } else {
                run.append(lines[index])
                index += 1
            }
        }
        flush()
        return Scan(text: pieces.joined(separator: "\n"), refs: refs.sorted(), markers: markers)
    }

    static func markerNumbers(_ inner: String) -> [Int]? {
        let parts = inner.split(separator: ",", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for part in parts {
            let piece = part.trimmingCharacters(in: CharacterSet(charactersIn: " "))
            guard !piece.isEmpty else { return nil }
            if let dash = piece.firstIndex(where: { $0 == "-" || $0 == "\u{2013}" }) {
                let low = piece[..<dash].trimmingCharacters(in: CharacterSet(charactersIn: " "))
                let high = piece[piece.index(after: dash)...].trimmingCharacters(in: CharacterSet(charactersIn: " "))
                guard let a = number(low), let b = number(high), a <= b, b - a < 20 else { return nil }
                numbers += Array(a...b)
            } else {
                guard let value = number(piece) else { return nil }
                numbers.append(value)
            }
        }
        return numbers.isEmpty ? nil : numbers
    }

    private static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 6, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    private static func scanInline(_ text: String, known: Set<Int>) -> Scan {
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var refs = Set<Int>()
        var markers: [[Int]] = []
        var plainCloses = Set<Int>()
        let brackets = bracketPairs(chars)
        var deadTicks = Set<Int>()
        var owed = false
        func restore() {
            if owed { out.append(" ") }
            owed = false
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                restore()
                out.append(c)
                if i + 1 < chars.count { out.append(chars[i + 1]) }
                i += 2
                continue
            }
            if c == "`" {
                restore()
                let run = runLength(chars, at: i)
                if !deadTicks.contains(run), let close = closingBackticks(chars, from: i + run, length: run) {
                    out.append(contentsOf: chars[i..<(close + run)])
                    i = close + run
                } else {
                    deadTicks.insert(run)
                    out.append(contentsOf: chars[i..<(i + run)])
                    i += run
                }
                continue
            }
            if c == "!", i + 1 < chars.count, chars[i + 1] == "[",
               let close = brackets[i + 1],
               close + 1 < chars.count, chars[close + 1] == "(",
               let paren = closingParen(chars, from: close + 1) {
                restore()
                out.append(contentsOf: chars[i...paren])
                i = paren + 1
                continue
            }
            if c == "[", let close = brackets[i] {
                if close + 1 < chars.count, chars[close + 1] == "(", let paren = closingParen(chars, from: close + 1) {
                    restore()
                    out.append(contentsOf: chars[i...paren])
                    i = paren + 1
                    continue
                }
                let inner = String(chars[(i + 1)..<close])
                if inner.hasPrefix("^") {
                    restore()
                    out.append(contentsOf: chars[i...close])
                    i = close + 1
                    continue
                }
                guard let numbers = markerNumbers(inner) else {
                    plainCloses.insert(close)
                    restore()
                    out.append(c)
                    i += 1
                    continue
                }
                let definition = close + 1 < chars.count && chars[close + 1] == ":" && atLineStart(chars, i)
                let reference = i > 0 && plainCloses.contains(i - 1)
                if definition || reference {
                    restore()
                    out.append(contentsOf: chars[i...close])
                    i = close + 1
                    continue
                }
                markers.append(numbers)
                if numbers.allSatisfy(known.contains) {
                    let before = out.count
                    trimHorizontal(&out)
                    if out.count < before { owed = true }
                    refs.formUnion(numbers)
                } else {
                    restore()
                    out.append(contentsOf: chars[i...close])
                }
                i = close + 1
                continue
            }
            if c.isLetter || c.isNumber { restore() } else { owed = false }
            out.append(c)
            i += 1
        }
        return Scan(text: String(out), refs: refs.sorted(), markers: markers)
    }

    private static func runLength(_ chars: [Character], at index: Int) -> Int {
        var end = index
        while end < chars.count, chars[end] == chars[index] { end += 1 }
        return end - index
    }

    private static func closingBackticks(_ chars: [Character], from start: Int, length: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "`" {
                let run = runLength(chars, at: i)
                if run == length { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    private static func bracketPairs(_ chars: [Character]) -> [Int: Int] {
        var pairs: [Int: Int] = [:]
        var open: [Int] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                i += 2
                continue
            }
            if c == "[" {
                open.append(i)
            } else if c == "]", let start = open.popLast() {
                if i - start <= spanLimit { pairs[start] = i }
            } else if c.isNewline, i + 1 < chars.count, chars[i + 1].isNewline {
                open.removeAll(keepingCapacity: true)
            }
            i += 1
        }
        return pairs
    }

    private static func closingParen(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var i = start
        let limit = min(chars.count, start + spanLimit)
        while i < limit {
            let c = chars[i]
            if c == "\\" {
                i += 2
                continue
            }
            if c == "(" { depth += 1 }
            if c == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            if c.isNewline { return nil }
            i += 1
        }
        return nil
    }

    private static func atLineStart(_ chars: [Character], _ index: Int) -> Bool {
        var i = index - 1
        var spaces = 0
        while i >= 0, !chars[i].isNewline {
            guard chars[i] == " " else { return false }
            spaces += 1
            i -= 1
        }
        return spaces <= 3
    }

    private static func trimHorizontal(_ out: inout [Character]) {
        var keep = out.count
        while keep > 0, out[keep - 1] == " " || out[keep - 1] == "\t" { keep -= 1 }
        guard keep < out.count, keep > 0, !out[keep - 1].isNewline else { return }
        out.removeSubrange(keep..<out.count)
    }

    private static func segments(_ text: String) -> [Segment] {
        let lines = text.components(separatedBy: "\n")
        var result: [Segment] = []
        var current: [String] = []
        var listOpen = false
        func flush() {
            if !current.isEmpty { result.append(Segment(lines: current, isCode: false)) }
            current = []
            listOpen = false
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let fence = fenceOpening(line, maxIndent: Int.max), fence.quoted || (listOpen && indentation(line) > 0) {
                let end = fenceEnd(lines, from: index, fence: fence)
                current.append(contentsOf: lines[index...end])
                index = end + 1
                continue
            }
            if let fence = fenceOpening(line, maxIndent: 3) {
                flush()
                let end = fenceEnd(lines, from: index, fence: fence)
                result.append(Segment(lines: Array(lines[index...end]), isCode: true))
                index = end + 1
                continue
            }
            if isBlank(line) {
                if listOpen, let next = nextNonBlank(lines, after: index), continuesList(lines[next]) {
                    current.append(contentsOf: lines[index..<next])
                    index = next
                    continue
                }
                flush()
                index += 1
                continue
            }
            if isListItem(line) { listOpen = true }
            current.append(line)
            index += 1
        }
        flush()
        return result
    }

    private static func continuesList(_ line: String) -> Bool {
        isListItem(line) || indentation(line) >= 2
    }

    private static func indentation(_ line: String) -> Int {
        var width = 0
        for c in line {
            if c == " " { width += 1 } else if c == "\t" { width += 4 } else { break }
        }
        return width
    }

    static func isListItem(_ line: String) -> Bool {
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard let first = body.first else { return false }
        if first == "-" || first == "*" || first == "+" {
            let next = body.dropFirst().first
            return next == nil || next == " " || next == "\t"
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return false }
        let after = body.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")" else { return false }
        let next = after.dropFirst().first
        return next == nil || next == " " || next == "\t"
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func nextNonBlank(_ lines: [String], after index: Int) -> Int? {
        var i = index + 1
        while i < lines.count {
            if !isBlank(lines[i]) { return i }
            i += 1
        }
        return nil
    }

    private static func fenceOpening(_ line: String, maxIndent: Int) -> Fence? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let unquoted = withoutQuoteMarks(line)
        let quoted = unquoted.count < line.count - indent.count
        guard quoted || indent.count <= maxIndent else { return nil }
        let rest = quoted ? unquoted : line.dropFirst(indent.count)
        guard let mark = rest.first, mark == "`" || mark == "~" else { return nil }
        let length = rest.prefix { $0 == mark }.count
        guard length >= 3 else { return nil }
        if mark == "`", rest.dropFirst(length).contains("`") { return nil }
        return Fence(mark: mark, length: length, quoted: quoted)
    }

    private static func withoutQuoteMarks(_ line: String) -> Substring {
        var rest = line.drop { $0 == " " || $0 == "\t" }
        while rest.first == ">" {
            rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
        }
        return rest
    }

    private static func hasWrittenList(_ lines: [String]) -> Bool {
        headingIndices(lines).contains { heading in
            guard let next = nextNonBlank(lines, after: heading) else { return false }
            return entryPrefix(lines[next]) != nil || bulletRest(lines[next]) != nil
        }
    }

    private static func fenceCloses(_ line: String, _ fence: Fence) -> Bool {
        let body = (fence.quoted ? String(withoutQuoteMarks(line)) : line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = body.first, first == fence.mark else { return false }
        return body.allSatisfy { $0 == fence.mark } && body.count >= fence.length
    }

    private static func fenceEnd(_ lines: [String], from start: Int, fence: Fence) -> Int {
        var i = start + 1
        while i < lines.count {
            if fenceCloses(lines[i], fence) { return i }
            if fence.quoted, lines[i].drop(while: { $0 == " " || $0 == "\t" }).first != ">" { return i - 1 }
            i += 1
        }
        return lines.count - 1
    }

    private static func headingIndices(_ lines: [String]) -> [Int] {
        var found: [Int] = []
        var index = 0
        while index < lines.count {
            if let fence = fenceOpening(lines[index], maxIndent: Int.max) {
                index = fenceEnd(lines, from: index, fence: fence) + 1
                continue
            }
            if isBibliographyHeading(lines[index]) { found.append(index) }
            index += 1
        }
        return found
    }

    static func isBibliographyHeading(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("#") {
            let hashes = text.prefix { $0 == "#" }.count
            guard hashes <= 4 else { return false }
            let rest = text.dropFirst(hashes)
            guard let gap = rest.first, gap == " " || gap == "\t" else { return false }
            return isHeadingWord(String(rest), colon: true)
        }
        if text.hasPrefix("**") {
            if text.hasSuffix("**:"), text.count >= 5 {
                return isHeadingWord(String(text.dropFirst(2).dropLast(3)), colon: false, spaced: false)
            }
            if text.hasSuffix("**"), text.count >= 4 {
                return isHeadingWord(String(text.dropFirst(2).dropLast(2)), colon: true, spaced: false)
            }
            return false
        }
        return isHeadingWord(text, colon: true)
    }

    private static func isHeadingWord(_ text: String, colon: Bool, spaced: Bool = true) -> Bool {
        var word = spaced ? text.trimmingCharacters(in: .whitespaces) : text
        if colon, word.hasSuffix(":") {
            word = String(word.dropLast())
            if spaced { word = word.trimmingCharacters(in: .whitespaces) }
        }
        return word == "sources" || word == "references"
    }

    private static func entryPrefix(_ line: String) -> (number: Int, rest: String)? {
        var body = Substring(line.trimmingCharacters(in: .whitespacesAndNewlines))
        if body.hasPrefix("- ") || body.hasPrefix("* ") {
            body = body.dropFirst(2).drop { $0 == " " || $0 == "\t" }
        }
        if body.hasPrefix("[") {
            guard let close = body.firstIndex(of: "]"),
                  let value = number(String(body[body.index(after: body.startIndex)..<close])) else { return nil }
            return (value, String(body[body.index(after: close)...]))
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard let value = number(String(digits)) else { return nil }
        let after = body.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")" else { return nil }
        let rest = after.dropFirst()
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return (value, String(rest))
    }

    private static func bulletRest(_ line: String) -> String? {
        let body = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") else { return nil }
        return String(body.dropFirst(2))
    }

    private static func httpCount(_ text: String) -> Int {
        httpPattern?.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? 0
    }

    private static func entryLink(_ rest: String) -> (url: String, title: String)? {
        let ns = rest as NSString
        let links = linkPattern?.matches(in: rest, range: NSRange(location: 0, length: ns.length)) ?? []
        if links.count > 1 { return nil }
        if let link = links.first {
            let label = ns.substring(with: link.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let url = ns.substring(with: link.range(at: 2))
            let remainder = ns.replacingCharacters(in: link.range, with: " ")
            guard httpCount(url) == 1, url.lowercased().hasPrefix("http"), httpCount(remainder) == 0 else { return nil }
            if httpCount(label) > 0 {
                guard normalized(label) == normalized(url) else { return nil }
                return (url, "")
            }
            return (url, label)
        }
        guard httpCount(rest) == 1,
              let start = rest.range(of: "https?://", options: [.regularExpression, .caseInsensitive])?.lowerBound else { return nil }
        let end = rest[start...].firstIndex { $0 == " " || $0 == "\t" } ?? rest.endIndex
        var token = String(rest[start..<end])
        if let close = token.firstIndex(of: ">") { token = String(token[..<close]) }
        let trailing = CharacterSet(charactersIn: ".,;:!?")
        token = token.trimmingTrailing(trailing)
        while token.hasSuffix(")"), token.filter({ $0 == ")" }).count > token.filter({ $0 == "(" }).count {
            token = String(token.dropLast()).trimmingTrailing(trailing)
        }
        let title = (String(rest[..<start]) + " " + String(rest[end...])).trimmingCharacters(in: separators)
        return (token, title)
    }

    private static func entry(_ rest: String, matches source: PulseSource) -> Bool {
        if httpCount(rest) > 0 {
            guard let link = entryLink(rest) else { return false }
            return normalized(link.url) == normalized(source.url)
        }
        let label = rest.trimmingCharacters(in: separators).lowercased()
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !label.isEmpty, !title.isEmpty else { return false }
        return label == title || label.contains(title) || title.contains(label)
    }

    private static func normalized(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    private static func trailingTrimmed(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous].isWhitespace else { break }
            end = previous
        }
        return String(text[..<end])
    }
}

private extension String {
    func trimmingTrailing(_ set: CharacterSet) -> String {
        var scalars = Substring(self)
        while let last = scalars.unicodeScalars.last, set.contains(last) { scalars = scalars.dropLast() }
        return String(scalars)
    }
}
