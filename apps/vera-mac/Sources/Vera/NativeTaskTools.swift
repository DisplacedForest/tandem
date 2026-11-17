import Foundation

enum NativeTaskTools {
    static let toolID = "background-research"
    static let toolName = "create_background_task"
    static let searchUnavailable = "Web search is not set up, so research can't run. Add a search URL in Settings, Search, and ask again. Writing a document still works."

    static let description = "Starts one piece of work that carries on while the conversation continues and posts its result in this conversation when it is ready. When to use: the person wants research across many sources gathered into a cited report, or a written document, such as a report, plan or guide, that the person wants created and saved in their Library. When not to use: a quick question you can answer from what you know or from one web_search call, so just answer it; reading one known page, which fetch_page does; something that should happen later or on a repeat, which schedule_task handles when it is offered; a short piece of writing the person only wants to read in your reply, not keep. Effects: saves and starts one new piece of work and changes nothing else; the app does not ask first. Inputs: worker_type research investigates a question from web sources and needs web search set up; worker_type document writes from the objective, which is the brief, and the deliverables, which are the facts, notes or requirements to include. Give a short title for the result. Returns message and started. Then reply with one short first-person sentence that says what you'll do in the person's terms, and end your turn. The result arrives by itself, so don't wait for it, don't say it's done, don't say where or how it will arrive, don't repeat its status on unrelated turns, and never show identifiers. If it says nothing was started, say so in one sentence and help as well as you can in the conversation."

    static let missingArguments = "Provide the kind of work, an objective and deliverables."

    static let acknowledged = "Saved. Reply with one short first-person sentence saying what you'll do, then end your turn."

    static let generalWorkerType = "general"
    static let generalDescription = " In this conversation you may also use worker_type general for anything the person wants done that takes more than a reply, such as work across several steps or tools: the objective says what to do, in up to \(generalLimit) characters, and deliverables are not needed. Make one call per separate thing asked, at the start of your reply, never for something you can simply answer."
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
                    "worker_type": .object(["type": .string("string"), "minLength": .number(1), "enum": .array(kinds),
                                            "description": .string("The kind of work: research to investigate a question from web sources and deliver a cited report, or document to write a longer piece from the brief and inputs." + (general == nil ? "" : " general for anything else the person wants done that takes more than a reply."))]),
                    "title": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(200),
                                      "description": .string("A short title for the result, one line of up to 200 characters. Optional.")]),
                    "objective": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(5000),
                                          "description": .string("For research, the question to investigate; for a document, the brief saying what to write. Up to 5000 characters.")]),
                    "deliverables": .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(5),
                        "description": .string("For research, 1 to 5 things the report must cover; for a document, 1 to 5 facts, notes or requirements to include. Each item up to 500 characters. Required for research and document."),
                        "items": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(500)])]),
                ]),
            ]), confirmation: .none, timeout: .seconds(10), effect: .read, isAvailable: { true }, execute: { arguments in
                let position = NativeToolCallContext.sameToolOrdinal
                if general != nil, position == nil { throw NativeToolError.failed(notStarted) }
                guard Set(arguments.keys).isSubset(of: ["worker_type", "title", "objective", "deliverables"]),
                      case .string(let workerType) = arguments["worker_type"],
                      NativeResearchTaskRequest.chatWorkerTypes.contains(workerType) || (general != nil && workerType == generalWorkerType),
                      case .string(let objective) = arguments["objective"] else {
                    throw NativeToolError.invalidArguments(missingArguments)
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
                        throw NativeToolError.invalidArguments(missingArguments)
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
                        throw NativeToolError.failed("Nothing was started, because this message did not allow it.")
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
