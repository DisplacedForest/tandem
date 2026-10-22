import Foundation

final class NativeCommandRunRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [NativeCommandRun] = []

    func add(_ run: NativeCommandRun) {
        lock.lock(); defer { lock.unlock() }
        runs.append(run)
    }

    var recorded: [NativeCommandRun] {
        lock.lock(); defer { lock.unlock() }
        return runs
    }
}

@MainActor
extension SelfTest {
    static func runNativeRules() async throws {
        let require = NativeTaskFixture.require

        var global = NativeRules.defaults
        try require(global.choice(for: .fileEdits) == .act && global.choice(for: .commands) == .ask
                    && global.choice(for: .trash) == .ask && global.choice(for: .networkSends) == .handOff
                    && global.choice(for: .sensitive) == .handOff, "Defaults match the safe set")
        global.set(.act, for: .sensitive)
        try require(global.choice(for: .sensitive) == .handOff, "Sensitive actions stay at hand off")
        global.set(.act, for: .commands)
        let encoded = try JSONEncoder().encode(global)
        let decoded = try JSONDecoder().decode(NativeRules.self, from: encoded)
        try require(decoded.choice(for: .commands) == .act, "Rules round-trip through JSON")
        let partial = try JSONDecoder().decode(NativeRules.self, from: Data("{\"commands\":\"bogus\",\"trash\":\"hand_off\"}".utf8))
        try require(partial.choice(for: .commands) == .ask && partial.choice(for: .trash) == .handOff, "Unknown choices fall back to defaults")

        var conversation = NativeConversationRules()
        conversation.tighten(.act, for: .commands, global: .defaults)
        try require(conversation.isEmpty, "A chat cannot loosen a global rule")
        conversation.tighten(.handOff, for: .commands, global: .defaults)
        var resolver = NativeRuleResolver(global: .defaults, conversation: conversation, requestText: "please run the tests")
        try require(resolver.decision(for: .commands) == .handOff, "A chat can tighten a global rule")
        resolver = NativeRuleResolver(global: global, conversation: conversation, requestText: "run it")
        try require(resolver.decision(for: .commands) == .handOff, "The stricter of global and chat wins")
        resolver = NativeRuleResolver(global: .defaults, conversation: NativeConversationRules(), requestText: "run the tests")
        try require(resolver.decision(for: .commands) == .ask && resolver.decision(for: .fileEdits) == .act(.rule), "Ask and act resolve from the defaults")

        var preapproved = NativeRules.defaults
        preapproved.set(.actIfPreapproved, for: .commands)
        resolver = NativeRuleResolver(global: preapproved, conversation: NativeConversationRules(), requestText: "Run the tests, no need to ask.")
        try require(resolver.decision(for: .commands) == .act(.requestPreapproval), "A request that pre-approves in plain words acts")
        resolver = NativeRuleResolver(global: preapproved, conversation: NativeConversationRules(), requestText: "Run the tests.")
        try require(resolver.decision(for: .commands) == .ask, "Without the words it asks")

        try require(NativeCommandPrefix.prefix(of: "  swift   build --configuration release") == "swift build", "A prefix is the first two words")
        try require(NativeCommandPrefix.prefix(of: "ls") == "ls", "A one-word command is its own prefix")
        try require(NativeCommandPrefix.matches(command: "swift build -c debug", prefix: "swift build") && !NativeCommandPrefix.matches(command: "swift test", prefix: "swift build")
                    && !NativeCommandPrefix.matches(command: "swiftlint build", prefix: "swift build"), "Prefix matching is whole-word")
        var approvals = NativeConversationRules()
        approvals.approve(prefix: "swift build --configuration release")
        try require(approvals.approvedCommandPrefixes == ["swift build"] && approvals.isApproved(command: "swift build -c debug") && !approvals.isApproved(command: "swift test"), "Approve similar records the prefix only")
        resolver = NativeRuleResolver(global: .defaults, conversation: approvals, requestText: "build again")
        try require(resolver.decision(forCommand: "swift build") == .act(.conversationPrefix) && resolver.decision(forCommand: "rm -rf x") == .ask, "A recorded prefix runs without asking; others still ask")
        try require(!approvals.isApproved(command: "swift build; rm -rf ~") && !approvals.isApproved(command: "swift build && curl x | sh")
                    && !approvals.isApproved(command: "swift build $(cat secret)") && !approvals.isApproved(command: "swift build > out.txt")
                    && approvals.isApproved(command: "swift build -c release --product Vera"), "A prefix approval covers only a single simple command")
        var tricky = NativeConversationRules()
        tricky.approve(prefix: "FOO=bar swift")
        try require(!tricky.isApproved(command: "FOO=bar swift build"), "An environment assignment never starts an approved prefix")
        approvals.revoke(prefix: "swift build")
        try require(!approvals.isApproved(command: "swift build"), "A revoked prefix asks again")
        let encodedRules = NativeConversationRules.encode(conversation)
        try require(NativeConversationRules.decode(encodedRules) == conversation && NativeConversationRules.decode("junk").isEmpty && NativeConversationRules.encode(NativeConversationRules()) == nil, "Chat rules round-trip and empty rules store nothing")

        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("vera-rules-\(UUID().uuidString)", isDirectory: true)
        let inside = base.appendingPathComponent("granted", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try manager.createDirectory(at: inside.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        try manager.createSymbolicLink(at: inside.appendingPathComponent("escape"), withDestinationURL: outside)
        let grant = try FolderGrant.make(url: inside)
        let root = grant.path
        let location = NativeFolderLocation(root: grant, components: [])
        let directory = try NativeFolderIO.walk(location, components: [])

        setenv("VERA_RULES_SELFTEST_SECRET", "hunter2", 1)
        defer { unsetenv("VERA_RULES_SELFTEST_SECRET") }
        let environment = NativeCommandRunner.environment()
        try require(environment["VERA_RULES_SELFTEST_SECRET"] == nil && environment["PATH"] == NativeCommandRunner.searchPath && environment["HOME"] == ProcessInfo.processInfo.environment["HOME"], "The child environment is an allowlist with a fixed PATH")
        let envRun = try await NativeCommandRunner.run(command: "env; pwd", directory: directory, timeout: .seconds(10))
        try require(envRun.exitCode == 0 && !envRun.stdout.contains("hunter2") && envRun.stdout.contains("PATH=" + NativeCommandRunner.searchPath)
                    && envRun.stdout.hasSuffix(root + "\n"), "A secret in the app's environment never reaches the child, and the grant is the working directory")

        let failing = try await NativeCommandRunner.run(command: "echo out; echo err 1>&2; exit 3", directory: directory, timeout: .seconds(10))
        try require(failing.exitCode == 3 && failing.stdout == "out\n" && failing.stderr == "err\n" && !failing.timedOut, "Exit status, stdout and stderr are captured separately")

        let capped = try await NativeCommandRunner.run(command: "yes | head -c 200000", directory: directory, timeout: .seconds(20), outputCap: 4096)
        try require(capped.exitCode == 0 && capped.stdout.utf8.count == 4096 && capped.stdoutTruncated && !capped.stderrTruncated, "Output is capped and marked truncated without blocking the child")
        let cappedRun = NativeCommandRun(id: "x", command: "yes", directory: root, outcome: .ran, exitCode: 0, stdout: capped.stdout, stdoutTruncated: true)
        guard case .object(let cappedResult) = NativeCommandTools.result(cappedRun), case .string(let cappedText)? = cappedResult["stdout"] else {
            throw NativeTaskFixture.Failure.assertion("The result serializes")
        }
        try require(cappedText.hasSuffix(NativeCommandRun.truncationMarker), "The model sees the truncation marker")

        let started = Date()
        let timed = try await NativeCommandRunner.run(command: "sleep 30 & echo $!; wait", directory: directory, timeout: .seconds(1))
        try require(timed.timedOut && timed.exitCode == nil && timed.signal == SIGKILL && Date().timeIntervalSince(started) < 8, "A timeout kills the shell and reports it")
        if let grandchild = pid_t(timed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            try await Task.sleep(for: .milliseconds(200))
            try require(kill(grandchild, 0) != 0 && errno == ESRCH, "The grandchild in the process group is gone after the timeout")
        } else {
            throw NativeTaskFixture.Failure.assertion("The timed-out command printed its child's pid: \(timed.stdout)")
        }

        let cancelTask = Task { try await NativeCommandRunner.run(command: "sleep 30", directory: directory, timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(300))
        cancelTask.cancel()
        let canceled = try await cancelTask.value
        try require(canceled.canceled && !canceled.timedOut && canceled.signal == SIGKILL, "Cancel kills the process and is reported as a cancel")

        do {
            _ = try await NativeCommandRunner.run(command: "", directory: directory, timeout: .seconds(1))
            throw NativeTaskFixture.Failure.assertion("An empty command is refused")
        } catch NativeToolError.invalidArguments {}

        let recorder = NativeCommandRunRecorder()
        let grants: @Sendable () -> [FolderGrant] = { [grant] }
        func loop(decision: NativeRuleDecision, rounds: [[NativeChatStreamSnapshot]], confirm: @escaping @Sendable (NativeToolActivity) async -> Bool,
                  reason: NativeRuleReason? = nil) async throws -> (NativeToolTurnSnapshot?, ScriptedNativeToolTransport) {
            let transport = ScriptedNativeToolTransport(rounds: rounds)
            let registry = NativeToolRegistry(definitions: NativeCommandTools.definitions(
                grants: grants, decision: decision, reason: { _ in reason }, record: { recorder.add($0) }))
            let toolLoop = NativeToolLoop(transport: transport, registry: registry, confirm: confirm)
            var final: NativeToolTurnSnapshot?
            for try await snapshot in toolLoop.stream(
                messages: [NativeChatMessage(role: "user", content: "run it")], model: "local-model",
                enabledToolIDs: [NativeCommandTools.toolID]) {
                final = snapshot
            }
            return (final, transport)
        }
        func call(_ id: String, _ arguments: String) -> [NativeChatStreamSnapshot] {
            [NativeChatStreamSnapshot(content: "", toolCalls: [NativeChatToolCall(id: id, name: NativeCommandTools.runName, arguments: arguments)], finishReason: "tool_calls")]
        }
        let done = [NativeChatStreamSnapshot(content: "Done.", toolCalls: [], finishReason: "stop")]

        let (declined, declinedTransport) = try await loop(decision: .ask, rounds: [call("c1", "{\"command\":\"echo ran > marker.txt\"}"), done], confirm: { _ in false })
        try require(declined?.activities.first?.state == .failed && declined?.activities.first?.confirmationRequired == true
                    && declinedTransport.histories.count == 2
                    && declinedTransport.histories[1].last?.content.contains("did not approve") == true
                    && !manager.fileExists(atPath: root + "/marker.txt") && recorder.recorded.isEmpty,
                    "Declining leaves a failed call, tells the model, and runs nothing")

        let (approved, _) = try await loop(decision: .ask, rounds: [call("c2", "{\"command\":\"printf approved\"}"), done], confirm: { activity in
            activity.name == NativeCommandTools.runName && activity.request.contains("printf approved")
        }, reason: .userApproved)
        try require(approved?.activities.first?.state == .succeeded && recorder.recorded.count == 1 && recorder.recorded[0].stdout == "approved"
                    && recorder.recorded[0].reason == .userApproved && recorder.recorded[0].id == "c2" && recorder.recorded[0].exitCode == 0,
                    "Approving runs the command and records the decision on the card")
        try require(approved?.activities.first?.result?.contains("\"exit_code\":0") == true || approved?.activities.first?.result?.contains("\"exit_code\": 0") == true, "The model receives the exit status")

        let (acted, _) = try await loop(decision: .act(.rule), rounds: [call("c3", "{\"command\":\"printf quiet\"}"), done], confirm: { _ in
            fatalError("A rule set to act must not ask")
        })
        try require(acted?.activities.first?.state == .succeeded && acted?.activities.first?.confirmationRequired == false && recorder.recorded.last?.reason == .rule, "Act runs without asking and says so")

        let changedTransport = ScriptedNativeToolTransport(rounds: [call("c9", "{\"command\":\"printf changed\"}"), done])
        let changedRegistry = NativeToolRegistry(definitions: NativeCommandTools.definitions(
            grants: grants, decision: .act(.rule), reason: { _ in nil }, record: { recorder.add($0) }, live: { _ in .ask }))
        var changedFinal: NativeToolTurnSnapshot?
        for try await snapshot in NativeToolLoop(transport: changedTransport, registry: changedRegistry).stream(messages: [NativeChatMessage(role: "user", content: "run")], model: "local-model", enabledToolIDs: [NativeCommandTools.toolID]) {
            changedFinal = snapshot
        }
        try require(changedFinal?.activities.first?.state == .failed && changedTransport.histories[1].last?.content.contains("rules changed") == true && recorder.recorded.count == 2, "A rule tightened to ask mid-answer stops an act decision")
        let source = NativeRuleSource()
        source.setGlobal(.defaults)
        source.set(NativeConversationRules(choices: [.fileEdits: .handOff]), for: "chat")
        try require(source.resolver(for: "chat", requestText: "").decision(for: .fileEdits) == .handOff && source.resolver(for: "other", requestText: "").decision(for: .fileEdits) == .act(.rule), "The live rule source scopes chat rules to their chat")

        let (handedOff, handOffTransport) = try await loop(decision: .handOff, rounds: [call("c4", "{\"command\":\"printf never\"}"), done], confirm: { _ in true })
        try require(handedOff?.activities.first?.state == .failed && handOffTransport.histories[1].last?.content.contains("hand off") == true && recorder.recorded.count == 2, "Hand off refuses with the rule named")

        let (outsideRun, outsideTransport) = try await loop(decision: .act(.rule), rounds: [call("c5", "{\"command\":\"printf x\",\"directory\":\"\(outside.path)\"}"), done], confirm: { _ in true })
        try require(outsideRun?.activities.first?.state == .failed && outsideTransport.histories[1].last?.content.replacingOccurrences(of: "\\/", with: "/").contains(outside.path) == true && recorder.recorded.count == 2, "A directory outside every grant is refused with the path named")
        let (linkRun, _) = try await loop(decision: .act(.rule), rounds: [call("c6", "{\"command\":\"printf x\",\"directory\":\"\(root)/escape\"}"), done], confirm: { _ in true })
        try require(linkRun?.activities.first?.state == .failed && recorder.recorded.count == 2, "A symlinked directory is refused")

        let (prose, proseTransport) = try await loop(decision: .act(.rule), rounds: [[NativeChatStreamSnapshot(content: "run_command {\"command\":\"touch prose.txt\"}", toolCalls: [], finishReason: "stop")]], confirm: { _ in true })
        try require(prose?.activities.isEmpty == true && proseTransport.histories.count == 1 && !manager.fileExists(atPath: root + "/prose.txt") && recorder.recorded.count == 2, "Prose that looks like a command never runs")

        let revocable = NativeFolderGrantSource()
        revocable.set([grant], for: "chat")
        let revokedTransport = ScriptedNativeToolTransport(rounds: [call("c7", "{\"command\":\"printf x\"}"), done])
        let revokedRegistry = NativeToolRegistry(definitions: NativeCommandTools.definitions(
            grants: { revocable.grants(for: "chat") }, decision: .act(.rule), reason: { _ in nil }, record: { recorder.add($0) }))
        let revokedLoop = NativeToolLoop(transport: revokedTransport, registry: revokedRegistry, willExecute: { _ in
            revocable.set([], for: "chat")
            return true
        })
        var revokedFinal: NativeToolTurnSnapshot?
        for try await snapshot in revokedLoop.stream(messages: [NativeChatMessage(role: "user", content: "run")], model: "local-model", enabledToolIDs: [NativeCommandTools.toolID]) {
            revokedFinal = snapshot
        }
        try require(revokedFinal?.activities.first?.state == .failed && recorder.recorded.count == 2, "A grant revoked before the command runs refuses it")

        let ledger = NativeFileChangeLedger()
        let access = NativeFolderAccess(grants: [grant])
        try "bye".write(to: inside.appendingPathComponent("sub/old.txt"), atomically: true, encoding: .utf8)
        let trashed = try NativeFolderTools.moveToTrash(try access.locate(root + "/sub/old.txt"), ledger: ledger)
        guard case .object(let trashResult) = trashed, case .string(let trashPath)? = trashResult["trash_path"] else {
            throw NativeTaskFixture.Failure.assertion("The trash result names the destination")
        }
        try require(!manager.fileExists(atPath: root + "/sub/old.txt") && manager.fileExists(atPath: trashPath)
                    && ledger.recorded().last?.kind == .trashed && ledger.recorded().last?.movedFrom == trashPath, "A file moves to the Trash and the card records where")
        try? manager.removeItem(atPath: trashPath)
        do {
            _ = try NativeFolderTools.moveToTrash(try access.locate(root), ledger: ledger)
            throw NativeTaskFixture.Failure.assertion("The grant root cannot be trashed")
        } catch NativeToolError.failed {}
        do {
            _ = try NativeFolderTools.moveToTrash(try access.locate(root + "/escape"), ledger: ledger)
            throw NativeTaskFixture.Failure.assertion("A symlink is refused before anything moves")
        } catch NativeFolderAccessError.outsideGrants {} catch NativeFolderAccessError.symlink {}
        try require(manager.fileExists(atPath: outside.path), "The symlink target is untouched")

        let gated = NativeFolderTools.definitions(grants: grants, ledger: ledger, edits: .handOff, trash: .ask)
        let writeDefinition = gated.first { $0.name == NativeFolderTools.writeName }!
        try require(writeDefinition.confirmation == .none && gated.first { $0.name == NativeFolderTools.trashName }!.confirmation == .required
                    && gated.first { $0.name == NativeFolderTools.readName }!.confirmation == .none, "Rule decisions shape which file tools ask")
        do {
            _ = try await writeDefinition.execute(["path": .string(root + "/sub/new.txt"), "content": .string("x")])
            throw NativeTaskFixture.Failure.assertion("A hand-off edit never writes")
        } catch NativeToolError.failed(let message) {
            try require(message.contains("hand off") && !manager.fileExists(atPath: root + "/sub/new.txt"), "The hand-off refusal names the rule and writes nothing")
        }
        let asking = NativeFolderTools.definitions(grants: grants, ledger: ledger, edits: .ask, trash: .handOff)
        try require(asking.first { $0.name == NativeFolderTools.editName }!.confirmation == .required && asking.first { $0.name == NativeFolderTools.moveName }!.confirmation == .required, "Ask applies to every writing tool")

        let request = NativeToolConfirmationRequest(activity: NativeToolActivity(
            id: "a", toolID: NativeCommandTools.toolID, name: NativeCommandTools.runName, title: "Run a command", round: 1,
            request: "{\"command\":\"swift test --filter x\",\"directory\":\"\(root)\"}", result: nil, state: .pending, confirmationRequired: true))
        try require(NativeToolConfirmationBar.prompt(for: request) == "Run this command?\nswift test --filter x" && NativeToolConfirmationBar.similarPrefix(for: request) == "swift test"
                    && NativeToolConfirmationBar.detail(for: request)?.contains(root) == true, "The ask card shows the exact command and offers the prefix")
        let block = NativeDisplayBlock.commandRun(NativeCommandRun(id: "a", command: "ls", directory: root, outcome: .declined))
        let roundTrip = try JSONDecoder().decode(NativeDisplayBlock.self, from: try JSONEncoder().encode(block))
        try require(roundTrip == block && roundTrip.id == "command:a", "Command cards persist with the message")
        print("  native rules OK (defaults, fixed sensitive, tightening, pre-approval phrases, prefixes, environment allowlist, cwd, exit status, output caps, timeout tree kill, cancel, decline, approve, act, hand off, outside grant, symlink, prose, revocation, trash, gated file tools, ask card, persistence)")
    }
}
