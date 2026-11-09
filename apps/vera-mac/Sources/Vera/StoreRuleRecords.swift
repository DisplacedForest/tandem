import Foundation

extension ChatStore {
    var nativeRuleRecordStore: NativeRuleRecordStore? {
        (repository as? LocalChatRepository).map { NativeRuleRecordStore(database: $0.database) }
    }

    func prepareRuleRecords() {
        guard let store = nativeRuleRecordStore else { return }
        if let epoch = try? store.advanceEpoch() { nativeRuleSource.setEpoch(epoch) }
        _ = try? store.expireDue()
        reloadRuleRecords()
    }

    func reloadRuleRecords() {
        guard let store = nativeRuleRecordStore, let active = try? store.active() else { return }
        nativeRuleSource.setRecords(active)
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
