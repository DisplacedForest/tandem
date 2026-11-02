import Foundation

@MainActor
extension SelfTest {
    static func runSidebarDestinations() throws {
        let require = NativeTaskFixture.require
        let primary = SidebarDestination.primary
        let secondary = SidebarDestination.secondary
        try require(primary == [.chats, .projects, .library, .scheduled, .integrations], "The rail lists Chats, Projects, Library, Scheduled and Integrations in order")
        try require(secondary == [.pulse, .workflows, .activity, .memory], "The More menu lists Pulse, Workflows, Activity and Memory in order")
        try require(Set(primary).isDisjoint(with: secondary), "No destination appears in both the rail and the More menu")
        try require(Set(primary).union(secondary) == Set(SidebarDestination.allCases) && primary.count + secondary.count == SidebarDestination.allCases.count, "Every destination is reachable exactly once")

        let panes: [AgenticPane] = [.canvas, .activity]
        for section in AppSection.allCases {
            for pane in panes {
                try require(SidebarDestination.library.isSelected(section: section, pane: pane) == (section == .artifacts), "Library is selected only for the library section")
                try require(SidebarDestination.chats.isSelected(section: section, pane: pane) == (section == .chat), "Chats is selected only for the chats section")
                let selected = SidebarDestination.allCases.filter { $0.isSelected(section: section, pane: pane) }.count + (section == .vera ? 1 : 0)
                try require(selected == 1, "Exactly one sidebar row is selected for \(section.rawValue) with the \(pane.rawValue) pane")
            }
        }

        try require(!SidebarDestination.chats.isSelected(section: .chat, pane: .canvas, showingConversation: true), "Chats steps aside while a listed conversation row is selected")
        for section in AppSection.allCases {
            let shown = SidebarDestination.allCases.filter { $0.isSelected(section: section, pane: .canvas, showingConversation: true) }.count
                + (section == .vera ? 1 : 0) + (section == .chat ? 1 : 0)
            try require(shown == 1, "Exactly one sidebar row is selected for \(section.rawValue) while a conversation row is shown")
        }
        try require(SidebarDestination.allCases.allSatisfy { !$0.title.isEmpty && !$0.icon.isEmpty }, "Every destination has a title and an icon")
        try require(AppSection.artifacts.title == "Library", "The artifacts section is called Library")
    }
}
