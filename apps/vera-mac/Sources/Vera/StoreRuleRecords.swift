import Foundation
import GRDB
import OSLog

extension Notification.Name {
    static let ruleRecordsChanged = Notification.Name("tandem.rule-records-changed")
}

extension ChatStore {
    var nativeRuleRecordStore: NativeRuleRecordStore? {
        (repository as? LocalChatRepository).map { NativeRuleRecordStore(database: $0.database) }
    }

    func prepareRuleRecords() {
        guard let store = nativeRuleRecordStore else { return }
        Self.prepareRules(nativeRuleSource, from: store)
    }

    func reloadRuleRecords() {
        guard let store = nativeRuleRecordStore else { return }
        Self.reloadRules(nativeRuleSource, from: store)
    }

    nonisolated static func prepareRules(_ source: NativeRuleSource, from store: NativeRuleRecordStore) {
        source.attach(allocator: { try store.advanceVersion() })
        do {
            _ = try store.advanceVersion()
            _ = try store.expireDue()
        } catch {
            Logger(subsystem: "Vera", category: "rules").error("rules_launch_failed \(error.localizedDescription, privacy: .public)")
            source.fail()
            return
        }
        reloadRules(source, from: store)
    }

    nonisolated static func reloadRules(_ source: NativeRuleSource, from store: NativeRuleRecordStore) {
        for _ in 0..<2 {
            do {
                let snapshot = try store.snapshot()
                if source.publish(snapshot.records, version: snapshot.version) { return }
            } catch {
                Logger(subsystem: "Vera", category: "rules").error("rules_reload_failed \(error.localizedDescription, privacy: .public)")
                source.fail()
                return
            }
        }
    }

    func syncRuleProjects() {
        nativeRuleSource.replaceProjects(conversations.map { ($0.id, $0.projectID) })
    }

    var ruleRecords: [NativeRuleRecord] {
        (try? nativeRuleRecordStore?.all()) ?? []
    }

    func approvedCommandRecords(for conversationID: String?) -> [NativeRuleRecord] {
        guard let conversationID else { return [] }
        let now = Date()
        return ruleRecords.filter {
            $0.scope == .conversation(conversationID) && $0.effect == .allow && $0.target?.kind == .commandPrefix && $0.isLive(at: now)
        }
    }

    @discardableResult
    func addRuleRecord(_ record: NativeRuleRecord) -> NativeRuleRecord? {
        guard let store = nativeRuleRecordStore, let saved = try? store.add(record) else { return nil }
        reloadRuleRecords()
        announceRuleChange()
        return saved
    }

    @discardableResult
    func updateRuleRecord(id: String, _ mutate: (inout NativeRuleRecord) -> Void) -> NativeRuleRecord? {
        guard let store = nativeRuleRecordStore, let saved = try? store.update(id: id, mutate) else { return nil }
        reloadRuleRecords()
        announceRuleChange()
        return saved
    }

    @discardableResult
    func disableRuleRecord(id: String) -> Bool {
        guard let store = nativeRuleRecordStore, (try? store.disable(id: id)) == true else { return false }
        reloadRuleRecords()
        announceRuleChange()
        return true
    }

    @discardableResult
    func enableRuleRecord(id: String) -> Bool {
        guard let store = nativeRuleRecordStore, (try? store.enable(id: id)) == true else { return false }
        reloadRuleRecords()
        announceRuleChange()
        return true
    }

    @discardableResult
    func revokeRuleRecord(id: String) -> Bool {
        guard let store = nativeRuleRecordStore, (try? store.revoke(id: id)) == true else { return false }
        reloadRuleRecords()
        announceRuleChange()
        return true
    }

    func announceRuleChange() {
        NotificationCenter.default.post(name: .ruleRecordsChanged, object: nil)
    }

    private var ruleDatabase: DatabaseQueue? { (repository as? LocalChatRepository)?.database }

