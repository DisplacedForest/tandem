import Foundation

enum IntegrationsPageModel {
    static let contentWidth: CGFloat = 700
    static let twoColumnWidth: CGFloat = 660
    static let headerRowWidth: CGFloat = 520
    static let subtitle = "Connect the services {name} can use."
    static let noMatch = "Nothing matches."
    static let emptyTitle = "No connected services yet."
    static let emptyDetail = "Browse Public to install one, or add your own."

    struct Section: Identifiable, Equatable {
        let title: String
        let entries: [NativeMCPStarterEntry]
        var id: String { title }
    }

    enum Trailing: Equatable {
        case install
        case menu
    }

    enum MenuAction: String, CaseIterable, Identifiable {
        case manage, connect, signIn, cancel, disconnect, remove
        var id: Self { self }
        var title: String {
            switch self {
            case .manage: return "Manage…"
            case .connect: return "Connect"
            case .signIn: return "Sign in"
            case .cancel: return "Cancel connection"
            case .disconnect: return "Disconnect"
            case .remove: return "Remove…"
            }
        }
        var symbol: String {
            switch self {
            case .manage: return "slider.horizontal.3"
            case .connect: return "link"
            case .signIn: return "person.badge.key"
            case .cancel, .disconnect: return "xmark"
            case .remove: return "trash"
            }
        }
    }

    struct Connection: Equatable {
        var authentication: NativeMCPServerConfiguration.Authentication
        var connected = false
        var connecting = false
        var signingIn = false
        var reconnecting = false
        var kept = false

        var action: MenuAction {
            guard connected || connecting || signingIn || reconnecting else { return authentication == .oauth ? .signIn : .connect }
            return !kept && (connecting || signingIn) ? .cancel : .disconnect
        }
    }

    static func menu(_ connection: Connection) -> [MenuAction] { [.manage, connection.action, .remove] }

    static func columns(for width: CGFloat) -> Int { width >= twoColumnWidth ? 2 : 1 }

    static func sections(_ entries: [NativeMCPStarterEntry]) -> [Section] {
        var order: [String] = []
        for entry in entries where !order.contains(entry.category) { order.append(entry.category) }
        return order.map { title in Section(title: title, entries: entries.filter { $0.category == title }) }
    }

    static func installed(_ entry: NativeMCPStarterEntry, in servers: [NativeMCPServerState]) -> [NativeMCPServerState] {
        servers.filter { entry.matches($0.configuration) }
    }

    static func trailing(_ entry: NativeMCPStarterEntry, in servers: [NativeMCPServerState]) -> Trailing {
        installed(entry, in: servers).isEmpty ? .install : .menu
    }

    static func entry(for server: NativeMCPServerState, in entries: [NativeMCPStarterEntry]) -> NativeMCPStarterEntry? {
        entries.first { $0.matches(server.configuration) }
    }

    static func matching(_ servers: [NativeMCPServerState], entries: [NativeMCPStarterEntry], query: String) -> [NativeMCPServerState] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return servers }
        return servers.filter { server in
            let listed = entry(for: server, in: entries)
            return [server.configuration.name, server.configuration.publisher ?? listed?.publisher ?? "", listed?.description ?? ""]
                .contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    static func line(_ server: NativeMCPServerState, state: String, entry: NativeMCPStarterEntry?) -> String {
        guard server.connected else { return state }
        if let description = entry?.description, !description.isEmpty { return description }
        return state
    }
}
