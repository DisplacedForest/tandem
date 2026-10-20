import Foundation
import Security
import LocalAuthentication

final class NativeCredentialFixtureContext: LAContext {
    var refusesInteractionFlag = false
    private var disabled = false
    override var interactionNotAllowed: Bool {
        get { disabled }
        set { if !refusesInteractionFlag { disabled = newValue } }
    }
}

final class NativeCredentialFixtureStore: NativeCredentialStore {
    var values: [String: String] = [:]
    var denied: Set<String> = []
    var failWrites = false
    var writes: [String] = []
    var reads: [String] = []
    var startupReads: [String] = []

    func read(for profileID: String) throws -> String? {
        reads.append(profileID)
        if denied.contains(profileID) { throw NativeCredentialError.read }
        return values[profileID]
    }

    @MainActor func readForStartup(for profileID: String) throws -> String? {
        startupReads.append(profileID)
        return try read(for: profileID)
    }

    func set(_ value: String?, for profileID: String) throws {
        if failWrites { throw NativeCredentialError.write }
        writes.append(value == nil ? "remove" : "update")
        values[profileID] = value
    }

    func addIfAbsent(_ value: String, for profileID: String) throws {
        if failWrites { throw NativeCredentialError.write }
        if values[profileID] != nil { throw NativeCredentialError.migrationConflict }
        writes.append("add")
        values[profileID] = value
    }
}

@MainActor
enum NativeCredentialLifecycleFixture {
    static func run() throws {
        try lifecycle()
        try deniedReads()
        try migration()
        try keychainOperations()
        try startupInteraction()
        print("NATIVE CREDENTIAL LIFECYCLE FIXTURE OK")
    }

    static func configuration() -> [String: Any] {
        var settings = NativeChatSettings.fresh
        settings.profiles = [NativeEndpointProfile(id: "fixture-profile", name: "Fixture", baseURL: "https://model.example/v1",
            discoveredModels: [], selectedModel: "fixture-model", selectionBasis: .user, lastDiscoveryAt: nil)]
        settings.activeProfileID = "fixture-profile"
        return settings.merging(into: [:])
    }

    static func expectFailure(_ operation: () throws -> Void) throws {
        do { try operation() }
        catch is NativeCredentialError { return }
        throw NativeTaskFixture.Failure.assertion("Expected a sanitized credential failure")
    }

    static func lifecycle() throws {
        let credentials = NativeCredentialFixtureStore()
        credentials.values = ["fixture-profile": "synthetic-initial", ConfigStore.visionBridgeCredentialID: "synthetic-bridge"]
        let raw = configuration()
        var persisted: [[String: Any]] = []
        var failConfiguration = false
        let config = ConfigStore(credentialStore: credentials, readConfiguration: { raw }, writeConfiguration: {
            if failConfiguration { throw NativeToolError.failed("Synthetic configuration failure") }
            persisted.append($0)
        })
        try NativeTaskFixture.require(credentials.writes.isEmpty && persisted.isEmpty,
            "Startup must not write either Keychain or configuration")
        config["appearance"] = "dark"
        config.apiKeyBinding().wrappedValue = "synthetic-initial"
        config.visionBridgeAPIKey = "synthetic-bridge"
        try config.save()
        try NativeTaskFixture.require(credentials.writes.isEmpty && persisted.count == 1,
            "Unchanged keys and unrelated settings must not replace credential items")
        config.apiKeyBinding().wrappedValue = "synthetic-edited"
        try config.save()
        try config.save()
        try NativeTaskFixture.require(credentials.writes == ["update"], "Explicit edits persist once")
        config.apiKeyBinding().wrappedValue = "temporary-edit"
        config.apiKeyBinding().wrappedValue = "synthetic-edited"
        try config.save()
        try NativeTaskFixture.require(credentials.writes == ["update"], "Reverting an unsaved edit is a no-op")
        config.apiKeyBinding().wrappedValue = ""
        try config.save()
        try NativeTaskFixture.require(credentials.writes == ["update", "remove"], "Only explicit clearing removes a key")
        config.visionBridgeAPIKey = "synthetic-bridge-edited"
        credentials.failWrites = true
        let before = persisted.count
        try expectFailure { try config.save() }
        try NativeTaskFixture.require(config.credentialError != nil && persisted.count == before,
            "Credential failure must surface and must not claim settings were persisted")
        credentials.failWrites = false
        config["appearance"] = "light"
        try config.save()
        try NativeTaskFixture.require(credentials.values[ConfigStore.visionBridgeCredentialID] == "synthetic-bridge-edited"
            && credentials.writes == ["update", "remove", "update"] && config.credentialError == nil,
            "A failed bridge edit survives until its successful retry")
        config.visionBridgeAPIKey = ""
        try config.save()
        try NativeTaskFixture.require(credentials.values[ConfigStore.visionBridgeCredentialID] == nil,
            "Explicit bridge removal follows the same lifecycle")
        config.apiKeyBinding().wrappedValue = "synthetic-final"
        failConfiguration = true
        do {
            try config.save()
            throw NativeTaskFixture.Failure.assertion("Configuration failure should propagate")
        } catch is NativeToolError {}
        let written = credentials.writes.count
        failConfiguration = false
        try config.save()
        try NativeTaskFixture.require(credentials.values["fixture-profile"] == "synthetic-final" && credentials.writes.count == written,
            "Retrying a configuration failure must not rewrite a credential that already persisted")
    }

