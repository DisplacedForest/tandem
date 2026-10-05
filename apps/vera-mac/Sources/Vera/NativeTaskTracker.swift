import Foundation

actor NativeTaskTracker {
    let repository: any NativeTaskProjectionRepository
    let client: NativeTaskClient
    let service: NativeTaskHandoffService
    let transport: NativeTaskEventTransport
    let configuredBase: @Sendable () -> URL?
    let onUpdate: @MainActor @Sendable ([NativeTaskMessageUpdate]) -> Void
    private let instanceID = UUID()
    private var lease: NativeTaskStreamLease?
    private var progress = NativeTaskStreamProgress()
    private var batch: NativeTaskStreamBatch?
    private var stream: Task<Void, Never>?
    private var states: [String: NativeTaskReconciliation] = [:]
    private var references: [String: UUID] = [:]
    private var busy = false
    private var actions: Set<UUID> = []
    private var retryActive: Set<UUID> = []
    private var ticks = 0
    private var nextStream: ContinuousClock.Instant?
    private var refreshAfter: [String: ContinuousClock.Instant] = [:]

    init(repository: any NativeTaskProjectionRepository, client: NativeTaskClient,
         service: NativeTaskHandoffService, transport: NativeTaskEventTransport = .live,
         configuredBase: @escaping @Sendable () -> URL?,
         onUpdate: @escaping @MainActor @Sendable ([NativeTaskMessageUpdate]) -> Void = { _ in }) {
        self.repository = repository
        self.client = client
        self.service = service
        self.transport = transport
        self.configuredBase = configuredBase
        self.onUpdate = onUpdate
    }

    func stop() {
        stream?.cancel()
        stream = nil
        if let lease { try? repository.releaseTaskStream(lease) }
        lease = nil
        batch = nil
        progress = NativeTaskStreamProgress()
        states = [:]
        references = [:]
        nextStream = nil
        refreshAfter = [:]
    }

    private func configuredEngine() -> NativeTaskEngineIdentity? {
        configuredBase().flatMap { try? NativeTaskEngineIdentity($0) }
    }

    private func current(_ value: NativeTaskStreamLease) -> Bool {
        !Task.isCancelled && lease == value && configuredEngine() == value.engine
    }

    func tick() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if let lease, try !repository.taskStreamIsCurrent(lease) { stop() }
            let all = try repository.taskReferences(conversationID: nil)
            for reference in all {
                let update = try? repository.projectTask(id: reference.id, snapshot: nil, cursor: 0,
                    connectionNote: try repository.taskProjection(id: reference.id)?.connectionNote,
                    lease: nil, generation: nil)
                if let update { await onUpdate([update]) }
            }
            guard let engine = configuredEngine() else { stop(); return }
            if lease?.engine != engine {
                stop()
                lease = try repository.claimTaskStream(engine: engine, instanceID: instanceID)
                progress = NativeTaskStreamProgress(cursor: lease?.cursor ?? 0)
            }
            guard let lease else { return }
            let enrolled = all.filter {
                $0.engine == engine && $0.remoteTaskID != nil && (try? repository.taskProjection(id: $0.id)) != nil
            }
            references = Dictionary(uniqueKeysWithValues: enrolled.map { ($0.remoteTaskID!, $0.id) })
            states = states.filter { references[$0.key] != nil }
            for reference in enrolled {
                let id = reference.remoteTaskID!
                let cached = try repository.taskProjection(id: reference.id)
                if states[id] == nil || cached?.snapshot?.state.isTerminal == true {
                    states[id] = NativeTaskReconciliation(taskID: id, cursor: cached?.cursor ?? 0,
                        terminal: cached?.snapshot?.state.isTerminal == true)
                }
            }
            if stream == nil && (nextStream == nil || ContinuousClock.now >= nextStream!) && enrolled.contains(where: { states[$0.remoteTaskID!]?.terminal != true }) {
                startStream(lease)
            }
            ticks += 1
            if ticks.isMultiple(of: 60) {
                for id in states.keys where states[id]?.terminal != true { states[id]?.invalidate() }
            }
            if batch == nil { batch = progress.beginBatch() }
            if let batch {
                for id in progress.remaining(in: batch).keys where references[id] == nil {
                    let deleted = all.first { $0.engine == engine && $0.remoteTaskID == id }
                    if let deleted, try repository.taskProjection(id: deleted.id) != nil { continue }
                    progress.acknowledge(taskID: id, in: batch)
                }
            }
            for reference in enrolled {
                guard current(lease) else { return }
                guard !actions.contains(reference.id), !retryActive.contains(reference.id), let id = reference.remoteTaskID else { continue }
                if states[id]?.terminal != true, refreshAfter[id].map({ ContinuousClock.now >= $0 }) ?? true,
                   let ticket = states[id]?.beginFetch() {
                    await refresh(reference, ticket: ticket, lease: lease)
                }
                if let batch, let target = progress.remaining(in: batch)[id] {
                    if let saved = try repository.taskProjection(id: reference.id),
                       saved.snapshot?.state.isTerminal == true, saved.cursor < target {
                        _ = try repository.projectTask(id: reference.id, snapshot: nil, cursor: target,
                            connectionNote: saved.connectionNote, lease: lease, generation: nil)
                    }
                    if let saved = try repository.taskProjection(id: reference.id), saved.cursor >= target {
                        progress.acknowledge(taskID: id, in: batch)
                    }
                }
            }
            if let batch, progress.canCommit(batch), current(lease) {
                try repository.saveTaskCursor(batch.cursor, lease: lease, reset: false)
                if progress.committed(batch) { self.batch = nil }
            }
            if !states.isEmpty && states.values.allSatisfy(\.terminal), stream != nil {
                stream?.cancel()
                stream = nil
                _ = progress.replaceConnection()
                batch = nil
            }
            for intent in try repository.pendingTaskRetries() {
                guard current(lease) else { return }
                await deliverRetry(intent, lease: lease)
            }
        } catch is CancellationError {
            stop()
        } catch {
            if let lease, !current(lease) { stop() }
        }
    }

    private func startStream(_ lease: NativeTaskStreamLease) {
        let connection = progress.replaceConnection()
        batch = nil
        for id in states.keys { states[id]?.invalidate() }
        stream = Task {
            do {
                for try await event in transport.events(lease.engine, progress.appliedCursor) {
                    guard current(lease), progress.connectionEpoch == connection else { return }
                    progress.receive(event, enrolled: references[event.taskID] != nil, connection: connection)
                    try states[event.taskID]?.receive(event)
                }
                streamEnded(lease, connection: connection, reset: false)
            } catch let error as NativeTaskHTTPError {
                streamEnded(lease, connection: connection, reset: error == .status(409))
            } catch {
                streamEnded(lease, connection: connection, reset: false)
            }
        }
    }

    private func streamEnded(_ lease: NativeTaskStreamLease, connection: UInt64, reset: Bool) {
        guard current(lease), progress.connectionEpoch == connection else { return }
        stream = nil
        nextStream = ContinuousClock.now.advanced(by: .seconds(2))
        if reset {
            try? repository.saveTaskCursor(0, lease: lease, reset: true)
            stop()
        }
    }

    private func refresh(_ reference: NativeTaskReference, ticket: NativeTaskSnapshotTicket,
                         lease: NativeTaskStreamLease) async {
        guard let id = reference.remoteTaskID else { return }
        var reservedGeneration: Int64?
        do {
            let generation = try repository.beginTaskRefresh(id: reference.id, lease: lease)
            reservedGeneration = generation
            guard current(lease) else { return }
            let snapshot = try await client.fetch(reference)
            guard current(lease), states[id]?.canApply(ticket, terminal: snapshot.state.isTerminal) == true else { return }
            if let update = try repository.projectTask(id: reference.id, snapshot: snapshot, cursor: ticket.cursor,
                connectionNote: nil, lease: lease, generation: generation) {
                _ = states[id]?.committed(ticket, terminal: snapshot.state.isTerminal)
                refreshAfter[id] = nil
                await onUpdate([update])
            } else {
                _ = states[id]?.committed(ticket, terminal: snapshot.state.isTerminal)
            }
        } catch is CancellationError {
            states[id]?.failed(ticket)
            if (try? repository.taskStreamIsCurrent(lease)) != true { stop() }
        } catch {
            guard current(lease) else { return }
            states[id]?.failed(ticket)
            refreshAfter[id] = ContinuousClock.now.advanced(by: .seconds(2))
            let note = (error as? NativeTaskHTTPError)?.localizedDescription ?? "Research progress couldn't be refreshed."
            if let generation = reservedGeneration,
               let update = try? repository.projectTask(id: reference.id, snapshot: nil, cursor: 0,
                connectionNote: note, lease: lease, generation: generation) {
                await onUpdate([update])
            }
        }
    }

    private func actionSession(for reference: NativeTaskReference) throws -> NativeTaskStreamLease {
        guard !Task.isCancelled, let engine = configuredEngine(), engine == reference.engine else {
            throw NativeTaskError.engineChanged
        }
        if let lease, lease.engine == engine, try repository.taskStreamIsCurrent(lease) { return lease }
        stop()
        let session = try repository.claimTaskStream(engine: engine, instanceID: instanceID)
        lease = session
        progress = NativeTaskStreamProgress(cursor: session.cursor)
        return session
    }

    func cancel(_ id: UUID) async {
        guard !actions.contains(id), let reference = try? repository.taskReference(id: id),
              let lease = try? actionSession(for: reference) else { return }
        actions.insert(id)
        defer { actions.remove(id) }
        if let remote = reference.remoteTaskID { states[remote]?.invalidate() }
        do {
            _ = try repository.beginTaskRefresh(id: id, lease: lease)
            _ = try repository.requestTaskCancellation(id: id)
            if let update = try repository.projectTask(id: id, snapshot: nil, cursor: 0,
                connectionNote: nil, lease: lease, generation: nil) { await onUpdate([update]) }
            guard current(lease) else { return }
            _ = try await service.requestCancellation(id)
        } catch {}
        if let remote = reference.remoteTaskID { states[remote]?.invalidate() }
    }

    func retry(_ id: UUID) async {
        guard !actions.contains(id), !retryActive.contains(id),
              let reference = try? repository.taskReference(id: id),
              let lease = try? actionSession(for: reference),
              let snapshot = try? repository.taskProjection(id: id)?.snapshot,
              snapshot.state == .needsDecision, let decision = snapshot.decision,
              decision.choices.contains("retry"), !reference.cancelRequested else { return }
        do {
            if let remote = reference.remoteTaskID { states[remote]?.invalidate() }
            let intent = try repository.prepareTaskRetry(id: id, decisionID: decision.id)
            if let update = try repository.projectTask(id: id, snapshot: nil, cursor: 0,
                connectionNote: nil, lease: lease, generation: nil) { await onUpdate([update]) }
            await deliverRetry(intent, lease: lease)
        } catch {}
    }

    private func deliverRetry(_ intent: NativeTaskDecisionIntent, lease: NativeTaskStreamLease) async {
        let id = intent.referenceID
        guard !retryActive.contains(id), !actions.contains(id), current(lease),
              let reference = try? repository.taskReference(id: id), reference.engine == lease.engine else { return }
        guard !reference.cancelRequested else { try? repository.resolveTaskRetry(intent); return }
        guard let saved = try? repository.taskProjection(id: id)?.snapshot else { return }
        guard saved.state == .needsDecision, saved.decision?.id == intent.decisionID,
              saved.decision?.choices.contains("retry") == true else {
            try? repository.resolveTaskRetry(intent)
            return
        }
        retryActive.insert(id)
        defer { retryActive.remove(id) }
        if let remote = reference.remoteTaskID { states[remote]?.invalidate() }
        do {
            let generation = try repository.beginTaskRefresh(id: id, lease: lease)
            guard current(lease) else { return }
            let snapshot = try await client.retry(reference, intent: intent)
            guard current(lease) else { return }
            if let update = try repository.projectTask(id: id, snapshot: snapshot, cursor: 0,
                connectionNote: nil, lease: lease, generation: generation) { await onUpdate([update]) }
            try repository.resolveTaskRetry(intent)
        } catch {}
        if let remote = reference.remoteTaskID { states[remote]?.invalidate() }
    }
}
