import Foundation

protocol NativeTaskRepository: Sendable {
    func prepareTaskReference(origin: NativeTaskOrigin, engine: NativeTaskEngineIdentity,
                              request: NativeResearchTaskRequest,
                              profile: NativeTaskProfileBinding?, options: NativeTaskResearchOptions) throws -> NativeTaskReference
    func taskReferences(conversationID: String?) throws -> [NativeTaskReference]
    func taskReference(id: UUID) throws -> NativeTaskReference?
    func acknowledgeTaskReference(id: UUID, snapshot: NativeTaskSnapshot) throws -> NativeTaskReference
    func failTaskDelivery(id: UUID, permanent: Bool, message: String) throws -> NativeTaskReference
    func requestTaskCancellation(id: UUID) throws -> NativeTaskReference
    func acknowledgeTaskCancellation(id: UUID, snapshot: NativeTaskSnapshot) throws -> NativeTaskReference
}

actor NativeTaskHandoffService {
    let repository: any NativeTaskRepository
    let client: NativeTaskClient
    let configuredBase: @Sendable () -> URL?
    let researchOptions: NativeTaskResearchOptions
    private var active: Set<UUID> = []

    init(repository: any NativeTaskRepository, client: NativeTaskClient = .live,
         researchOptions: NativeTaskResearchOptions = .standard,
         configuredBase: @escaping @Sendable () -> URL?) {
        self.researchOptions = researchOptions
        self.repository = repository
        self.client = client
        self.configuredBase = configuredBase
    }

    func submit(origin: NativeTaskOrigin, request: NativeResearchTaskRequest,
                profile: NativeTaskProfileBinding? = nil) async throws -> NativeTaskReference {
        guard let base = configuredBase() else { throw NativeTaskError.invalidEngine }
        let engine = try NativeTaskEngineIdentity(base)
        let reference = try repository.prepareTaskReference(
            origin: origin, engine: engine, request: request, profile: profile, options: researchOptions)
        return try await deliver(reference.id)
    }

    func requestCancellation(_ id: UUID) async throws -> NativeTaskReference {
        let reference = try repository.requestTaskCancellation(id: id)
        guard !active.contains(id) else { return reference }
        return try await deliver(id)
    }

    func recoverPending() async {
        guard let references = try? repository.taskReferences(conversationID: nil) else { return }
        for reference in references where reference.deliveryState == .pending
            || (reference.cancelRequested && !reference.cancelDelivered && reference.deliveryState != .rejected) {
            guard !Task.isCancelled else { return }
            _ = try? await deliver(reference.id)
        }
    }

    func deliver(_ id: UUID) async throws -> NativeTaskReference {
        guard var reference = try repository.taskReference(id: id) else {
            throw NativeTaskError.persistenceUnavailable
        }
        guard !active.contains(id) else { return reference }
        guard let base = configuredBase(), let engine = try? NativeTaskEngineIdentity(base),
              engine == reference.engine else {
            return try repository.failTaskDelivery(
                id: id, permanent: false, message: NativeTaskError.engineChanged.localizedDescription)
        }
        guard reference.deliveryState != .rejected else { return reference }
        active.insert(id)
        defer { active.remove(id) }
        do {
            if reference.remoteTaskID == nil {
                let snapshot = try await client.create(reference)
                reference = try repository.acknowledgeTaskReference(id: id, snapshot: snapshot)
            }
            if reference.cancelRequested && !reference.cancelDelivered {
                guard let current = configuredBase(),
                      try NativeTaskEngineIdentity(current) == reference.engine else {
                    throw NativeTaskError.engineChanged
                }
                let snapshot = try await client.cancel(reference)
                reference = try repository.acknowledgeTaskCancellation(id: id, snapshot: snapshot)
            }
            return reference
        } catch let error as NativeTaskHTTPError {
            return try repository.failTaskDelivery(id: id, permanent: !error.canRetry,
                                                  message: error.localizedDescription)
        } catch is CancellationError {
            return try repository.failTaskDelivery(
                id: id, permanent: false, message: "The request is saved and waiting to reconnect.")
        } catch let error as NativeTaskError {
            return try repository.failTaskDelivery(id: id, permanent: false,
                                                  message: error.localizedDescription)
        } catch {
            throw NativeTaskError.persistenceUnavailable
        }
    }
}
