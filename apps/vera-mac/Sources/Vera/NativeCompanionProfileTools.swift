import Foundation

enum NativeCompanionProfileTools {
    static let toolID = "companion.profile"
    static let name = "update_companion_profile"

    static func string(_ value: NativeJSONValue?) -> String? {
        if case .string(let text) = value { return text }
        return nil
    }

    static func change(_ arguments: [String: NativeJSONValue]) throws -> (action: String, value: String, category: String?) {
        guard Set(arguments.keys).isSubset(of: ["action", "value", "category"]),
              let action = string(arguments["action"]),
              ["name", "goal", "rule", "connect", "disconnect", "note", "finish_setup"].contains(action),
              let value = string(arguments["value"]), value.count <= NativeDotProfile.goalLimit,
              action == "goal" || action == "finish_setup" || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeToolError.invalidArguments("Supply one supported profile change and a value of at most 2000 characters.")
        }
        if action == "name" && value.count > 80 { throw NativeToolError.invalidArguments("Use a name of at most 80 characters.") }
        if action == "rule" {
            guard let category = string(arguments["category"]), let actionClass = NativeActionClass(rawValue: category),
                  NativeActionClass.configurable.contains(actionClass), NativeRuleChoice(rawValue: value) != nil else {
                throw NativeToolError.invalidArguments("Choose a configurable rule and a supported choice.")
            }
        } else if arguments["category"] != nil {
            throw NativeToolError.invalidArguments("Only a rule change accepts a category.")
        }
        return (action, value.trimmingCharacters(in: .whitespacesAndNewlines), string(arguments["category"]))
    }

    static func prompt(_ request: NativeToolConfirmationRequest) -> String? {
        guard request.toolID == toolID,
              let data = request.request.data(using: .utf8),
              let arguments = try? NativeJSONValue.piRead(data).piObject,
              let change = try? change(arguments) else { return nil }
        if change.action == "connect" { return "Allow this companion to use \(change.value)?" }
        if change.action == "rule", let category = change.category.flatMap(NativeActionClass.init(rawValue:)),
           let choice = NativeRuleChoice(rawValue: change.value) {
            return "Change \(category.title.lowercased()) to \(choice.title.lowercased())?"
        }
        return nil
    }
}

extension ChatStore {
    func companionProfileTool(for turn: NativeConversationTurn) -> NativeToolDefinition? {
        guard isVeraThread(turn.conversationID), turn.mode == .chat, turn.companionEvent == nil else { return nil }
        let profile = dotProfile
        let rules = conversationRules(for: turn.conversationID)
        let global = nativeRules
        let services = dotServiceOptions()
        let selected = dotSelectedServices(services)
        let generation = dotResetGeneration
        let serviceNames = services.map(\.name).joined(separator: ", ")
        var definition = NativeToolDefinition(id: NativeCompanionProfileTools.toolID, name: NativeCompanionProfileTools.name,
            title: "Update companion profile",
            description: "Apply one profile change explicitly requested by the current user. Actions: name, goal, rule, connect, disconnect, note, finish_setup. value is the new text or service name. For rule only, category is file_edits, commands, trash, network_sends, risky_commands or other_changes, and value is act, act_if_preapproved, ask or hand_off. Global restrictions cannot be widened. Notes become memory suggestions for review and require memory enabled. finish_setup uses an empty value when setup was answered or skipped. Configured service names: " + serviceNames,
            parameters: .object(["type": .string("object"), "properties": .object([
                "action": .object(["type": .string("string")]),
                "value": .object(["type": .string("string")]),
                "category": .object(["type": .string("string")]),
            ]), "required": .array([.string("action"), .string("value")]), "additionalProperties": .bool(false)]), confirmation: .none,
            confirmationFor: { arguments in
                guard let change = try? NativeCompanionProfileTools.change(arguments) else { return true }
                if change.action == "connect" {
                    return services.filter { $0.name == change.value }.contains { !selected.contains($0.id) }
                }
                if change.action == "rule", let category = change.category.flatMap(NativeActionClass.init(rawValue:)),
                   let choice = NativeRuleChoice(rawValue: change.value) {
                    return choice.strictness < (rules.choices[category] ?? global.choice(for: category)).strictness
                }
                return false
            }, isAvailable: { true }, execute: { [weak self] arguments in
                try await MainActor.run {
                    guard let self, self.turnOwned(turn), self.dotResetGeneration == generation,
                          self.dotProfile == profile, self.conversationRules(for: turn.conversationID) == rules,
                          self.nativeRules == global else {
                        throw NativeToolError.failed("The profile changed. Read the current settings and propose the change again.")
                    }
                    return try self.applyCompanionProfile(arguments, turn: turn, services: services)
                }
            })
        definition.argumentValidator = {
            let change = try NativeCompanionProfileTools.change($0)
            if change.action == "rule", let category = change.category.flatMap(NativeActionClass.init(rawValue:)),
               let choice = NativeRuleChoice(rawValue: change.value), choice.strictness < global.choice(for: category).strictness {
                throw NativeToolError.invalidArguments("The rule cannot exceed the defaults in Settings.")
            }
        }
        return definition
    }

