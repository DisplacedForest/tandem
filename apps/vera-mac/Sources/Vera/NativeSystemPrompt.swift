import Foundation

struct NativeSystemPromptPart: Equatable, Sendable, Identifiable {
    enum Destination: Equatable, Sendable {
        case persona
        case userContext
        case preferences
    }

    let name: String
    let lead: String
    let text: String
    var sent = true

    var id: String { name }

    var title: String {
        if name.hasPrefix("format:") { return "Formatting" }
        switch name {
        case "policy": return "App rules"
        case "persona": return "Persona"
        case "user": return "User context"
        case "preferences": return "Preferences"
        case "project": return "Project"
        case "conversation": return "Conversation instructions"
        case "assistant": return "Standing role"
        case "session": return "Session"
        case "memory", "knowledge", NativeSystemPrompt.memoryPlaceholderName: return "Memories and library"
        case "world": return "What it knows"
        case "tools": return "Tools"
        case "unavailable": return "Not available right now"
        case "companion": return "Companion instructions"
        case "talk": return "Talking"
        case "grant": return "Folder access"
        case "revision": return "Revising"
        case "preferenceNote": return "Preference note"
        case "reply": return "Reply instructions"
        case "companionEvent": return "Companion event"
        default: return name.capitalized
        }
    }

    var destination: Destination? {
        switch name {
        case "persona": return .persona
        case "user": return .userContext
        case "preferences": return .preferences
        default: return nil
        }
    }
}

enum NativeSystemPrompt {
    static let memoryPlaceholderName = "memoryPlaceholder"
    static let memoryPlaceholder = "Saved memories and library material are added here when they're relevant to the message."
    static let ordinaryOtherWorkRule = "Other accepted turns may still be working; this message does not cancel or change them."

    static func otherWorkRule(talking: Bool) -> String {
        talking ? CompanionTalkCopy.otherWork : ordinaryOtherWorkRule
    }

    static func replyInstructions(otherWorkRule: String) -> String {
        "Answer the user's question directly and concisely. Use at most two web lookups for current facts, then answer from the evidence or explain what remains uncertain. Only the final user message is the current request. Earlier requests are context, not permission to run their tools again. Respect the current request's tool restrictions. " + ChatStore.researchReplyRule + " Do not add progress commentary about other turns to an unrelated answer. " + otherWorkRule
    }

    static func parts(
        assembled: NativeAssembledContext,
        companionInstruction: String,
        talkSection: String? = nil,
        grantNote: String? = nil,
        revisionNote: String? = nil,
        preferenceNote: String? = nil,
        otherWorkRule: String = ordinaryOtherWorkRule,
        companionEventInstruction: String? = nil
    ) -> [NativeSystemPromptPart] {
        var parts = assembled.sections.enumerated().map { index, section in
            NativeSystemPromptPart(name: section.name, lead: index == 0 ? "" : "\n\n", text: section.content)
        }
        parts.append(NativeSystemPromptPart(name: "companion", lead: "\n\n", text: companionInstruction))
        let notes: [(String, String?)] = [("talk", talkSection), ("grant", grantNote), ("revision", revisionNote), ("preferenceNote", preferenceNote)]
        for (name, note) in notes {
            if let note { parts.append(NativeSystemPromptPart(name: name, lead: "\n\n", text: note)) }
        }
        parts.append(NativeSystemPromptPart(name: "reply", lead: "\n\n", text: replyInstructions(otherWorkRule: otherWorkRule)))
        if let companionEventInstruction {
            parts.append(NativeSystemPromptPart(name: "companionEvent", lead: "\n\n", text: companionEventInstruction))
        }
        return parts
    }

    static func joined(_ parts: [NativeSystemPromptPart]) -> String {
        parts.filter(\.sent).map { $0.lead + $0.text }.joined()
    }

    static func compose(
        assembled: NativeAssembledContext,
        companionInstruction: String,
        talkSection: String? = nil,
        grantNote: String? = nil,
        revisionNote: String? = nil,
        preferenceNote: String? = nil,
        otherWorkRule: String = ordinaryOtherWorkRule,
        companionEventInstruction: String? = nil
    ) -> String {
        joined(parts(assembled: assembled, companionInstruction: companionInstruction, talkSection: talkSection,
                     grantNote: grantNote, revisionNote: revisionNote, preferenceNote: preferenceNote,
                     otherWorkRule: otherWorkRule, companionEventInstruction: companionEventInstruction))
    }
}
