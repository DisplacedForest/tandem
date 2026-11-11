import AppKit
import SwiftUI

@MainActor
enum RulesShot {
    static func render(view: String, to path: String, appearance: String) {
        let scheme: ColorScheme = appearance == "light" && view != "rules-dark" ? .light : .dark
        let showsHelp = view == "rules-info" || view == "rules-unnamed"
        let companion: String? = view == "rules-saved-literal" ? CompanionNameShot.name(environment: ProcessInfo.processInfo.environment)
            : view.hasSuffix("-unnamed") ? nil : "Ada"
        let variant = view.hasSuffix("-ada") ? String(view.dropLast("-ada".count))
            : view.hasSuffix("-unnamed") ? String(view.dropLast("-unnamed".count)) : view
        let showsMenu = variant == "rules-menu"
        let showsChoices = variant == "rules-choices"
        let advancedVariant = variant.hasPrefix("rules-advanced")
        let sharedVariant = variant.hasPrefix("rules-shared")
        let showsSharingInfo = variant == "rules-shared-info"
        let size = NSSize(width: showsHelp || showsMenu || showsChoices || advancedVariant || showsSharingInfo ? 1240 : 860,
                          height: advancedVariant ? 1100 : sharedVariant ? 1280 : 980)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rules-shot-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("Seedlings"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatStore()
        store.adoptAssistantName(companion ?? "")
        store.ensureVeraThread()
        store.prepareRuleRecords()
        if variant == "rules-saved" || variant == "rules-saved-kind" || showsMenu { seed(store, folder: directory.appendingPathComponent("Seedlings").path) }
        if variant == "rules-saved-kind" { store.addRuleRecord(RuleOffer.record(.fileEdits, conversationID: "rules-greenhouse")) }
        if variant == "rules-saved-literal" { seedLiteral(store, root: directory.path) }
        if variant == "rules-shared" || showsSharingInfo { seedShared(store, root: directory.path) }
        let opened = showsMenu ? store.ruleRows().first(where: { $0.widenQuestion != nil }) : nil
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in })
        var advanced = RulesAdvancedState()
        var asked: RulesAdvancedState.Question?
        if variant == "rules-advanced-closed" { asked = .open }
        if variant == "rules-advanced-open" || variant == "rules-advanced-mixed" {
            advanced.askToOpen()
            _ = advanced.confirm()
        }
        if variant == "rules-advanced-open" { asked = .allow(.payments) }
        if variant == "rules-advanced-on" || variant == "rules-advanced-mixed" { config.letThrough(.payments, store: store) }
        if variant.hasPrefix("rules-advanced-each") {
            let settings: [(NativeFloorItem, NativeRuleChoice)] = [(.credentialEntry, .ask), (.payments, .act), (.permanentDeletion, .handOff)]
            for (item, choice) in settings {
                config.letThrough(item, store: store)
                config.setChoice(choice, for: item, store: store)
            }
        }
        if variant == "rules-advanced-each-open" || variant == "rules-advanced-asking" {
            advanced.askToOpen()
            _ = advanced.confirm()
        }
        if variant == "rules-advanced-asking" {
            config.letThrough(.payments, store: store)
            asked = .withoutAsking(.payments)
        }
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let root = HStack(alignment: .top, spacing: 16) {
            RulesSettingsTab(showing: advanced).frame(width: 860, height: size.height)
            if let asked {
                RulesAdvancedQuestionView(question: asked, onCancel: {}, onConfirm: {})
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
                .padding(.top, 20)
            }
            if showsSharingInfo {
                SharedFolderInfo()
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
                    .padding(.top, 20)
            }
            if showsHelp {
                RulesChoiceHelp()
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
            }
            if showsChoices {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Opens from each choice picker").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    ForEach(NativeRuleChoice.allCases, id: \.self) { Text($0.title).font(.system(size: 13)) }
                }
                .padding(14)
                .frame(width: 340, alignment: .leading)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
                .padding(.top, 20)
            }
            if let opened {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Opens from the menu on this row").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    CompanionLineText(line: opened.line).font(.system(size: 12, weight: .semibold))
                    ForEach(opened.menuTitles, id: \.self) { Text($0).font(.system(size: 13)) }
                    Divider()
                    Text("Apply everywhere asks first").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    Text(opened.widenQuestion ?? "").font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button(RuleRows.cancel) {}
                        Button(RuleRows.widenConfirm) {}.buttonStyle(.borderedProminent)
                    }
                }
                .padding(14)
                .frame(width: 340, alignment: .leading)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
                .padding(.top, 20)
            }
        }
        .environmentObject(store).environmentObject(config)
        .environment(\.companionName, companion)
        .environment(\.companionAppearance, CompanionAppearance(shape: .pebble, color: .apricot))
        .environment(\.colorScheme, scheme)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Theme.bg)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: URL(fileURLWithPath: path)); print("wrote \(path)"); exit(0) }
        catch { exit(1) }
    }

    static func seed(_ store: ChatStore, folder: String) {
        let greenhouse = Conversation(id: "rules-greenhouse", title: "Greenhouse notes", messages: [], updatedAt: Date())
        let orders = Conversation(id: "rules-orders", title: "Seed orders", messages: [], updatedAt: Date())
        store.conversations.insert(contentsOf: [greenhouse, orders], at: 0)
        let command = NativeCommandTools.toolID
        var records: [NativeRuleRecord] = []
        if let status = NativeRuleTarget.make(.commandPrefix, "git status") {
            records.append(NativeRuleRecord(scope: .everywhere, action: .commands, toolID: command, target: status, effect: .allow,
                                            statement: "Always allow commands that start with git status", origin: .confirmCard,
                                            originConversationID: greenhouse.id))
        }
        if let seedlings = NativeRuleTarget.folder(folder) {
            records.append(NativeRuleRecord(scope: .everywhere, action: .fileEdits, target: seedlings, effect: .forbid,
                                            statement: "Never allow file edits in Seedlings", origin: .confirmCard, originConversationID: orders.id))
        }
        if let pdf = NativeRuleTarget.make(.commandPrefix, "make pdf") {
            records.append(NativeRuleRecord(scope: .conversation(greenhouse.id), action: .commands, toolID: command, target: pdf, effect: .allow,
                                            statement: "In this chat, allow commands that start with make pdf", origin: .migration,
                                            originConversationID: greenhouse.id))
        }
        records.append(NativeRuleRecord(scope: .conversation(greenhouse.id), action: nil, toolID: command, effect: .forbid,
                                        statement: "Never run commands in this chat", origin: .confirmCard, originConversationID: greenhouse.id))
        if let workshop = NativeRuleTarget.make(.recipient, "workshop@example.com") {
            let mail = "{\"name\":\"mail_send\",\"title\":\"Mail\",\"description\":\"Send an email\",\"parameters\":{\"type\":\"object\",\"properties\":{\"to\":{\"type\":\"string\"}},\"required\":[\"to\"],\"additionalProperties\":false},\"endpoint\":\"https://mail.example/send\",\"method\":\"POST\",\"confirmation\":\"none\"}"
            let declaration = try? NativeCapabilityTools.parse(data: Data(mail.utf8), source: "mail.json")
            if let declaration { store.reloadCapabilityTools([declaration]) }
            records.append(NativeRuleRecord(scope: .conversation(orders.id), action: .networkSends, toolID: declaration?.id ?? "mail", target: workshop, effect: .allow,
                                            statement: "In this chat, allow sending to workshop@example.com", origin: .confirmCard,
                                            originConversationID: orders.id, remainingUses: 2))
        }
        if let thread = store.veraThreadID {
            records.append(NativeRuleRecord(scope: .conversation(thread), action: .networkSends, toolID: "garden-log", effect: .allow,
                                            statement: "In this chat, allow: Post to the garden log", origin: .confirmCard, originConversationID: thread))
        }
        var off: String?
        for record in records {
            let saved = store.addRuleRecord(record)
            if record.target?.kind == .folder { off = saved?.id }
        }
        if let off { store.disableRuleRecord(id: off) }
        store.tightenConversationRule(.ask, for: .fileEdits, conversationID: orders.id)
    }

    static func seedShared(_ store: ChatStore, root: String) {
        func folder(_ parts: String...) -> String {
            let path = parts.reduce(root) { ($0 as NSString).appendingPathComponent($1) }
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        let garden = ProjectRecord(id: "rules-shared-garden", name: "Spring garden", instructions: "",
                                   grants: [FolderGrant(path: folder("Plans", "Garden plans"))], files: [], createdAt: Date(), updatedAt: Date())
        store.projects = [garden]
        var greenhouse = Conversation(id: "rules-shared-greenhouse", title: "Greenhouse notes", messages: [], updatedAt: Date())
        greenhouse.grants = [FolderGrant(path: folder("Work", "Documents")), FolderGrant(path: folder("Seedlings"))]
        var orders = Conversation(id: "rules-shared-orders", title: "Seed orders", messages: [], updatedAt: Date())
        orders.grants = [FolderGrant(path: folder("Home", "Documents"))]
        orders.projectID = garden.id
        var receipts = Conversation(id: "rules-shared-receipts", title: "Receipts", messages: [], updatedAt: Date())
        receipts.grants = [FolderGrant(path: folder("Archive", "Receipts"), readOnly: true)]
        receipts.projectID = garden.id
        var beds = Conversation(id: "rules-shared-beds", title: "Raised beds", messages: [], updatedAt: Date())
        beds.projectID = garden.id
        store.conversations.insert(contentsOf: [greenhouse, orders, receipts, beds], at: 0)
        if let thread = store.veraThreadID, let index = store.conversations.firstIndex(where: { $0.id == thread }) {
            store.conversations[index].grants = [FolderGrant(path: folder("Journal"))]
        }
    }

    static func seedLiteral(_ store: ChatStore, root: String) {
        let folder = (root as NSString).appendingPathComponent("{name}")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let notes = Conversation(id: "rules-literal-notes", title: "Notes about {name}", messages: [], updatedAt: Date())
        store.conversations.insert(notes, at: 0)
        let command = NativeCommandTools.toolID
        var records: [NativeRuleRecord] = []
        if let named = NativeRuleTarget.folder(folder) {
            records.append(NativeRuleRecord(scope: .everywhere, action: .fileEdits, target: named, effect: .allow,
                                            statement: "Always allow file edits in {name}", origin: .settings))
        }
        if let echo = NativeRuleTarget.make(.commandPrefix, "echo {name}") {
            records.append(NativeRuleRecord(scope: .everywhere, action: .commands, toolID: command, target: echo, effect: .allow,
                                            statement: "Always allow commands that start with echo {name}", origin: .settings))
        }
        if let thread = store.veraThreadID {
            records.append(NativeRuleRecord(scope: .conversation(thread), action: .networkSends, toolID: "garden-log", effect: .allow,
                                            statement: "In this chat, allow: Post to the garden log", origin: .confirmCard, originConversationID: thread))
        }
        records.append(NativeRuleRecord(scope: .conversation(notes.id), action: nil, toolID: command, effect: .forbid,
                                        statement: "Never run commands in this chat", origin: .confirmCard, originConversationID: notes.id))
        for record in records { store.addRuleRecord(record) }
    }
}
