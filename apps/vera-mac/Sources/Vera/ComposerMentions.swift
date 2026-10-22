import Foundation

enum ComposerMentionSection: String, CaseIterable, Sendable {
    case add = "Add"
    case tools = "Tools"
    case plugins = "Plugins"
}

struct ComposerMentionItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case files, folder, tools(Set<String>) }
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

    init(items: [ComposerMentionItem]) {
        var names: Set<String> = []
        self.items = items.filter { names.insert($0.name.lowercased()).inserted }
    }

    static let filesItem = ComposerMentionItem(id: "add-files", section: .add, name: "Add photos and files",
        detail: "", icon: "paperclip", available: true, kind: .files)

    static let folderItem = ComposerMentionItem(id: "grant-folder", section: .add, name: "Work in a folder",
        detail: "Let this chat read and change files in a folder", icon: "folder", available: true, kind: .folder)

    static func builtIns(webAvailable: Bool, imageAvailable: Bool) -> [ComposerMentionItem] {
        [
            ComposerMentionItem(id: NativeWebTools.searchToolID, section: .tools, name: "Search the web",
                detail: "Answer from live search results", icon: "magnifyingglass", available: webAvailable,
                kind: .tools([NativeWebTools.searchToolID])),
            ComposerMentionItem(id: NativeWebTools.researchToolID, section: .tools, name: "Background research",
                detail: "A cited report gathered in the background", icon: "doc.text.magnifyingglass", available: webAvailable,
                kind: .tools([NativeWebTools.researchToolID, NativeTaskTools.toolID])),
            ComposerMentionItem(id: NativeTaskTools.toolID, section: .tools, name: "Write a document",
                detail: "A longer document written in the background", icon: "doc.text", available: true,
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
            detail: "", icon: "wrench.and.screwdriver",
            available: declaration.enabled && (!declaration.needsAPIBase || webAvailable),
            kind: .tools([declaration.id]))
    }

    static func plugin(name: String, serverID: String, connected: Bool, toolIDs: [String], allowedIDs: [String]) -> ComposerMentionItem {
        let detail: String
        if !connected { detail = "Not connected" }
        else if toolIDs.isEmpty { detail = "Connected" }
        else if allowedIDs.isEmpty { detail = "Turned off in Settings" }
        else { detail = allowedIDs.count == 1 ? "1 tool" : "\(allowedIDs.count) tools" }
        return ComposerMentionItem(id: "plugin-" + serverID, section: .plugins, name: name, detail: detail,
            icon: "puzzlepiece.extension", available: connected && !allowedIDs.isEmpty, kind: .tools(Set(allowedIDs)))
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
        case .files, .folder: next.replaceSubrange(query.range, with: "")
        case .tools: next.replaceSubrange(query.range, with: "@" + item.name + " ")
        }
        return next
    }

    static func resolve(_ text: String, catalog: ComposerMentionCatalog) -> Set<String> {
        let masked = Array(NativeTurnToolAuthority.literalMask(text).lowercased())
        let original = Array(text)
        guard masked.count == original.count else { return [] }
        let names = catalog.items.map { (Array($0.name.lowercased()), $0.toolIDs) }
            .sorted { $0.0.count > $1.0.count }
        var ids: Set<String> = []
        var index = 0
        while index < masked.count {
            guard masked[index] == "@", index == 0 || original[index - 1].isWhitespace else { index += 1; continue }
            let start = index + 1
            var consumed = 0
            for (name, toolIDs) in names {
                let end = start + name.count
                guard end <= masked.count, Array(masked[start..<end]) == name else { continue }
                if end < masked.count, masked[end].isLetter || masked[end].isNumber { continue }
                ids.formUnion(toolIDs)
                consumed = name.count
                break
            }
            index = start + max(consumed, 0)
        }
        return ids
    }
}