    func applyCompanionProfile(_ arguments: [String: NativeJSONValue], turn: NativeConversationTurn,
                               services: [NativeDotServiceOption]) throws -> NativeJSONValue {
        let change = try NativeCompanionProfileTools.change(arguments)
        guard let profileStore = nativeDotProfileStore else { throw NativeToolError.failed("The profile couldn't be saved.") }
        var profile = dotProfile
        switch change.action {
        case "name":
            guard let companionNameWriter else { throw NativeToolError.failed("The name couldn't be saved.") }
            try companionNameWriter(change.value)
            companionHasSavedName = true
            adoptAssistantName(change.value)
            return .object(["result": .string("Name updated.")])
        case "goal": profile.goal = change.value
        case "finish_setup":
            profile.setupCompleted = true
            profile.needsIntroduction = false
        case "rule":
            guard let category = change.category.flatMap(NativeActionClass.init(rawValue:)),
                  let choice = NativeRuleChoice(rawValue: change.value),
                  choice.strictness >= nativeRules.choice(for: category).strictness,
                  let index = conversations.firstIndex(where: { $0.id == turn.conversationID }), let repository else {
                throw NativeToolError.failed("That change exceeds the defaults in Settings. Change those defaults yourself first.")
            }
            var conversation = conversations[index]
            conversation.rules.choices[category] = choice
            try repository.saveConversation(conversation)
            conversations[index] = conversation
            syncRuleSource()
            return .object(["result": .string("Rule updated.")])
        case "connect", "disconnect":
            let matches = services.filter { $0.name == change.value }
            guard matches.count == 1, let service = matches.first,
                  dotServiceOptions().contains(where: { $0 == service }) else {
                throw NativeToolError.failed("That service isn't available. Check its connection in Settings.")
            }
            var selected = dotSelectedServices(services)
            if change.action == "connect" { selected.insert(service.id) }
            else { selected.remove(service.id) }
            profile.connectedToolIDs = dotConnectedToolIDs(selected: selected, options: services)
        case "note":
            guard nativeMemorySettings.enabled, let memoryRepository = repository as? any NativeMemoryRepository else {
                throw NativeToolError.failed("Memory is off. Turn it on before saving a preference.")
            }
            let proposal = NativeMemoryProposal(id: UUID().uuidString, kind: .create,
                title: String(change.value.prefix(80)), summary: change.value, details: [change.value],
                group: .profile, category: .preference, bank: "personal", durability: .durable,
                expiry: nil, targetIDs: [], sourceConversationID: turn.conversationID,
                sourceMessageID: turn.userMessageID.uuidString, createdAt: Date(), status: .pending)
            try memoryRepository.saveProposal(proposal)
            reloadNativeMemory()
            return .object(["result": .string("Preference saved as a memory suggestion for review.")])
        default: throw NativeToolError.invalidArguments("Unsupported profile change.")
        }
        profile.updatedAt = Date()
        try profileStore.save(profile)
        dotProfile = profile
        return .object(["result": .string("Profile updated.")])
    }
}
