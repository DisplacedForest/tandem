import Foundation

struct NativeResourcePolicy: Equatable, Hashable, Sendable {
    static let defaultContextTokens = 32_000
    static let charactersPerToken = 3
    static let replyShareDivisor = 4
    static let reasoningShareDivisor = 2
    static let wrapperReserveTokens = 192
    static let messageOverheadBytes = 32
    static let shortestSectionCharacters = 400
    static let maximumShrinks = 2
    static let fullSectionCharacters = 3_000
    static let headingCharacters = 200
    static let instructionCharacters = 500
    static let titleCharacters = 120
    static let condenseShrinkPercent = 90
    static let materialShareDivisor = 2
    static let condenseInputMultiple = 4
    static let legacyMaximumSections = 6
    static let legacyMaximumSources = 14
    static let searchResultsPerQuestion = 4
    static let pageCharacters = 2_000
    static let reviewCharacters = 300
    static let urlBytes = 1_024
    static let noteLineCharacters = 100
    static let keptNoteLines = 16
    static let progressSources = 6
    static let wireEncodingMultiple = 2
    static let sectionFrameCharacters = 8
    static let jobBytes = 1_048_576
    static let jobFrameBytes = 16_384
    static let noteQuestionCharacters = 40
    static let shortestPlanCharacters = 50
    static let maximumPlanAttempts = 3
    static let maximumRequestedBullets = 20
    static let legacyPromptBytes = 24_000
    static let legacyOutputTokens = 8_192
    static let legacyReportCharacters = 40_000
    static let legacyResearchReportCharacters = 16_000
    static let legacySourceCharacters = 1_500
    static let companionReportScalars = 40_000
    static let companionNoteScalars = 240
    static let companionStepScalars = 20_000
    static let summaryCharacters = 280
    static let companionCheckpointReserveBytes = 16_384
    static let companionUnknownMessageBytes = 4_096
    static let companionSeparatorBytes = 2
    static let companionMarkerBytes = 64
    static let companionEffects = 64
    static let companionDecisionScalars = 2_000
    static let companionLabelScalars = 120
    static let companionArgumentCharacters = 512
    static let companionCallOverheadBytes = 96
    static let companionToolReserveBytes = 32_768
    static let companionShortestResultBytes = 1_024
    static let companionShortestReportScalars = 1_000
    static let companionClosingReserveBytes = 16_384
    static let companionReplyReserveBytes = 65_536
    static let companionAnswerBytes = 16_384
    static var savedResultBytes: Int { NativeTaskStore.maximumJSONBytes }
    static var savedSnapshotBytes: Int { NativeTaskStore.maximumSnapshotBytes }
    static var requestBytes: Int { NativeTaskStore.maximumJSONBytes - jobFrameBytes }

