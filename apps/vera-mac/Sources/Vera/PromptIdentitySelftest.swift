import Foundation

@MainActor
enum PromptIdentitySelftest {
    static let builtIn = "Ver" + "a"
    static let fixed = Date(timeIntervalSince1970: 1_786_000_000)
    static let zone = TimeZone(identifier: "America/Chicago")!

    static func run() async throws {
        let require = NativeTaskFixture.require
        try migration(require)
        try naming(require)
        try composition(require)
        try missingService(require)
        try await preview(require)
        try await companionWork(require)
        print("PROMPT IDENTITY SELFTEST OK")
    }

    static func occurrences(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    static func migration(_ require: (Bool, String) throws -> Void) throws {
        let repository = try LocalChatRepository(inMemory: true)
        let old = PromptProfile.fresh(name: builtIn, scope: .persona, content: NativePromptMigration.retiredBuiltInPersona + "\n")
        let renamed = PromptProfile.fresh(name: "Work", scope: .persona, content: NativePromptMigration.retiredBuiltInPersona)
        let custom = PromptProfile.fresh(name: "Brief", scope: .persona, content: "You are " + builtIn + ". Answer in as few words as accuracy allows.")
        for profile in [old, renamed, custom] { try repository.migratePromptProfile(profile) }
        var settings = NativeChatSettings.fresh
        settings.systemPrompt = NativePromptMigration.retiredBuiltInPersona
        settings.activePersonaID = old.id
        try require(try NativePromptMigration.run(repository: repository, settings: &settings), "The retired built-in persona is replaced")
        let migrated = try repository.promptProfile(old.id)
        try require(migrated?.name == "Default" && migrated?.content == NativeChatSettings.defaultSystemPrompt,
                    "The retired built-in persona becomes Default with the current default text")
        let kept = try repository.promptProfile(renamed.id)
        try require(kept?.name == "Work" && kept?.content == NativeChatSettings.defaultSystemPrompt,
                    "A persona with the retired text keeps a name the user chose")
        let untouched = try repository.promptProfile(custom.id)
        try require(untouched?.name == custom.name && untouched?.content == custom.content, "A custom persona never changes")
        try require(settings.systemPrompt == NativeChatSettings.defaultSystemPrompt && settings.activePersonaID == old.id,
                    "The fallback prompt is replaced and the active persona stays")
        try require(try repository.promptRevisions(entityID: old.id).count == 2, "The replaced text stays in revision history")
        let before = try repository.promptProfiles()
        try require(try NativePromptMigration.run(repository: repository, settings: &settings) == false, "A second run changes nothing")
        try require(try repository.promptProfiles() == before, "A second run leaves every persona as it was")
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativePersonaID: old.id)
        try require(store.resolvePromptScopes(conversationID: nil).persona == NativeChatSettings.defaultSystemPrompt,
                    "The store sends the migrated persona")
    }

    static func missingService(_ require: (Bool, String) throws -> Void) throws {
        let rule = NativeContextAssembler.missingServiceRule
        for companionThread in [false, true] {
            let assembled = NativeContextAssembler.assemble(NativeContextInput(
                persona: "You are a helpful assistant.", timestamp: fixed, timeZone: zone, ownerName: "Riley",
                assistantName: companionThread ? "Wren" : nil, companionThread: companionThread))
            try require(occurrences(rule, in: assembled.prompt) == 1, "Every chat is told once that a missing service can be added in Plugins")
            let policy = assembled.sections.first { $0.name == "policy" }
            try require(policy?.content.contains(rule) == true && policy?.truncated == false, "The rule fits in the policy section")
        }
        let listed = try NativeMCPStarterCatalog.bundled().entries
        try require(!listed.isEmpty && listed.allSatisfy { !rule.localizedCaseInsensitiveContains($0.name) }, "The rule names no plugin")
    }

    static func naming(_ require: (Bool, String) throws -> Void) throws {
        let persona = "You are " + builtIn + ", a helpful assistant."
        let ordinary = NativeContextAssembler.assemble(NativeContextInput(
            persona: persona, timestamp: fixed, timeZone: zone, ownerName: "Riley", assistantName: "Wren")).prompt
        try require(!ordinary.contains("Your name is") && !ordinary.contains("Wren"), "Normal chat is never told a name")
        try require(occurrences(NativeContextAssembler.unnamedRule, in: ordinary) == 1, "Normal chat is told it has no personal name")
        let companion = NativeContextAssembler.assemble(NativeContextInput(
            persona: persona, timestamp: fixed, timeZone: zone, ownerName: "Riley", assistantName: "Wren", companionThread: true)).prompt
        try require(occurrences("Your name is Wren.", in: companion) == 1, "The companion is told its name exactly once")
        try require(companion.contains(NativeContextAssembler.namedRule("Wren")) && !companion.contains(NativeContextAssembler.unnamedRule),
                    "The companion's name overrides any other name in the prompt")
        let unnamed = NativeContextAssembler.assemble(NativeContextInput(
            persona: persona, timestamp: fixed, timeZone: zone, assistantName: "  ", companionThread: true)).prompt
        try require(!unnamed.contains("Your name is") && !unnamed.contains(NativeContextAssembler.unnamedRule),
                    "An unnamed companion gets no name line")
    }

