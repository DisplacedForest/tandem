import Foundation

enum NativeTaskTools {
    static let toolID = "background-research"
    static let toolName = "create_background_task"
    static let searchUnavailable = "Web search is not set up, so background research cannot run. Add a search URL in Settings, Search, and ask again. Background document writing still works."

    static func enabledIDs(_ existing: Set<String>, hasEngine: Bool, hasRepository: Bool) -> Set<String> {
        let base = existing.subtracting([toolID])
        guard base.contains(NativeWebTools.researchToolID), hasEngine, hasRepository else { return base }
        return base.union([toolID])
    }

    static func definition(service: NativeTaskHandoffService, origin: NativeTaskOrigin,
                           profile: NativeTaskProfileBinding?,
                           searchAvailable: @escaping @Sendable () -> Bool = { NativeWebSearch.resolvedBase() != nil },
                           allowedWorkerTypes: @escaping @Sendable () -> Set<String> = { NativeResearchTaskRequest.workerTypes },
                           didSave: @escaping @Sendable (NativeTaskReference) async -> Void) -> NativeToolDefinition {
        NativeToolDefinition(id: toolID, name: toolName, title: "Start background work",
            description: "Start one background task only when the current user message explicitly asks for research or for a written document to be produced in the background. Earlier conversation requests do not authorize another task. Use worker_type research to investigate a question from web sources and deliver a cited report; use worker_type document to write a longer deliverable from the objective (the brief) and the deliverables (facts, notes or requirements to include). Give a short title for documents. Then acknowledge briefly. Progress and the result appear on the task card. Do not repeat task status on unrelated turns, expose internal identifiers, wait for the result, or claim completion.",
            parameters: .object([
                "type": .string("object"), "additionalProperties": .bool(false),
                "required": .array([.string("worker_type"), .string("objective"), .string("deliverables")]),
                "properties": .object([
                    "worker_type": .object(["type": .string("string"), "enum": .array([.string("research"), .string("document")])]),
                    "title": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(200),
                                      "description": .string("One-line title for a document")]),
                    "objective": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(5000)]),
                    "deliverables": .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(5),
                        "items": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(500)])]),
                ]),
            ]), confirmation: .none, timeout: .seconds(10), isAvailable: { true }, execute: { arguments in
                guard Set(arguments.keys).isSubset(of: ["worker_type", "title", "objective", "deliverables"]),
                      case .string(let workerType) = arguments["worker_type"],
                      NativeResearchTaskRequest.workerTypes.contains(workerType),
                      case .string(let objective) = arguments["objective"],
                      case .array(let values) = arguments["deliverables"] else {
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
                        ? "The current message did not ask for a document to be written, so no document task was started."
                        : "The current message did not ask for research, so no research task was started.")
                }
                if workerType == "research", !searchAvailable() {
                    throw NativeToolError.failed(searchUnavailable)
                }
                let request = try NativeResearchTaskRequest(objective: objective, deliverables: deliverables, workerType: workerType, title: title)
                let reference = try await service.submit(origin: origin, request: request, profile: profile)
                await didSave(reference)
                let work = workerType == "document" ? "document" : "research"
                let message: String
                switch reference.deliveryState {
                case .accepted: message = workerType == "document" ? "Writing has started." : "Research has started."
                case .pending: message = "The \(work) request is saved and waiting to connect."
                case .rejected: message = reference.lastDeliveryError ?? "The task engine couldn't accept this request."
                }
                if reference.cancelRequested || reference.snapshot?.state == .canceled {
                    return .object(["message": .string("This message's \(work) request was canceled."), "started": .bool(false)])
                }
                if reference.snapshot?.state == .completed {
                    return .object(["message": .string("This message's \(work) result is already available on its card."), "started": .bool(false)])
                }
                if let state = reference.snapshot?.state, [.blocked, .needsDecision, .failed].contains(state) {
                    return .object(["message": .string("This \(work) request could not continue. Its card has the next step."), "started": .bool(false)])
                }
                if reference.deliveryState == .rejected {
                    return .object(["error": .string(message), "started": .bool(false)])
                }
                return .object(["message": .string(message), "started": .bool(reference.deliveryState == .accepted)])
            })
    }
}
