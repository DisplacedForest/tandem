import SwiftUI

struct RulesAdvancedState: Equatable {
    enum Question: Equatable {
        case open
        case allow(NativeFloorItem)
        case withoutAsking(NativeFloorItem)
    }

    enum Answer: Equatable {
        case allow(NativeFloorItem)
        case withoutAsking(NativeFloorItem)
    }

    private(set) var isOpen = false
    private(set) var question: Question?

    mutating func askToOpen() {
        guard !isOpen else { return }
        question = .open
    }

    mutating func ask(_ item: NativeFloorItem) {
        guard isOpen, item.isLiftable else { return }
        question = .allow(item)
    }

    mutating func cancel() { question = nil }

    mutating func choose(_ choice: NativeRuleChoice, for item: NativeFloorItem) -> Bool {
        guard isOpen, item.isLiftable else { return false }
        guard choice == .act else { return true }
        question = .withoutAsking(item)
        return false
    }

    mutating func confirm() -> Answer? {
        defer { question = nil }
        switch question {
        case .open:
            isOpen = true
            return nil
        case .allow(let item):
            return isOpen ? .allow(item) : nil
        case .withoutAsking(let item):
            return isOpen ? .withoutAsking(item) : nil
        case nil:
            return nil
        }
    }

    mutating func leave() {
        isOpen = false
        question = nil
    }
}

enum RulesAdvancedCopy {
    static let title = "Advanced"
    static let open = "Open Advanced"
    static let close = "Close Advanced"
    static let openQuestion = "Open Advanced?"
    static let openDetailTemplate = "This is where you can let \(CompanionSentence.placeholder) do things that are otherwise always left to you."
    static let openConfirm = "Open"
    static let cancel = "Cancel"
    static let allowTemplate = "Let \(CompanionSentence.placeholder) do this"
    static let takeBack = "Leave it to me again"

    static func lowered(_ text: String) -> String { text.prefix(1).lowercased() + text.dropFirst() }

    static func allowQuestionTemplate(_ item: NativeFloorItem) -> String {
        "Let \(CompanionSentence.placeholder) \(lowered(item.title))?"
    }

    static func withoutAskingQuestionTemplate(_ item: NativeFloorItem) -> String {
        "Let \(CompanionSentence.placeholder) \(lowered(item.title)) without asking?"
    }

    static func questionTemplate(_ question: RulesAdvancedState.Question?) -> String {
        switch question {
        case .open: return openQuestion
        case .allow(let item): return allowQuestionTemplate(item)
        case .withoutAsking(let item): return withoutAskingQuestionTemplate(item)
        case nil: return ""
        }
    }

    static func question(_ question: RulesAdvancedState.Question?, name: String?) -> String {
        CompanionSentence.plain(questionTemplate(question), name: name)
    }

    static func detailTemplate(_ question: RulesAdvancedState.Question?) -> String {
        switch question {
        case .open: return openDetailTemplate
        case .allow(let item), .withoutAsking(let item): return item.reason
        case nil: return ""
        }
    }

    static func confirmTemplate(_ question: RulesAdvancedState.Question?) -> String {
        switch question {
        case .open: return openConfirm
        case .allow: return allowTemplate
        case .withoutAsking: return NativeRuleChoice.act.title
        case nil: return ""
        }
    }

    static func detail(_ question: RulesAdvancedState.Question?, name: String?) -> String {
        switch question {
        case .open: return CompanionSentence.plain(openDetailTemplate, name: name)
        case .allow(let item), .withoutAsking(let item): return item.reason
        case nil: return ""
        }
    }

    static func confirm(_ question: RulesAdvancedState.Question?, name: String?) -> String {
        switch question {
        case .open: return openConfirm
        case .allow: return CompanionSentence.plain(allowTemplate, name: name)
        case .withoutAsking: return NativeRuleChoice.act.title
        case nil: return ""
        }
    }

    static func allowed(_ rules: NativeRules) -> [NativeFloorItem] {
        NativeFloorItem.allCases.filter { $0.isLiftable && rules.isLifted($0) }
    }

