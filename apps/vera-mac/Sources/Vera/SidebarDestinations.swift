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
    static let shared = SidebarPins()
    @Published private(set) var pinned: [SidebarDestination]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pinned = Self.stored(in: defaults)
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func isPinned(_ destination: SidebarDestination) -> Bool {
        pinned.contains(destination)
    }

    func toggle(_ destination: SidebarDestination) {
        var next = Self.stored(in: defaults)
        if let index = next.firstIndex(of: destination) { next.remove(at: index) } else { next.append(destination) }
        save(next)
    }

    func move(_ destination: SidebarDestination, before target: SidebarDestination) {
        var next = Self.stored(in: defaults)
        guard destination != target, next.contains(destination), next.contains(target) else { return }
        next.removeAll { $0 == destination }
        guard let index = next.firstIndex(of: target) else { return }
        next.insert(destination, at: index)
        save(next)
    }

    func moveToEnd(_ destination: SidebarDestination) {
        var next = Self.stored(in: defaults)
        guard next.contains(destination) else { return }
        next.removeAll { $0 == destination }
        next.append(destination)
        save(next)
    }

    private func save(_ next: [SidebarDestination]) {
        pinned = next
        defaults.set(next.map(\.rawValue), forKey: Self.key)
    }

    func refresh() {
        let current = Self.stored(in: defaults)
        if current != pinned { pinned = current }
    }

    private static func stored(in defaults: UserDefaults) -> [SidebarDestination] {
        guard let stored = defaults.array(forKey: key) as? [String] else { return SidebarDestination.defaultPins }
        var seen = Set<SidebarDestination>()
        return stored.compactMap(SidebarDestination.init(rawValue:)).filter { seen.insert($0).inserted }
    }
}