    static func composition(_ require: (Bool, String) throws -> Void) throws {
        let assembled = NativeContextAssembler.assemble(NativeContextInput(
            persona: "Be plain.", userScope: "I like maps.", preferences: ["Keep replies short"],
            timestamp: fixed, timeZone: zone))
        let reply = "Answer the user's question directly and concisely. Use at most two web lookups for current facts, then answer from the evidence or explain what remains uncertain. Only the final user message is the current request. Earlier requests are context, not permission to run their tools again. Respect the current request's tool restrictions. "
            + ChatStore.researchReplyRule + " Do not add progress commentary about other turns to an unrelated answer. "
        let ordinaryRule = "Other accepted turns may still be working; this message does not cancel or change them."
        for instruction in ["", "Do not restart onboarding."] {
            let expected = assembled.prompt + "\n\n" + instruction + "\n\n" + reply + ordinaryRule
            try require(NativeSystemPrompt.compose(assembled: assembled, companionInstruction: instruction) == expected,
                        "The prompt with no per-turn notes matches the earlier formula")
        }
        let talk = "Talk section."
        let full = assembled.prompt + "\n\n" + "Setup." + ("\n\n" + talk) + "\n\nGrant." + "\n\nRevision." + "\n\nPreference." + "\n\n"
            + reply + "Other work." + "\n\nEvent."
        try require(NativeSystemPrompt.compose(assembled: assembled, companionInstruction: "Setup.", talkSection: talk, grantNote: "Grant.",
                                               revisionNote: "Revision.", preferenceNote: "Preference.", otherWorkRule: "Other work.",
                                               companionEventInstruction: "Event.") == full,
                    "The prompt with every per-turn note matches the earlier formula")
    }

    static func fixtureStore(transport: (any NativeChatTransport)? = nil) throws -> ChatStore {
        let store = ChatStore(nativeConfig: transport == nil ? nil : NativeSessionFixture.config, nativeTransport: transport,
                              repository: try LocalChatRepository(inMemory: true), nativeOwnerName: "Riley",
                              nativeAssistantName: "Wren", artifactPersistenceEnabled: false)
        store.ensureVeraThread()
        if let library = store.promptLibrary {
            let persona = PromptProfile.fresh(name: "Default", scope: .persona, content: "You are " + builtIn + ". Be plain.")
            try library.savePromptProfile(persona)
            store.adoptPersona(persona.id)
            try library.savePromptProfile(PromptProfile.fresh(name: "About me", scope: .user, content: "I garden on weekends."))
        }
        try store.nativePreferenceStore?.add(statement: "Keep replies short")
        return store
    }

    static func withoutClock(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { !$0.hasPrefix("Current date and time:") }.joined(separator: "\n")
    }

