import AppKit
import SwiftUI

@MainActor
final class EndpointEditorFixtureDisk {
    var contents: [String: Any] = [:]
    var writes: [[String: Any]] = []
}

@MainActor
extension SelfTest {
    static func runEndpointEditor() throws {
        let require = NativeTaskFixture.require
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("endpoint-editor-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil,
                             attachmentStore: NativeAttachmentStore(directory: directory))

        func makeConfig(_ disk: EndpointEditorFixtureDisk) -> ConfigStore {
            ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents },
                        nativeMCP: NativeMCPManager(servers: []),
                        writeConfiguration: { disk.contents = $0; disk.writes.append($0) })
        }

        func host<Content: View>(_ view: Content, config: ConfigStore) {
            let root = view.environmentObject(config).environmentObject(chat).frame(width: 640, height: 640)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 640)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            hosting.layoutSubtreeIfNeeded()
            window.contentView = nil
        }

        func hasEndpoint(_ written: [String: Any]) -> Bool {
            let profiles = (written["native_chat"] as? [String: Any])?["profiles"] as? [Any] ?? []
            return written["model_base"] != nil || !profiles.isEmpty
        }

        let settingsDisk = EndpointEditorFixtureDisk()
        let settings = makeConfig(settingsDisk)
        host(ConnectionTab(), config: settings)
        try require(settings.nativeSettings.profiles.isEmpty && settings.nativeSettings.activeProfileID == nil,
                    "Opening the Endpoints tab adds no endpoint")
        try settings.save()
        try require(settingsDisk.writes.count == 1 && !hasEndpoint(settingsDisk.contents),
                    "Saving from Settings after visiting Endpoints writes no endpoint and no model address")
        settings.addNativeProfile()
        try require(settings.nativeSettings.profiles.count == 1
                    && settings.nativeSettings.activeProfileID == settings.nativeSettings.profiles.first?.id,
                    "Add endpoint adds exactly one active endpoint")
        try settings.save()
        try require(settingsDisk.contents["model_base"] as? String == "",
                    "An endpoint added by hand in Settings and left blank still saves")

        let guideDisk = EndpointEditorFixtureDisk()
        guideDisk.contents = ["native_chat": ["onboardingState": "inProgress", "onboardingStep": 0]]
        let guide = makeConfig(guideDisk)
        host(NativeEndpointEditor(addsOnEntry: true), config: guide)
        try require(guide.nativeSettings.profiles.count == 1 && guide.nativeSettings.activeProfileID != nil,
                    "The setup guide shows a new endpoint on entry")
        try require(guideDisk.writes.isEmpty, "Entering the setup guide writes nothing")
        guide.skipOnboarding()
        try require(guide.nativeSettings.profiles.isEmpty && guide.nativeSettings.activeProfileID == nil,
                    "Skipping the guide before an address is typed drops the untouched endpoint")
        try require(guideDisk.writes.count == 1 && !hasEndpoint(guideDisk.contents)
                    && (guideDisk.contents["native_chat"] as? [String: Any])?["onboardingState"] as? String == "skipped",
                    "Skipping the guide records the skip without an empty endpoint")

        let firstRunDisk = EndpointEditorFixtureDisk()
        let firstRun = makeConfig(firstRunDisk)
        try require(firstRun.showOnboarding, "An empty configuration opens the setup guide")
        host(OnboardingSheet(), config: firstRun)
        try require(firstRun.nativeSettings.profiles.count == 1, "The real setup guide shows a new endpoint on entry")
        try require(!firstRunDisk.writes.isEmpty && !firstRunDisk.writes.contains(where: hasEndpoint),
                    "Opening the setup guide for the first time records its start and writes no empty endpoint")
        firstRun.skipOnboarding()
        try require(firstRun.nativeSettings.profiles.isEmpty && !firstRunDisk.writes.contains(where: hasEndpoint),
                    "Closing the first-run guide without an address writes no endpoint")

        let typedDisk = EndpointEditorFixtureDisk()
        let typed = makeConfig(typedDisk)
        host(NativeEndpointEditor(addsOnEntry: true), config: typed)
        typed.activeProfileBinding(\.baseURL).wrappedValue = "https://models.example/v1"
        typed.discardUntouchedEntryProfile()
        typed.updateOnboarding(step: 1)
        try require(typed.nativeSettings.profiles.count == 1
                    && typedDisk.contents["model_base"] as? String == "https://models.example/v1",
                    "Continuing with an address saves the endpoint")
        typed.skipOnboarding()
        try require(typed.nativeSettings.profiles.count == 1
                    && typedDisk.contents["model_base"] as? String == "https://models.example/v1",
                    "Skipping later keeps an endpoint that has an address")

        let namedDisk = EndpointEditorFixtureDisk()
        let named = makeConfig(namedDisk)
        host(NativeEndpointEditor(addsOnEntry: true), config: named)
        named.activeProfileBinding(\.name).wrappedValue = "Studio"
        named.skipOnboarding()
        try require(named.nativeSettings.profiles.count == 1, "An endpoint the person named is kept")

        let draftDisk = EndpointEditorFixtureDisk()
        let draft = makeConfig(draftDisk)
        host(NativeEndpointEditor(addsOnEntry: true), config: draft)
        try draft.save()
        try require(draft.nativeSettings.profiles.count == 1 && draftDisk.writes.count == 1 && !hasEndpoint(draftDisk.contents),
                    "A save from elsewhere while the guide is open keeps the untouched endpoint on screen and off disk")
        let reopened = makeConfig(draftDisk)
        try require(reopened.nativeSettings.profiles.isEmpty, "Reopening after that save finds no endpoint")
        draft.activeProfileBinding(\.baseURL).wrappedValue = "https://models.example/v1"
        try draft.save()
        try require(draftDisk.contents["model_base"] as? String == "https://models.example/v1",
                    "Once an address is typed the same save writes the endpoint")

        let keyDisk = EndpointEditorFixtureDisk()
        let keyStore = NativeCredentialFixtureStore()
        let keyed = ConfigStore(credentialStore: keyStore, readConfiguration: { keyDisk.contents },
                                nativeMCP: NativeMCPManager(servers: []),
                                writeConfiguration: { keyDisk.contents = $0; keyDisk.writes.append($0) })
        host(NativeEndpointEditor(addsOnEntry: true), config: keyed)
        let keyedID = keyed.nativeSettings.activeProfileID ?? ""
        keyed.apiKeyBinding().wrappedValue = "synthetic-key"
        try keyed.save()
        try require(keyStore.values[keyedID] == "synthetic-key" && hasEndpoint(keyDisk.contents),
                    "An endpoint with only a key saves with its key")
        keyed.apiKeyBinding().wrappedValue = ""
        keyed.skipOnboarding()
        try require(keyed.nativeSettings.profiles.isEmpty && !hasEndpoint(keyDisk.contents) && keyStore.values[keyedID] == nil,
                    "Clearing the key and skipping drops the endpoint and removes its stored key")

        let savedDisk = EndpointEditorFixtureDisk()
        savedDisk.contents = ["native_chat": ["profiles": [["id": "saved", "name": "Home", "baseURL": "https://models.example/v1",
                                                             "discoveredModels": [String](), "selectedModel": ""]],
                                              "activeProfileID": "saved"]]
        let saved = makeConfig(savedDisk)
        try require(saved.nativeSettings.profiles.map(\.id) == ["saved"], "The saved endpoint fixture loads")
        host(ConnectionTab(), config: saved)
        host(NativeEndpointEditor(addsOnEntry: true), config: saved)
        try require(saved.nativeSettings.profiles.map(\.id) == ["saved"] && saved.nativeSettings.activeProfileID == "saved"
                    && savedDisk.writes.isEmpty, "A saved endpoint is never joined by another on entry")
        saved.skipOnboarding()
        try require(saved.nativeSettings.profiles.map(\.id) == ["saved"], "Skipping keeps a saved endpoint")

        print("  endpoint editor OK (no endpoint on entry in Settings, guide entry, skip and continue, saves while the guide is open, stored keys, saved endpoints)")
    }
}
