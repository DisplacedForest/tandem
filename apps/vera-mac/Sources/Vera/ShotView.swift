import SwiftUI

/// Render-safe mirror of the app for headless screenshots (ImageRenderer can't render
/// ScrollView contents or TextField). Renders the icon rail + the chosen surface.
struct ShotView: View {
    let store: ChatStore
    var section: AppSection = .chat
    var emptyChat: Bool = false
    var attachDemo: Bool = false
    var streaming: Bool = false
    var folder: Bool = false
    var command: Bool = false
    var schedule: Bool = false
    var chrome: ShotChrome = .window
    var collapsedSidebar: Bool = false
    var mentions: Bool = false
    var dotHeader: Bool = false
    var companionPanel: CompanionOverviewModel? = nil
    var companionSelection: String? = nil
    var height: CGFloat = 760
    var artifactSelection: String? = nil
    var artifactFilter: ArtifactKindFilter = .all
    var artifactSearch = ""
    var projectSelection: String? = nil
    var integrationsSeed: IntegrationsShotFixture.Seeded? = nil
    var workColumn = false
    var workCollapsed = false
    var voiceAvailability = ComposerVoiceAvailability(dictation: false, voiceChat: false)
    var dictating = false
    var width: CGFloat = 1180

    /// Which framing the shot renders: the main window, the Veins sheet over Pulse, or a Settings tab.
    enum ShotChrome: Equatable { case window, veinsSheet, veinBrowse, veinImport, settings(SettingsTab), dotSheet(settings: Bool) }

    var body: some View {
        Group {
            switch chrome {
            case .window: windowBody
            case .veinsSheet: veinsSheetShot
            case .veinBrowse: veinBrowseShot
            case .veinImport: veinImportShot
            case .settings(let tab): settingsShot(tab)
            case .dotSheet(let settings): dotSheetShot(settings: settings)
            }
        }
        .frame(width: width, height: height)
        .foregroundStyle(Theme.textPrimary)
    }

