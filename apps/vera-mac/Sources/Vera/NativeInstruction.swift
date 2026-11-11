import Foundation

struct NativeInstructionClaim: Hashable, Sendable {
    var verbs: [String]
    var names: [String] = []
    var nothing = false
}

final class NativeInstructionUses: @unchecked Sendable {
    private let lock = NSLock()
    private var spent: Set<String> = []

    func used(_ signature: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return spent.contains(signature)
    }

    @discardableResult
    func take(_ signature: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return spent.insert(signature).inserted
    }
}

enum NativeInstruction {
    static let terminators: Set<Character> = [".", "!", ";"]

    static func sentences(_ text: String) -> [String] {
        var found: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let last = index + 1 == characters.count
            let closes = character.isNewline || (terminators.contains(character) && (last || characters[index + 1].isWhitespace))
            if closes {
                found.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        found.append(current)
        return found.map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ","))) }.filter { !$0.isEmpty }
    }

    static func rest(_ sentence: String, after verbs: [String]) -> String? {
        let lowered = sentence.lowercased()
        guard lowered.count == sentence.count else { return nil }
        var offset = 0
        while true {
            let current = String(lowered.dropFirst(offset))
            if let verb = verbs.first(where: { current == $0 || current.hasPrefix($0 + " ") }) {
                return String(sentence.dropFirst(offset + verb.count)).trimmingCharacters(in: .whitespaces)
            }
            guard let opener = NativeRequestPreapproval.openers.first(where: { current.hasPrefix($0 + " ") || current.hasPrefix($0 + ",") }) else { return nil }
            var next = offset + opener.count
            let characters = Array(lowered)
            while next < characters.count, characters[next].isWhitespace || characters[next] == "," { next += 1 }
            offset = next
        }
    }

    static func opens(_ sentence: String, with verbs: [String]) -> Bool {
        rest(sentence, after: verbs) != nil
    }

    static func spans(_ target: NativeRuleTarget, in sentence: String) -> [Range<String.Index>] {
        switch target.kind {
        case .recipient, .service:
            return NativeTypedWords.spans(sentence, target.value, strict: true)
        case .folder:
            let whole = NativeTypedWords.spans(sentence, target.value, strict: true, exact: true)
            if !whole.isEmpty { return whole }
            let name = URL(fileURLWithPath: target.value).lastPathComponent
            return name.isEmpty || name == "/" ? [] : NativeTypedWords.spans(sentence, name, strict: true, exact: true)
        case .commandPrefix:
            return []
        }
    }

    static func canonical(_ command: String) -> String {
        command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func unmarked(_ text: String) -> String? {
        let characters = Array(text)
        let marks = characters.indices.filter { characters[$0] == "`" }
        if marks.isEmpty { return text }
        guard marks.count == 2, marks[1] - marks[0] > 1 else { return nil }
        let open = marks[0], close = marks[1]
        guard open == 0 || characters[open - 1].isWhitespace else { return nil }
        guard !characters[open + 1].isWhitespace, !characters[close - 1].isWhitespace, !".,;:!?".contains(characters[close - 1]) else { return nil }
        let after = String(characters[(close + 1)...])
        guard after.isEmpty || after.first?.isWhitespace == true || after == "." || after.hasPrefix(". ") else { return nil }
        return String(characters[..<open]) + String(characters[(open + 1)..<close]) + after
    }

    static func marked(_ text: String) -> String? {
        let characters = Array(text)
        let marks = characters.indices.filter { characters[$0] == "`" }
        guard marks.count == 2, marks[1] - marks[0] > 1 else { return nil }
        return String(characters[(marks[0] + 1)..<marks[1]])
    }

    static func command(_ tail: String) -> String? {
        let characters = Array(tail)
        let marks = characters.indices.filter { characters[$0] == "`" }
        if marks.isEmpty {
            var plain = tail.trimmingCharacters(in: .whitespaces)
            if plain.hasSuffix(".") { plain = String(plain.dropLast()) }
            let made = canonical(plain)
            return made.isEmpty ? nil : made
        }
        guard marks.count == 2, marks[0] == 0, marks[1] > 1 else { return nil }
        let after = String(characters[(marks[1] + 1)...]).trimmingCharacters(in: .whitespaces)
        guard after.isEmpty || after == "." else { return nil }
        let inner = String(characters[1..<marks[1]])
        guard inner == inner.trimmingCharacters(in: .whitespaces) else { return nil }
        let made = canonical(inner)
        return made.isEmpty ? nil : made
    }

    static func asks(_ raw: String, verbs: [String], targets: [NativeRuleTarget], names: [String]) -> Bool {
        let wanted = verbs.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return false }
        let folded = raw.replacingOccurrences(of: "\u{2019}", with: "'")
        let commands = targets.filter { $0.kind == .commandPrefix }
        if !commands.isEmpty {
            guard commands.count == 1, targets.count == 1, names.isEmpty, !folded.contains(where: \.isNewline),
                  let tail = rest(folded.trimmingCharacters(in: .whitespaces), after: wanted), let typed = command(tail) else { return false }
            return typed == canonical(commands[0].value) && NativeRequestPreapproval.settled("", original: NativeRequestPreapproval.normalized(folded))
        }
        guard let plain = unmarked(folded), targets.filter({ $0.kind == .folder }).count <= 1 else { return false }
        if let inner = marked(folded) {
            if inner.contains(where: \.isWhitespace), targets.count + names.count != 1 { return false }
            let whole = targets.contains { target in
                switch target.kind {
                case .folder: return inner == target.value || inner == URL(fileURLWithPath: target.value).lastPathComponent
                case .recipient, .service: return inner.lowercased() == target.value
                case .commandPrefix: return false
                }
            } || names.contains { inner.lowercased() == $0.lowercased() }
            guard whole else { return false }
        }
        let message = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.contains(where: \.isNewline), sentences(message).count == 1, let tail = rest(message, after: wanted) else { return false }
        var cuts: [Range<String.Index>] = []
        for target in targets {
            let found = spans(target, in: message).filter { span in !cuts.contains { $0.overlaps(span) } }
            if found.isEmpty { return false }
            cuts += found
        }
        for name in names {
            let found = NativeTypedWords.spans(message, name, strict: true).filter { span in !cuts.contains { $0.overlaps(span) } }
            if found.isEmpty { return false }
            cuts += found
        }
        var remainder = Array(message)
        for cut in cuts {
            let lower = message.distance(from: message.startIndex, to: cut.lowerBound)
            let upper = message.distance(from: message.startIndex, to: cut.upperBound)
            for index in lower..<upper { remainder[index] = " " }
        }
        guard alone(Array(remainder.suffix(tail.count))) else { return false }
        return NativeRequestPreapproval.settled(String(remainder).lowercased(), original: NativeRequestPreapproval.normalized(message))
    }

    static func alone(_ remainder: [Character]) -> Bool {
        var body = remainder
        while let last = body.last, last.isWhitespace || ".!".contains(last) { body.removeLast() }
        if body.contains(where: { ",:;@/\\~".contains($0) }) { return false }
        let text = String(body)
        if text.contains("--") || text.contains(" - ") || text.contains("\u{2013}") || text.contains("\u{2014}") { return false }
        for index in body.indices where body[index] == "." {
            let before = index > 0 && (body[index - 1].isLetter || body[index - 1].isNumber)
            let after = index + 1 < body.count && (body[index + 1].isLetter || body[index + 1].isNumber)
            if before && after { return false }
        }
        return true
    }

    static func signature(action: NativeActionClass, toolID: String?, targets: [NativeRuleTarget], names: [String]) -> String {
        ([action.rawValue, toolID ?? ""] + targets.map { $0.kind.rawValue + "=" + ($0.kind == .commandPrefix ? canonical($0.value) : $0.value) }.sorted()
            + names.map { $0.lowercased() }.sorted())
            .joined(separator: "\u{1F}")
    }
}

extension NativeRuleResolver {
    func instructed(_ query: NativeRuleQuery, honoringLimitedUse: Bool) -> String? {
        guard let asked, !asked.verbs.isEmpty, !failed, !global.holds(query.action) else { return nil }
        let targets = query.targets
        guard !targets.isEmpty || !asked.names.isEmpty || asked.nothing else { return nil }
        for part in query.parts {
            if let winner = NativeRuleMatcher.resolve(records, query: part, context: context, at: now, honoringLimitedUse: honoringLimitedUse)?.decidedBy,
               winner.effect.restricts { return nil }
        }
        guard !NativeRuleMatcher.restrictsUntargeted(records, query: query, context: context, at: now) else { return nil }
        guard !typed.said.isEmpty, NativeTypedWords.own(typed.said) == typed.said.replacingOccurrences(of: "\u{2019}", with: "'") else { return nil }
        guard NativeInstruction.asks(typed.current, verbs: asked.verbs, targets: targets, names: asked.names) else { return nil }
        let signature = NativeInstruction.signature(action: query.action, toolID: query.toolID, targets: targets, names: asked.names)
        if uses?.used(signature) == true { return nil }
        return signature
    }
}
