import Foundation

enum ComposerMentionSection: String, CaseIterable, Sendable {
    case add = "Add"
    case tools = "Tools"
    case plugins = "Plugins"
}

struct ComposerMentionItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case files, tools(Set<String>) }
    let id: String
    let section: ComposerMentionSection
    let name: String
    let detail: String
    let icon: String
    let available: Bool
    let kind: Kind

    var toolIDs: Set<String> {
        if case .tools(let ids) = kind { return ids }
        return []
    }
}

struct ComposerMentionCatalog: Equatable, Sendable {
    let items: [ComposerMentionItem]

    static let filesItem = ComposerMentionItem(id: "add-files", section: .add, name: "Add photos and files",
        detail: "", icon: "paperclip", available: true, kind: .files)

    static func builtIns(webAvailable: Bool, imageAvailable: Bool) -> [ComposerMentionItem] {
        [
            ComposerMentionItem(id: NativeWebTools.searchToolID, section: .tools, name: "Search the web",
                detail: "Answer from live search results", icon: "magnifyingglass", available: webAvailable,
                kind: .tools([NativeWebTools.searchToolID])),
            ComposerMentionItem(id: NativeWebTools.researchToolID, section: .tools, name: "Deep research",
                detail: "A cited report gathered in the background", icon: "doc.text.magnifyingglass", available: webAvailable,
                kind: .tools([NativeWebTools.researchToolID, NativeTaskTools.toolID])),
            ComposerMentionItem(id: NativeImageTools.toolID, section: .tools, name: "Create images",
                detail: "Generate a picture from a description", icon: "photo", available: imageAvailable,
                kind: .tools([NativeImageTools.toolID])),
            ComposerMentionItem(id: "apple-reminders", section: .tools, name: "Reminders",
                detail: "List, add and complete Apple Reminders", icon: "checklist", available: true,
                kind: .tools(["apple-reminders"])),
        ]
    }

    static func capability(_ declaration: NativeToolDeclaration, webAvailable: Bool) -> ComposerMentionItem {
        ComposerMentionItem(id: declaration.id, section: .tools, name: declaration.title,
            detail: declaration.description, icon: "wrench.and.screwdriver",
            available: declaration.enabled && (!declaration.needsAPIBase || webAvailable),
            kind: .tools([declaration.id]))
    }

    static func plugin(name: String, serverID: String, connected: Bool, toolIDs: [String]) -> ComposerMentionItem {
        let detail: String
        if !connected { detail = "Not connected" }
        else if toolIDs.isEmpty { detail = "Connected" }
        else { detail = toolIDs.count == 1 ? "1 tool" : "\(toolIDs.count) tools" }
        return ComposerMentionItem(id: "plugin-" + serverID, section: .plugins, name: name, detail: detail,
            icon: "puzzlepiece.extension", available: connected && !toolIDs.isEmpty, kind: .tools(Set(toolIDs)))
    }

    func matching(_ query: String) -> [ComposerMentionItem] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter { $0.name.lowercased().contains(needle) || $0.detail.lowercased().contains(needle) }
    }

    func sections(_ query: String) -> [(ComposerMentionSection, [ComposerMentionItem])] {
        let visible = matching(query)
        return ComposerMentionSection.allCases.compactMap { section in
            let rows = visible.filter { $0.section == section }
            return rows.isEmpty ? nil : (section, rows)
        }
    }
}

struct ComposerMentionQuery: Equatable {
    let range: Range<String.Index>
    let text: String
}

enum ComposerMentions {
    static func query(in draft: String) -> ComposerMentionQuery? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex {
            let before = draft[draft.index(before: at)]
            guard before.isWhitespace || before.isNewline else { return nil }
        }
        let text = String(draft[draft.index(after: at)...])
        guard !text.contains("\n"), text.count <= 40 else { return nil }
        return ComposerMentionQuery(range: at..<draft.endIndex, text: text)
    }

    static func insert(_ item: ComposerMentionItem, into draft: String, replacing query: ComposerMentionQuery) -> String {
        var next = draft
        switch item.kind {
        case .files: next.replaceSubrange(query.range, with: "")
        case .tools: next.replaceSubrange(query.range, with: "@" + item.name + " ")
        }
        return next
    }

    static func resolve(_ text: String, catalog: ComposerMentionCatalog) -> Set<String> {
        var stripped = text
        for pattern in [#"(?s)```.*?(?:```|$)"#, #"`[^`\n]*(?:`|$)"#] {
            stripped = stripped.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let lowered = stripped.lowercased()
        var ids: Set<String> = []
        for item in catalog.items.sorted(by: { $0.name.count > $1.name.count }) where !item.toolIDs.isEmpty {
            let needle = "@" + item.name.lowercased()
            var search = lowered.startIndex
            while let range = lowered.range(of: needle, range: search..<lowered.endIndex) {
                let startsClean = range.lowerBound == lowered.startIndex
                    || lowered[lowered.index(before: range.lowerBound)].isWhitespace
                let endsClean = range.upperBound == lowered.endIndex
                    || !(lowered[range.upperBound].isLetter || lowered[range.upperBound].isNumber)
                if startsClean && endsClean { ids.formUnion(item.toolIDs); break }
                search = range.upperBound
            }
        }
        return ids
    }
}