    static func withoutHandles(_ text: String) -> String {
        text.replacingOccurrences(of: #""item": "[^"]*""#, with: #""item": """#, options: .regularExpression)
    }

    static func preview(_ require: (Bool, String) throws -> Void) async throws {
        let store = try fixtureStore()
        for companion in [false, true] {
            let preview = store.fullPromptPreview(companion: companion, now: fixed, timeZone: zone)
            try require(preview.text == NativeSystemPrompt.compose(assembled: preview.sentInput, companionInstruction: preview.companionInstruction,
                                                                   talkSection: preview.talkSection, grantNote: preview.grantNote,
                                                                   otherWorkRule: preview.otherWorkRule),
                        "The full prompt view joins its parts with the same function the send path uses")
            try require(!preview.text.contains(NativeSystemPrompt.memoryPlaceholder)
                        && preview.parts.contains { $0.name == NativeSystemPrompt.memoryPlaceholderName && !$0.sent },
                        "Memories and library are shown as a line that is never sent")
            try require(preview.text.contains("Be plain.") && preview.text.contains("I garden on weekends.") && preview.text.contains("Keep replies short"),
                        "The full prompt shows the active persona, user context and preferences")
            let titles = FullPromptSheet.blocks(preview.parts).map(\.title)
            for title in ["App rules", "Persona", "User context", "Preferences", "Session", "Memories and library", "Formatting", "Reply instructions"] {
                try require(titles.contains(title), "The full prompt has a \(title) part")
            }
            try require(titles.filter { $0 == "Formatting" }.count == 1, "Formatting parts show together")
            let editable = FullPromptSheet.blocks(preview.parts).compactMap(\.destination)
            try require(editable == [.persona, .userContext, .preferences], "Persona, user context and preferences can be edited from the view")
            if companion {
                try require(occurrences("Your name is Wren.", in: preview.text) == 1 && occurrences("Wren", in: preview.text) == 1
                            && titles.contains("Standing role"),
                            "The companion view names the companion once and shows its standing role")
            } else {
                try require(!preview.text.contains("Your name is") && preview.text.contains(NativeContextAssembler.unnamedRule)
                            && !titles.contains("Standing role"),
                            "The normal chat view has no name and no standing role")
            }
        }
        let empty = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: try LocalChatRepository(inMemory: true))
        let blank = empty.fullPromptPreview(companion: false, now: fixed, timeZone: zone)
        let blankBlocks = FullPromptSheet.blocks(blank.parts)
        try require(blankBlocks.contains { $0.title == "User context" && !$0.sent && $0.destination == .userContext }
                    && blankBlocks.contains { $0.title == "Preferences" && !$0.sent && $0.destination == .preferences },
                    "Empty user context and preferences still offer a way to add them")
        try require(!blank.text.contains("Nothing saved yet."),
                    "Empty placeholders are never sent")

        let tooled = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: NativeSessionFixtureTransport(),
                               repository: try LocalChatRepository(inMemory: true),
                               nativeEnabledToolIDs: [NativeFolderTools.toolID, NativeCommandTools.toolID],
                               nativeCapabilityOverrides: [NativeSessionFixture.config.model: ModelCapabilityProfile(
                                   acceptsImages: false, supportsTools: true, supportsStreaming: true, maxImagesPerRequest: 0)],
                               artifactPersistenceEnabled: false)
        func listsFileTools(_ text: String) -> Bool {
            (NativeFolderTools.toolNames.union(NativeCommandTools.toolNames)).allSatisfy { text.contains("- \($0) (") }
        }
        func listsAnyFileTool(_ text: String) -> Bool {
            (NativeFolderTools.toolNames.union(NativeCommandTools.toolNames)).contains { text.contains("- \($0) (") }
        }
        let ungranted = tooled.fullPromptPreview(companion: false, now: fixed, timeZone: zone).text
        try require(!listsAnyFileTool(ungranted) && !ungranted.contains("Folders shared with this chat"),
                    "Without a shared folder the full prompt has no folder or command tools and no folder note")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        tooled.newConversation()
        tooled.grantFolder(folder)
        guard let grantedID = tooled.selectedID, let note = NativeFolderTools.grantNote(tooled.grants(for: grantedID)) else {
            throw NativeTaskFixture.Failure.assertion("The tooled store shares a folder")
        }
        let granted = tooled.fullPromptPreview(companion: false, now: fixed, timeZone: zone).text
        try require(listsFileTools(granted) && granted.contains(note),
                    "With a shared folder the full prompt lists folder and command tools and the folder note")
        let transport = NativeSessionFixtureTransport()
        let sending = try fixtureStore(transport: transport)
        sending.newConversation()
        try require(sending.sendText("What should I plant in May?"), "The normal chat accepts a message")
        try await NativeSessionFixture.eventually("The normal chat replies") {
            sending.selected?.messages.last?.role == .assistant && sending.selected?.messages.last?.state == .complete
        }
        let sent = transport.histories.last?.first { $0.role == "system" }?.content ?? ""
        let shown = sending.fullPromptPreview(companion: false).text
        try require(!sent.isEmpty && withoutClock(sent) == withoutClock(shown), "The normal chat sends exactly the prompt the view shows")
    }

    static func companionWork(_ require: (Bool, String) throws -> Void) async throws {
        let harness = try await CompanionTalkControlFixture.harness { _, _, _ in CompanionAskedWorkTransport.say("It's going well.") }
        defer { Task { await CompanionTalkControlFixture.finish(harness) } }
        let work = try await CompanionTalkControlFixture.start(harness, "Compare the opening hours of the two libraries.")
        try await CompanionTalkControlFixture.settle(harness, work, .going)
        let shown = harness.store.fullPromptPreview(companion: true).text
        let ask = "How is that going?"
        _ = try await CompanionTalkControlFixture.send(harness, ask)
        guard let record = harness.transport.records.last(where: { $0.user == ask }) else {
            throw NativeTaskFixture.Failure.assertion("The companion message was sent")
        }
        let sent = CompanionTalkControlFixture.system(record.messages)
        try require(shown.contains(CompanionTalkCopy.otherWork) && shown.contains(String(CompanionTalkCopy.lead.prefix(40))),
                    "With work running the companion view has the work section and rule")
        try require(withoutHandles(withoutClock(sent)) == withoutHandles(withoutClock(shown)),
                    "The companion sends exactly the prompt the view shows while work is running, apart from each turn's own work handles")
    }
}
