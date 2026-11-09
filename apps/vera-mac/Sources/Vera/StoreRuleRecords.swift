import Foundation
import OSLog

extension ChatStore {
    var nativeRuleRecordStore: NativeRuleRecordStore? {
        (repository as? LocalChatRepository).map { NativeRuleRecordStore(database: $0.database) }
    }

    func prepareRuleRecords() {
        guard let store = nativeRuleRecordStore else { return }
        let launch = NativeRuleSource.launchEpoch(now: Date()) { try store.advanceEpoch() }
        if launch.fellBack {
            Logger(subsystem: "Vera", category: "rules").error("rules_epoch_fallback \(launch.epoch, privacy: .public)")
        }
        nativeRuleSource.setEpoch(launch.epoch)
        _ = try? store.expireDue()
        reloadRuleRecords()
    }

    func reloadRuleRecords() {
        guard let store = nativeRuleRecordStore else { return }
        Self.reloadRules(nativeRuleSource, from: store)
    }

    nonisolated static func reloadRules(_ source: NativeRuleSource, from store: NativeRuleRecordStore) {
        do {
            source.setRecords(try store.active())
        } catch {
            Logger(subsystem: "Vera", category: "rules").error("rules_reload_failed \(error.localizedDescription, privacy: .public)")
            source.restrictRecords()
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
