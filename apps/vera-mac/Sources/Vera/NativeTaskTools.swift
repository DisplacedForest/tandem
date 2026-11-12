import Foundation

enum NativeTaskTools {
    static let toolID = "background-research"
    static let toolName = "create_background_task"
    static let searchUnavailable = "Web search is not set up, so research can't run. Add a search URL in Settings, Search, and ask again. Writing a document still works."

    static let description = "Start one piece of longer work only when the current user message explicitly asks for research or for a written document. Earlier conversation requests do not authorize more. Use worker_type research to investigate a question from web sources and deliver a cited report; use worker_type document to write a longer deliverable from the objective (the brief) and the deliverables (facts, notes or requirements to include). Give a short title for the result. Then reply with one short first-person sentence that says what you're going to do in the person's terms, for example: I'll compare quiet reading spaces at three public libraries using their official websites. End your turn there. The result arrives in this conversation by itself, so don't wait for it, don't say it's done, don't say where or how it will arrive, and don't describe it as started, queued or running somewhere else. Do not repeat its status on unrelated turns or expose internal identifiers."

    static let acknowledged = "Saved. Reply with one short first-person sentence saying what you'll do, then end your turn."

    static let generalWorkerType = "general"
    static let generalDescription = " In this conversation you may also use worker_type general, with the objective saying what to do, for anything the person asks to have done that takes more than a reply: one call per separate thing asked, never for something you can simply answer."
    static let generalLimit = 4000
    static let laterRound = "This can only be started from what the person asked, at the start of a reply."
    static let notStarted = "Nothing was started. Ask again in a moment."
    static let pausedReply = "I'm paused, so this wasn't started. Resume me and ask again."

    struct NotStarted: Error, Sendable {
        let message: String
    }

    static func enabledIDs(_ existing: Set<String>, hasEngine: Bool, hasRepository: Bool, general: Bool = false) -> Set<String> {
        let base = existing.subtracting([toolID])
        guard general || base.contains(NativeWebTools.researchToolID), hasEngine, hasRepository else { return base }
        return base.union([toolID])
    }

    static func definition(service: NativeTaskHandoffService, origin: NativeTaskOrigin,
                           profile: NativeTaskProfileBinding?,
                           searchAvailable: @escaping @Sendable () -> Bool = { NativeWebSearch.resolvedBase() != nil },
                           allowedWorkerTypes: @escaping @Sendable () -> Set<String> = { NativeResearchTaskRequest.chatWorkerTypes },
                           general: (@Sendable (_ assignment: String) async throws -> NativeResearchTaskRequest)? = nil,
                           didSave: @escaping @Sendable (NativeTaskReference) async -> Void) -> NativeToolDefinition {
        let kinds: [NativeJSONValue] = [.string("research"), .string("document")] + (general == nil ? [] : [.string(generalWorkerType)])
        return NativeToolDefinition(id: toolID, name: toolName, title: "Start work",
            description: description + (general == nil ? "" : generalDescription),
            parameters: .object([
                "type": .string("object"), "additionalProperties": .bool(false),
                "required": .array([.string("worker_type"), .string("objective")]),
                "properties": .object([
                    "worker_type": .object(["type": .string("string"), "enum": .array(kinds)]),
                    "title": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(200),
                                      "description": .string("Short title for the result")]),
                    "objective": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(5000)]),
                    "deliverables": .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(5),
                        "items": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(500)])]),
                ]),
            ]), confirmation: .none, timeout: .seconds(10), effect: .read, isAvailable: { true }, execute: { arguments in
                let position = NativeToolCallContext.sameToolOrdinal
                if general != nil, position == nil { throw NativeToolError.failed(notStarted) }
                guard Set(arguments.keys).isSubset(of: ["worker_type", "title", "objective", "deliverables"]),
                      case .string(let workerType) = arguments["worker_type"],
                      NativeResearchTaskRequest.chatWorkerTypes.contains(workerType) || (general != nil && workerType == generalWorkerType),
                      case .string(let objective) = arguments["objective"] else {
                    throw NativeToolError.invalidArguments("Provide a worker type, an objective and deliverables.")
                }
                let request: NativeResearchTaskRequest
                if workerType == generalWorkerType, let general {
                    guard NativeToolCallContext.round == 1, NativeToolCallContext.otherToolRan == false else {
                        return .object(["message": .string(laterRound), "started": .bool(false)])
                    }
                    guard allowedWorkerTypes().contains(workerType) else {
                        throw NativeToolError.failed("Nothing was started, because this message did not allow it.")
                    }
                    let assignment = objective.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard assignment.count <= generalLimit else {
                        throw NativeToolError.invalidArguments("Keep the objective under \(generalLimit) characters.")
                    }
                    do {
                        request = try await general(assignment)
                        try Task.checkCancellation()
                    } catch let refusal as NotStarted {
                        return .object(["message": .string(refusal.message), "started": .bool(false)])
                    }
                } else {
                    guard case .array(let values) = arguments["deliverables"] else {
                        throw NativeToolError.invalidArguments("Provide a worker type, an objective and deliverables.")
                    }
                    var title: String?
                    if let raw = arguments["title"] {
                        guard case .string(let text) = raw else { throw NativeToolError.invalidArguments("The title must be text.") }
                        title = text
                    }
                    let deliverables = try values.map { value -> String in
                        guard case .string(let text) = value else {
                            throw NativeToolError.invalidArguments("Each deliverable must be text.")
                        }
                        return text
                    }
                    guard allowedWorkerTypes().contains(workerType) else {
                        throw NativeToolError.failed(workerType == "document"
                            ? "The current message did not ask for a document to be written, so nothing was started."
                            : "The current message did not ask for research, so nothing was started.")
                    }
                    if workerType == "research", !searchAvailable() {
                        throw NativeToolError.failed(searchUnavailable)
                    }
                    request = try NativeResearchTaskRequest(objective: objective, deliverables: deliverables, workerType: workerType, title: title)
                }
                var placed = origin
                if general != nil, let position, position > 0 { placed.index = position }
                try Task.checkCancellation()
                let reference = try await service.submit(origin: placed, request: request, profile: profile)
                await didSave(reference)
                let message: String
                switch reference.deliveryState {
                case .accepted, .pending: message = acknowledged
                case .rejected: message = reference.lastDeliveryError ?? "This couldn't be started."
                }
                if reference.cancelRequested || reference.snapshot?.state == .canceled {
                    return .object(["message": .string("This message's request was stopped earlier. Say so in one short sentence."), "started": .bool(false)])
                }
                if reference.snapshot?.state == .completed {
                    return .object(["message": .string("This message's result was already sent in this conversation. Say so in one short sentence."), "started": .bool(false)])
                }
                if let state = reference.snapshot?.state, [.blocked, .needsDecision, .failed].contains(state) {
                    return .object(["message": .string("This message's request is waiting on the person. Say so in one short sentence."), "started": .bool(false)])
                }
                if reference.deliveryState == .rejected {
                    return .object(["error": .string(message), "started": .bool(false)])
                }
                return .object(["message": .string(message), "started": .bool(reference.deliveryState == .accepted)])
            })
    }
}
