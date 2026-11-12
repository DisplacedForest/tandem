import Foundation

enum NativeTaskTools {
    static let toolID = "background-research"
    static let toolName = "create_background_task"
    static let searchUnavailable = "Web search is not set up, so background research cannot run. Add a search URL in Settings, Search, and ask again. Background document writing still works."

    static let generalWorkerType = "general"
    static let generalLimit = 4000
    static let laterRound = "This can only be started from what the person asked, at the start of a reply."
    static let pausedReply = "I'm paused, so this wasn't started. Resume me and ask again."

    struct NotStarted: Error, Sendable {
        let message: String
    }

    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var issued = 0

        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            let index = issued
            issued += 1
            return index
        }
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
                           general: (@Sendable (_ assignment: String) throws -> NativeResearchTaskRequest)? = nil,
                           didSave: @escaping @Sendable (NativeTaskReference) async -> Void) -> NativeToolDefinition {
        let counter = CallCounter()
        let kinds: [NativeJSONValue] = [.string("research"), .string("document")] + (general == nil ? [] : [.string(generalWorkerType)])
        return NativeToolDefinition(id: toolID, name: toolName, title: "Start background work",
            description: "Start one background task per separate request only when the current user message explicitly asks for research or for a written document to be produced in the background. Earlier conversation requests do not authorize another task. Use worker_type research to investigate a question from web sources and deliver a cited report; use worker_type document to write a longer deliverable from the objective (the brief) and the deliverables (facts, notes or requirements to include). Give a short title for documents. Then acknowledge briefly. Progress and the result appear on the task card. Do not repeat task status on unrelated turns, expose internal identifiers, wait for the result, or claim completion."
                + (general == nil ? "" : " In this conversation you may also use worker_type general, with the objective saying what to do, for anything the person asks to have done that takes more than a reply: one call per separate thing asked, never for something you can simply answer. Afterwards reply with one short first-person line saying what you will do, without the words background, task or card."),
            parameters: .object([
                "type": .string("object"), "additionalProperties": .bool(false),
                "required": .array([.string("worker_type"), .string("objective")]),
                "properties": .object([
                    "worker_type": .object(["type": .string("string"), "enum": .array(kinds)]),
                    "title": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(200),
                                      "description": .string("One-line title for a document")]),
                    "objective": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(5000)]),
                    "deliverables": .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(5),
                        "items": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(500)])]),
                ]),
            ]), confirmation: .none, timeout: .seconds(10), effect: .read, isAvailable: { true }, execute: { arguments in
                guard Set(arguments.keys).isSubset(of: ["worker_type", "title", "objective", "deliverables"]),
                      case .string(let workerType) = arguments["worker_type"],
                      NativeResearchTaskRequest.chatWorkerTypes.contains(workerType) || (general != nil && workerType == generalWorkerType),
                      case .string(let objective) = arguments["objective"] else {
                    throw NativeToolError.invalidArguments("Provide a worker type, an objective and deliverables.")
                }
                let request: NativeResearchTaskRequest
                let work: String
                if workerType == generalWorkerType, let general {
                    guard NativeToolCallContext.round == 1 else {
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
                        request = try general(assignment)
                    } catch let refusal as NotStarted {
                        return .object(["message": .string(refusal.message), "started": .bool(false)])
                    }
                    work = "work"
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
                            ? "The current message did not ask for a document to be written, so no document task was started."
                            : "The current message did not ask for research, so no research task was started.")
                    }
                    if workerType == "research", !searchAvailable() {
                        throw NativeToolError.failed(searchUnavailable)
                    }
                    request = try NativeResearchTaskRequest(objective: objective, deliverables: deliverables, workerType: workerType, title: title)
                    work = workerType == "document" ? "document" : "research"
                }
                var placed = origin
                if general != nil {
                    let index = counter.next()
                    if index > 0 { placed.index = index }
                }
                let reference = try await service.submit(origin: placed, request: request, profile: profile)
                await didSave(reference)
                let message: String
                switch reference.deliveryState {
                case .accepted:
                    message = workerType == generalWorkerType ? "Started." : workerType == "document" ? "Writing has started." : "Research has started."
                case .pending:
                    message = workerType == generalWorkerType ? "Saved, and it will start once the connection is back." : "The \(work) request is saved and waiting to connect."
                case .rejected: message = reference.lastDeliveryError ?? "The task engine couldn't accept this request."
                }
                if reference.cancelRequested || reference.snapshot?.state == .canceled {
                    return .object(["message": .string("This \(work) was canceled."), "started": .bool(false)])
                }
                if reference.snapshot?.state == .completed {
                    return .object(["message": .string("This \(work) is already finished. The result is on its card."), "started": .bool(false)])
                }
                if let state = reference.snapshot?.state, [.blocked, .needsDecision, .failed].contains(state) {
                    return .object(["message": .string("This \(work) could not continue. Its card has the next step."), "started": .bool(false)])
                }
                if reference.deliveryState == .rejected {
                    return .object(["error": .string(message), "started": .bool(false)])
                }
                return .object(["message": .string(message), "started": .bool(reference.deliveryState == .accepted)])
            })
    }
}
