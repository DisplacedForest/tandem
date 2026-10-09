import Foundation
import AppKit

// Entry point. `Vera --shot <path>` renders the UI to a PNG headlessly (no window) and exits;
// otherwise it launches the normal app.
let arguments = CommandLine.arguments
switch SelectedCredentialAuthorization.dispatch(Array(arguments.dropFirst())) {
case .authorize(let values):
    SelectedCredentialAuthorization.main(values, configuration: { ConfigFile.read() })
case .reject:
    SelectedCredentialAuthorization.rejectInvocation()
case .unrelated:
    break
}
let piModes: Set<String> = ["--pi-native-selftest", "--pi-native-reopen-contract", "--pi-native-contract", "--pi-native-recovery-contract", "--pi-checkpoint-selftest", "--pi-checkpoint", "--pi-provider-wiring-selftest", "--pi-candidate-mock", "--pi-candidate-contract", "--pi-candidate-selftest", "--pi-candidate-recovery-contract", "--pi-broker-mock", "--pi-broker-selftest"]
if arguments.dropFirst().contains(where: { $0.hasPrefix("--pi-") }) && !piModes.contains(arguments.dropFirst().first ?? "") {
    FileHandle.standardError.write(Data("Unsupported isolated Vera mode\n".utf8))
    exit(2)
}
if arguments.dropFirst().first == "--pi-native-selftest" {
    NativeApplicationEntry.runAsync { await NativePiPresentationSelftest.run() }
} else if ["--pi-native-reopen-contract", "--pi-native-contract", "--pi-native-recovery-contract"].contains(arguments.dropFirst().first ?? "") {
    NativeApplicationEntry.runAsync { await NativePiNativeContract.run(Array(arguments.dropFirst(2)), recovery: arguments[1] == "--pi-native-recovery-contract", reopen: arguments[1] == "--pi-native-reopen-contract") }
} else if arguments.dropFirst().first == "--pi-checkpoint-selftest" {
    NativeApplicationEntry.runAsync { await NativePiCheckpointSelftest.run(Array(arguments.dropFirst(2))) }
} else if arguments.dropFirst().first == "--pi-checkpoint" {
    NativeApplicationEntry.runAsync { await NativePiCheckpoint.main(Array(arguments.dropFirst(2))) }
} else if arguments.dropFirst().first == "--pi-candidate-mock" {
    do {
        try NativeApplicationEntry.prepare(onTimeout: NativePiNativeContext.cancelBootstrap) { try await NativePiNativeContext.prepareFixture(Array(arguments.dropFirst(2))) }
        VeraApp.main()
    } catch {
        FileHandle.standardError.write(Data("The isolated assistant could not start. Saved work was preserved.\n".utf8))
        exit(1)
    }
} else if arguments.dropFirst().first == "--pi-provider-wiring-selftest" {
    NativeApplicationEntry.runAsync { await NativePiProviderSelftest.run(Array(arguments.dropFirst(2))) }
} else if arguments.dropFirst().first == "--pi-candidate-selftest" {
    NativeApplicationEntry.runAsync { await NativePiCandidateSelftest.run(Array(arguments.dropFirst(2))) }
} else if ["--pi-candidate-contract", "--pi-candidate-recovery-contract"].contains(arguments.dropFirst().first ?? "") {
    NativeApplicationEntry.runAsync { await NativePiCandidate.main(Array(arguments.dropFirst(2)), contract: arguments[1] == "--pi-candidate-contract", recovery: arguments[1] == "--pi-candidate-recovery-contract") }
} else if arguments.dropFirst().first == "--pi-broker-selftest" {
    NativeApplicationEntry.runAsync { await NativePiModelBrokerFixture.run() }
} else if arguments.dropFirst().first == "--pi-broker-mock" {
    NativeApplicationEntry.runAsync { await NativePiRuntimeSession.main(Array(arguments.dropFirst(2))) }
} else if let idx = arguments.firstIndex(of: "--shot"), idx + 1 < arguments.count {
    let path = arguments[idx + 1]
    let view = arguments.firstIndex(of: "--view").map { arguments[$0 + 1] } ?? "chat"
    let appearance = arguments.firstIndex(of: "--appearance").map { arguments[$0 + 1] } ?? "dark"
    Shot.render(view: view, to: path, appearance: appearance)
} else if let idx = arguments.firstIndex(of: "--voice-e2e"), idx + 1 < arguments.count {
    // DEBUG-ONLY: stream a sample wav through the real Wyoming servers, print transcript.
    NativeApplicationEntry.runAsync { await SelfTest.voiceE2E(wavPath: arguments[idx + 1]) }
} else if arguments.contains("--reminders-serve") {
    // DEBUG-ONLY: start the in-app EventKit bridge and block, to validate the native
    // Reminders path (macOS prompt + HTTP contract) independent of the UI.
    try? RemindersBridge.shared.start()
    print("vera-reminders bridge serving on :\(RemindersBridge.shared.port), ctrl-c to stop")
    NativeApplicationEntry.runAsync { while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } }
} else if arguments.contains("--openrouter-smoke") {
    NativeApplicationEntry.runAsync { await NativeProviderSmoke.run(arguments: arguments) }
} else if arguments.contains("--provider-smoke-selftest") {
    NativeProviderSmoke.selfTest()
} else if arguments.contains("--prepared-invocation-selftest") {
    NativeApplicationEntry.runAsync {
        do { try await NativePreparedInvocationSelftest.run() }
        catch { print("PREPARED INVOCATION SELFTEST FAILED"); exit(1) }
    }
} else if arguments.contains("--mcp-selftest") {
    NativeApplicationEntry.runAsync {
        do {
            try await NativeMCPAuthoritySelftest.run()
            try await NativeMCPTransportSelftest.run()
            try await NativeMCPOAuthSelftest.run()
            try await NativeMCPOAuthUISelftest.run()
            try await NativeMCPIntegrationFixture.run(Array(arguments.dropFirst(2)))
            print("NATIVE MCP SELFTEST OK")
        } catch { print("NATIVE MCP SELFTEST FAILED: \(error)"); exit(1) }
    }
} else if arguments.contains("--domain-state-selftest") {
    NativeApplicationEntry.runAsync {
        do { try NativeDomainStateSelftest.run(); try await NativeDomainRepositorySelftest.run() }
        catch { print("domain-state: FAIL \(error.localizedDescription)"); exit(1) }
    }
} else if arguments.contains("--shared-runtime-memory-selftest") {
    NativeApplicationEntry.runAsync {
        do { try await NativeRuntimeMemorySelftest.run() }
        catch { print("shared-runtime-memory: FAIL \(error.localizedDescription)"); exit(1) }
    }
} else if arguments.contains("--memory-evidence-selftest") {
    NativeApplicationEntry.runAsync {
        do { try await NativeMemoryEvidenceSelftest.run() }
        catch { print("native-memory-evidence: FAIL \(error.localizedDescription)"); exit(1) }
    }
} else if arguments.contains("--selftest") {
    NativeApplicationEntry.runAsync { await SelfTest.run() }
} else if arguments.contains("--dump-context") {
    SelfTest.dumpContext()
} else {
    VeraApp.main()
}
