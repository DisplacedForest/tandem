import Foundation

enum NativeTaskTranscript {
    static func visibleActivities(in message: Message) -> [NativeToolActivity] {
        let saved = Set(message.displayBlocks.compactMap { block -> String? in
            if case .taskCard(let card) = block { return card.id }
            return nil
        })
        return message.toolActivities.filter { activity in
            guard activity.toolID == NativeTaskTools.toolID,
                  let result = activity.result?.data(using: .utf8),
                  let value = try? JSONDecoder().decode([String: NativeJSONValue].self, from: result),
                  case .string(let id) = value["task_reference"] else { return true }
            return !saved.contains(id)
        }
    }
}
