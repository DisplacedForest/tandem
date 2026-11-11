import SwiftUI

struct ScheduledView: View {
    @EnvironmentObject var store: ChatStore
    var renderSafe = false
    @State private var selectedID: String?
    @State private var editing: ScheduleEditorTarget?
    @State private var confirmingDelete: NativeSchedule?

    private var selected: NativeSchedule? {
        store.schedules.first(where: { $0.id == selectedID })
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if store.menuBarIsDefaulted { menuBarNotice }
                if let error = store.scheduleError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 24).padding(.bottom, 8)
                }
                if store.schedules.isEmpty {
                    emptyState
                } else {
                    scheduleList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let selected {
                Rectangle().fill(Theme.hairline).frame(width: 1)
                ScheduleDetail(schedule: selected, runs: store.scheduleRuns[selected.id] ?? [], renderSafe: renderSafe,
                               onEdit: { editing = .existing(selected) })
                    .frame(width: 380)
            }
        }
        .background(Theme.bg)
        .sheet(item: $editing) { target in
            ScheduleEditor(target: target) { draft in
                switch target {
                case .new:
                    if let created = store.createSchedule(draft) { selectedID = created.id }
                case .existing(let schedule):
                    store.updateSchedule(schedule.id, with: draft)
                }
            }
            .environmentObject(store)
        }
        .confirmationDialog("Delete this schedule?", isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
                            presenting: confirmingDelete) { schedule in
            Button("Delete \(schedule.title)", role: .destructive) {
                store.deleteSchedule(schedule.id)
                if selectedID == schedule.id { selectedID = nil }
            }
        } message: { _ in
            Text("Its run history goes with it. Chats that hold past results stay.")
        }
        .onAppear {
            store.reloadSchedules()
            if selectedID == nil { selectedID = store.schedules.first?.id }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scheduled").font(.system(size: 22, weight: .semibold))
                CompanionNamedText(template: "Work {name} runs on a schedule while Tandem is open or in the menu bar.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button { editing = .new } label: { Label("New schedule", systemImage: "plus") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 16)
    }

    private var menuBarNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "menubar.rectangle").foregroundStyle(Theme.accent)
            Text("Tandem now keeps running in the menu bar when you close the window, so these can fire on time. Change this in Settings, Identity.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 24).padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: AppSection.scheduled.icon).font(.system(size: 30, weight: .light)).foregroundStyle(Theme.textSecondary)
            Text("Nothing scheduled yet").font(.system(size: 16, weight: .semibold))
            Text("Set up research or a document to run every day, on weekdays, weekly, every few hours, or once.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("New schedule") { editing = .new }.padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scheduleList: some View {
        ShotSafeScroll(renderSafe: renderSafe) {
            VStack(spacing: 8) {
                ForEach(store.schedules) { schedule in
                    ScheduleRow(schedule: schedule, selected: schedule.id == selectedID,
                                pausedNote: NativeScheduleControls.pausedNote(schedule, assistantPaused: store.isDotPaused),
                                openOutcome: (store.scheduleRuns[schedule.id] ?? []).first { $0.outcome.isOpen }?.outcome)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = schedule.id }
                        .contextMenu { actions(for: schedule) }
                        .overlay(alignment: .trailing) {
                            if renderSafe { EmptyView() } else {
                            Menu { actions(for: schedule) } label: {
                                Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).frame(width: 28, height: 28)
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                            .padding(.trailing, 10)
                            .accessibilityLabel("Actions for \(schedule.title)")
                            }
                        }
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func actions(for schedule: NativeSchedule) -> some View {
        ScheduleControlButtons(schedule: schedule, onEdit: { editing = .existing(schedule) })
        Divider()
        Button("Delete", role: .destructive) { confirmingDelete = schedule }
    }
}

private struct ScheduleRow: View {
    let schedule: NativeSchedule
    let selected: Bool
    var pausedNote: String? = nil
    let openOutcome: NativeScheduleOutcome?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: schedule.isDocument ? "doc.text" : "magnifyingglass")
                .font(.system(size: 15)).foregroundStyle(Theme.accent).frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(schedule.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                CompanionLineText(line: NativeScheduleControls.resultsLine("\(schedule.cadenceSummary). ", toCompanion: schedule.owner == .dot))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                CompanionLineText(line: statusLine).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 36)
        }
        .padding(14)
        .background(selected ? Theme.surfaceSelected : Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var statusLine: CompanionLine {
        switch openOutcome {
        case .running: return .literal("Running now")
        case .waiting: return .literal("Waiting for you")
        case .blocked: return .literal("Blocked")
        default: break
        }
        guard schedule.enabled else { return .literal("Paused") }
        if let pausedNote { return .named(pausedNote) }
        var parts: [String] = []
        if let next = schedule.nextRunAt {
            parts.append("Next \(NativeScheduleClock.relative(next, now: Date(), timeZone: schedule.timeZone))")
        }
        if let outcome = schedule.lastOutcome, let at = schedule.lastRunAt {
            parts.append("\(outcome.title) \(NativeScheduleClock.relative(at, now: Date(), timeZone: schedule.timeZone))")
        }
        return .literal(parts.isEmpty ? "Waiting for its first run" : parts.joined(separator: ". "))
    }
}

private struct ScheduleDetail: View {
    @EnvironmentObject var store: ChatStore
    let schedule: NativeSchedule
    let runs: [NativeScheduleRun]
    let renderSafe: Bool
    let onEdit: () -> Void

    var body: some View {
        ShotSafeScroll(renderSafe: renderSafe) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(schedule.title).font(.system(size: 17, weight: .semibold))
                    CompanionLineText(line: NativeScheduleControls.resultsLine("\(schedule.workTitle). \(schedule.cadenceSummary). ", toCompanion: schedule.owner == .dot, end: "."))
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Text(schedule.instruction).font(.system(size: 13)).textSelection(.enabled).padding(.top, 4)
                }
                HStack(spacing: 10) {
                    ScheduleControlButtons(schedule: schedule, onEdit: onEdit)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Runs").font(.system(size: 13, weight: .semibold))
                    if runs.isEmpty {
                        Text("No runs yet.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(runs) { run in
                        ScheduleRunRow(run: run, note: store.scheduleRunNote(run), timeZone: schedule.timeZone,
                                       onOpen: run.conversationID == nil || renderSafe ? nil : { store.openScheduleRun(run) },
                                       onStop: run.outcome.isOpen && run.taskReferenceID != nil && !renderSafe ? { store.stopScheduleRun(run) } : nil,
                                       choices: store.scheduleRunDecision(run)?.choices ?? (run.outcome == .waiting ? ["retry"] : []),
                                       covers: store.scheduleRunDecision(run)?.covers, neverTitle: store.scheduleRunDecision(run)?.never,
                                       literal: store.scheduleRunDecision(run)?.details,
                                       onChoose: renderSafe ? nil : { store.answerScheduleRun(run, choice: $0) })
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ScheduleControlButtons: View {
    @EnvironmentObject var store: ChatStore
    let schedule: NativeSchedule
    let onEdit: () -> Void

    var body: some View {
        ForEach(NativeScheduleControls.controls(for: schedule, assistantPaused: store.isDotPaused), id: \.self) { control in
            Button {
                switch control {
                case .runNow: store.runScheduleNow(schedule.id)
                case .pause: store.setSchedule(schedule.id, enabled: false)
                case .resume: store.setSchedule(schedule.id, enabled: true)
                case .resumeAssistant: store.setDotState(.active)
                case .edit: onEdit()
                }
            } label: {
                CompanionNamedText(template: NativeScheduleControls.title(control))
            }
        }
    }
}

private struct ScheduleRunRow: View {
    let run: NativeScheduleRun
    let note: CompanionLine
    let timeZone: TimeZone
    let onOpen: (() -> Void)?
    let onStop: (() -> Void)?
    let choices: [String]
    var covers: String? = nil
    var neverTitle: String? = nil
    var literal: String? = nil
    let onChoose: ((String) -> Void)?

    private var isApproval: Bool {
        choices.contains(NativeCardChoiceKind.allowOnce.rawValue) && choices.contains(NativeCardChoiceKind.decline.rawValue)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: run.outcome.symbol).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(run.outcome.title), \(NativeScheduleClock.relative(run.scheduledFor, now: Date(), timeZone: timeZone))")
                            .font(.system(size: 13, weight: .medium))
                        if !run.detail.isEmpty {
                            CompanionLineText(line: note).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    if let onStop { Button("Stop", action: onStop).buttonStyle(.borderless).font(.system(size: 12)).fixedSize() }
                    if let onOpen { Button("Open", action: onOpen).buttonStyle(.borderless).font(.system(size: 12)).fixedSize() }
                }
                if isApproval, let literal, !literal.isEmpty, literal.unicodeScalars.count <= 20000 {
                    Text(literal)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled).lineLimit(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.bg))
                        .accessibilityLabel("Action details: " + literal)
                }
                if isApproval {
                    CardAnswerRow(answers: CardAnswers.task(choices: choices, covers: covers, neverTitle: neverTitle, run: true),
                                  defaultApproval: false, allowApprove: onChoose != nil, allowDecline: onChoose != nil,
                                  onAllow: { onChoose?(NativeCardChoiceKind.allowOnce.rawValue) },
                                  onDecline: { onChoose?(NativeCardChoiceKind.decline.rawValue) },
                                  onItem: { onChoose?($0) })
                } else if !choices.isEmpty {
                    HStack(spacing: 8) { choiceButtons }
                }
            }
        }
        .padding(10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var choiceButtons: some View {
        ForEach(choices, id: \.self) { choice in
            Button(Self.title(for: choice)) { onChoose?(choice) }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
        }
    }

    static func title(for choice: String) -> String {
        switch choice.lowercased() {
        case "retry": return "Retry"
        case "stop", "cancel": return "Stop"
        default: return NativeTaskCardPresentation.choiceTitle(choice) ?? (choice.prefix(1).uppercased() + choice.dropFirst())
        }
    }
}

enum ScheduleEditorTarget: Identifiable {
    case new
    case existing(NativeSchedule)

    var id: String {
        switch self {
        case .new: return "new"
        case .existing(let schedule): return schedule.id
        }
    }
}

struct ScheduleEditor: View {
    enum Repeat: String, CaseIterable, Identifiable {
        case daily, weekdays, weekly, hours, once
        var id: String { rawValue }
        var title: String {
            switch self {
            case .daily: return "Every day"
            case .weekdays: return "Weekdays"
            case .weekly: return "Weekly"
            case .hours: return "Every few hours"
            case .once: return "Once"
            }
        }
    }

    let target: ScheduleEditorTarget
    let onSave: (NativeScheduleDraft) -> Void
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = NativeScheduleDraft()
    @State private var repeatMode: Repeat = .daily
    @State private var time = Date()
    @State private var weekday = 2
    @State private var hours = 6
    @State private var onceAt = Date().addingTimeInterval(3600)
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New schedule" : "Edit schedule").font(.system(size: 17, weight: .semibold)).padding(.bottom, 14)
            Form {
                TextField("Name", text: $draft.title, prompt: Text("Morning news check"))
                Picker("Work", selection: $draft.workerType) {
                    Text("Research").tag("research")
                    Text("Document").tag("document")
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 6) {
                    Text(draft.workerType == "document" ? "What to write" : "What to look into")
                    TextEditor(text: $draft.instruction)
                        .font(.system(size: 13))
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
                }
                Picker("Results go to", selection: $draft.owner) {
                    Text(store.companion.leading).tag(NativeScheduleOwner.dot)
                    Text("Its own chat").tag(NativeScheduleOwner.conversation)
                }
                Picker("Repeat", selection: $repeatMode) {
                    ForEach(Repeat.allCases) { Text($0.title).tag($0) }
                }
                switch repeatMode {
                case .daily, .weekdays:
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                case .weekly:
                    Picker("Day", selection: $weekday) {
                        ForEach(1...7, id: \.self) { Text(NativeScheduleCadence.weekdayName($0)).tag($0) }
                    }
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                case .hours:
                    Stepper("Every \(hours) \(hours == 1 ? "hour" : "hours")", value: $hours, in: 1...NativeScheduleCadence.maximumHours)
                case .once:
                    DatePicker("When", selection: $onceAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                }
            }
            .formStyle(.columns)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.top, 10)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(22)
        .frame(width: 480)
        .onAppear(perform: load)
    }

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private func load() {
        guard case .existing(let schedule) = target else { return }
        draft = NativeScheduleDraft(schedule)
        switch schedule.cadence {
        case .daily(let minute): repeatMode = .daily; time = Self.date(minute: minute)
        case .weekdays(let minute): repeatMode = .weekdays; time = Self.date(minute: minute)
        case .weekly(let day, let minute): repeatMode = .weekly; weekday = day; time = Self.date(minute: minute)
        case .everyHours(let count): repeatMode = .hours; hours = count
        case .once(let at): repeatMode = .once; onceAt = at
        }
    }

    private static func date(minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }

    private var minuteOfDay: Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func save() {
        switch repeatMode {
        case .daily: draft.cadence = .daily(minuteOfDay: minuteOfDay)
        case .weekdays: draft.cadence = .weekdays(minuteOfDay: minuteOfDay)
        case .weekly: draft.cadence = .weekly(weekday: weekday, minuteOfDay: minuteOfDay)
        case .hours: draft.cadence = .everyHours(hours)
        case .once: draft.cadence = .once(onceAt)
        }
        do {
            _ = try NativeSchedule(owner: draft.owner, workerType: draft.workerType, title: draft.title,
                                   instruction: draft.instruction, cadence: draft.cadence, timeZone: .current)
        } catch {
            problem = error.localizedDescription
            return
        }
        if case .once(let at) = draft.cadence, at <= Date() {
            problem = "Pick a time that is still ahead."
            return
        }
        onSave(draft)
        dismiss()
    }
}

struct ShotSafeScroll<Content: View>: View {
    let renderSafe: Bool
    var axis: Axis.Set = .vertical
    @ViewBuilder let content: () -> Content

    var body: some View {
        if renderSafe {
            VStack(spacing: 0) { content() }.frame(maxWidth: .infinity, maxHeight: axis == .vertical ? .infinity : nil, alignment: .topLeading)
        } else {
            ScrollView(axis, showsIndicators: axis.contains(.horizontal)) { content() }
        }
    }
}
