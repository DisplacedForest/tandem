import Foundation

extension ChatStore {
    func reloadNativeTaskReferences() {
        nativeTaskReferences = (try? nativeTaskRepository?.taskReferences(conversationID: nil)) ?? []
    }

    func startNativeTaskRecovery() {
        reloadNativeTaskReferences()
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

    func stopNativeTaskRecovery() {
        nativeTaskRecoveryLoop?.cancel()
        nativeTaskGenerationLoop?.cancel()
        nativeTaskRecoveryLoop = nil
        nativeTaskGenerationLoop = nil
    }
}
