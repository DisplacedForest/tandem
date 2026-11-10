import Foundation

@MainActor
enum NativeDotShotFixture {
    static let name = "Ada"
    static let goal = "Keep the greenhouse on track this season: watering, vent checks and a short weekly note on what changed."

    static func populate(_ store: ChatStore, paused: Bool, setupCompleted: Bool) {
        CompanionNameShot.apply(to: store)
        store.ensureVeraThread()
        guard let id = store.veraThreadID, let index = store.conversations.firstIndex(where: { $0.id == id }) else { return }
        store.conversations[index].messages = [
            Message(role: .user, text: "What changed in the greenhouse this week?"),
            Message(role: .assistant, text: "Three things stood out:\n\n- The afternoon vent check is now part of the plan.\n- Humidity is logged alongside temperature.\n- The tomato bed needed water twice on the hottest day.\n\nI'll keep the weekly note going every Friday."),
            Message(role: .user, text: "Remind me what's left before the frost."),
            Message(role: .assistant, text: "Move the seedlings in, cover the raised beds and drain the outdoor line. The first two can happen this weekend."),
        ]
        store.tightenConversationRule(.handOff, for: .commands, conversationID: id)
        store.tightenConversationRule(.ask, for: .fileEdits, conversationID: id)
        store.dotProfile = NativeDotProfile(goal: setupCompleted ? goal : "", state: paused ? .paused : .active, setupCompleted: setupCompleted)
        store.openVeraThread()
    }

    static var options: [NativeDotServiceOption] {
        let catalog = NativeChatToolCatalog.tools(veraAPIConfigured: false, imageConfigured: true, searchConfigured: true)
            .filter(\.available)
            .prefix(3)
            .map { NativeDotServiceOption(id: $0.id, name: $0.name, detail: $0.summary, toolIDs: [$0.id]) }
        return catalog + [NativeDotServiceOption(id: "service:garden", name: "Garden sensors", detail: "4 tools from this service",
                                                 toolIDs: ["garden-a", "garden-b", "garden-c", "garden-d"])]
    }

    static var selected: Set<String> {
        Set(options.dropFirst().map(\.id))
    }
}
