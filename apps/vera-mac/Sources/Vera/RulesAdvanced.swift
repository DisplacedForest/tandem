import SwiftUI

struct RulesAdvancedState: Equatable {
    enum Question: Equatable {
        case open
        case allow(NativeFloorItem)
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

    mutating func confirm() -> NativeFloorItem? {
        defer { question = nil }
        switch question {
        case .open:
            isOpen = true
            return nil
        case .allow(let item):
            return isOpen ? item : nil
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

    static func question(_ question: RulesAdvancedState.Question?, name: String?) -> String {
        switch question {
        case .open: return openQuestion
        case .allow(let item): return CompanionSentence.plain(allowQuestionTemplate(item), name: name)
        case nil: return ""
        }
    }

    static func detail(_ question: RulesAdvancedState.Question?, name: String?) -> String {
        switch question {
        case .open: return CompanionSentence.plain(openDetailTemplate, name: name)
        case .allow(let item): return item.reason
        case nil: return ""
        }
    }

    static func confirm(_ question: RulesAdvancedState.Question?, name: String?) -> String {
        switch question {
        case .open: return openConfirm
        case .allow: return CompanionSentence.plain(allowTemplate, name: name)
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
        let questions: [RulesAdvancedState.Question] = [.open] + NativeFloorItem.allCases.filter(\.isLiftable).map { .allow($0) }
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                        Text(RulesAdvancedCopy.follows(item, rules: rules))
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(RulesAdvancedCopy.takeBack) { config.leaveToMe(item, store: store) }
                        .accessibilityLabel("\(RulesAdvancedCopy.takeBack): \(item.title)")
                }
                .padding(.vertical, 2)
            }
        }
        .confirmationDialog(RulesAdvancedCopy.question(state.question, name: name), isPresented: asking, titleVisibility: .visible) {
            Button(RulesAdvancedCopy.confirm(state.question, name: name)) {
                if let item = state.confirm() { config.letThrough(item, store: store) }
            }
            Button(RulesAdvancedCopy.cancel, role: .cancel) { state.cancel() }
        } message: {
            Text(RulesAdvancedCopy.detail(state.question, name: name))
        }
    }
}