    static let reasons: [String: String] = [
        "defaultContextTokens": "Used only when neither the endpoint's model list nor the Context length ceiling setting gives a context size.",
        "charactersPerToken": "A cautious count of characters per token, so a prompt sized from tokens still fits.",
        "replyShareDivisor": "With no Max output tokens set, a quarter of the context is left free for the reply.",
        "reasoningShareDivisor": "When reasoning is on, half of the reply room is left for the reasoning.",
        "wrapperReserveTokens": "Room for the JSON wrapper around a section's text.",
        "messageOverheadBytes": "Bytes each message adds on the wire beyond its text.",
        "shortestSectionCharacters": "Asking again shorter never asks for less than this, so a section stays useful.",
        "maximumShrinks": "How many times one step is asked again shorter before the work pauses with Retry.",
        "fullSectionCharacters": "The most one section asks for when the reply room allows more, so long documents use more sections instead of very long ones.",
        "headingCharacters": "A section heading is one short line.",
        "instructionCharacters": "A section's scope note in the plan is a short description, not content.",
        "titleCharacters": "A derived title is one short line.",
        "condenseShrinkPercent": "Each condensing pass must bring the material under this share of its size, or the work pauses instead of looping.",
        "materialShareDivisor": "The brief and inputs may use half of the prompt room, leaving the rest for the plan, the section being written and its draft.",
        "condenseInputMultiple": "One part sent for condensing is at most four times the notes it may return, so the notes can keep everything that matters.",
        "legacyMaximumSections": "Documents started before this policy keep the section count they started with.",
        "legacyMaximumSources": "Research started before this policy keeps the source count it started with.",
        "searchResultsPerQuestion": "How many search results are read for each sub-question. This sets how widely research looks, not how much it can write.",
        "pageCharacters": "How much of one fetched page is kept as a source, so a single long page doesn't crowd out the rest.",
        "reviewCharacters": "The short look over gathered pages before the write-up only reads the start of each source.",
        "urlBytes": "A source address longer than this is not a usable link.",
        "noteLineCharacters": "A troubleshooting note about one step is one short line.",
        "keptNoteLines": "Only the latest troubleshooting notes are kept with the work.",
        "wireEncodingMultiple": "A prompt's text can take up to twice its size once encoded for sending, from escaped quotes and line breaks.",
        "jobBytes": "One model request travels inside the app as a job of at most this many bytes, so prompts stay under it even for models with very large context windows.",
        "jobFrameBytes": "Room in that job for everything around the prompt: ids, digests and the request settings.",
        "sectionFrameCharacters": "The heading marks and blank lines each section adds to a finished document.",
        "progressSources": "A progress update names only the first few new sources, so it stays inside one update's size.",
        "noteQuestionCharacters": "A troubleshooting note quotes only the start of the search it is about.",
        "shortestPlanCharacters": "Asking again for a shorter plan never asks for less than this.",
        "maximumPlanAttempts": "How many times the plan is asked for before the work stops with the reason.",
        "maximumRequestedBullets": "A brief asking for an exact number of bullets is followed exactly up to this many. A larger list is written as a normal document.",
        "legacyPromptBytes": "Documents started before this policy keep the prompt size they started with.",
        "legacyOutputTokens": "Documents started before this policy only sized sections from an output limit up to this many tokens.",
        "legacyReportCharacters": "Documents started before this policy keep the report size they started with.",
        "legacyResearchReportCharacters": "Research started before this policy keeps the report size it started with.",
        "legacySourceCharacters": "Research started before this policy keeps the source size it started with.",
        "companionReportScalars": "The longest report companion work saves, kept well inside the local store's result size.",
        "companionNoteScalars": "A companion's note about one action is one short line.",
        "companionStepScalars": "The longest description of the step companion work stopped on.",
        "companionCheckpointReserveBytes": "Room kept free in companion work's saved progress for the next step's bookkeeping.",
        "companionUnknownMessageBytes": "The size assumed for a message whose encoded size can't be measured, so space is never underestimated.",
        "companionSeparatorBytes": "The separator between messages in the saved transcript.",
        "companionMarkerBytes": "Room for the short marker added where a long result is cut, and for each message's framing.",
        "companionEffects": "Only the latest action notes are kept with companion work.",
        "companionDecisionScalars": "A question put to the person, or the description of a step, is kept short enough to read on a card.",
        "companionLabelScalars": "An answer button's label is one short line.",
        "companionArgumentCharacters": "A detail quoted from a tool call in a question is one short value.",
        "companionCallOverheadBytes": "The framing each tool call adds to the transcript beyond its arguments.",
        "companionToolReserveBytes": "Room kept free in the transcript for the reply that follows a tool result.",
        "companionShortestResultBytes": "A tool result always gets at least this much room, so the model sees enough of it to act.",
        "companionShortestReportScalars": "When a finished report has to be shortened to save, it is never cut below this.",
        "companionClosingReserveBytes": "Room kept free before the final write-up, so it can always be written.",
        "companionReplyReserveBytes": "Room kept free in saved progress for the model's next reply.",
        "companionAnswerBytes": "The most of one tool answer kept when the person's approval is replayed.",
        "summaryCharacters": "Finished work's one-line summary on its card and in the profile.",
        "savedResultBytes": "The app's local store holds one result of at most this many bytes. A larger document fails with both numbers.",
        "requestBytes": "One saved request, with its brief and everything to include, must fit the app's local store with room left for the rest of the request.",
        "savedSnapshotBytes": "The app's local store holds one snapshot of at most this many bytes.",
    ]

    let contextTokens: Int?
    let outputTokens: Int?
    let reasoning: Bool

    init(contextTokens: Int?, outputTokens: Int?, reasoning: Bool) {
        self.contextTokens = contextTokens.flatMap { $0 > 0 ? $0 : nil }
        self.outputTokens = outputTokens.flatMap { $0 > 0 ? $0 : nil }
        self.reasoning = reasoning
    }

