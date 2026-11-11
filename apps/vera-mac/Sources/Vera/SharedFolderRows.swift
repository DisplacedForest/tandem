import Foundation

struct SharedFolderRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case chat(conversationID: String, grantID: String)
        case project(projectID: String, grantID: String)
    }

    let id: String
    let title: String
    let path: String
    let sentence: CompanionLine
    let readOnly: Bool
    let kind: Kind

    func spoken(name: String?) -> String { sentence.plain(name: name) }

    func stopLabel(name: String?) -> String {
        let place = spoken(name: name)
        return "\(SharedFolderRows.stop) \(title), \(place.prefix(1).lowercased() + place.dropFirst())"
    }
}

enum SharedFolderRows {
    static let sectionTitle = "Shared folders"
    static let info = "Sharing a folder is what lets files there be edited and commands run there. The rules above decide whether you're asked first."
    static let infoLabel = "What sharing a folder means"
    static let stop = "Stop sharing"
    static let readOnlyNote = " Read only."
    static let failed = "That folder is still shared. The change couldn't be saved."

    static func folderName(_ grant: FolderGrant) -> String {
        let last = URL(fileURLWithPath: grant.path).lastPathComponent
        return last.isEmpty || last == "/" ? grant.name : last
    }

    static func components(_ path: String) -> [String] {
        URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
    }

    static func titles(for paths: [String: String]) -> [String: String] {
        var titles: [String: String] = [:]
        let groups = Dictionary(grouping: paths.keys, by: { paths[$0] ?? "" })
        for (name, group) in groups {
            guard group.count > 1 else {
                if let only = group.first { titles[only] = name }
                continue
            }
            let parts = Dictionary(uniqueKeysWithValues: group.map { ($0, components($0)) })
            func suffix(_ path: String, _ depth: Int) -> ArraySlice<String> {
                let all = parts[path] ?? []
                return all.suffix(depth + 1)
            }
            for path in group {
                let all = parts[path] ?? []
                var depth = 1
                while depth + 1 < all.count, group.contains(where: { $0 != path && suffix($0, depth) == suffix(path, depth) }) {
                    depth += 1
                }
                let chosen = suffix(path, depth)
                let exhausted = chosen.count == all.count && group.contains(where: { $0 != path && suffix($0, depth) == chosen })
                titles[path] = exhausted || chosen.count < 2 ? path : chosen.joined(separator: "/")
            }
        }
        return titles
    }

    static func chatSentence(_ title: String) -> CompanionLine {
        .literal("Shared with \(title)")
    }

    static let companionSentence = CompanionLine.parts([.text("Shared with "), .name, .text("'s thread")])

    static func projectSentence(_ name: String, chats: Int) -> CompanionLine {
        let use = chats == 0 ? "no chats yet" : chats == 1 ? "used by 1 chat" : "used by \(chats) chats"
        return .literal("Shared with the project \(name), \(use)")
    }

    static func marked(_ line: CompanionLine, readOnly: Bool) -> CompanionLine {
        guard readOnly else { return line }
        if case .literal(let text) = line { return .literal(text + "." + readOnlyNote) }
        return .parts(line.parts + [.text("." + readOnlyNote)])
    }

    static func rows(conversations: [Conversation], projects: [ProjectRecord], companionThreadID: String?, name: String?) -> [SharedFolderRow] {
        var pending: [(grant: FolderGrant, sentence: CompanionLine, kind: SharedFolderRow.Kind, id: String)] = []
        for conversation in conversations {
            let sentence = conversation.id == companionThreadID ? companionSentence : chatSentence(conversation.title)
            for grant in conversation.grants {
                pending.append((grant, marked(sentence, readOnly: grant.readOnly),
                                .chat(conversationID: conversation.id, grantID: grant.id), "chat|\(conversation.id)|\(grant.id)"))
            }
        }
        for project in projects {
            let chats = conversations.filter { $0.projectID == project.id }.count
            let sentence = projectSentence(project.name, chats: chats)
            for grant in project.grants {
                pending.append((grant, marked(sentence, readOnly: grant.readOnly),
                                .project(projectID: project.id, grantID: grant.id), "project|\(project.id)|\(grant.id)"))
            }
        }
        var names: [String: String] = [:]
        for entry in pending { names[entry.grant.path] = folderName(entry.grant) }
        let titles = titles(for: names)
        let rows = pending.map { entry in
            SharedFolderRow(id: entry.id, title: titles[entry.grant.path] ?? folderName(entry.grant), path: entry.grant.path,
                            sentence: entry.sentence, readOnly: entry.grant.readOnly, kind: entry.kind)
        }
        return rows.sorted { first, second in
            let byTitle = first.title.localizedStandardCompare(second.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            let byPlace = first.spoken(name: name).localizedStandardCompare(second.spoken(name: name))
            if byPlace != .orderedSame { return byPlace == .orderedAscending }
            return first.id < second.id
        }
    }

    static func screenStrings(_ rows: [SharedFolderRow], name: String?) -> [String] {
        var strings = [sectionTitle, info, infoLabel, stop, failed]
        for row in rows {
            strings.append(row.title)
            strings.append(row.spoken(name: name))
            strings.append(row.stopLabel(name: name))
        }
        return strings
    }
}
