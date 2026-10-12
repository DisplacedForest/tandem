import Foundation

enum NativeTaskTools {
    static let toolID = "background-research"
    static let toolName = "create_background_task"

    static func enabledIDs(_ existing: Set<String>, hasEngine: Bool, hasRepository: Bool) -> Set<String> {
        let base = existing.subtracting([toolID])
        guard base.contains(NativeWebTools.researchToolID), hasEngine, hasRepository else { return base }
        return base.union([toolID])
    }

    static func definition(service: NativeTaskHandoffService, origin: NativeTaskOrigin,
                           profile: NativeTaskProfileBinding?,
                           didSave: @escaping @Sendable (NativeTaskReference) async -> Void) -> NativeToolDefinition {
        NativeToolDefinition(id: toolID, name: toolName, title: "Start background research",
            description: "Start one research task only when the current user message explicitly requests research. Earlier conversation requests do not authorize another task. Specify the objective and deliverables, then acknowledge briefly. Progress and the report appear on the task card. Do not repeat task status on unrelated turns, expose internal identifiers, wait for the report, or claim completion.",
            parameters: .object([
                "type": .string("object"), "additionalProperties": .bool(false),
                "required": .array([.string("worker_type"), .string("objective"), .string("deliverables")]),
                "properties": .object([
                    "worker_type": .object(["type": .string("string"), "enum": .array([.string("research")])]),
                    "objective": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(5000)]),
                    "deliverables": .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(5),
                        "items": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(500)])]),
                ]),
            ]), confirmation: .none, timeout: .seconds(10), isAvailable: { true }, execute: { arguments in
                guard Set(arguments.keys) == Set(["worker_type", "objective", "deliverables"]),
                      arguments["worker_type"] == .string("research"),
                      case .string(let objective) = arguments["objective"],
                      case .array(let values) = arguments["deliverables"] else {
                    throw NativeToolError.invalidArguments("Provide a research objective and deliverables.")
                }
                let deliverables = try values.map { value -> String in
                    guard case .string(let text) = value else {
                        throw NativeToolError.invalidArguments("Each research deliverable must be text.")
                    }
                    return text
                }
                let request = try NativeResearchTaskRequest(objective: objective, deliverables: deliverables)
                let reference = try await service.submit(origin: origin, request: request, profile: profile)
                await didSave(reference)
                let message: String
                switch reference.deliveryState {
                case .accepted: message = "Research has started."
                case .pending: message = "The research request is saved and waiting to connect."
                case .rejected: message = reference.lastDeliveryError ?? "The research engine couldn't accept this request."
                }
                if reference.cancelRequested || reference.snapshot?.state == .canceled {
                    return .object(["message": .string("This message's research request was canceled."), "started": .bool(false)])
                }
                if reference.snapshot?.state == .completed {
                    return .object(["message": .string("This message's research report is already available on its card."), "started": .bool(false)])
                }
                if let state = reference.snapshot?.state, [.blocked, .needsDecision, .failed].contains(state) {
                    return .object(["message": .string("This research request could not continue. Its card has the next step."), "started": .bool(false)])
                }
                if reference.deliveryState == .rejected {
                    return .object(["error": .string(message), "started": .bool(false)])
                }
                return .object(["message": .string(message), "started": .bool(reference.deliveryState == .accepted)])
            })
    }
}