    static func workTitle(_ payload: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return "" }
        for key in ["title", "assignment", "objective"] {
            guard let text = object[key] as? String else { continue }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if !line.isEmpty { return line.count > 80 ? String(line.prefix(77)) + "..." : line }
        }
        return ""
    }

    func ruleScopeExists(_ scope: NativeRuleScope) -> Bool? {
        switch scope {
        case .everywhere: return true
        case .conversation(let id):
            if conversations.contains(where: { $0.id == id }) || id == veraThreadID { return true }
            return stored("conversations", id)
        case .project(let id):
            if projects.contains(where: { $0.id == id }) { return true }
            return stored("projects", id)
        case .schedule(let id):
            if schedules.contains(where: { $0.id == id }) { return true }
            return stored("native_schedules", id)
        case .task(let id):
            guard let database = ruleDatabase else { return nil }
            do { return try !NativeTaskStore(database: database).get(id).state.isTerminal }
            catch NativeTaskStoreError.notFound { return false }
            catch { return nil }
        }
    }

    private func storedLabel(_ table: String, _ column: String, _ id: String) -> String {
        guard let database = ruleDatabase else { return "" }
        let label = try? database.read { db in
            try String.fetchOne(db, sql: "SELECT \(column) FROM \(table) WHERE id = ?", arguments: [id])
        }
        return label ?? ""
    }

    private func stored(_ table: String, _ id: String) -> Bool? {
        guard let database = ruleDatabase else { return nil }
        return try? database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE id = ?)", arguments: [id]) ?? false
        }
    }

    func rulePlaces(for records: [NativeRuleRecord]) -> RulePlaces {
        var places = RulePlaces()
        places.companionThreadID = veraThreadID
        for conversation in conversations where conversation.id != veraThreadID { places.chats[conversation.id] = conversation.title }
        for project in projects { places.projects[project.id] = project.name }
        for schedule in schedules { places.schedules[schedule.id] = schedule.title }
        var entries = NativeChatToolCatalog.tools(veraAPIConfigured: true, imageConfigured: true, searchConfigured: true)
            .map { (id: $0.id, title: $0.name, hints: [String]()) }
        for declaration in capabilityDeclarations {
            let host = URL(string: declaration.endpoint)?.host ?? ""
            let spoken = declaration.name.replacingOccurrences(of: "_", with: " ")
            entries.removeAll { $0.id == declaration.id }
            entries.append((id: declaration.id, title: declaration.title, hints: [host, spoken, declaration.endpoint].filter { !$0.isEmpty }))
        }
        places.tools = RuleRows.toolNames(entries)
        for record in records where !places.contains(record.scope) && ruleScopeExists(record.scope) != false {
            switch record.scope {
            case .conversation(let id): places.chats[id] = storedLabel("conversations", "title", id)
            case .project(let id): places.projects[id] = storedLabel("projects", "name", id)
            case .schedule(let id): places.schedules[id] = storedLabel("native_schedules", "title", id)
            case .everywhere, .task: break
            }
        }
        if let database = ruleDatabase {
            let tasks = NativeTaskStore(database: database)
            for record in records {
                guard case .task(let id) = record.scope, places.work[id] == nil,
                      let task = try? tasks.get(id), !task.state.isTerminal else { continue }
                let title = Self.workTitle(task.payload)
                places.work[id] = title.isEmpty ? " " : title
            }
        }
        return places
    }

    func ruleRows(now: Date = Date(), calendar: Calendar = .current) -> [RuleRow] {
        let records = ruleRecords
        let chatRules = conversations.filter { !$0.rules.isEmpty }.map { (id: $0.id, rules: $0.rules) }
        return RuleRows.rows(records: records, chatRules: chatRules, places: rulePlaces(for: records), defaults: nativeRules,
                             now: now, calendar: calendar)
    }

    func removeRule(_ row: RuleRow) {
        switch row.source {
        case .saved(let id): revokeRuleRecord(id: id)
        case .chat(let conversationID, let action): clearConversationRule(for: action, conversationID: conversationID)
        }
    }

    func toggleRule(_ row: RuleRow) {
        guard case .saved(let id) = row.source else { return }
        if row.off { enableRuleRecord(id: id) } else { disableRuleRecord(id: id) }
    }

    @discardableResult
    func widenRule(_ row: RuleRow) -> Bool {
        guard case .saved(let id) = row.source, row.widens,
              let record = try? nativeRuleRecordStore?.record(id: id), RuleRows.widens(record) else { return false }
        return updateRuleRecord(id: id) { $0.scope = .everywhere } != nil
    }

    func removeRules(for scope: NativeRuleScope) {
        guard scope != .everywhere, let store = nativeRuleRecordStore else { return }
        var changed = false
        for record in ((try? store.all()) ?? []) where record.scope == scope && record.status != .revoked {
            if (try? store.revoke(id: record.id)) == true { changed = true }
        }
        guard changed else { return }
        reloadRuleRecords()
        announceRuleChange()
    }

    @discardableResult
    func sweepRuleRecords() -> Int {
        guard let store = nativeRuleRecordStore, let records = try? store.all() else { return 0 }
        var removed = 0
        for id in RuleRows.leftBehind(records, exists: { ruleScopeExists($0) }) where (try? store.revoke(id: id)) == true { removed += 1 }
        guard removed > 0 else { return 0 }
        reloadRuleRecords()
        announceRuleChange()
        return removed
    }
}
