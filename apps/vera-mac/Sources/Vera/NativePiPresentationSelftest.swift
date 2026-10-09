import Combine
import Foundation
import VeraAssistantUI

@MainActor
private final class NativePiStartGate {
    var continuation: CheckedContinuation<NativePiConnection, Never>?
    var stops = 0
    func start() async -> NativePiConnection {
        await withCheckedContinuation { continuation = $0 }
    }
    func release(_ connection: NativePiConnection) {
        continuation?.resume(returning: connection)
        continuation = nil
    }
}

@MainActor
enum NativePiPresentationSelftest {
    static func run() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-pi-presentation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try NativePiRuntimePathsSelftest.run()
            let idle = NativePiPresentation()
            try piCheck(!idle.canConnect && !idle.canSend && idle.conversation == nil)
            await idle.connect()
            await idle.stop()
            try piCheck(!FileManager.default.fileExists(atPath: root.path))
            let accountHome = root.appendingPathComponent("account")
            let isolated = root.appendingPathComponent("isolated")
            try NativePiNativeContext.validateIsolation(["--root", isolated.appendingPathComponent("runtime").path],
                environment: ["CFFIXED_USER_HOME": isolated.path], foundationHome: isolated, accountHome: accountHome)
            for invalid in [root, accountHome, accountHome.appendingPathComponent(".vera"), accountHome.appendingPathComponent("Library"), accountHome.appendingPathComponent("Library/Keychains/child")] {
                do {
                    try NativePiNativeContext.validateIsolation(["--root", invalid.appendingPathComponent("runtime").path],
                        environment: ["CFFIXED_USER_HOME": invalid.path], foundationHome: invalid, accountHome: accountHome)
                    throw PiBrokerError.unavailable
                } catch PiBrokerError.invalid { }
            }
            do {
                try NativePiNativeContext.validateIsolation(["--root", accountHome.appendingPathComponent(".vera").path],
                    environment: ["CFFIXED_USER_HOME": isolated.path], foundationHome: isolated, accountHome: accountHome)
                throw PiBrokerError.unavailable
            } catch PiBrokerError.invalid { }
            let workspace = try AssistantWorkspace(dataRoot: root.appendingPathComponent("ui"),
                endpoint: URL(string: "http://127.0.0.1:49152")!, workspaceRoot: root.appendingPathComponent("workspaces"),
                runtimeIdentity: "native-presentation-selftest") { request in
                    let object: [String: Any]
                    switch request.url?.path {
                    case "/assistant/capabilities": object = ["protocol_version": 1, "foreground": true, "worker": true, "computers": false, "transport": "mock"]
                    case "/assistant/messages": object = ["messages": []]
                    case "/tasks": object = ["tasks": []]
                    default: throw PiBrokerError.invalid
                    }
                    return (try JSONSerialization.data(withJSONObject: object), 200)
                }
            for cancelCaller in [false, true] {
                let gate = NativePiStartGate()
                let connection = NativePiConnection(workspace: workspace, stop: { gate.stops += 1 })
                let presentation = NativePiPresentation(factory: { await gate.start() })
                let startup = Task { await presentation.connect() }
                for _ in 0..<100 where gate.continuation == nil { await Task.yield() }
                try piCheck(gate.continuation != nil)
                if cancelCaller {
                    startup.cancel()
                    gate.release(connection)
                    await startup.value
                    try piCheck(presentation.connection == nil && !presentation.starting && gate.stops == 1)
                    await presentation.stop()
                } else {
                    let first = Task { await presentation.stop() }
                    for _ in 0..<100 where presentation.starting { await Task.yield() }
                    try piCheck(!presentation.starting)
                    let second = Task { await presentation.stop() }
                    gate.release(connection)
                    await first.value
                    await second.value
                    await startup.value
                    try piCheck(presentation.connection == nil && !presentation.canConnect && gate.stops == 1)
                }
                await connection.stop()
                try piCheck(gate.stops == 1)
            }
            let readyGate = NativePiStartGate()
            let ready = NativePiPresentation(factory: {
                NativePiConnection(workspace: workspace, stop: { readyGate.stops += 1 })
            })
            await ready.connect()
            var changes = 0
            let observation = ready.objectWillChange.sink { MainActor.assumeIsolated { changes += 1 } }
            ready.draft = "Draft through native adapter"
            try piCheck(changes > 0 && ready.draft == workspace.session.draft && ready.canSend)
            let identifier = workspace.session.id
            let source = UUID().uuidString
            try piCheck(NativePiPresentation.messageID(conversation: identifier, source: source)
                == NativePiPresentation.messageID(conversation: identifier, source: source.lowercased()))
            try piCheck(NativePiPresentation.messageID(conversation: identifier, source: "task:test")
                != NativePiPresentation.messageID(conversation: UUID(), source: "task:test"))
            observation.cancel()
            await ready.stop()
            await ready.stop()
            try piCheck(readyGate.stops == 1 && ready.connection == nil)
            try await NativePiTranscriptSelftest.run(root: root)
            print("PASS: idle isolation, direct observation, late startup cancellation, concurrent shutdown and stable projection namespace")
        } catch {
            FileHandle.standardError.write(Data("Native presentation selftest failed: \(type(of: error))\n".utf8))
            exit(1)
        }
    }
}