    static func deniedReads() throws {
        let credentials = NativeCredentialFixtureStore()
        credentials.values = ["fixture-profile": "synthetic-protected", ConfigStore.visionBridgeCredentialID: "synthetic-protected-bridge"]
        credentials.denied = Set(credentials.values.keys)
        let raw = configuration()
        let config = ConfigStore(credentialStore: credentials, readConfiguration: { raw }, writeConfiguration: { _ in })
        try NativeTaskFixture.require(config.credentialError != nil && config.activeNativeAPIKey.isEmpty,
            "Read failure must be distinguishable from an absent credential")
        config["appearance"] = "dark"
        try config.save()
        try NativeTaskFixture.require(credentials.writes.isEmpty && credentials.values.count == 2,
            "Unavailable keys must survive startup and unrelated settings saves")
        config.apiKeyBinding().wrappedValue = "synthetic-replacement"
        try config.save()
        try NativeTaskFixture.require(credentials.values["fixture-profile"] == "synthetic-replacement"
            && credentials.values[ConfigStore.visionBridgeCredentialID] == "synthetic-protected-bridge",
            "Explicit editing authorizes only that credential change")
    }

    static func migration() throws {
        var raw = configuration()
        raw["model_api_key"] = "synthetic-legacy"
        let credentials = NativeCredentialFixtureStore()
        var persisted: [[String: Any]] = []
        let config = ConfigStore(credentialStore: credentials, readConfiguration: { raw }, writeConfiguration: { persisted.append($0) })
        try NativeTaskFixture.require(credentials.writes.isEmpty && persisted.isEmpty, "Legacy migration is deferred until Save")
        try config.save()
        try NativeTaskFixture.require(credentials.writes == ["add"] && persisted.last?["model_api_key"] == nil,
            "A confirmed absent legacy credential is added before plaintext is removed from configuration")
        let denied = NativeCredentialFixtureStore()
        denied.denied = ["fixture-profile"]
        let blocked = ConfigStore(credentialStore: denied, readConfiguration: { raw }, writeConfiguration: { _ in
            throw NativeTaskFixture.Failure.assertion("Denied legacy migration must not rewrite configuration")
        })
        try expectFailure { try blocked.save() }
        try NativeTaskFixture.require(denied.writes.isEmpty, "Denied reads must never authorize migration over an existing item")
        let raced = NativeCredentialFixtureStore()
        let pending = ConfigStore(credentialStore: raced, readConfiguration: { raw }, writeConfiguration: { _ in
            throw NativeTaskFixture.Failure.assertion("Migration conflict must preserve original configuration")
        })
        raced.values["fixture-profile"] = "synthetic-concurrent"
        try expectFailure { try pending.save() }
        try NativeTaskFixture.require(raced.values["fixture-profile"] == "synthetic-concurrent" && raced.writes.isEmpty,
            "Migration must not overwrite an item created after the initial read")
    }

