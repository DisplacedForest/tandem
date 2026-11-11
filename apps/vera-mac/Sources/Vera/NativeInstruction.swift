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

    static func opens(_ sentence: String, with verbs: [String]) -> Bool {
        var rest = sentence
        while true {
            if verbs.contains(where: { rest == $0 || rest.hasPrefix($0 + " ") }) { return true }
            guard let opener = NativeRequestPreapproval.openers.first(where: { rest.hasPrefix($0 + " ") || rest.hasPrefix($0 + ",") }) else { return false }
            rest = String(rest.dropFirst(opener.count)).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
        }
    }

    static func spans(_ target: NativeRuleTarget, in sentence: String) -> [Range<String.Index>] {
        switch target.kind {
        case .recipient, .service:
            return NativeTypedWords.spans(sentence, target.value, strict: true)
        case .folder:
            let whole = NativeTypedWords.spans(sentence, target.value, strict: true)
            if !whole.isEmpty { return whole }
            let name = URL(fileURLWithPath: target.value).lastPathComponent
            return name.isEmpty || name == "/" ? [] : NativeTypedWords.spans(sentence, name, strict: true)
        case .commandPrefix:
            return NativeTypedWords.spans(sentence, canonical(target.value), strict: true)
        }
    }

    static func canonical(_ command: String) -> String {
        command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func spaced(_ text: String) -> String {
        canonical(text.replacingOccurrences(of: "`", with: " "))
    }

    static func asks(_ text: String, verbs: [String], targets: [NativeRuleTarget], names: [String]) -> Bool {
        let wanted = verbs.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return false }
        let lowered = NativeRequestPreapproval.normalized(text)
        let all = sentences(lowered)
        for (position, raw) in all.enumerated() where opens(raw, with: wanted) {
            let sentence = targets.contains(where: { $0.kind == .commandPrefix }) ? spaced(raw) : raw
            var cuts: [Range<String.Index>] = []
            var complete = true
            for target in targets where complete {
                let found = spans(target, in: sentence)
                if found.isEmpty { complete = false }
                cuts += found
            }
            for name in names where complete {
                let found = NativeTypedWords.spans(sentence, name, strict: true)
                if found.isEmpty { complete = false }
                cuts += found
            }
            guard complete else { continue }
            var remainder = Array(sentence)
            for cut in cuts {
                let lower = sentence.distance(from: sentence.startIndex, to: cut.lowerBound)
                let upper = sentence.distance(from: sentence.startIndex, to: cut.upperBound)
                for index in lower..<upper { remainder[index] = " " }
            }
            let others = all.enumerated().filter { $0.offset != position }.map(\.element).joined(separator: ". ")
            if NativeRequestPreapproval.settled(String(remainder) + ". " + others, original: lowered) { return true }
        }
        return false
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