    init(_ binding: NativeTaskAdmissionBinding?) {
        self.init(contextTokens: binding?.contextTokens, outputTokens: binding?.outputTokens, reasoning: binding?.reasoning == true)
    }

    var legacy: Bool { contextTokens == nil }

    var context: Int { contextTokens ?? Self.defaultContextTokens }

    var replyTokens: Int {
        if let outputTokens { return min(outputTokens, context / 2) }
        return context / Self.replyShareDivisor
    }

    var promptBytes: Int {
        if legacy { return Self.legacyPromptBytes }
        let fits = max(1, (context - replyTokens) * Self.charactersPerToken)
        return min(fits, Self.jobBytes / Self.wireEncodingMultiple - Self.jobFrameBytes)
    }

    var wireBytes: Int { promptBytes * Self.wireEncodingMultiple }

    var replyCharacters: Int {
        let room = max(0, replyTokens - Self.wrapperReserveTokens) / (reasoning ? Self.reasoningShareDivisor : 1)
        return max(Self.shortestSectionCharacters, room * Self.charactersPerToken)
    }

    var sectionCharacters: Int {
        var tokens = replyTokens
        if legacy {
            guard let saved = outputTokens, saved <= Self.legacyOutputTokens else { return Self.fullSectionCharacters }
            tokens = saved
        }
        let room = max(0, tokens - Self.wrapperReserveTokens) / (reasoning ? Self.reasoningShareDivisor : 1)
        return min(Self.fullSectionCharacters, max(Self.shortestSectionCharacters, room * Self.charactersPerToken))
    }

    var reportCharacters: Int { legacy ? Self.legacyReportCharacters : Self.savedResultBytes }

    var researchReportCharacters: Int { legacy ? Self.legacyResearchReportCharacters : Self.savedResultBytes }

    var sourceCharacters: Int? { legacy ? Self.legacySourceCharacters : nil }

    static func promptSize(_ messages: [NativeTaskGenerationMessage]) -> Int {
        messages.reduce(0) { total, message in
            var content = Substring(message.content)
            if let block = message.content.range(of: "\n\n" + NativePreferencePrompt.header) { content = message.content[..<block.lowerBound] }
            return total + message.role.utf8.count + content.utf8.count + messageOverheadBytes
        }
    }

    static var sectionShare: Int { fullSectionCharacters + headingCharacters + sectionFrameCharacters }

    static var sectionsThatFit: Int { max(1, (savedResultBytes - jobFrameBytes) / sectionShare) }

    static func planTooLarge(needed: Int, room: Int) -> String {
        "This document would need about \(NativeTaskInputSize.grouped(needed)) characters, and Tandem can save up to about \(NativeTaskInputSize.grouped(room)) in one document. Ask for it as two documents."
    }

    static func tooLarge(_ characters: Int, limit: Int, document: Bool) -> String {
        let size = NativeTaskInputSize.grouped(characters)
        let room = NativeTaskInputSize.grouped(limit)
        return document
            ? "The finished document is \(size) characters, and Tandem can save up to about \(room) in one document. Ask for it as two documents."
            : "The finished report is \(size) characters, and Tandem can save up to about \(room) in one report. Ask for a narrower report."
    }
}

@MainActor
final class NativeModelContext {
    static let shared = NativeModelContext()
    private var known: [String: Int] = [:]
    private var asked: Set<String> = []

    static func key(_ base: URL, _ model: String) -> String {
        ((try? NativeTaskEngineIdentity(base))?.base ?? base).absoluteString + "\n" + model
    }

    static func reported(_ profile: NativeTaskProfileBinding?) async -> NativeTaskProfileBinding? {
        guard var profile else { return nil }
        if let tokens = await shared.tokens(base: profile.provider.base, model: profile.executionModel) { profile.contextTokens = tokens }
        return profile
    }

    func tokens(base: URL, model: String) -> Int? { known[Self.key(base, model)] }

    func record(base: URL, contexts: [String: Int]) {
        for (model, tokens) in contexts where tokens > 0 { known[Self.key(base, model)] = tokens }
    }

    func prepare(_ config: NativeChatConfig?, transport: (any NativeChatTransport)?) async {
        guard let config, let client = transport as? NativeChatClient else { return }
        let base = Self.key(config.baseURL, "")
        guard !asked.contains(base) else { return }
        asked.insert(base)
        if let contexts = try? await client.modelContexts() { record(base: config.baseURL, contexts: contexts) }
    }
}
