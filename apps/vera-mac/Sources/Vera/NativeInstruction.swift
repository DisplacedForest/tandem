import Foundation

struct NativeInstructionClaim: Hashable, Sendable {}

final class NativeInstructionUses: @unchecked Sendable {
    private let lock = NSLock()
    private var spent: Set<String> = []
    let store: NativeInstructionUseStore?
    let messageID: UUID?
    let conversationID: String?
    let holder: String?

    init(messageID: UUID? = nil, conversationID: String? = nil) {
        store = nil
        self.messageID = messageID
        self.conversationID = conversationID
        holder = nil
    }

    init(store: NativeInstructionUseStore, messageID: UUID, conversationID: String, holder: String?) {
        self.store = store
        self.messageID = messageID
        self.conversationID = conversationID
        self.holder = holder
    }

    func used(_ signature: String) -> Bool {
        let inMemory = lock.withLock { spent.contains(signature) }
        if inMemory { return true }
        guard let store, let messageID else { return false }
        return store.used(messageID, signature: signature, excluding: NativeToolCallContext.instructionHolder ?? holder)
    }

    @discardableResult
    func take(_ signature: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return spent.insert(signature).inserted
    }

    func refuse(_ signature: String) {
        take(signature)
        guard let store, let messageID, let conversationID else { return }
        _ = store.refuse(messageID, conversationID: conversationID, signature: signature)
    }
}

enum NativeInstruction {
    static func canonical(_ command: String) -> String {
        command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func signature(action: NativeActionClass, toolID: String?, targets: [NativeRuleTarget], names: [String]) -> String {
        ([action.rawValue, toolID ?? ""] + targets.map { $0.kind.rawValue + "=" + ($0.kind == .commandPrefix ? canonical($0.value) : $0.value) }.sorted()
            + names.map { $0.lowercased() }.sorted())
            .joined(separator: "\u{1F}")
    }
}

extension NativeRuleResolver {
    func instructed(_ query: NativeRuleQuery, honoringLimitedUse: Bool) -> String? {
        guard asked != nil, !failed, !global.holds(query.action) else { return nil }
        let targets = query.targets
        guard !targets.isEmpty else { return nil }
        for part in query.parts {
            if let winner = NativeRuleMatcher.resolve(records, query: part, context: context, at: now, honoringLimitedUse: honoringLimitedUse)?.decidedBy,
               winner.effect.restricts { return nil }
        }
        guard !NativeRuleMatcher.restrictsUntargeted(records, query: query, context: context, at: now) else { return nil }
        guard !typed.said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard unnamed(in: query, honoringLimitedUse: honoringLimitedUse) == nil else { return nil }
        let message = NativeTypedWords(current: typed.said, earlier: [])
        guard targets.filter({ $0.kind == .commandPrefix }).allSatisfy({ message.names($0, inCurrentOnly: true) }) else { return nil }
        let signature = NativeInstruction.signature(action: query.action, toolID: query.toolID, targets: targets, names: [])
        if uses?.used(signature) == true { return nil }
        return signature
    }
}
