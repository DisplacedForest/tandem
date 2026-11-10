import Foundation

final class NativeToolAccessFixtureService: NativeRemindersService, @unchecked Sendable {
    private let lock = NSLock()
    private var state: NativeRemindersAuthorization
    private var asked = 0
    private let grants: Bool

    init(_ state: NativeRemindersAuthorization, grants: Bool = false) {
        self.state = state
        self.grants = grants
    }

    var requests: Int { lock.withLock { asked } }
    var nativeAuthorization: NativeRemindersAuthorization { lock.withLock { state } }

    func nativeRequestAccess() async -> Bool {
        lock.withLock {
            asked += 1
            state = grants ? .authorized : .denied
            return grants
        }
    }

    func nativeLists() async throws -> [NativeReminderList] { [NativeReminderList(id: "errands", name: "Errands")] }
    func nativeReminders(list: String?, completed: Bool) async throws -> [NativeReminder] { [] }
    func nativeCreateReminder(list: String, title: String, notes: String?, due: String?) async throws -> NativeReminder {
        throw NativeToolError.unavailable
    }
    func nativeCompleteReminder(id: String) async throws -> NativeReminder { throw NativeToolError.unavailable }
}

@MainActor
extension SelfTest {
    static func runToolSystemAccess() async throws {
        let require = NativeTaskFixture.require
        let reminderNames = Set(NativeRemindersTools.definitions(service: NativeToolAccessFixtureService(.authorized)).map(\.name))
        let privateWords = reminderNames.union(["apple-reminders", "APP POLICY", "TOOLS", "NOT AVAILABLE", "isAvailable", NativeContextAssembler.policyHeading,
            NativeContextAssembler.toolsHeading, NativeContextAssembler.unavailableHeading, NativeContextAssembler.sessionHeading])

        func store(_ service: NativeToolAccessFixtureService, enabled: Set<String> = [NativeRemindersTools.toolID, "contacts"],
                   contacts: NativeSystemAccess = .granted, repository: LocalChatRepository? = nil,
                   transport: NativeSessionFixtureTransport) throws -> ChatStore {
            var lookup = NativeToolDefinition(id: "contacts", name: "contacts_lookup", title: "Look up a contact",
                description: "Find a contact by name", parameters: .object(["type": .string("object")]),
                confirmation: .none, effect: .read, isAvailable: { contacts == .granted }, execute: { _ in .object([:]) })
            lookup.access = NativeToolAccess(subject: "Contacts", settingsPane: nil, state: { contacts }, request: { false })
            let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport,
                repository: try repository ?? LocalChatRepository(inMemory: true), nativeEnabledToolIDs: enabled,
                nativeToolRegistry: NativeToolRegistry(definitions: NativeRemindersTools.definitions(service: service) + [lookup]),
                artifactPersistenceEnabled: false)
            store.asksForSystemAccess = true
            return store
        }
        func ask(_ store: ChatStore, _ text: String) async throws {
            store.newConversation()
            try require(store.sendText(text), "The request is accepted")
            try await NativeSessionFixture.eventually("The reply completes") {
                store.selected?.messages.last?.role == .assistant && store.selected?.messages.last?.state == .complete
            }
        }
        func prompt(_ transport: NativeSessionFixtureTransport) -> String { transport.histories.last?.first { $0.role == "system" }?.content ?? "" }
        func offered(_ transport: NativeSessionFixtureTransport) -> Set<String> { Set((transport.schemas.last ?? []).map(\.name)) }
        func clean(_ note: String) -> Bool { privateWords.allSatisfy { !note.contains($0) } }

        let access = NativeRemindersTools.definitions(service: NativeToolAccessFixtureService(.denied))[0].access
        for state in [NativeSystemAccess.notAsked, .refused] {
            let note = access?.note(state) ?? ""
            let status = access?.status(state)
            try require(!note.isEmpty && clean(note) && clean(status?.line ?? "-") && clean(status?.action ?? "-") && note.contains("Reminders"),
                        "The note and the Settings line for \(state) name Reminders in plain words and nothing internal")
        }
        try require(access?.note(.granted) == nil && access?.status(.granted) == nil && access?.settingsPane != nil,
                    "Granted access shows nothing extra, and the refused state has a System Settings pane to open")

