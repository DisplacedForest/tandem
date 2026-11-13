import Foundation

enum NativeTaskTranscript {
    static func visibleActivities(in message: Message) -> [NativeToolActivity] {
        message.toolActivities.filter { activity in
            !(activity.toolID == NativeTaskTools.toolID && activity.state == .succeeded) && activity.toolID != CompanionTalkTools.toolID
        }
    }
}
