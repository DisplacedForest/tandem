import Foundation

@MainActor
extension SelfTest {
    static func runCardQuestions() throws {
        let require = NativeTaskFixture.require
        let stop = "Stop work"
        let keep = CardQuestion.make(choices: ["continue", "finish"], stop: stop)
        try require(keep?.allow == "continue" && keep?.decline == "finish" && keep?.answers.allowTitle == "Keep going" && keep?.answers.declineTitle == "Finish"
                        && keep?.answers.declineMenu == [CardMenuItem(id: CardQuestion.stopID, title: stop)] && keep?.answers.allowMenu.isEmpty == true
                        && keep?.controls == 2,
                    "Keep going or finish shows two answers, with stopping in the menu on the second")
        let keepOnly = CardQuestion.make(choices: ["continue", "finish"], stop: nil)
        try require(keepOnly?.answers.declineMenu.isEmpty == true && keepOnly?.controls == 2, "With nothing to stop the two answers have no menu")
        let check = CardQuestion.make(choices: ["it_happened", "it_did_not", "stop"], stop: stop)
        try require(check?.allow == "it_happened" && check?.decline == "it_did_not"
                        && check?.answers.declineMenu == [CardMenuItem(id: "stop", title: "Stop here")] && check?.controls == 2,
                    "A check shows two answers and keeps its own way to stop in the menu, without a second one")
        let retry = CardQuestion.make(choices: ["retry"], stop: stop)
        try require(retry?.allow == "retry" && retry?.decline == CardQuestion.stopID && retry?.answers.allowTitle == "Retry"
                        && retry?.answers.declineTitle == stop && retry?.answers.declineMenu.isEmpty == true && retry?.controls == 2,
                    "Retry shows Retry and the stop answer, and nothing else")
        let retryOnly = CardQuestion.make(choices: ["retry"], stop: nil)
        try require(retryOnly?.decline == nil && retryOnly?.controls == 1, "Retry with nothing to stop is one answer")
        try require(CardQuestion.make(choices: [], stop: stop) == nil, "A card that asks nothing has no question, so it keeps its stop control")
        try require(CardQuestion.make(choices: [NativeCardChoiceKind.allowOnce.rawValue, NativeCardChoiceKind.decline.rawValue], stop: stop) == nil
                        && CardQuestion.make(choices: ["made_up"], stop: stop) == nil,
                    "Approval answers and unknown answers are never drawn as a question")
        try require(NativeTaskCardPresentation.choiceTitle(CardQuestion.stopID) == nil, "The stop marker is never a stored answer")
        for choices in [["continue", "finish"], ["it_happened", "it_did_not", "stop"], ["retry"]] {
            for stopping in [stop, nil] as [String?] {
                guard let question = CardQuestion.make(choices: choices, stop: stopping) else { throw NativeTaskFixture.Failure.assertion("A known question draws") }
                try require(question.controls <= 2, "No question card shows more than two controls")
                let reachable = Set([question.allow] + [question.decline].compactMap { $0 } + question.answers.declineMenu.map(\.id) + question.answers.allowMenu.map(\.id))
                try require(Set(choices).isSubset(of: reachable), "Every answer the work offered is still reachable: \(choices)")
                try require(stopping == nil || reachable.contains(CardQuestion.stopID) || reachable.contains("stop"), "Stopping stays reachable while a question is open")
            }
        }
        print("  card questions OK (keep going or finish, a check, retry, nothing to stop, no question, approval untouched, two controls at most, every answer reachable)")
    }
}
