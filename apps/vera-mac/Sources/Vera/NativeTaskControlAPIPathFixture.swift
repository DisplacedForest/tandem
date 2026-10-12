import Foundation

enum NativeTaskControlAPIPathFixture {
    static func run(base: URL, database: URL) async throws {
        let repository = try LocalChatRepository(url: database)
        let client = NativeTaskClient.live
        let service = NativeTaskHandoffService(repository: repository, client: client, configuredBase: { base })
        var references: [NativeTaskReference] = []
        for index in 0..<8 {
            let origin = try NativeTaskFixture.origin(repository)
            let request = try NativeResearchTaskRequest(objective: "Fictional research \(index)", deliverables: ["Cited report"])
            references.append(try await service.submit(origin: origin, request: request))
        }
        let tracker = NativeTaskTracker(repository: repository, client: client, service: service, configuredBase: { base })
        let loop = Task {
            while !Task.isCancelled {
                await tracker.tick()
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        defer { loop.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try references.allSatisfy({ try repository.taskProjection(id: $0.id)?.snapshot != nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try NativeTaskFixture.require(try references.allSatisfy { try repository.taskProjection(id: $0.id)?.snapshot != nil },
                                      "Every enrolled task must receive a canonical snapshot")
        let started = ContinuousClock.now
        let stopped = references.last!
        await tracker.cancel(stopped.id)
        let controlSeconds = nativeTaskSeconds(started.duration(to: .now))
        try NativeTaskFixture.require(controlSeconds < 2, "Eight task references must not starve cancellation")
        let finish = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < finish {
            if try repository.taskProjection(id: stopped.id)?.snapshot?.state == .canceled { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try NativeTaskFixture.require(try repository.taskProjection(id: stopped.id)?.snapshot?.state == .canceled,
                                      "Cancellation must reach the original transcript")
        for reference in references {
            let message = try repository.messages(conversationID: reference.origin.conversationID).last!
            try NativeTaskFixture.require(message.displayBlocks.count == 1, "Eight tasks must retain eight original cards")
        }
        loop.cancel()
        await tracker.stop()
        await NativeTaskAPIPathFixture.emit(["event": "controls", "tasks": references.count, "cancel_seconds": controlSeconds])
    }
}