        let refused = NativeToolAccessFixtureService(.denied)
        let refusedTransport = NativeSessionFixtureTransport()
        let refusedStore = try store(refused, transport: refusedTransport)
        try await ask(refusedStore, "Add milk to my reminders")
        let refusedPrompt = prompt(refusedTransport)
        try require(refusedPrompt.contains("Tandem doesn't have access to Reminders on this Mac")
                        && refusedPrompt.contains("System Settings, Privacy & Security, Reminders"),
                    "A turn with Reminders switched on and access refused tells the model why and what the person should do")
        try require(offered(refusedTransport).isDisjoint(with: reminderNames) && offered(refusedTransport).contains("contacts_lookup"),
                    "Tools that can't run are not offered, and other tools still are")
        try require(refused.requests == 0, "Refused access is never asked for again by the app")

        let granted = NativeToolAccessFixtureService(.authorized)
        let grantedTransport = NativeSessionFixtureTransport()
        let grantedStore = try store(granted, transport: grantedTransport)
        try await ask(grantedStore, "Add milk to my reminders")
        try require(reminderNames.isSubset(of: offered(grantedTransport)) && !prompt(grantedTransport).contains("access to Reminders") && granted.requests == 0,
                    "With access granted the tools are offered, there is no note and nothing is asked")

        let off = NativeToolAccessFixtureService(.notDetermined)
        let offTransport = NativeSessionFixtureTransport()
        let offStore = try store(off, enabled: ["contacts"], transport: offTransport)
        offStore.requestSystemAccess()
        try await ask(offStore, "Add milk to my reminders")
        try require(off.requests == 0 && !prompt(offTransport).contains("access to Reminders"),
                    "A tool that is switched off is never asked for and gets no note")

        let fresh = NativeToolAccessFixtureService(.notDetermined)
        let freshTransport = NativeSessionFixtureTransport()
        let freshStore = try store(fresh, transport: freshTransport)
        for task in freshStore.requestSystemAccess() { _ = await task.value }
        try require(fresh.requests == 1, "Access that was never asked for is asked for at launch")
        freshStore.requestSystemAccess()
        try await ask(freshStore, "Add milk to my reminders")
        try require(fresh.requests == 1, "It is asked once per launch, not again for each message")

        let typed = NativeToolAccessFixtureService(.notDetermined, grants: true)
        let typedTransport = NativeSessionFixtureTransport()
        let typedStore = try store(typed, transport: typedTransport)
        try await ask(typedStore, "Add milk to my reminders")
        try await NativeSessionFixture.eventually("The typed turn asks for access") { typed.requests == 1 }
        try await ask(typedStore, "Add milk to my reminders")
        try require(typed.requests == 1 && reminderNames.isSubset(of: offered(typedTransport)) && !prompt(typedTransport).contains("access to Reminders"),
                    "Once the person allows it, the next message has the tools and no note")

        let quiet = NativeToolAccessFixtureService(.notDetermined)
        let quietTransport = NativeSessionFixtureTransport()
        let quietStore = try store(quiet, transport: quietTransport)
        quietStore.asksForSystemAccess = false
        quietStore.requestSystemAccess()
        try await ask(quietStore, "Add milk to my reminders")
        try require(quiet.requests == 0 && prompt(quietTransport).contains("hasn't been given access to Reminders on this Mac yet")
                        && !prompt(quietTransport).contains("is asking the person now"),
                    "Outside the real app nothing asks macOS, and the note says access hasn't been given without claiming a prompt is on screen")

        let other = NativeToolAccessFixtureService(.authorized)
        let otherTransport = NativeSessionFixtureTransport()
        let otherStore = try store(other, contacts: .refused, transport: otherTransport)
        try await ask(otherStore, "Find Sam's number")
        try require(prompt(otherTransport).contains("Tandem doesn't have access to Contacts on this Mac") && !offered(otherTransport).contains("contacts_lookup")
                        && otherStore.toolAccess("contacts")?.status(.refused)?.line == "Tandem doesn't have access to Contacts.",
                    "A second tool with a system requirement gets the same note and the same Settings line")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tool-access-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let companion = NativeToolAccessFixtureService(.notDetermined)
        let companionTransport = NativeSessionFixtureTransport()
        let companionStore = try store(companion, repository: LocalChatRepository(url: directory.appendingPathComponent("history.sqlite")),
                                       transport: companionTransport)
        await companionStore.connect()
        companionStore.openVeraThread()
        try await NativeSessionFixture.eventually("The companion's opening completes") {
            companionStore.selected?.messages.last?.role == .assistant && companionStore.selected?.messages.last?.state == .complete
        }
        try require(companion.requests == 0, "A turn the companion starts on its own never asks macOS for access")
        print("  tool system access OK (plain notes, refused, granted, switched off, asked at launch once, asked on a typed turn, never outside the app, a second tool, never for a companion-started turn)")
    }
}
