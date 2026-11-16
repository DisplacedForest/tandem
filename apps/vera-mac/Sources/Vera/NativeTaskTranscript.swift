import Foundation

enum NativeTaskTranscript {
    static func visibleActivities(in message: Message) -> [NativeToolActivity] {
        let runs = message.displayBlocks.compactMap { block -> String? in
            if case .commandRun(let run) = block { return run.id }
            return nil
        }
        return message.toolActivities.filter { activity in
            !(activity.toolID == NativeTaskTools.toolID && activity.state == .succeeded) && activity.toolID != CompanionTalkTools.toolID
                && !shownAsCommandRun(activity, runs: runs)
        }
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
