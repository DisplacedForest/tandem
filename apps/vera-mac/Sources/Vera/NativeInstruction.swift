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

    static func stripped(_ text: String, of values: [String]) -> String {
        var remainder = text
        for value in values.map({ $0.lowercased() }).filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            remainder = remainder.replacingOccurrences(of: value, with: " ")
        }
        return remainder
    }

    static func asks(_ text: String, verbs: [String], values: [String]) -> Bool {
        let wanted = verbs.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return false }
        let lowered = NativeRequestPreapproval.normalized(text)
        guard NativeRequestPreapproval.settled(stripped(lowered, of: values), original: lowered) else { return false }
        return sentences(lowered).contains { opens($0, with: wanted) }
    }

    static func signature(action: NativeActionClass, toolID: String?, targets: [NativeRuleTarget], names: [String]) -> String {
        ([action.rawValue, toolID ?? ""] + targets.map { $0.kind.rawValue + "=" + $0.value }.sorted() + names.map { $0.lowercased() }.sorted())
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
        guard targets.allSatisfy({ typed.names($0, inCurrentOnly: true) }),
              asked.names.allSatisfy({ NativeTypedWords.holds(typed.current, $0, strict: true) }) else { return nil }
        guard NativeInstruction.asks(typed.current, verbs: asked.verbs, values: targets.map(\.value) + asked.names) else { return nil }
        let signature = NativeInstruction.signature(action: query.action, toolID: query.toolID, targets: targets, names: asked.names)
        if uses?.used(signature) == true { return nil }
        return signature
    }
}
