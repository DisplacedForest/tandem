import Foundation

extension ChatStore {
    func reloadNativeTaskReferences() {
        nativeTaskReferences = (try? nativeTaskRepository?.taskReferences(conversationID: nil)) ?? []
    }

    func startNativeTaskRecovery() {
        reloadNativeTaskReferences()
        if nativeTaskTracker == nil, let repository = nativeTaskRepository as? any NativeTaskProjectionRepository,
           let service = nativeTaskService {
            let engine = nativeTaskEngine
            nativeTaskTracker = NativeTaskTracker(repository: repository, client: nativeTaskTrackingClient,
                service: service, transport: nativeTaskLocalEngine?.transport ?? .live,
                configuredBase: { engine.base }, onUpdate: { [weak self] updates in
                    self?.applyNativeTaskUpdates(updates)
                })
        }
        if let engine = nativeTaskLocalEngine {
            Task { try? await engine.start() }
        }
        if nativeTaskTrackingLoop == nil, let tracker = nativeTaskTracker {
            nativeTaskTrackingLoop = Task { [weak self] in
                while !Task.isCancelled {
                    await tracker.tick()
                    guard self != nil else { await tracker.stop(); return }
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { await tracker.stop(); return }
                }
            }
        }
        if nativeTaskRecoveryLoop == nil, let service = nativeTaskService {
            nativeTaskRecoveryLoop = Task { [weak self] in
                while !Task.isCancelled {
                    await service.recoverPending()
                    guard let self else { return }
                    self.reloadNativeTaskReferences()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
        if nativeTaskGenerationLoop == nil, let broker = nativeTaskBroker {
            nativeTaskGenerationLoop = Task {
                while !Task.isCancelled {
                    await broker.poll()
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
            }
        }
    }

    func applyNativeTaskUpdates(_ updates: [NativeTaskMessageUpdate]) {
        var changed = false
        for update in updates {
            guard let conversation = conversations.firstIndex(where: { $0.id == update.conversationID }),
                  let message = conversations[conversation].messages.firstIndex(where: { $0.id == update.messageID }),
                  conversations[conversation].messages[message].displayBlocks != update.blocks else { continue }
            conversations[conversation].messages[message].displayBlocks = update.blocks
            changed = true
        }
        if changed { reloadNativeTaskReferences() }
    }

    var connectedNativeTaskIDs: Set<String> {
        guard let base = nativeTaskEngine.base, let engine = try? NativeTaskEngineIdentity(base) else { return [] }
        return Set(nativeTaskReferences.filter { $0.engine == engine }.map { $0.id.uuidString })
    }

    func cancelNativeTask(_ value: String) {
        guard let id = UUID(uuidString: value), let nativeTaskTracker else { return }
        Task { await nativeTaskTracker.cancel(id) }
    }

    func retryNativeTask(_ value: String) {
        guard let id = UUID(uuidString: value), let nativeTaskTracker else { return }
        Task { await nativeTaskTracker.retry(id) }
    }

    func stopNativeTaskRecovery() {
        if let engine = nativeTaskLocalEngine { Task { await engine.stop() } }
        nativeTaskRecoveryLoop?.cancel()
        nativeTaskGenerationLoop?.cancel()
        nativeTaskTrackingLoop?.cancel()
        nativeTaskTrackingLoop = nil
        if let nativeTaskTracker { Task { await nativeTaskTracker.stop() } }
        nativeTaskRecoveryLoop = nil
        nativeTaskGenerationLoop = nil
    }
}
