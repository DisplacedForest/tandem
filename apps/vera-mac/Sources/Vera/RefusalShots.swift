import AppKit
import SwiftUI

@MainActor
enum RefusalShot {
    static let chatID = "refusal-greenhouse"
    static let longPath = "/" + ["Volumes", "Archive", "Household", "Paperwork", "2024", "Insurance", "Claims", "Water damage", "Photos and receipts",
                                 "kitchen-ceiling-estimate.pdf"].joined(separator: "/")

    static func samples() -> [(title: String, request: String, why: NativeRuleWhy)] {
        let command = NativeCommandTools.toolID
        var list: [(String, String, NativeRuleWhy)] = []
        list.append(("Run a command", "sudo softwareupdate --install --all",
                     NativeRuleWhy(kind: .unsaved, action: .riskyCommands, handsOff: true, choice: .handOff, source: .settings,
                                   trigger: .init(.program, "sudo"))))
        list.append(("Edit a file", "notes/plan.md",
                     NativeRuleWhy(kind: .unsaved, action: .fileEdits, handsOff: true, choice: .handOff, source: .chat)))
        let never = NativeRuleRecord(scope: .conversation(chatID), action: nil, toolID: command, effect: .forbid, statement: "Never run commands in this chat")
        list.append(("Run a command", "make pdf", NativeRuleWhy(kind: .rule, action: .commands, handsOff: true, rule: .init(never))))
        list.append(("Pay an invoice", "Invoice 2207, 84.00", NativeRuleWhy(kind: .held, action: .payments, handsOff: true, item: .payments)))
        list.append(("Edit a file", longPath, NativeRuleWhy.folder(.fileEdits, path: longPath)))
        return list
    }

    static func asking() -> [(title: String, why: NativeRuleWhy)] {
        var list: [(String, NativeRuleWhy)] = []
        if let target = NativeRuleTarget.make(.commandPrefix, "make pdf") {
            let allow = NativeRuleRecord(scope: .conversation(chatID), action: .commands, toolID: NativeCommandTools.toolID, target: target, effect: .allow,
                                         statement: "Allow commands that start with make pdf")
            list.append(("Run a command", NativeRuleWhy(kind: .outside, action: .commands, handsOff: false, choice: .ask, source: .settings,
                                                        rule: .init(allow))))
        }
        list.append(("Post to the garden log", NativeRuleWhy.tool(.networkSends)))
        list.append(("Send an email", NativeRuleWhy(kind: .unnamed, action: .networkSends, handsOff: false, subject: "orders@workshop.example")))
        return list
    }

    static func render(view: String, to path: String, appearance: String) {
        let named = !view.hasSuffix("-unnamed")
        let variant = view.hasSuffix("-ada") ? String(view.dropLast("-ada".count))
            : view.hasSuffix("-unnamed") ? String(view.dropLast("-unnamed".count)) : view
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let store = ChatStore()
        store.adoptAssistantName(named ? "Ada" : "")
        store.ensureVeraThread()
        store.conversations.insert(Conversation(id: chatID, title: "Greenhouse notes", messages: [], updatedAt: Date()), at: 0)
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in })
        let size = CGSize(width: 760, height: ["refusal-command", "refusal-instructed-command", "refusal-instructed-step", "refusal-slow-command"].contains(variant) ? 300 : 620)
        let content: AnyView
        switch variant {
        case "refusal-command":
            let why = NativeRuleWhy(kind: .unsaved, action: .riskyCommands, handsOff: true, choice: .handOff, source: .settings,
                                    trigger: .init(.program, "sudo"))
            content = AnyView(NativeCommandRunCard(run: NativeCommandRun(id: "c1", command: "sudo softwareupdate --install --all",
                                                                         directory: "/Volumes/Notes/Greenhouse", outcome: .refused, why: why)))
        case "refusal-asking":
            content = AnyView(VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(asking().enumerated()), id: \.offset) { _, sample in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sample.title).font(.system(size: 12, weight: .medium))
                        Text(RefusalCopy.notRun).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        RefusalReasonLine(why: sample.why)
                    }
                }
            })
        case "refusal-instructed-command":
            content = AnyView(NativeCommandRunCard(run: NativeCommandRun(id: "c2", command: "make pdf", directory: "/Volumes/Notes/Greenhouse",
                                                                         outcome: .ran, reason: .instruction, exitCode: 0,
                                                                         stdout: "Wrote notes.pdf\n", durationMilliseconds: 840)))
        case "refusal-slow-command":
            content = AnyView(NativeCommandRunCard(run: NativeCommandRun(id: "c3", command: "make pdf", directory: "/Volumes/Notes/Greenhouse",
                                                                         outcome: .timedOut, reason: .userApproved,
                                                                         stdout: "Building notes.pdf\n", durationMilliseconds: 120000)))
        case "refusal-instructed-step":
            content = AnyView(NativeToolActivityChip(activity: NativeToolActivity(id: "s1", toolID: "garden-mail", name: "send_notes", title: "Send the notes",
                                                                                   round: 0, request: "{\"to\":\"ana@greenhouse.test\"}",
                                                                                   result: "{\"sent\":true}", state: .succeeded, confirmationRequired: false,
                                                                                   ranBecause: .instruction),
                                                     startsExpanded: true))
        default:
            content = AnyView(VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(samples().enumerated()), id: \.offset) { index, sample in
                    NativeToolActivityChip(activity: NativeToolActivity(id: "a\(index)", toolID: "fixture", name: "fixture", title: sample.title, round: 0,
                                                                        request: sample.request, result: nil, state: .failed, confirmationRequired: false,
                                                                        why: sample.why))
                }
            })
        }
        let root = content
            .padding(24)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environmentObject(store).environmentObject(config)
            .environment(\.companionName, named ? "Ada" : nil)
            .environment(\.companionAppearance, CompanionAppearance(shape: .pebble, color: .apricot))
            .environment(\.colorScheme, scheme)
            .environment(\.renderSafe, true)
            .background(Theme.bg)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: AppLocations.checkedOutput(path)); print("wrote \(path)"); exit(0) }
        catch { exit(1) }
    }
}
