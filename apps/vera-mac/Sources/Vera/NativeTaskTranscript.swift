import Foundation

enum NativeTaskTranscript {
    static func visibleActivities(in message: Message, companionThread: Bool = false) -> [NativeToolActivity] {
        guard !companionThread else { return [] }
        let runs = message.displayBlocks.compactMap { block -> String? in
            if case .commandRun(let run) = block { return run.id }
            return nil
        }
        return message.toolActivities.filter { activity in
            !(activity.toolID == NativeTaskTools.toolID && activity.state == .succeeded) && activity.toolID != CompanionTalkTools.toolID
                && !shownAsCommandRun(activity, runs: runs)
        }
    }

    static func visibleBlocks(in message: Message, companionThread: Bool) -> [NativeDisplayBlock] {
        guard companionThread else { return message.displayBlocks }
        return message.displayBlocks.filter { block in
            switch block {
            case .commandRun: return false
            case .ruleOffer(let offer): return offer.subject?.service == nil
            default: return true
            }
        }
    }

    static func companionStatus(in message: Message, awaitingDecision: Bool) -> String? {
        guard ToolCallParser.parse(message.text).clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !awaitingDecision, message.state != .interrupted, visibleBlocks(in: message, companionThread: true).isEmpty,
              message.artifacts.isEmpty, message.attachments.isEmpty, message.ask == nil else { return nil }
        if message.toolActivities.contains(where: { $0.state == .pending }) { return "Working on your request." }
        if message.toolActivities.contains(where: { $0.state == .failed }) { return "I couldn't finish that request." }
        for block in message.displayBlocks {
            if case .commandRun(let run) = block {
                if run.outcome == .canceled { return "That request was stopped." }
                if run.outcome != .ran || run.exitCode != 0 { return "I couldn't finish that request." }
            }
        }
        if message.toolActivities.contains(where: { $0.state == .canceled }) { return "That request was stopped." }
        return nil
    }

    static func showsCompanionMessage(_ message: Message, awaitingDecision: Bool) -> Bool {
        message.role != .assistant || awaitingDecision || message.state != .complete
            || !ToolCallParser.parse(message.text).clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || message.ask != nil || !message.artifacts.isEmpty || !message.attachments.isEmpty || !message.sources.isEmpty
            || !visibleBlocks(in: message, companionThread: true).isEmpty
            || companionStatus(in: message, awaitingDecision: awaitingDecision) != nil
    }

    static func shownAsCommandRun(_ activity: NativeToolActivity, runs: [String]) -> Bool {
        guard activity.toolID == NativeCommandTools.toolID, activity.state != .pending else { return false }
        return runs.contains { callID(ofRun: $0) == activity.id }
    }

    static func callID(ofRun id: String) -> String {
        let scope = id.prefix(36)
        guard id.count > 37, UUID(uuidString: String(scope)) != nil, id.dropFirst(36).first == ":" else { return id }
        return String(id.dropFirst(37))
    }
}
