import Foundation

enum NativePiPipeFixture {
    static func exercise() async throws {
        let payload: PiValue = .object(["fixture": .bool(true)])
        do {
            let pipe = Pipe()
            let channel = PiPrivatePipe(read: pipe.fileHandleForReading, write: pipe.fileHandleForWriting)
            channel.closeWrite()
            channel.closeWrite()
            try await NativePiModelBrokerFixture.rejected(.unavailable) { try channel.send(payload) }
            try await NativePiModelBrokerFixture.rejected(.unavailable) { _ = try channel.writeDescriptor() }
            try piCheck(try channel.next() == nil)
        }
        for _ in 0..<32 {
            let pipe = Pipe()
            let channel = PiPrivatePipe(read: pipe.fileHandleForReading, write: pipe.fileHandleForWriting)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask { channel.closeWrite() }
                    group.addTask {
                        do { try channel.send(payload) }
                        catch PiBrokerError.unavailable {}
                    }
                }
                try await group.waitForAll()
            }
            try await NativePiModelBrokerFixture.rejected(.unavailable) { try channel.send(payload) }
        }
    }
}
