import Foundation

enum NativeCompanionRouting {
    static let foregroundIDs: Set<String> = [NativeTaskTools.toolID, NativeScheduleTools.toolID,
        NativeCompanionProfileTools.toolID, CompanionTalkTools.toolID]

    static let instruction = "Handle the conversation. Hand off every lookup or action, even one step, with relevant facts and confirmed results from this conversation. Never invent a missing previous value. Acknowledge only after work starts, then stay available. Give progress and results plainly without implementation details. Answer directly when no lookup or action is needed."
}
