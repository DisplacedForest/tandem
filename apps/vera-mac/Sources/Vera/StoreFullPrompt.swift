import Foundation

struct NativePromptPreview: Equatable, Sendable {
    let parts: [NativeSystemPromptPart]
    let sentInput: NativeAssembledContext
    let companionInstruction: String

    var text: String { NativeSystemPrompt.joined(parts) }
}

extension ChatStore {
    func fullPromptPreview(companion: Bool, now: Date = Date(), timeZone: TimeZone = .current) -> NativePromptPreview {
        let conversationID = companion ? (veraThreadID ?? UUID().uuidString) : UUID().uuidString
        let scopes = resolvePromptScopes(conversationID: conversationID)
        let turn = NativeConversationTurn(id: UUID(), conversationID: conversationID,
            userMessageID: UUID(), assistantMessageID: UUID(), mode: .chat,
            profile: currentTurnProfile, enabledToolIDs: turnConsentedToolIDs(conversationID: conversationID, mentions: []),
            persona: scopes.persona, userScope: scopes.userScope, instructions: scopes.instructions, projectName: scopes.projectName,
            grounding: [], memorySettings: nativeMemorySettings, createdAt: now, history: [])
        let capabilityProfile = activeCapabilityResolution?.profile ?? .textOnly
        let built = turnToolRegistry(for: turn, typed: .none, grantsAvailable: true, includeTasks: true, prepareTasks: false)
        turnInstructionUseSources[turn.id] = nil
        let registry = built.registry
        let enabledToolIDs = baseTurnEnabledToolIDs(for: turn, supportsTools: capabilityProfile.supportsTools,
                                                    grantsAvailable: true, profileTool: built.profileTool != nil)
        let activeTools = registry.active(enabledIDs: enabledToolIDs)
        var contracts = NativePresentationContract.chatDefaults
        if activeTools.contains(where: { NativeWebTools.researchCapableIDs.contains($0.id) }) { contracts.insert(.citations) }
        let assembled = NativeContextAssembler.assemble(NativeContextInput(
            persona: scopes.persona, userScope: scopes.userScope, preferences: activePreferenceStatements(),
            conversationInstructions: scopes.instructions, projectName: scopes.projectName,
            timestamp: now, timeZone: timeZone,
            ownerName: promptOwnerName, assistantName: companion ? companionName : nil, companionThread: companion,
            capabilities: capabilityProfile, tools: activeTools, contracts: contracts,
            unavailableNotes: (NativeImageTools.resolvedBase() == nil ? [NativeImageTools.unavailableNote] : [])
                + (NativeWebSearch.resolvedBase() == nil ? [NativeWebSearch.unavailableNote] : [])
                + systemAccessNotes(registry, enabledIDs: enabledToolIDs),
            assistantProfile: dotContext(for: conversationID, requestText: "")))
        let companionInstruction = companionProfileInstruction(conversationID: conversationID)
        let parts = NativeSystemPrompt.parts(assembled: assembled, companionInstruction: companionInstruction)
        return NativePromptPreview(parts: Self.previewParts(parts), sentInput: assembled, companionInstruction: companionInstruction)
    }

    static func previewParts(_ parts: [NativeSystemPromptPart]) -> [NativeSystemPromptPart] {
        var shown = parts
        func insert(_ part: NativeSystemPromptPart, after names: [String]) {
            guard !shown.contains(where: { $0.name == part.name }) else { return }
            let anchor = shown.lastIndex { names.contains($0.name) }
            shown.insert(part, at: anchor.map { $0 + 1 } ?? min(1, shown.count))
        }
        insert(NativeSystemPromptPart(name: "user", lead: "", text: "Nothing saved yet.", sent: false), after: ["policy", "persona"])
        insert(NativeSystemPromptPart(name: "preferences", lead: "", text: "Nothing saved yet.", sent: false), after: ["policy", "persona", "user"])
        if !shown.contains(where: { ["memory", "knowledge"].contains($0.name) }) {
            insert(NativeSystemPromptPart(name: NativeSystemPrompt.memoryPlaceholderName, lead: "", text: NativeSystemPrompt.memoryPlaceholder, sent: false),
                   after: ["policy", "persona", "user", "preferences", "project", "conversation", "assistant", "session"])
        }
        return shown
    }
}
