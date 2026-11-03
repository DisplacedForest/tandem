import Foundation
import SwiftUI

enum SidebarDestination: String, CaseIterable, Identifiable {
    case chats, projects, library, scheduled, integrations, pulse, workflows, activity, memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: "Home"
        case .projects: "Projects"
        case .library: "Library"
        case .scheduled: "Scheduled"
        case .integrations: "Plugins"
        case .pulse: "Pulse"
        case .workflows: "Workflows"
        case .activity: "Activity"
        case .memory: "Memory"
        }
    }

    var icon: String {
        switch self {
        case .chats: "house"
        case .projects: AppSection.projects.icon
        case .library: AppSection.artifacts.icon
        case .scheduled: "clock"
        case .integrations: AppSection.integrations.icon
        case .pulse: AppSection.pulse.icon
        case .workflows: "point.3.connected.trianglepath.dotted"
        case .activity: "bolt"
        case .memory: AppSection.memory.icon
        }
    }

    static let primary: [SidebarDestination] = [.chats, .library, .scheduled, .integrations]
    static let secondary: [SidebarDestination] = [.projects, .pulse, .workflows, .activity, .memory]

    func isRailSelected(section: AppSection, pane: AgenticPane) -> Bool {
        if self == .chats { return [.chat, .vera, .projects].contains(section) }
        return isSelected(section: section, pane: pane)
    }

    func isSelected(section: AppSection, pane: AgenticPane, showingConversation: Bool = false) -> Bool {
        switch self {
        case .chats: section == .chat && !showingConversation
        case .projects: section == .projects
        case .library: section == .artifacts
        case .scheduled: section == .scheduled
        case .integrations: section == .integrations
        case .pulse: section == .pulse
        case .workflows: section == .agentic && pane == .canvas
        case .activity: section == .agentic && pane == .activity
        case .memory: section == .memory
        }
    }
}
