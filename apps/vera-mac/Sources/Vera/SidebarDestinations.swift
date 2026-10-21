import Foundation
import SwiftUI

enum SidebarDestination: String, CaseIterable, Identifiable {
    case projects, artifacts, scheduled, integrations, pulse, workflows, activity, memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects: "Projects"
        case .artifacts: "Artifacts"
        case .scheduled: "Scheduled"
        case .integrations: "Integrations"
        case .pulse: "Pulse"
        case .workflows: "Workflows"
        case .activity: "Activity"
        case .memory: "Memory"
        }
    }

    var icon: String {
        switch self {
        case .projects: AppSection.projects.icon
        case .artifacts: AppSection.artifacts.icon
        case .scheduled: AppSection.scheduled.icon
        case .integrations: AppSection.integrations.icon
        case .pulse: AppSection.pulse.icon
        case .workflows: "point.3.connected.trianglepath.dotted"
        case .activity: "bolt"
        case .memory: AppSection.memory.icon
        }
    }

    static let defaultPins: [SidebarDestination] = [.projects, .pulse]

    func isSelected(section: AppSection, pane: AgenticPane) -> Bool {
        switch self {
        case .workflows: section == .agentic && pane == .canvas
        case .activity: section == .agentic && pane == .activity
        case .projects: section == .projects
        case .artifacts: section == .artifacts
        case .scheduled: section == .scheduled
        case .integrations: section == .integrations
        case .pulse: section == .pulse
        case .memory: section == .memory
        }
    }
}

@MainActor
final class SidebarPins: ObservableObject {
    static let key = "sidebarPinnedSections"
    @Published private(set) var pinned: [SidebarDestination]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.array(forKey: Self.key) as? [String] {
            let set = Set(stored)
            pinned = SidebarDestination.allCases.filter { set.contains($0.rawValue) }
        } else {
            pinned = SidebarDestination.defaultPins
        }
    }

    func isPinned(_ destination: SidebarDestination) -> Bool {
        pinned.contains(destination)
    }

    func toggle(_ destination: SidebarDestination) {
        var set = Set(pinned)
        if set.contains(destination) { set.remove(destination) } else { set.insert(destination) }
        pinned = SidebarDestination.allCases.filter { set.contains($0) }
        defaults.set(pinned.map(\.rawValue), forKey: Self.key)
    }
}