    private var windowBody: some View {
        HStack(spacing: 0) {
            shellChrome
            Group {
                switch section {
                case .pulse: pulse
                case .memory: memory
                case .agentic: agenticBoard
                case .scheduled: ScheduledView(renderSafe: true)
                case .artifacts:
                    ArtifactsView(initialSelection: artifactSelection, initialFilter: artifactFilter,
                                  initialSearch: artifactSearch)
                case .projects: ProjectsView(initialSelection: projectSelection)
                case .integrations:
                    IntegrationsView(initialTab: integrationsSeed?.tab ?? .personal,
                                     initialSearch: integrationsSeed?.search ?? "",
                                     initialSelection: integrationsSeed?.selection)
                case .vera, .chat:
                    if emptyChat, companionPanel == nil, section != .vera {
                        emptyChatShot
                    } else {
                        HStack(alignment: .top, spacing: 0) {
                            VStack(spacing: 0) {
                                if emptyChat && section == .vera {
                                    CompanionOpeningView(error: store.chatConfigurationError, retry: {})
                                    shotComposerRow(text: shotComposerText, typed: false, active: false, stop: false)
                                        .modifier(ShotComposerPill())
                                        .padding(.horizontal, 28).padding(.bottom, 18)
                                } else if emptyChat { emptyChatShot } else { chat }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .clipped()
                            if let companionPanel {
                                CompanionThreadPanel(fixed: companionPanel, selectedID: companionSelection)
                                    .frame(width: CompanionThreadPanelMetrics.width)
                            } else if workColumn {
                                OngoingWorkPanel(conversationID: store.selectedID, onSelect: { _ in })
                                    .frame(width: OngoingWorkMetrics.panelWidth)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
        }
    }

    private var veinsSheetShot: some View {
        ZStack {
            windowBodyForPulse.opacity(0.5)
            Color.black.opacity(0.35)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Text("Done").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
                veinsBoard
            }
            .frame(width: 900, height: 600)
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func dotSheetShot(settings: Bool) -> some View {
        ZStack {
            ShotView(store: store, section: .vera, dotHeader: true).opacity(0.5)
            Color.black.opacity(0.35)
            DotSheetShot(settings: settings, options: NativeDotShotFixture.options, selected: NativeDotShotFixture.selected,
                         goal: NativeDotShotFixture.goal)
                .environmentObject(store)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var windowBodyForPulse: some View {
        ShotView(store: store, section: .pulse)
    }

    private var veinBrowseShot: some View {
        let entry = VeinEntry.browseMock()[0]
        return ZStack {
            windowBodyForPulse.opacity(0.5)
            Color.black.opacity(0.35)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "plus.rectangle.on.rectangle").font(.system(size: 16))
                    Text("Add a vein").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("Done").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
                }
                .padding(16)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                VStack(alignment: .leading, spacing: 12) {
                    shotStartRow(icon: "wand.and.stars", title: "Build a new vein",
                                 note: "Describe a watch in your own words and Vera drafts it.", enabled: true)
                    shotStartRow(icon: "square.and.arrow.down", title: "Import from file",
                                 note: "Add a vein someone shared with you. It lands disabled for review.",
                                 enabled: true)
                    Text("AVAILABLE WITH AN INTEGRATION")
                        .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(Theme.textSecondary).padding(.top, 6)
                    shotUnexposedRow(entry)
                }
                .padding(16)
                Spacer(minLength: 0)
            }
            .frame(width: 520, height: 460)
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func shotStartRow(icon: String, title: String, note: String, enabled: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).frame(width: 24)
                .foregroundStyle(enabled ? Theme.accent : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(enabled ? Theme.textPrimary : Theme.textSecondary)
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            if enabled {
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
    }

    private func shotUnexposedRow(_ entry: VeinEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceHover)
                .overlay(Image(systemName: entry.icon).font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary))
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.label).font(.system(size: 13, weight: .semibold))
                Text(entry.blurb).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let req = entry.requiresUnmet.first {
                    HStack(spacing: 6) {
                        Image(systemName: "link").font(.system(size: 10))
                        Text("Available if you connect \(req.label)").font(.system(size: 11, weight: .medium))
                        Text("Open Plugins").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .foregroundStyle(.orange).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
    }

    private var veinImportShot: some View {
        ZStack {
            windowBodyForPulse.opacity(0.5)
            Color.black.opacity(0.35)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 16))
                    Text("Review import").font(.system(size: 16, weight: .semibold))
                    Spacer()
                }
                .padding(16)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("River gauge").font(.system(size: 15, weight: .semibold))
                        Text("watches the river level and speaks up past flood stage")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    shotImportField("SCHEDULE", "*/30 * * * *")
                    shotImportField("PIPELINE", "http_fetch -> trip_band")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WARNINGS").font(.system(size: 10, weight: .semibold)).tracking(0.6)
                            .foregroundStyle(Theme.textSecondary)
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                            Text("Needs Grocy").font(.system(size: 12))
                            Text("Open Plugins").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }.foregroundStyle(.orange)
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                            Text("Unknown block moon_phase. It stays inert until this Vera has it.")
                                .font(.system(size: 12))
                        }.foregroundStyle(.orange)
                    }
                    Text("This vein was added disabled. Review its settings, then enable it when you're ready.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                .padding(16)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack {
                    Spacer()
                    Text("Done").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
                }
                .padding(12)
                Spacer(minLength: 0)
            }
            .frame(width: 460, height: 470)
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func shotImportField(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Theme.textSecondary)
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
        }
    }

    private func settingsShot(_ tab: SettingsTab) -> some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 0) {
                settingsTabBar(tab)
                Divider().overlay(Theme.hairline)
                pluginsBoard
            }
            .frame(width: 860, height: 640, alignment: .top)
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func settingsTabBar(_ active: SettingsTab) -> some View {
        let tabs: [(SettingsTab, String, String)] = [
            (.connection, "Connection", "link"), (.model, "Model", "cpu"),
            (.services, "Services", "server.rack"), (.plugins, "Plugins", "shippingbox"),
            (.identity, "Identity", "person"), (.about, "About", "info.circle"),
        ]
        return HStack(spacing: 22) {
            ForEach(tabs, id: \.0) { t in
                VStack(spacing: 3) {
                    Image(systemName: t.2).font(.system(size: 16))
                    Text(t.1).font(.system(size: 11))
                }
                .foregroundStyle(t.0 == active ? Theme.accent : Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10).background(Theme.surface)
    }

    /// Render-safe stand-in for a Toggle (ImageRenderer can't draw the live switch).
    fileprivate struct StatePill: View {
        let on: Bool
        var body: some View {
            Text(on ? "On" : "Off").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background((on ? Theme.accent : Theme.textSecondary).opacity(0.16)).clipShape(Capsule())
        }
    }

    // Demo messages for the chat screenshot — includes a Vera structured-question card.
    private var shotMessages: [Message] {
        if dotHeader || companionPanel != nil { return store.selected?.messages ?? [] }
        if schedule { return scheduleMessages }
        if command { return commandMessages }
        if folder { return folderMessages }
        var m = store.selected?.messages ?? []
        m.append(Message(role: .assistant, text: """
        <details type="tool_calls" done="true" name="kitchen_status"><summary>Tool Executed</summary>"low: spaghetti, chicken nuggets, pork sausage"</details>
        You're low on a few **staples**:

        - Spaghetti
        - Chicken nuggets
        - Pork sausage

        With those back you could do a quick `Bolognese`. Want me to add them to the list?
        """))
        m.append(Message(role: .user, text: "Keep an eye on lumber prices for me"))
        m.append(Message(role: .assistant, text: """
        <details type="tool_calls" done="true" name="recurring_watch"><summary>Tool Executed</summary>"drafted: Lumber prices"</details>
        Here's the watch I'd set up: 'Lumber prices' will run http fetch then trip band every 30 minutes and post a card to your Pulse when something is worth saying. Should I save it?
        """))
        m.append(Message(role: .assistant, text: "Happy to line up the next batch. Which direction?", ask: VeraAsk.mock()))
        m.append(Message(role: .assistant, text: "Sketched the label mark. Open it in the Canvas to tweak.", artifacts: [Artifact.mock()]))
        m.append(Message.assistant(from: "The downtown farmers market kicks off its 2026 season today.\n\n**Sources** https://www.springfield-downtown.example/news_detail.php https://www.heraldpress.example/story/news/local/2026/06/03/events/90354139007/ https://www.localtv.example/news/downtown-market-2026-schedule.html\n\nLet me know if you want the full vendor list."))
        // A deep-research style cited reply — exercises chips, Sources-section stripping, and the row.
        m.append(Message.assistant(
            from: "Cover crops measurably improve vineyard soil health [1]. Clover mixes also fix nitrogen between rows [2].\n\n**Sources**\n1. Vineyard soil study\n2. Cover crop guide",
            sources: [PulseSource(n: 1, title: "Vineyard soil study", url: "https://viticulture.example/soil-health"),
                      PulseSource(n: 2, title: "Cover crop guide", url: "https://extension.example/cover-crops")]))
        m.append(Message(id: Self.shotPreferenceMessageID, role: .user, text: "Keep answers short with me."))
        m.append(Message(role: .assistant, text: "Will do."))
        return m
    }

    private static let shotPreferenceMessageID = UUID()

    private func shotMarker(for message: Message) -> TranscriptMarker? {
        message.id == Self.shotPreferenceMessageID ? .preferenceSaved : nil
    }

    private var commandMessages: [Message] {
        let ran = NativeToolActivity(id: "c1", toolID: NativeCommandTools.toolID, name: NativeCommandTools.runName, title: "Run a command", round: 1,
                                     request: "{\"command\":\"make check\"}", result: "{\"exit_code\":0}", state: .succeeded, confirmationRequired: true)
        return [
            Message(role: .user, text: "Run the checks so we know the plan still parses."),
            Message(role: .assistant, text: "The checks pass. Two files were linted and nothing needs fixing.",
                    toolActivities: [ran],
                    displayBlocks: [
                        .commandRun(NativeCommandRun(id: "shot-run", command: "make check", directory: "/Volumes/Notes/Greenhouse", outcome: .ran, reason: .userApproved,
                                                     exitCode: 0, stdout: "markdownlint plan.md watering-log.md\n2 files, 0 errors\n", durationMilliseconds: 1840)),
                    ]),
            Message(role: .user, text: "Now rebuild the PDF."),
            Message(role: .assistant, text: "",
                    toolActivities: [NativeToolActivity(id: "c2", toolID: NativeCommandTools.toolID, name: NativeCommandTools.runName, title: "Run a command", round: 1,
                                                        request: "{\"command\":\"make pdf\",\"directory\":\"/Volumes/Notes/Greenhouse\"}", result: nil, state: .pending, confirmationRequired: true)]),
        ]
    }

    private var scheduleActivity: NativeToolActivity {
        NativeToolActivity(id: "s1", toolID: NativeScheduleTools.toolID, name: NativeScheduleTools.toolName, title: "Schedule work", round: 1,
                           request: "{\"title\":\"Morning policy check\",\"worker_type\":\"research\",\"instruction\":\"Summarize overnight developments in semiconductor export policy with sources.\",\"results_to\":\"own_chat\",\"repeat\":\"weekdays\",\"time\":\"07:00\"}",
                           result: nil, state: .pending, confirmationRequired: true)
    }

    private var scheduleMessages: [Message] {
        [
            Message(role: .user, text: "Every weekday at 7 research overnight developments in semiconductor export policy and give me a short summary with sources."),
            Message(role: .assistant, text: "", toolActivities: [scheduleActivity]),
        ]
    }

    private var scheduleConfirmation: NativeToolConfirmationRequest {
        NativeToolConfirmationRequest(activity: scheduleActivity)
    }

    private var shotConfirmation: NativeToolConfirmationRequest {
        NativeToolConfirmationRequest(activity: NativeToolActivity(id: "c2", toolID: NativeCommandTools.toolID, name: NativeCommandTools.runName, title: "Run a command", round: 1,
                                                                   request: "{\"command\":\"make pdf\",\"directory\":\"/Volumes/Notes/Greenhouse\"}", result: nil, state: .pending, confirmationRequired: true))
    }

    private var folderMessages: [Message] {
        let before = "# Greenhouse plan\n\nWater every morning.\nCheck the vents at noon.\nLog the temperature.\n"
        let after = "# Greenhouse plan\n\nWater every morning.\nCheck the vents at noon and 4 PM.\nLog the temperature and humidity.\n"
        var activity = NativeToolActivity(id: "e1", toolID: NativeFolderTools.toolID, name: NativeFolderTools.editName, title: "Edit a file", round: 1,
                                          request: "{\"path\":\"~/Greenhouse/plan.md\"}", result: "{\"replacements\":1}", state: .succeeded, confirmationRequired: false)
        activity.result = "{\"path\":\"~/Greenhouse/plan.md\",\"replacements\":1}"
        return [
            Message(role: .user, text: "Add the afternoon vent check and humidity logging to the plan, and start a watering log file."),
            Message(role: .assistant, text: "Updated the plan and started a log you can fill in each morning.",
                    toolActivities: [activity],
                    displayBlocks: [
                        .fileChange(NativeFileChange(id: "shot-edit", path: "/Volumes/Notes/Greenhouse/plan.md", kind: .edited, before: before, after: after)),
                        .fileChange(NativeFileChange(id: "shot-new", path: "/Volumes/Notes/Greenhouse/watering-log.md", kind: .created, before: nil,
                                                     after: "# Watering log\n\n| Date | Minutes | Notes |\n|---|---|---|\n")),
                    ]),
            Message(role: .user, text: "Run the checks so we know the plan still parses."),
            Message(role: .assistant, text: "The checks pass. Two files were linted and nothing needs fixing.",
                    toolActivities: [NativeToolActivity(id: "c1", toolID: NativeCommandTools.toolID, name: NativeCommandTools.runName, title: "Run a command", round: 1,
                                                        request: "{\"command\":\"make check\"}", result: "{\"exit_code\":0}", state: .succeeded, confirmationRequired: true)],
                    displayBlocks: [
                        .commandRun(NativeCommandRun(id: "shot-run", command: "make check", directory: "/Volumes/Notes/Greenhouse", outcome: .ran, reason: .userApproved,
                                                     exitCode: 0, stdout: "markdownlint plan.md watering-log.md\n2 files, 0 errors\n", durationMilliseconds: 1840)),
                    ]),
        ]
    }

    private var shotGrants: [FolderGrant] { [FolderGrant(id: "shot-grant", path: "/Volumes/Notes/Greenhouse", name: "Greenhouse", bookmark: nil)] }

    private var emptyChatShot: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 22) {
                HStack(spacing: 14) {
                    ConversationFigureView(figure: ConversationPresence.greetingFigure(companionThread: store.isVeraThread(store.selectedID)), size: 56)
                    Text("Good afternoon, Jordan").font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Theme.warmTextPrimary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if attachDemo {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(LinearGradient(colors: [Theme.accent, Theme.accentGlow],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 76, height: 76)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
                            shotFileCard(title: "Vendor Platform Proposal (Software and…", badge: "PPTX")
                            shotSkeletonCard
                        }
                    }
                    shotComposerRow(text: attachDemo ? "What do you make of these?" : "Message \(store.conversationAssistantName)",
                                    typed: attachDemo, active: attachDemo, stop: false)
                }
                .modifier(ShotComposerPill())
                HStack(spacing: 8) {
                    ForEach(["What's on today?", "What's the weather?", "Research a topic for me"], id: \.self) { s in
                        StarterChipLabel(title: s)
                    }
                }
            }
            .frame(maxWidth: 640).padding(.horizontal, 28)
            Spacer(); Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.conversationBackground)
    }

    private func shotComposerRow(text: String, typed: Bool, active: Bool, stop: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            ComposerControlGlyph(kind: .plus)
            Text(text).font(.system(size: ConversationMetrics.bodySize))
                .foregroundStyle(typed ? Theme.warmTextPrimary : Theme.warmTextSecondary)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: ComposerControlGlyph.sendSize, alignment: .leading)
            if voiceAvailability.any {
                ComposerVoiceControls(availability: voiceAvailability, dictating: dictating,
                                      assistantName: store.conversationAssistantName, animated: false)
            }
            if stop {
                ComposerControlGlyph(kind: .stop(enabled: true))
            } else {
                ComposerControlGlyph(kind: .send(active: active, generating: false))
            }
        }
    }

    private var shotComposerText: String {
        if mentions { return "@" }
        if dictating { return "Move the dentist appointment to Thursday and remind me the day before" }
        return "Message \(store.conversationAssistantName)"
    }

    private var shotStatusLine: String {
        if streaming { return "Working on your answer" }
        if command || schedule { return "Waiting for your approval" }
        return "Ready"
    }

    private func shotFileCard(title: String, badge: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(badge).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.surfaceHover).clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(10).frame(width: 152, height: 76, alignment: .topLeading)
        .background(Theme.bg).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
    }

    private var shotSkeletonCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 6).fill(Theme.surfaceHover).frame(height: 11)
            RoundedRectangle(cornerRadius: 6).fill(Theme.surfaceHover).frame(width: 92, height: 11)
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 6).fill(Theme.surfaceHover).frame(width: 42, height: 14)
        }
        .padding(10).frame(width: 152, height: 76, alignment: .topLeading)
        .background(Theme.bg).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
    }

    private var shellChrome: some View {
        HStack(spacing: 0) {
            VeraSidebar(collapsed: .constant(collapsedSidebar), search: .constant(""),
                        workflowEditor: WorkflowEditorStore(), onSelect: { _ in })
                .environmentObject(store)
                .environment(\.renderSafe, true)
            Rectangle().fill(Theme.hairline).frame(width: 1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var chat: some View {
        VStack(spacing: 0) {
            if ConversationPresence.headerKind(companionThread: store.isVeraThread(store.selectedID)) == .conversation, companionPanel == nil {
                ConversationHeader(name: ConversationPresence.headerTitle(conversationTitle: store.selected?.title), status: shotStatusLine)
            }
            VStack(alignment: .leading, spacing: 22) {
                ForEach(shotMessages) { message in
                    MessageRow(message: message, pendingConfirmation: schedule && message.toolActivities.contains { $0.id == "s1" } ? scheduleConfirmation
                        : command && message.toolActivities.contains { $0.id == "c2" } ? shotConfirmation : nil, companionThread: store.isVeraThread(store.selectedID))
                    if let marker = shotMarker(for: message) {
                        TranscriptMarkerRow(marker: marker)
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 26)
            .frame(maxWidth: ConversationMetrics.columnWidth, alignment: .leading)
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .bottom)
            .clipped()
            VStack(alignment: .leading, spacing: 8) {
                if folder || command {
                    FolderGrantChips(grants: shotGrants, onRemove: { _ in })
                }
                if mentions {
                    ComposerMentionList(sections: shotMentionCatalog.sections(""), selection: 1, onHover: { _ in }, onPick: { _ in })
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                shotComposerRow(text: shotComposerText, typed: mentions || dictating, active: dictating, stop: streaming)
            }
            .modifier(ShotComposerPill())
            .padding(.horizontal, 28).padding(.bottom, 18).padding(.top, 6)
            .frame(maxWidth: ConversationMetrics.columnWidth)
        }
        .background(Theme.conversationBackground)

    }

    private var shotMentionCatalog: ComposerMentionCatalog {
        ComposerMentionCatalog(items: [ComposerMentionCatalog.filesItem, ComposerMentionCatalog.folderItem]
            + ComposerMentionCatalog.builtIns(webAvailable: true, imageAvailable: true)
            + [ComposerMentionCatalog.plugin(name: "Home Assistant", serverID: "ha", connected: true, toolIDs: ["a", "b", "c"], allowedIDs: ["a", "b", "c"]),
               ComposerMentionCatalog.plugin(name: "Calendar", serverID: "cal", connected: false, toolIDs: [], allowedIDs: [])])
    }

    private var pulse: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pulse").font(.system(size: 22, weight: .bold))
                Text("\(store.feedCards.count)").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.surface).clipShape(Capsule())
                Spacer()
                Text("today").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: pulseFeedWidth, alignment: .leading).frame(maxWidth: .infinity)
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 8)
            if !store.pulseVeins.isEmpty {
                VeinChipRow(veins: store.pulseVeins, cards: store.pulseCards)
                    .frame(maxWidth: pulseFeedWidth, alignment: .leading).frame(maxWidth: .infinity)
                    .padding(.horizontal, 28).padding(.bottom, 8)
            }
            PulseGrid(cards: store.feedCards).padding(.horizontal, 28).padding(.vertical, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var memory: some View {
        let rows = store.memoryRecords.isEmpty ? NativeMemoryRecord.shotLibrary : store.memoryRecords
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory").font(.system(size: 24, weight: .bold))
                    Text("A local, reviewable library of what Vera may remember about you.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text("\(rows.count) approved").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready").font(.system(size: 12, weight: .semibold))
                    Text("Only approved, relevant, unexpired items can be added to native chat requests.")
                        .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            ForEach(NativeMemoryGroup.allCases) { group in
                let items = rows.filter { $0.group == group }
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.rawValue).font(.system(size: 13, weight: .semibold))
                    ForEach(items) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 12, weight: .semibold))
                                Text(item.summary).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Text(item.updatedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                            Image(systemName: "ellipsis")
                        }
                        .padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    // Static Agentic board for screenshots — the organism map over the mock graph
    // (render-safe: no live controls, animations off, pulses frozen mid-edge).
    private var agenticBoard: some View {
        let graph = AgenticGraph.mock()
        let jobs = Dictionary(uniqueKeysWithValues: SchedulerJob.mock().map { ($0.id, $0) })
        let pulses = [
            CanvasPulse(id: "shot-rivergauge", flowID: "vein_rivergauge", surfaceID: "veins",
                        startedAt: Date().addingTimeInterval(-CanvasPulse.duration / 2)),
        ]
        return VStack(spacing: 0) {
            HStack {
                Text("Agentic").font(.system(size: 22, weight: .bold))
                InfoTip(text: "Everything Vera runs on her own, as one living system.", size: 13)
                Text("\(graph.flows.count) flows").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Theme.surface).clipShape(Capsule())
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 14)
            let viewport = CGSize(width: 882, height: 666)
            let laid = OrganismLayout(graph: graph, viewport: viewport).size
            let scale = min(1, viewport.width / laid.width, viewport.height / laid.height)
            OrganismMap(graph: graph, jobs: jobs, size: viewport, pulses: pulses, animated: false)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
                .clipped()
                .overlay(Rectangle().fill(Theme.hairline).frame(height: 1), alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    // Static Veins board for screenshots — the vein catalog over mock entries
    // (render-safe: StatePill instead of live Toggles).
    private var veinsBoard: some View {
        let entries = VeinEntry.mock()
        return VStack(spacing: 0) {
            HStack {
                Text("Veins").font(.system(size: 22, weight: .bold))
                InfoTip(text: "The ambient watches pinned above the Pulse feed.", size: 13)
                Text("\(entries.filter(\.enabled).count)/6")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.surface).clipShape(Capsule())
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 8)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 14) {
                ForEach(entries) { e in shotVeinCard(e) }
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func shotVeinCard(_ e: VeinEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 9).fill(Theme.surfaceHover)
                    .overlay(Image(systemName: e.icon)
                        .font(.system(size: 17)).foregroundStyle(Theme.textPrimary))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(e.label).font(.system(size: 15, weight: .semibold))
                        InfoTip(text: e.blurb)
                    }
                    HStack(spacing: 5) {
                        Circle().fill(e.enabled ? Color(red: 0.36, green: 0.78, blue: 0.5)
                                                : Theme.textSecondary.opacity(0.5))
                            .frame(width: 6, height: 6)
                        Text(e.enabled ? "On" : "Off")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                if e.canEnable || e.enabled { StatePill(on: e.enabled) }
            }
            ForEach(e.requires.filter { !$0.met }, id: \.label) { req in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                    Text("Requires \(req.label): \(req.detail)").font(.system(size: 11, weight: .medium))
                        .lineLimit(1).truncationMode(.tail)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color.orange.opacity(0.12)).clipShape(Capsule())
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Text("Configure").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Theme.surfaceHover).clipShape(Capsule())
                if let job = e.jobs.first, e.enabled {
                    Text(cronSummary(job.cron)).font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 148)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 1))
    }

    // Static Plugins board for screenshots — the integration store over mock entries
    // (render-safe: StatePill instead of live Toggles).
    private var pluginsBoard: some View {
        let entries = PluginEntry.mock()
        return VStack(spacing: 0) {
            HStack {
                Text("Plugins").font(.system(size: 22, weight: .bold))
                InfoTip(text: "What Vera is connected to: each integration unlocks capabilities across the app.", size: 13)
                Text("\(entries.filter(\.enabled).count)/\(entries.count)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.surface).clipShape(Capsule())
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 8)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 14) {
                ForEach(entries) { e in shotPluginCard(e) }
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func shotPluginCard(_ e: PluginEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                PluginLogo(id: e.id)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(e.displayName).font(.system(size: 15, weight: .semibold))
                        InfoTip(text: e.unlocksLine)
                    }
                    HStack(spacing: 5) {
                        Circle().fill(shotStatusColor(e)).frame(width: 6, height: 6)
                        Text(shotStatusText(e)).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                if e.configured { StatePill(on: e.enabled) }
            }
            if let pairing = e.pairing, pairing.active {
                HStack(spacing: 6) {
                    Image(systemName: "link").font(.system(size: 10))
                    Text("Paired: \(pairing.label)").font(.system(size: 11, weight: .medium))
                        .lineLimit(1).truncationMode(.tail)
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Theme.accent.opacity(0.12)).clipShape(Capsule())
            }
            ForEach(e.features) { f in
                HStack(spacing: 8) {
                    Text(f.label).font(.system(size: 12, weight: .medium))
                    Text("EXPERIMENTAL").font(.system(size: 8, weight: .bold)).tracking(0.5)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15)).clipShape(Capsule())
                    Spacer(minLength: 8)
                    StatePill(on: f.enabled)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.bg.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Spacer(minLength: 0)
            HStack {
                Text(e.configured ? "Configure" : "Add")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(e.configured ? Theme.textPrimary : .white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(e.configured ? Theme.surfaceHover : Theme.accent)
                    .clipShape(Capsule())
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 188)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 1))
    }

    private func shotStatusColor(_ e: PluginEntry) -> Color {
        switch e.status {
        case "enabled": Color(red: 0.36, green: 0.78, blue: 0.5)
        case "error": Color(red: 0.92, green: 0.42, blue: 0.38)
        default: Theme.textSecondary
        }
    }

    private func shotStatusText(_ e: PluginEntry) -> String {
        switch e.status {
        case "enabled": "Connected"
        case "error": e.lastTestDetail.isEmpty ? "Error" : "Error: \(e.lastTestDetail)"
        case "configured": "Off"
        default: "Not connected"
        }
    }

}

private struct ShotComposerPill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: ConversationMetrics.composerRadius, style: .continuous).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: ConversationMetrics.composerRadius, style: .continuous)
                .stroke(Theme.cardStroke, lineWidth: 1))
    }
}
