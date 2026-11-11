import AppKit
import SwiftUI

struct CardShotChat {
    let messages: [Message]
    let confirmation: NativeToolConfirmationRequest
}

@MainActor
enum CardShot {
    static let folder = "/Volumes/Notes/Greenhouse"
    static let engineURL = URL(string: "https://engine.test/api")!

    static func render(view: String, to path: String, appearance: String) {
        let named = view.hasSuffix("-ada")
        let variant = named ? String(view.dropLast("-ada".count))
            : view.hasSuffix("-unnamed") ? String(view.dropLast("-unnamed".count)) : view
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let store = ChatStore()
        let companion = named ? CompanionAppearance(shape: .fold, color: .periwinkle) : CompanionAppearance.default
        store.adoptAssistantName(named ? NativeDotShotFixture.name : "")
        store.ensureVeraThread()
        let settings: [String: String] = named
            ? ["assistant_name": NativeDotShotFixture.name, ConfigStore.companionShapeKey: companion.shape.rawValue,
               ConfigStore.companionColorKey: companion.color.rawValue]
            : [:]
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { settings }, writeConfiguration: { _ in })
        var size = CGSize(width: 1180, height: 760)
        let content: AnyView
        switch variant {
        case "card-command", "card-folder-edit", "card-once-only", "card-send", "card-reminder", "card-schedule", "card-schedule-companion", "card-send-companion",
             "card-send-recipient", "card-send-unknown", "card-send-fixed":
            let chat = self.chat(variant, store: store)
            content = AnyView(ShotView(store: store, section: .chat, cardChat: chat, width: size.width))
        case "card-command-menus", "card-folder-edit-menus", "card-send-menus", "card-reminder-menus",
             "card-send-recipient-menus", "card-send-unknown-menus", "card-send-fixed-menus":
            size = CGSize(width: 640, height: 420)
            let request = self.chat(String(variant.dropLast("-menus".count)), store: store).confirmation
            let answers = CardAnswers.chat(request)
            content = AnyView(VStack(alignment: .trailing, spacing: 14) {
                NativeToolConfirmationBar(request: request, actor: "Tandem", onDecision: { _ in }, onChoice: { _ in })
                HStack(alignment: .top, spacing: 12) {
                    CardMenuPreview(heading: "Opens from the caret on Decline", items: answers.declineMenu)
                    CardMenuPreview(heading: "Opens from the caret on Allow", items: answers.allowMenu)
                }
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        case "card-task", "card-task-command", "card-task-asks":
            size = CGSize(width: 1180, height: 1040)
            seedTask(command: variant == "card-task-command", asks: variant == "card-task-asks", store: store)
            let model = CompanionOverviewModel.build(name: store.companion.leading, profile: store.dotProfile,
                                                     services: "Can reach every service that is turned on.",
                                                     rules: store.companionRulesSummary, activity: [], results: [])
            content = AnyView(ShotView(store: store, section: .vera, companionPanel: model, height: size.height))
        case "card-left", "card-left-kept", "card-left-asked", "card-left-chat":
            size = CGSize(width: 1180, height: 1040)
            seedLeft(variant, store: store)
            let model = CompanionOverviewModel.build(name: store.companion.leading, profile: store.dotProfile,
                                                     services: "Can reach every service that is turned on.",
                                                     rules: store.companionRulesSummary, activity: [], results: [])
            content = AnyView(ShotView(store: store, section: .vera, companionPanel: model, height: size.height))
        case "card-rules-popover":
            size = CGSize(width: 420, height: 760)
            let id = seedRules(store)
            content = AnyView(ConversationRulesEditor(conversationID: id).background(Theme.bg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 20))
        case "card-offer-edits", "card-offer-sends", "card-offer-risky", "card-offer-allowed", "card-offer-everywhere", "card-offer-failed":
            size = CGSize(width: 760, height: 380)
            content = AnyView(offer(variant))
        case "card-offer-menus":
            size = CGSize(width: 640, height: 300)
            let answers = CardAnswers.offer()
            content = AnyView(VStack(alignment: .trailing, spacing: 14) {
                RuleOfferCard(offer: NativeRuleOffer(id: "shot", action: .fileEdits), onAnswer: { _ in })
                HStack(alignment: .top, spacing: 12) {
                    CardMenuPreview(heading: "Opens from the caret on Decline", items: answers.declineMenu)
                    CardMenuPreview(heading: "Opens from the caret on Allow", items: answers.allowMenu)
                }
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        case "card-scheduled-answer":
            store.section = .scheduled
            seedSchedule(store)
            content = AnyView(ShotView(store: store, section: .scheduled, width: size.width))
        default:
            FileHandle.standardError.write(Data("Unknown card view\n".utf8))
            exit(1)
        }
        let hosting = NSHostingView(rootView: content
            .environment(\.renderSafe, true)
            .environment(\.companionAppearance, companion)
            .environment(\.companionName, named ? NativeDotShotFixture.name : nil)
            .environmentObject(store)
            .environmentObject(config)
            .frame(width: size.width, height: size.height)
            .background(Theme.bg)
            .environment(\.colorScheme, scheme))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            FileHandle.standardError.write(Data("Card render failed\n".utf8))
            exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("Card render failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Card image couldn't be saved\n".utf8))
            exit(1)
        }
    }

    static func offer(_ variant: String) -> some View {
        let action: NativeActionClass = variant == "card-offer-sends" ? .networkSends : variant == "card-offer-risky" ? .riskyCommands : .fileEdits
        let state: NativeRuleOffer.State = variant == "card-offer-allowed" ? .allowedHere : variant == "card-offer-everywhere" ? .allowedEverywhere : .waiting
        let ask: String
        let reply: String
        switch action {
        case .networkSends:
            ask = "Note that I watered the tomato bed twice today."
            reply = "Posted to the garden log."
        case .riskyCommands:
            ask = "Clear the old build cache."
            reply = "The old build cache is cleared."
        default:
            ask = "Add the afternoon vent check to the plan."
            reply = "The plan now has the afternoon vent check."
        }
        var message = Message(role: .assistant, text: reply)
        message.displayBlocks = [.ruleOffer(NativeRuleOffer(id: "shot", action: action, state: state, failed: variant == "card-offer-failed"))]
        return VStack(alignment: .leading, spacing: 22) {
            MessageRow(message: Message(role: .user, text: ask))
            MessageRow(message: message, onRuleOffer: { _, _ in })
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static func ruledActivity(_ definition: NativeToolDefinition, rules: NativeRules, id: String, request: String, ask: String,
                              conversationID: String) -> (NativeToolActivity, NativeCardSubject) {
        let source = NativeRuleSource()
        source.setGlobal(rules)
        let ruled = ChatStore.ruled(definition, rules: source, store: nil, conversationID: conversationID, requestText: ask)
        let activity = NativeToolActivity(id: id, toolID: ruled.id, name: ruled.name, title: ruled.title, round: 1,
                                          request: request, result: nil, state: .pending, confirmationRequired: true)
        let subject = ChatStore.cardSubject(for: activity, definitions: [ruled])
            ?? NativeCardSubject(action: .otherChanges, toolID: ruled.id, toolTitle: ruled.title)
        return (activity, subject)
    }

    static var gardenLog: NativeToolDefinition {
        let declaration = try? NativeCapabilityTools.parse(object: [
            "name": "garden_log", "title": "Post to the garden log", "description": "Post a line to the garden log",
            "parameters": ["type": "object", "properties": ["entry": ["type": "string"]], "required": ["entry"], "additionalProperties": false],
            "endpoint": "https://garden.example/log", "method": "POST", "confirmation": "none",
        ], source: "garden_log.json")
        return NativeCapabilityTools.definition(declaration!, base: { nil })
    }

    static func chat(_ variant: String, store: ChatStore) -> CardShotChat {
        let conversation = Conversation(id: "card-chat", title: "Greenhouse notes", messages: [], updatedAt: Date())
        let conversationID: String
        if variant == "card-send-companion" {
            store.dotProfile = NativeDotProfile(goal: NativeDotShotFixture.goal, state: .active, setupCompleted: true)
            store.openVeraThread()
            conversationID = store.veraThreadID ?? conversation.id
            store.selectedID = conversationID
        } else {
            store.conversations.insert(conversation, at: 0)
            store.selectedID = conversation.id
            conversationID = conversation.id
        }
        store.section = .chat
        let place = NativeCardPlace.chat(conversationID: conversationID)
        let activity: NativeToolActivity
        let subject: NativeCardSubject
        let ask: String
        switch variant {
        case "card-send", "card-send-companion":
            ask = "Note that I watered the tomato bed twice today."
            (activity, subject) = ruledActivity(gardenLog, rules: .defaults, id: "card-send",
                                                request: "{\"entry\":\"Watered the tomato bed twice.\"}", ask: ask, conversationID: conversationID)
        case "card-reminder":
            ask = "Remind me to buy seed potatoes."
            var rules = NativeRules.defaults
            rules.set(.ask, for: .reminders)
            let create = NativeRemindersTools.definitions(service: SelfTestRemindersService()).first { $0.name == "apple_reminders_create" }!
            (activity, subject) = ruledActivity(create, rules: rules, id: "card-reminder",
                                                request: "{\"list\":\"Errands\",\"title\":\"Buy seed potatoes\"}", ask: ask, conversationID: conversationID)
        case "card-schedule", "card-schedule-companion":
            ask = "Every weekday at 7, check the frost forecast for the greenhouse."
            let schedule = NativeScheduleTools.definition(save: { _ in throw NativeToolError.unavailable })
            (activity, subject) = ruledActivity(schedule, rules: .defaults, id: "card-schedule",
                                                request: "{\"title\":\"Frost check\",\"worker_type\":\"research\",\"instruction\":\"Check the overnight frost forecast for the greenhouse.\",\"results_to\":\"\(variant == "card-schedule" ? "own_chat" : "assistant")\",\"repeat\":\"weekdays\",\"time\":\"07:00\"}",
                                                ask: ask, conversationID: conversationID)
        case "card-folder-edit":
            ask = "Add the afternoon vent check to the plan."
            activity = NativeToolActivity(id: "card-edit", toolID: NativeFolderTools.toolID, name: NativeFolderTools.editName, title: "Edit a file", round: 1,
                                          request: "{\"path\":\"\(folder)/plan.md\"}", result: nil, state: .pending, confirmationRequired: true)
            subject = NativeCardSubject(action: .fileEdits, toolID: NativeFolderTools.toolID, toolTitle: "Edit a file",
                                        targets: [NativeRuleTarget.make(.folder, "\(folder)/plan.md")].compactMap { $0 })
        case "card-once-only":
            ask = "Note that I watered the tomato bed twice today."
            activity = NativeToolActivity(id: "card-garden", toolID: "garden-log", name: "garden_log_post", title: "Post to the garden log", round: 1,
                                          request: "{\"entry\":\"Watered the tomato bed twice.\"}", result: nil, state: .pending, confirmationRequired: true)
            subject = NativeCardSubject(action: .networkSends, toolID: "garden-log", toolTitle: "Post to the garden log", governed: false)
        case "card-send-recipient":
            ask = "Let the workshop know the order is ready."
            activity = NativeToolActivity(id: "card-mail", toolID: "workshop-mail", name: "send_email", title: "Send an email", round: 1,
                                          request: "{\"to\":\"orders@workshop.example\",\"body\":\"The order is ready.\"}", result: nil,
                                          state: .pending, confirmationRequired: true)
            subject = NativeCardSubject(action: .networkSends, toolID: "workshop-mail", toolTitle: "Send an email",
                                        targets: [NativeRuleTarget.make(.recipient, "orders@workshop.example")].compactMap { $0 }, phrase: "send an email")
        case "card-send-unknown":
            ask = "Let the workshop know the order is ready."
            activity = NativeToolActivity(id: "card-notify", toolID: "workshop-notify", name: "notify_workshop", title: "Notify the workshop", round: 1,
                                          request: "{\"message\":\"The order is ready.\"}", result: nil, state: .pending, confirmationRequired: true)
            subject = NativeCardSubject(action: .networkSends, toolID: "workshop-notify", toolTitle: "Notify the workshop")
        case "card-send-fixed":
            ask = "Note that I watered the tomato bed twice today."
            activity = NativeToolActivity(id: "card-fixed", toolID: "garden-log-fixed", name: "garden_log_post", title: "Post to the garden log", round: 1,
                                          request: "{\"entry\":\"Watered the tomato bed twice.\"}", result: nil, state: .pending, confirmationRequired: true)
            subject = NativeCardSubject(action: .networkSends, toolID: "garden-log-fixed", toolTitle: "Post to the garden log", fixed: true)
        default:
            ask = "Now rebuild the PDF."
            activity = NativeToolActivity(id: "card-command", toolID: NativeCommandTools.toolID, name: NativeCommandTools.runName, title: "Run a command", round: 1,
                                          request: "{\"command\":\"make pdf\",\"directory\":\"\(folder)\"}", result: nil, state: .pending, confirmationRequired: true)
            subject = NativeCardSubject(action: .commands, toolID: NativeCommandTools.toolID, toolTitle: "Run a command", command: "make pdf")
        }
        var request = NativeToolConfirmationRequest(activity: activity)
        request.subject = subject
        request.choices = NativeCardChoices.offered(subject, place: place)
        request.covers = NativeCardChoices.covers(subject)
        return CardShotChat(messages: [
            Message(role: .user, text: ask),
            Message(role: .assistant, text: "", toolActivities: [activity]),
        ], confirmation: request)
    }

    static func seedTask(command: Bool, asks: Bool = false, store: ChatStore) {
        store.dotProfile = NativeDotProfile(goal: NativeDotShotFixture.goal, state: .active, setupCompleted: true)
        store.openVeraThread()
        guard let threadID = store.veraThreadID, let index = store.conversations.firstIndex(where: { $0.id == threadID }) else { return }
        let toolTitle = command ? "Run a command" : "Send a booking request"
        let arguments = command
            ? "{\"command\":\"make pdf\",\"directory\":\"\(folder)\"}"
            : "{\"message\":\"Please book the workshop inspection for Tuesday morning and confirm by email.\",\"to\":\"inspections@example.com\"}"
        let subject = command
            ? NativeCardSubject(action: .commands, toolID: NativeCommandTools.toolID, toolTitle: toolTitle, command: "make pdf")
            : NativeCardSubject(action: .networkSends, toolID: "booking-send", toolTitle: toolTitle, alwaysAsks: asks)
        let place = NativeCardPlace.task(taskID: "card-task", conversationID: threadID, scheduleID: nil)
        let offered = NativeCardChoices.offered(subject, place: place)
        let details = command ? "make pdf\nin \(folder)" : NativeCompanionWorker.details(toolTitle, argumentsJSON: arguments)
        let never = offered.first(where: { $0.kind == .never })?.title ?? ""
        let covers = NativeCardChoices.scope(subject) ?? ""
        let decision: [String: Any] = [
            "id": "card-decision", "prompt": NativeCardChoices.sentence(actor: CompanionSentence.placeholder, subject: subject, title: toolTitle), "covers": covers, "never": never,
            "choices": offered.map { NativeCardChoices.wire($0, subject: subject) }, "details": details,
        ]
        let title = command ? "Rebuild the greenhouse PDF" : "Book the workshop inspection"
        guard let reference = try? OngoingWorkFixture.reference(conversationID: threadID, title: title, workerType: "companion",
                                                                state: "needs_decision", decision: decision),
              var display = try? NativeTaskProjection.display(reference: reference, snapshot: reference.snapshot) else { return }
        display.card.choices = reference.snapshot?.decision?.choices.filter { NativeTaskCardPresentation.choiceTitle($0) != nil }
        store.nativeTaskEngine.set(engineURL)
        store.nativeTaskReferences = [reference]
        var message = Message(role: .assistant, text: command ? "I'll rebuild the PDF in the background." : "I'll send the booking request in the background.")
        message.displayBlocks = [.taskCard(display.card)]
        store.conversations[index].messages = [
            Message(role: .user, text: command ? "Rebuild the greenhouse PDF when you get a chance." : "Book the workshop inspection for Tuesday morning."),
            message,
        ]
    }

    static func seedLeft(_ variant: String, store: ChatStore) {
        store.dotProfile = NativeDotProfile(goal: NativeDotShotFixture.goal, state: .active, setupCompleted: true)
        store.openVeraThread()
        guard let threadID = store.veraThreadID, let index = store.conversations.firstIndex(where: { $0.id == threadID }) else { return }
        let chat = variant == "card-left-chat"
        var rules = store.nativeRules
        rules.set(chat ? .ask : .handOff, for: .riskyCommands)
        store.updateNativeRules(rules)
        if chat { store.tightenConversationRule(.handOff, for: .riskyCommands, conversationID: threadID) }
        let command = "sudo systemsetup -setremotelogin on"
        let title = "Turn on remote login for the garden Mac"
        let why = NativeRuleWhy(kind: .unsaved, action: .riskyCommands, handsOff: true, choice: .handOff, source: chat ? .chat : .settings)
        let reason = (try? JSONEncoder().encode(why)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
        let lead = NativeCompanionWorker.handOffLead(title: "Run a command: \(command)")
        let result: [String: Any] = [
            "kind": "companion_report", "query": title, "title": title, "sources": [],
            "report": NativeCompanionWorker.handOffText(title: "Run a command: \(command)", why: why) + " Nothing was changed.",
            "summary": lead + " Nothing was changed.", "why": reason,
            "offer": ["action": NativeActionClass.riskyCommands.rawValue, "source": chat ? "chat" : "settings",
                      "step": command + "\nin /Volumes/Garden/notes"],
        ]
        guard let reference = try? OngoingWorkFixture.reference(conversationID: threadID, title: title, workerType: "companion",
                                                                state: "completed", result: result),
              let display = try? NativeTaskProjection.display(reference: reference, snapshot: reference.snapshot) else { return }
        store.nativeTaskEngine.set(engineURL)
        store.nativeTaskReferences = [reference]
        let cardID = display.card.id
        if variant == "card-left-kept" { store.leftToYouAnswers[cardID] = .kept }
        if variant == "card-left-asked" {
            store.leftToYouAnswers[cardID] = .askFirst
            rules.set(.ask, for: .riskyCommands)
            store.updateNativeRules(rules)
        }
        var message = Message(role: .assistant, text: "I'll turn on remote login in the background.")
        message.displayBlocks = [.taskCard(display.card)]
        store.conversations[index].messages = [
            Message(role: .user, text: "Turn on remote login for the garden Mac."),
            message,
        ]
    }

    static func seedRules(_ store: ChatStore) -> String {
        let conversation = Conversation(id: "card-rules", title: "Greenhouse notes", messages: [], updatedAt: Date())
        store.conversations.insert(conversation, at: 0)
        store.selectedID = conversation.id
        store.prepareRuleRecords()
        let place = NativeCardPlace.chat(conversationID: conversation.id)
        for command in ["make pdf", "git status"] {
            let subject = NativeCardSubject(action: .commands, toolID: NativeCommandTools.toolID, toolTitle: "Run a command", command: command)
            for record in NativeCardChoices.records(.allowHere, subject: subject, place: place, originMessageID: nil) {
                store.addRuleRecord(record)
            }
        }
        store.tightenConversationRule(.ask, for: .reminders, conversationID: conversation.id)
        return conversation.id
    }

    static func seedSchedule(_ store: ChatStore) {
        guard let repository = store.repository as? LocalChatRepository,
              let origin = try? NativeTaskFixture.origin(repository),
              let request = try? NativeResearchTaskRequest(objective: "Check current lumber futures and note any move over two percent.",
                                                           deliverables: ["A short summary"]),
              let engine = try? NativeTaskEngineIdentity(engineURL),
              let reference = try? repository.prepareTaskReference(origin: origin, engine: engine, request: request, profile: nil) else {
            NativeScheduleShotFixture.populate(store)
            return
        }
        let prompt = "\(CompanionSentence.placeholder) wants to send a price alert."
        let remote = UUID().uuidString
        if let queued = try? NativeTaskDisplayFixture.snapshot(reference, id: remote, state: "queued"),
           let waiting = try? NativeTaskDisplayFixture.snapshot(reference, id: remote, state: "needs_decision", decision: [
               "id": "card-schedule", "prompt": prompt, "choices": ["decline", "never", "allow_always", "allow_here", "approve"],
               "details": "Message: Lumber is up 2.4 percent since yesterday.\nTo: workshop@example.com",
               "covers": "This action every time", "never": "Never allow this in this task",
           ]) {
            _ = try? repository.acknowledgeTaskReference(id: reference.id, snapshot: queued)
            _ = try? repository.projectTask(id: reference.id, snapshot: waiting)
        }
        NativeScheduleShotFixture.populate(store, waiting: (reference.id.uuidString, prompt))
    }
}

extension CompanionShotFixture {
    static let waitingViews: Set<String> = ["companion-work-waiting", "companion-work-waiting-unnamed"]

    static func seedWaiting(_ store: ChatStore, outer: ChatStore, view: String) {
        guard waitingViews.contains(view), let threadID = store.veraThreadID else { return }
        if view.hasSuffix("-unnamed") {
            store.adoptAssistantName(nil)
            outer.adoptAssistantName(nil)
        }
        let reference = try? CompanionSavedTextFixture.reference(state: "needs_decision", conversationID: threadID,
                                                                 decision: CompanionSavedTextFixture.approvalDecision())
        store.nativeTaskReferences = reference.map { [$0] } ?? []
    }
}
