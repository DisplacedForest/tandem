import Foundation
import OSLog

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

    @discardableResult
    func addRuleRecord(_ record: NativeRuleRecord) -> NativeRuleRecord? {
        guard let store = nativeRuleRecordStore, let saved = try? store.add(record) else { return nil }
        reloadRuleRecords()
        return saved
    }

    @discardableResult
    func updateRuleRecord(id: String, _ mutate: (inout NativeRuleRecord) -> Void) -> NativeRuleRecord? {
        guard let store = nativeRuleRecordStore, let saved = try? store.update(id: id, mutate) else { return nil }
        reloadRuleRecords()
        return saved
    }

    @discardableResult
    func disableRuleRecord(id: String) -> Bool {
        guard let store = nativeRuleRecordStore, (try? store.disable(id: id)) == true else { return false }
        reloadRuleRecords()
        return true
    }

    @discardableResult
    func enableRuleRecord(id: String) -> Bool {
        guard let store = nativeRuleRecordStore, (try? store.enable(id: id)) == true else { return false }
        reloadRuleRecords()
        return true
    }

    @discardableResult
    func revokeRuleRecord(id: String) -> Bool {
        guard let store = nativeRuleRecordStore, (try? store.revoke(id: id)) == true else { return false }
        reloadRuleRecords()
        return true
    }
}