    static func offered(_ rules: NativeRules) -> [NativeFloorItem] {
        NativeFloorItem.allCases.filter { $0.isLiftable && !rules.isLifted($0) }
    }

    static func leftToYou(_ rules: NativeRules) -> [NativeFloorItem] {
        NativeFloorItem.allCases.filter { !rules.isLifted($0) }
    }

    static func follows(_ item: NativeFloorItem, rules: NativeRules) -> String {
        guard let action = item.actionClass else { return "" }
        return rules.choice(for: action).title
    }

    static func screenStrings(name: String?) -> [String] {
        var strings = [title, open, close, openConfirm, cancel, takeBack, CompanionSentence.plain(allowTemplate, name: name)]
        let liftable = NativeFloorItem.allCases.filter(\.isLiftable)
        let questions: [RulesAdvancedState.Question] = [.open] + liftable.map { .allow($0) } + liftable.map { .withoutAsking($0) }
        for question in questions {
            strings.append(self.question(question, name: name))
            strings.append(detail(question, name: name))
            strings.append(confirm(question, name: name))
        }
        return strings
    }
}

struct RulesLeftToYouRow: View {
    let item: NativeFloorItem
    @Binding var state: RulesAdvancedState
    @Environment(\.companionName) private var name

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                Text(item.reason).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if state.isOpen && item.isLiftable {
                Button {
                    state.ask(item)
                } label: {
                    CompanionNamedText(template: RulesAdvancedCopy.allowTemplate)
                }
                .accessibilityLabel("\(CompanionSentence.plain(RulesAdvancedCopy.allowTemplate, name: name)): \(item.title)")
            }
        }
        .padding(.vertical, 2)
    }
}

struct RulesAdvancedSection: View {
    @Binding var state: RulesAdvancedState
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore
    @Environment(\.companionName) private var name

    private var rules: NativeRules { config.nativeSettings.rules }

    private func choice(for item: NativeFloorItem) -> Binding<NativeRuleChoice> {
        Binding(
            get: { item.actionClass.map { rules.choice(for: $0) } ?? .handOff },
            set: { picked in
                if state.choose(picked, for: item) { config.setChoice(picked, for: item, store: store) }
            })
    }

    private var asking: Binding<Bool> {
        Binding(get: { state.question != nil }, set: { if !$0 { state.cancel() } })
    }

    var body: some View {
        Section(RulesAdvancedCopy.title) {
            if state.isOpen {
                Button(RulesAdvancedCopy.close) { state.leave() }
            } else {
                Button(RulesAdvancedCopy.open) { state.askToOpen() }
            }
            ForEach(RulesAdvancedCopy.allowed(rules), id: \.self) { item in
                HStack(alignment: .center, spacing: 10) {
                    if state.isOpen {
                        Picker(item.title, selection: choice(for: item)) {
                            ForEach(NativeRuleChoice.allCases, id: \.self) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                            Text(RulesAdvancedCopy.follows(item, rules: rules))
                                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button(RulesAdvancedCopy.takeBack) { config.leaveToMe(item, store: store) }
                            .accessibilityLabel("\(RulesAdvancedCopy.takeBack): \(item.title)")
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .sheet(isPresented: asking) {
            RulesAdvancedQuestionView(question: state.question, onCancel: { state.cancel() }) {
                switch state.confirm() {
                case .allow(let item): config.letThrough(item, store: store)
                case .withoutAsking(let item): config.setChoice(.act, for: item, store: store)
                case nil: break
                }
            }
        }
    }
}

struct RulesAdvancedQuestionView: View {
    let question: RulesAdvancedState.Question?
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CompanionNamedText(template: RulesAdvancedCopy.questionTemplate(question))
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            CompanionNamedText(template: RulesAdvancedCopy.detailTemplate(question))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(RulesAdvancedCopy.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(action: onConfirm) {
                    CompanionNamedText(template: RulesAdvancedCopy.confirmTemplate(question))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
    }
}
