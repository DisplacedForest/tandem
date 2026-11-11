import Foundation

typealias NativeInstructionAnswerer = @Sendable (_ said: String, _ about: String) async -> Bool

struct NativeInstructionPending: Sendable {
    let signature: String
    let about: String
    let refuse: @Sendable () -> Void
}

enum NativeInstructionCheck {
    @TaskLocal static var cleared: String?

    static let systemPrompt = "You are checking one thing before an assistant acts without asking. You get the person's message and what is about to be done. Answer whether the person, in this message, told the assistant to do exactly this, to exactly this target, now. If the message is a question, a hypothetical, a report of what someone else said, names a different target, or you are not sure, answer false. Reply with only JSON: {\"run\": true} or {\"run\": false}."
    static let saidLabel = "Message:"
    static let aboutLabel = "About to be done:"
    static let timeout = Duration.seconds(15)
    static let seconds: Double = 15
    static let replyCap = 256
    static let targetLimit = 300
    static let saidLimit = 2_000
    static let attemptSuffix = "-check-"

    static func content(said: String, about: String) -> String {
        saidLabel + "\n" + String(said.prefix(saidLimit)) + "\n\n" + aboutLabel + "\n" + about
    }

    static func messages(said: String, about: String) -> [NativeChatMessage] {
        [NativeChatMessage(role: "system", content: systemPrompt), NativeChatMessage(role: "user", content: content(said: said, about: about))]
    }

    static func taskMessages(said: String, about: String) -> [NativeTaskGenerationMessage] {
        [NativeTaskGenerationMessage(role: "system", content: systemPrompt), NativeTaskGenerationMessage(role: "user", content: content(said: said, about: about))]
    }

    static func clean(_ value: String) -> String {
        let flat = value.unicodeScalars.map { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String(flat.trimmingCharacters(in: .whitespaces).prefix(targetLimit))
    }

    static func about(_ title: String, targets: [String]) -> String {
        let action = clean(title)
        let named = targets.map(clean).filter { !$0.isEmpty }
        return named.isEmpty ? action + "." : action + ": " + named.joined(separator: ", ") + "."
    }

    static func about(_ definition: NativeToolDefinition, arguments: [String: NativeJSONValue], targets: [NativeRuleTarget], names: [String] = []) -> String {
        if definition.id == NativeCommandTools.toolID, case .string(let command)? = arguments["command"] {
            return about(definition.title, targets: [NativeInstruction.canonical(command)])
        }
        return about(definition.title, targets: targets.map(\.value) + names)
    }

    static func parse(_ reply: String) -> Bool {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<think>") {
            guard let close = text.range(of: "</think>") else { return false }
            text = String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.range(of: #"\A\{[ \t\r\n]*"run"[ \t\r\n]*:[ \t\r\n]*true[ \t\r\n]*\}\z"#, options: .regularExpression) != nil
    }

    static func bounded(_ timeout: Duration, _ answer: @escaping @Sendable () async -> Bool) async -> Bool {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        guard let yes = try? await NativeInferenceDeadline.run(seconds: seconds, body: { await answer() }) else { return false }
        return yes && !Task.isCancelled
    }

    static func ask(transport: any NativeChatTransport, model: String, said: String, about: String, timeout: Duration = Self.timeout) async -> Bool {
        let prompt = messages(said: said, about: about)
        let quick: any NativeChatTransport = (transport as? NativeChatClient)?.briefly(cap: replyCap) ?? transport
        return await bounded(timeout) {
            do {
                var latest: NativeChatStreamSnapshot?
                for try await snapshot in quick.stream(messages: prompt, model: model, tools: []) {
                    guard snapshot.toolCalls.isEmpty else { return false }
                    latest = snapshot
                }
                try Task.checkCancellation()
                guard let latest, latest.toolCalls.isEmpty else { return false }
                return parse(latest.content)
            } catch {
                return false
            }
        }
    }
}
