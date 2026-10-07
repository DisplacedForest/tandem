import Foundation
import AppKit

// Entry point. `Vera --shot <path>` renders the UI to a PNG headlessly (no window) and exits;
// otherwise it launches the normal app.
let arguments = CommandLine.arguments
let piModes: Set<String> = ["--pi-provider-wiring-selftest", "--pi-candidate-mock", "--pi-candidate-contract", "--pi-candidate-selftest", "--pi-candidate-recovery-contract", "--pi-broker-mock", "--pi-broker-selftest"]
if arguments.dropFirst().contains(where: { $0.hasPrefix("--pi-") }) && !piModes.contains(arguments.dropFirst().first ?? "") {
    FileHandle.standardError.write(Data("Unsupported isolated Vera mode\n".utf8))
    exit(2)
}
if arguments.dropFirst().first == "--pi-candidate-mock" {
    NSApplication.shared.setActivationPolicy(.regular)
    NativePiCandidateApplication.launcher.arguments = Array(arguments.dropFirst(2))
    NativePiCandidateApplication.main()
} else if arguments.dropFirst().first == "--pi-provider-wiring-selftest" {
    await NativePiProviderSelftest.run(Array(arguments.dropFirst(2)))
} else if arguments.dropFirst().first == "--pi-candidate-selftest" {
    await NativePiCandidateSelftest.run(Array(arguments.dropFirst(2)))
} else if ["--pi-candidate-contract", "--pi-candidate-recovery-contract"].contains(arguments.dropFirst().first ?? "") {
    await NativePiCandidate.main(Array(arguments.dropFirst(2)), contract: arguments[1] == "--pi-candidate-contract", recovery: arguments[1] == "--pi-candidate-recovery-contract")
} else if arguments.dropFirst().first == "--pi-broker-selftest" {
    await NativePiModelBrokerFixture.run()
} else if arguments.dropFirst().first == "--pi-broker-mock" {
    await NativePiRuntimeSession.main(Array(arguments.dropFirst(2)))
} else if let idx = arguments.firstIndex(of: "--shot"), idx + 1 < arguments.count {
    let path = arguments[idx + 1]
    let view = arguments.firstIndex(of: "--view").map { arguments[$0 + 1] } ?? "chat"
    let appearance = arguments.firstIndex(of: "--appearance").map { arguments[$0 + 1] } ?? "dark"
    await Shot.render(view: view, to: path, appearance: appearance)
} else if let idx = arguments.firstIndex(of: "--voice-e2e"), idx + 1 < arguments.count {
    // DEBUG-ONLY: stream a sample wav through the real Wyoming servers, print transcript.
    await SelfTest.voiceE2E(wavPath: arguments[idx + 1])
} else if arguments.contains("--reminders-serve") {
    // DEBUG-ONLY: start the in-app EventKit bridge and block, to validate the native
    // Reminders path (macOS prompt + HTTP contract) independent of the UI.
    try? RemindersBridge.shared.start()
    print("vera-reminders bridge serving on :\(RemindersBridge.shared.port), ctrl-c to stop")
    while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
} else if arguments.contains("--openrouter-smoke") {
    await NativeProviderSmoke.run(arguments: arguments)
} else if arguments.contains("--provider-smoke-selftest") {
    NativeProviderSmoke.selfTest()
} else if arguments.contains("--selftest") {
    await SelfTest.run()
} else if arguments.contains("--dump-context") {
    await SelfTest.dumpContext()
} else {
    VeraApp.main()
}
