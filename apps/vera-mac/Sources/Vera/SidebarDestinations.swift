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

    var glyph: InterfaceIcon {
        switch self {
        case .chats: .home
        case .projects: AppSection.projects.glyph
        case .library: AppSection.artifacts.glyph
        case .scheduled: AppSection.scheduled.glyph
        case .integrations: AppSection.integrations.glyph
        case .pulse: AppSection.pulse.glyph
        case .workflows: AppSection.agentic.glyph
        case .activity: .activity
        case .memory: AppSection.memory.glyph
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
