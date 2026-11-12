import Foundation

extension ChatStore {
    func reloadNativeTaskReferences() {
        nativeTaskReferences = (try? nativeTaskRepository?.taskReferences(conversationID: nil)) ?? []
        refreshNativeTaskDeliveries()
        prepareCompanionRefinement()
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
            companionWorkerRelay.attach(self)
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
        var changed = deliverNativeTaskMessages(updates)
        for update in updates {
            guard let conversation = conversations.firstIndex(where: { $0.id == update.conversationID }) else { continue }
            for mirror in update.mirrors {
                guard let index = conversations[conversation].messages.firstIndex(where: { $0.id == mirror }) else { continue }
                let cards = update.blocks.filter { if case .taskCard = $0 { return true }; if case .artifact = $0 { return true }; return false }
                var blocks = conversations[conversation].messages[index].displayBlocks
                if let reference = update.referenceID, !cards.contains(where: { $0.id == "task:" + reference.uuidString }) {
                    blocks.removeAll { $0.id == "task:" + reference.uuidString }
                }
                for card in cards {
                    if let existing = blocks.firstIndex(where: { $0.id == card.id }) { blocks[existing] = card } else { blocks.append(card) }
                }
                if blocks != conversations[conversation].messages[index].displayBlocks {
                    conversations[conversation].messages[index].displayBlocks = blocks
                    changed = true
                }
            }
            guard let message = conversations[conversation].messages.firstIndex(where: { $0.id == update.messageID }) else { continue }
            let kept = conversations[conversation].messages[message].displayBlocks.filter { block in
                switch block {
                case .fileChange, .commandRun: return !update.blocks.contains(where: { $0.id == block.id })
                default: return false
                }
            }
            if update.blocks.contains(where: { if case .artifact = $0 { true } else { false } }) {
                recordTaskArtifacts(update.blocks, conversationID: update.conversationID, messageID: update.messageID.uuidString)
            }
            let merged = Self.keepingSavedAnswers(update.blocks + kept, current: conversations[conversation].messages[message].displayBlocks)
            guard conversations[conversation].messages[message].displayBlocks != merged else { continue }
            conversations[conversation].messages[message].displayBlocks = merged
            changed = true
        }
        if changed { reloadNativeTaskReferences() }
    }

    static func keepingSavedAnswers(_ incoming: [NativeDisplayBlock], current: [NativeDisplayBlock]) -> [NativeDisplayBlock] {
        var merged = incoming
        for block in current {
            guard case .artifact(let artifact) = block, !merged.contains(where: { $0.id == block.id }),
                  let card = merged.firstIndex(where: { $0.id == "task:" + artifact.id }),
                  case .taskCard(let presentation) = merged[card],
                  NativeTaskProjection.answerDocument(presentation) != nil else { continue }
            merged.insert(block, at: card + 1)
        }
        return merged
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

    func saveNativeTaskAnswer(_ value: String) {
        guard let id = UUID(uuidString: value), let projection = repository as? any NativeTaskProjectionRepository,
              let updates = try? projection.saveTaskAnswer(id: id) else { return }
        for update in updates {
            guard let artifact = update.blocks.first(where: { $0.id == "artifact:" + value }) else { continue }
            if let conversation = conversations.firstIndex(where: { $0.id == update.conversationID }),
               let message = conversations[conversation].messages.firstIndex(where: { $0.id == update.messageID }) {
                var blocks = conversations[conversation].messages[message].displayBlocks
                if !blocks.contains(where: { $0.id == artifact.id }) {
                    let card = blocks.firstIndex(where: { $0.id == "task:" + value }).map { $0 + 1 } ?? blocks.endIndex
                    blocks.insert(artifact, at: card)
                    conversations[conversation].messages[message].displayBlocks = blocks
                }
            }
            recordTaskArtifacts([artifact], conversationID: update.conversationID, messageID: update.messageID.uuidString)
        }
    }

    func answerNativeTask(_ value: String, choice: String) {
        guard let id = UUID(uuidString: value), let nativeTaskTracker else { return }
        Task { await nativeTaskTracker.decide(id, choice: choice) }
    }

    func stopNativeTaskRecovery() {
        nativeSchedulerLoop?.cancel()
        nativeSchedulerLoop = nil
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
