import Foundation

enum ConversationTitleGenerator {
    static let excerptLimit = 1500

    static func messages(user: String, assistant: String) -> [NativeChatMessage] {
        let system = """
            Write a title for this conversation in three to six words. Use sentence case. \
            Do not use quotes or trailing punctuation. Reply with nothing but the title.
            """
        let body = """
            First message:
            \(String(user.prefix(excerptLimit)))

            First reply:
            \(String(assistant.prefix(excerptLimit)))
            """
        return [NativeChatMessage(role: "system", content: system), NativeChatMessage(role: "user", content: body)]
    }

    static func clean(_ raw: String) -> String? {
        guard let line = raw.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        let wrappers = CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019}*")
        var text = line.trimmingCharacters(in: wrappers.union(.whitespaces))
        if text.lowercased().hasPrefix("title:") {
            text = String(text.dropFirst("title:".count)).trimmingCharacters(in: wrappers.union(.whitespaces))
        }
        while text.hasSuffix(".") { text.removeLast() }
        text = text.trimmingCharacters(in: wrappers.union(.whitespaces))
        let words = text.split(whereSeparator: \.isWhitespace)
        text = words.joined(separator: " ")
        guard let first = text.first else { return nil }
        text = first.uppercased() + text.dropFirst()
        guard (2...8).contains(words.count), text.count <= 60 else { return nil }
        return text
    }

    static func shouldGenerate(for conversation: Conversation, isAssistantThread: Bool) -> Bool {
        guard conversation.titleSource == .fallback, !isAssistantThread else { return false }
        guard let user = conversation.messages.first(where: { $0.role == .user }),
              !user.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let reply = conversation.messages.first(where: { $0.role == .assistant }),
              reply.state == .complete,
              !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    private enum Outcome: Sendable {
        case finished(String?)
        case timedOut
    }

    static func generate(
        transport: any NativeChatTransport, model: String, user: String, assistant: String,
        timeout: Duration = .seconds(20)
    ) async -> String? {
        let prompt = messages(user: user, assistant: assistant)
        let outcome = await withTaskGroup(of: Outcome.self) { group -> Outcome in
            group.addTask {
                do {
                    var latest = ""
                    for try await snapshot in transport.stream(messages: prompt, model: model, tools: []) {
                        latest = snapshot.content
                    }
                    try Task.checkCancellation()
                    return .finished(latest)
                } catch {
                    return .finished(nil)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        guard case .finished(let content) = outcome, let content else { return nil }
        return clean(content)
    }
}