    static func startupInteraction() throws {
        var reads = 0
        var prohibitedInteraction = 0
        var writes = 0
        var interactionAllowed = true
        var forceReadbackFailure = false
        var refuseDisable = false
        var readStatus = errSecInteractionNotAllowed
        var refuseContext = false
        let operations = NativeKeychainOperations(authenticationContext: {
            let context = NativeCredentialFixtureContext()
            context.refusesInteractionFlag = refuseContext
            return context
        }, interactionAllowed: {
            (errSecSuccess, forceReadbackFailure ? true : interactionAllowed)
        }, setInteraction: { allowed in
            if !allowed && refuseDisable { return errSecAuthFailed }
            interactionAllowed = allowed
            return errSecSuccess
        }, read: { query, result in
            reads += 1
            let context = (query as NSDictionary)[kSecUseAuthenticationContext] as? LAContext
            if context?.interactionNotAllowed == true {
                prohibitedInteraction += 1
                guard !interactionAllowed,
                      (query as NSDictionary)[kSecUseAuthenticationUI] as? String == kSecUseAuthenticationUIFail as String else {
                    return errSecAuthFailed
                }
                result?.pointee = Data("synthetic-startup-read".utf8) as CFData
                return readStatus
            }
            result?.pointee = Data("synthetic-explicit-read".utf8) as CFData
            return errSecSuccess
        }, update: { _, _ in writes += 1; return errSecSuccess },
           add: { _, _ in writes += 1; return errSecSuccess }, delete: { _ in writes += 1; return errSecSuccess })
        let credentials = KeychainNativeCredentialStore(operations: operations)
        let raw = configuration()
        let config = ConfigStore(credentialStore: credentials, readConfiguration: { raw }, writeConfiguration: { _ in })
        try NativeTaskFixture.require(reads == 2 && prohibitedInteraction == 2 && writes == 0,
            "Every startup credential read must prohibit interaction without changing saved items")
        try NativeTaskFixture.require(config.credentialError != nil && config.activeNativeAPIKey.isEmpty,
            "Denied startup access must return an unavailable state so the application can open")
        config["appearance"] = "dark"
        try config.save()
        try NativeTaskFixture.require(writes == 0, "An unavailable startup credential must survive unrelated settings saves")
        try NativeTaskFixture.require(try credentials.read(for: "fixture-profile") == "synthetic-explicit-read"
            && prohibitedInteraction == 2 && credentials.allowsInteraction,
            "Startup read policy must not mutate the existing explicit credential path")
        try NativeTaskFixture.require(interactionAllowed, "Denied startup reads must restore the prior process policy")
        readStatus = errSecSuccess
        try NativeTaskFixture.require(try credentials.readForStartup(for: "fixture-profile") == "synthetic-startup-read" && interactionAllowed,
            "Successful startup reads must restore interaction policy")
        interactionAllowed = false
        _ = try credentials.readForStartup(for: "fixture-profile")
        try NativeTaskFixture.require(!interactionAllowed, "An initially noninteractive process must remain noninteractive")
        interactionAllowed = true
        refuseDisable = true
        let before = reads
        try expectFailure { _ = try credentials.readForStartup(for: "fixture-profile") }
        try NativeTaskFixture.require(reads == before && interactionAllowed, "Failed suppression must refuse before any item read")
        refuseDisable = false
        forceReadbackFailure = true
        try expectFailure { _ = try credentials.readForStartup(for: "fixture-profile") }
        try NativeTaskFixture.require(reads == before && interactionAllowed, "Unverified suppression must refuse and restore without reading")
        forceReadbackFailure = false
        refuseContext = true
        try expectFailure { _ = try credentials.readForStartup(for: "fixture-profile") }
        try NativeTaskFixture.require(reads == before && interactionAllowed, "An unverified authentication context must refuse before item access and restore")
    }

    static func keychainOperations() throws {
        var calls: [String] = []
        var updateStatus = errSecSuccess
        var addStatus = errSecSuccess
        var deleteStatus = errSecSuccess
        var readStatus = errSecSuccess
        var readValue: CFTypeRef = Data("synthetic-read".utf8) as CFData
        var checkedContext = false
        var onlyValueUpdated = false
        let operations = NativeKeychainOperations(authenticationContext: { NativeCredentialFixtureContext() }, read: { query, result in
            calls.append("read")
            let dictionary = query as NSDictionary
            checkedContext = (dictionary[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed == true
            result?.pointee = readValue
            return readStatus
        }, update: { _, attributes in
            calls.append("update")
            let dictionary = attributes as NSDictionary
            onlyValueUpdated = dictionary.count == 1 && dictionary[kSecValueData] is Data
            return updateStatus
        }, add: { _, _ in calls.append("add"); return addStatus }, delete: { _ in calls.append("delete"); return deleteStatus })
        let store = KeychainNativeCredentialStore(allowsInteraction: false, operations: operations)
        try NativeTaskFixture.require(try store.read(for: "fixture-profile") == "synthetic-read" && checkedContext,
            "Noninteractive reads must retain the existing no-prompt authentication context")
        for malformed: CFTypeRef in [Data([0xff]) as CFData, "synthetic-invalid-type" as CFString] {
            readValue = malformed
            do {
                _ = try store.read(for: "fixture-profile")
                throw NativeTaskFixture.Failure.assertion("Malformed data must fail")
            } catch NativeCredentialError.format {}
        }
        readStatus = errSecItemNotFound
        try NativeTaskFixture.require(try store.read(for: "fixture-profile") == nil, "Only item-not-found is absence")
        readStatus = errSecAuthFailed
        try expectFailure { _ = try store.read(for: "fixture-profile") }
        calls = []
        try store.set("synthetic-update", for: "fixture-profile")
        try NativeTaskFixture.require(calls == ["update"] && onlyValueUpdated,
            "In-place writes must update only value data and preserve item access attributes")
        calls = []
        updateStatus = errSecItemNotFound
        try store.set("synthetic-new", for: "fixture-profile")
        try NativeTaskFixture.require(calls == ["update", "add"], "Add is allowed only after item-not-found")
        calls = []
        updateStatus = errSecAuthFailed
        try expectFailure { try store.set("synthetic-denied", for: "fixture-profile") }
        try NativeTaskFixture.require(calls == ["update"], "Denied update must not fall back to delete or add")
        calls = []
        deleteStatus = errSecAuthFailed
        try expectFailure { try store.set(nil, for: "fixture-profile") }
        try NativeTaskFixture.require(calls == ["delete"], "Removal errors must propagate without recreating the item")
        calls = []
        updateStatus = errSecItemNotFound
        addStatus = errSecAuthFailed
        try expectFailure { try store.set("synthetic-new", for: "fixture-profile") }
        try NativeTaskFixture.require(calls == ["update", "add"], "Add errors must propagate without deleting anything")
    }
}
