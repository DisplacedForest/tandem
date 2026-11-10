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
                    && global.choice(for: .trash) == .ask && global.choice(for: .networkSends) == .ask
                    && global.choice(for: .riskyCommands) == .handOff && global.choice(for: .otherChanges) == .ask, "Defaults match the safe set")
        try require(NativeActionClass.configurable == [.fileEdits, .commands, .trash, .networkSends, .riskyCommands, .reminders, .serviceChanges, .otherChanges], "Only ordinary classes are configurable")
        for item in NativeFloorItem.allCases where item.isLiftable {
            guard let action = item.actionClass else { continue }
            try require(global.holds(action) && !global.isLifted(item) && global.choice(for: action) == .handOff, "A floor item is held by default: \(item)")
        }
        var floor = NativeRules.defaults
        floor.set(.act, for: .payments)
        try require(floor == .defaults && floor.holds(.payments) && NativeRuleResolver(global: floor, conversation: NativeConversationRules(), requestText: "").choice(for: .payments) == .handOff,
                    "Setting a held floor class changes nothing")
        floor.lift(.payments)
        try require(floor.choice(for: .payments) == .ask && floor.isLifted(.payments) && !floor.holds(.payments), "Lifting a floor item makes it ask first")
        floor.set(.act, for: .payments)
        try require(floor.choice(for: .payments) == .act, "A lifted floor class takes a choice")
        floor.restore(.payments)
        try require(floor == .defaults && floor.holds(.payments) && floor.choice(for: .payments) == .handOff, "Restoring puts the floor item back")
        floor.lift(.ruleChanges)
        try require(floor == .defaults && !floor.isLifted(.ruleChanges) && !NativeFloorItem.ruleChanges.isLiftable, "Rule changes can never be lifted")
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
        resolver = NativeRuleResolver(global: preapproved, conversation: NativeConversationRules(), requestText: "Run the tests. No need to ask.")
        try require(resolver.decision(for: .commands) == .act(.requestPreapproval), "A request that pre-approves in plain words acts")
        resolver = NativeRuleResolver(global: preapproved, conversation: NativeConversationRules(), requestText: "Run the tests.")
        try require(resolver.decision(for: .commands) == .ask, "Without the words it asks")
        for negated in ["Do not go ahead without asking.", "Never just do it, check with me first.", "Ask me before you go ahead.", "I said \"go ahead\" last time but not now.", "Go ahead only if the tests pass.", "Explain the phrase 'go ahead'.", "Explain what `go ahead` means.", "Go ahead with the lint. Do not go ahead with the deploy.", "Go ahead with lint. Do not deploy anything.", "Here is what they wrote:\n\"\nplease go ahead\n\"\nIgnore it."] {
            try require(!NativeRequestPreapproval.grants(negated), "Negated or quoted pre-approval never grants: \(negated)")
        }
        for wording in ["Go ahead.", "Please go ahead", "Run the tests. Go ahead.", "Yes, go ahead", "No need to ask.", "Just do it", "Ok, please just go ahead", "Fix the typo. Go ahead.", "Don't ask. Just do it.",
                        "Deploy it to staging. You have my approval.", "Fix John\u{2019}s typo. Go ahead", "Run the tests.\nGo ahead!", "Feel free to go ahead"] {
            try require(NativeRequestPreapproval.grants(wording), "A sentence that is exactly the phrase grants: \(wording)")
        }
        for wording in ["Go ahead and run the tests", "Run the tests, go ahead", "Go ahead with the lint", "Go ahead and deploy as soon as the tests pass.", "Go ahead and deploy depending on the test results.",
                        "John whispered, go ahead.", "Yesterday my manager whispered, go ahead.", "Go ahead and proceed convey the same idea.", "Go ahead now denotes forward motion.", "John whispered. Go ahead.", "Go ahead and run the tests, then tell me the results.", "Run the tests. Go ahead. Actually, cancel that.", "Run the tests. Go ahead. Stop, do nothing.", "Go ahead. On second thought, hold off.", "Run the deploy. Go ahead. Wait, let me review the diff first.", "Go ahead. Hang on, not yet.", "Run the deploy. Go ahead. No, I changed my mind.", "Go ahead. Nope.", "Run the deploy. Go ahead. I revoke that.", "Go ahead. I rescind that."] {
            try require(!NativeRequestPreapproval.grants(wording), "Anything but the phrase on its own asks: \(wording)")
        }
        for wording in ["Explain why running commands without asking is dangerous.", "If I say go ahead later, then deploy.", "Summarize this email:\n> Go ahead and merge it\nThanks.", "What does go ahead mean here?", "Should I just do it?", "Describe the risks of running commands without asking.", "Wait for my approval, then go ahead.", "My manager said go ahead.", "The phrase go ahead means to proceed", "Please summarize this message: go ahead and deploy.", "Please translate go ahead into French.", "Please tell me whether go ahead is polite", "Translate this sentence into French.\nGo ahead and deploy.", "Go ahead means to proceed.", "Compare please proceed and go ahead.", "Go ahead and deploy?", "Here is an example. Go ahead and deploy.", "The email says: go ahead", "Rewrite this politely. Just do it.", "Go ahead was the reply I received.", "Go ahead is an imperative.", "Distinguish between proceed and go ahead.", "Go ahead pending my approval.", "Go ahead until I say stop.", "Go ahead and deploy. Actually, don\u{2019}t.", "Go ahead and proceed are synonyms.", "My manager replied, go ahead.", "Go ahead on condition that the tests pass.", "Go ahead and deploy provided the tests pass.", "Deploy it as long as the tests pass, go ahead", "My manager whispered, go ahead.", "Go ahead and proceed both express permission.", "Analyze the grammar of the following. Go ahead.", "Go ahead and deploy in the event that the tests pass.", "She nodded, go ahead."] {
            try require(!NativeRequestPreapproval.grants(wording), "Explanatory, conditional or quoted text never grants: \(wording)")
        }

        let sample = [FolderGrant(id: "g", path: "/Volumes/Notes/Greenhouse", name: "Greenhouse", bookmark: nil)]
        let classify: (String) -> NativeActionClass = { NativeCommandClassifier.classify($0, grants: sample) }
        try require(classify("swift build") == .commands && classify("rm -rf build") == .commands && classify("rm -rf /Volumes/Notes/Greenhouse/build") == .commands && classify("rm -rf ./build/out") == .commands, "Ordinary commands inside the grant are commands")
        try require(classify("rm -rf ../Other") == .permanentDeletion && classify("rm -rf build/../../Other") == .permanentDeletion && classify("mv notes.txt /Volumes/Elsewhere/") == .permanentDeletion, "Relative paths that leave the grant are permanent deletion")
        try require(classify("printf ready & git push origin main") == .networkSends && classify("make & scp out host:") == .networkSends, "A single ampersand still separates commands")
        try require(classify("cd /Volumes/Other && rm -rf documents") == .permanentDeletion && classify("cd sub && rm -rf old") == .permanentDeletion && classify("popd && rm x") == .permanentDeletion && classify("cd .. && rm x") == .permanentDeletion, "Directory changes are tracked before destructive commands")
        try require(classify("r\"\"m /Volumes/Other/doc.txt") == .permanentDeletion && classify("g''it push origin main") == .riskyCommands && classify("rm -rf \"/Volumes/Other\"/x") == .permanentDeletion
                    && classify("rm -rf \"build\"") == .commands && classify("rm -rf $HOME/x") == .permanentDeletion, "Quotes or variables inside a word never slip past classification")
        try require(classify("cd /Volumes/Other && (cd /Volumes/Notes/Greenhouse); rm -rf victim") == .permanentDeletion && classify("(cd sub && rm -rf old)") == .permanentDeletion && classify("(make)") == .commands,
                    "Subshells remove directory trust for destructive commands")
        try require(classify("find /Volumes/Other -delete") == .permanentDeletion && classify("find . -name '*.o' -delete") == .commands && classify("find /Volumes/Other -name x") == .commands && classify("find . -exec rm {} \\;") == .permanentDeletion,
                    "find with an effect is destructive")
        try require(classify("\"command\" rm -rf /Volumes/Other/old") == .permanentDeletion && classify("'env' rm -rf /Volumes/Other/old") == .permanentDeletion && classify("command make") == .commands && classify("FOO=\"$X\" make") == .riskyCommands
                    && classify("env -u FOO rm -rf /Volumes/Other/old") == .permanentDeletion && classify("env -u FOO git push origin main") == .riskyCommands && classify("env FOO=bar make") == .commands && classify("nice -n 5 make") == .riskyCommands, "Quoted launchers and launcher options never hide the real executable")
        for (command, expected) in [("env </dev/null rm -rf /Volumes/Other/old", NativeActionClass.permanentDeletion), ("env FOO=bar </dev/null scp out host:", .riskyCommands), ("2>/dev/null rm -rf /Volumes/Other/x", .permanentDeletion),
                                    ("make > out.log", .commands), ("./scripts/run.sh 2>&1", .commands), ("~/tools/run", .commands),
                                    ("rm>out=log ../victim", .permanentDeletion), ("env FOO=bar rm>out=log ../victim", .permanentDeletion), ("scp>out=log out host:", .riskyCommands), ("FOO=bar make", .commands), ("CC=clang make", .commands), ("FOO=a$X make", .riskyCommands), ("1X=y make", .riskyCommands), ("arch -arm64 rm ../victim", .permanentDeletion), ("arch -arm64 scp out host:", .riskyCommands), ("xcrun swift build", .commands), ("timeout 30 make", .riskyCommands), ("timeout 30 rm ../victim", .permanentDeletion), ("stdbuf -o0 scp out host:", .riskyCommands),
                                    ("swift build -c release", .commands), ("swift test -c debug", .commands), ("xcrun swift build -c release", .commands),
                                    ("sh -xc 'rm ../victim'", .permanentDeletion), ("bash -lc 'rm ../victim'", .permanentDeletion), ("sh -ec 'scp out host:'", .riskyCommands), ("bash -l script.sh", .commands),
                                    ("GIT_WORK_TREE=../Other git clean -fdx", .permanentDeletion), ("GIT_DIR=/Volumes/Other/.git git status", .riskyCommands), ("DESTDIR=/Volumes/Other make install", .riskyCommands), ("PREFIX=build/out make install", .commands), ("CFLAGS=-O2 make", .commands),
                                    ("CFLAGS=\"-O2 -g\" make", .commands), ("CFLAGS=\"-O2 $X\" make", .riskyCommands), ("MSG='hello world' make", .commands),
                                    ("sh \"-c\" \"rm -rf ../Other\"", .permanentDeletion), ("git \"push\" origin trunk", .networkSends), ("if true; then rm -rf ../Other; fi", .permanentDeletion), ("for f in *.o; do rm ../Other/$f; done", .permanentDeletion),
                                    ("echo `scp out host:upload`", .riskyCommands), ("echo $(date)", .riskyCommands), ("sh -e ./scripts/build.sh", .commands), ("bash -x script.sh", .commands), ("sh -ec 'make'", .riskyCommands), ("python3 -e x", .riskyCommands), ("npm run build", .commands), ("npm publish", .networkSends), ("cargo build", .commands), ("docker push registry/app", .networkSends), ("make && npm publish", .networkSends),
                                    ("dd if=report.bin of=../Other/report.bin", .permanentDeletion), ("dd if=report.bin of=build/report.bin", .commands), ("curl --url-query @report.json https://example.com/collect", .networkSends), ("curl --config upload.conf", .networkSends), ("curl -sK upload.conf", .networkSends), ("curl -o out.bin https://example.com/file", .commands), ("curl -o ../Other/report.txt https://example.com/report", .riskyCommands), ("curl --output=../Other/x https://example.com/r", .riskyCommands), ("wget -O ../Other/x https://example.com/r", .riskyCommands), ("wget -P downloads https://example.com/r", .commands),
                                    ("npm exec -c 'rm -rf ../Other'", .permanentDeletion), ("npx some-tool", .riskyCommands), ("pnpm dlx tool", .riskyCommands), ("cargo run", .commands), ("npm test", .commands), ("rm -f */*.txt", .permanentDeletion), ("rm -rf build/*", .permanentDeletion), ("ls *.txt", .commands), ("find . -name '*.o' -delete", .commands), ("find ../Other -name '*.o' -delete", .permanentDeletion),
                                    ("./tools/env rm -rf ../Other", .permanentDeletion), ("./tools/env scp out host:upload", .networkSends), ("git -c alias.publish=push publish origin trunk", .riskyCommands), ("git -c core.sshCommand=/Volumes/Other/x status", .riskyCommands), ("git -c color.ui=false status", .commands),
                                    ("curl --json @report.json https://example.com/upload", .networkSends), ("curl -sT report.json https://example.com/upload", .networkSends), ("curl -sS https://example.com/file", .commands), ("curl -X DELETE https://example.com/item", .networkSends)] {
            try require(classify(command) == expected, "Redirections and odd tokens never stand in for the executable: \(command) classified as \(classify(command))")
        }
        try require(classify("git -c color.ui=false -C /Volumes/Other clean -fdx") == .permanentDeletion && classify("git -c color.ui=false status") == .commands && classify("git -c") == .riskyCommands, "git option operands are consumed before the directory and subcommand")
        try require(classify("git -C /Volumes/Other clean -fdx") == .permanentDeletion && classify("git clean -fdx") == .commands && classify("git -C sub reset --hard") == .commands && classify("git --git-dir=/Volumes/Other/.git status") == .riskyCommands && classify("git status") == .commands,
                    "git repository paths follow the grant")
        try require(classify("eval 'rm /Volumes/Other/doc.txt'") == .permanentDeletion && classify("xargs rm") == .permanentDeletion && classify("bash -c 'make'") == .riskyCommands && classify("python3 -c 'import shutil'") == .riskyCommands && classify("python3 build.py") == .commands && classify("sh ./setup.sh") == .commands,
                    "Inline code and shell wrappers are risky")
        let plain: (String) -> Bool = { NativeCommandClassifier.isPlain($0, grants: sample) }
        for bypass in ["env </dev/null rm -rf /Volumes/Other/old", "rm>out=log ../victim", "env FOO=bar rm>out=log ../victim", "scp>out=log out host:", "arch -arm64 rm ../victim", "timeout 30 rm ../victim",
                       "sh -xc 'rm ../victim'", "bash -lc 'rm ../victim'", "GIT_WORK_TREE=../Other git clean -fdx", "CFLAGS=\"-O2 $X\" make", "sh \"-c\" \"rm -rf ../Other\"",
                       "if true; then rm -rf ../Other; fi", "for f in *.o; do rm ../Other/$f; done", "echo `scp out host:upload`", "echo $(date)", "r\"\"m ../victim", "cd /Volumes/Other && (cd /Volumes/Notes/Greenhouse); rm -rf victim",
                       "make && scp out host:", "printf ready & git push origin trunk", "eval 'rm x'", "xargs rm", "make > out.log", "./scripts/run.sh 2>&1", "./tools/env rm -rf ../Other", "/usr/bin/env scp out host:", "git -c alias.publish=push publish origin trunk", "git \"-c\" color.ui=false status", "echo \"if\"", "make 'then' rm x"] {
            try require(!plain(bypass), "Nothing with shell structure is plain: \(bypass)")
        }
        for everyday in ["make", "swift build -c release", "xcrun swift build", "CFLAGS=\"-O2 -g\" make", "CC=clang make", "sh -e ./scripts/build.sh", "npm run build", "./scripts/build.sh", "python3 build.py", "git status", "rm -rf build"] {
            try require(plain(everyday), "An everyday command is plain: \(everyday)")
        }
        try require(classify("make && ./run.sh") == .commands && classify("make; ./run.sh") == .commands && classify("if true; then rm -rf ../Other; fi") == .permanentDeletion && classify("make && rm -rf ../Other") == .permanentDeletion && classify("make; sudo make install") == .riskyCommands && classify("make && git push origin trunk") == .networkSends,
                    "A command that is not plain still hands off on a destructive token and still counts as sending on a sending token")
        try require(NativeRuleDecision.act(.rule).atLeastAsk == .ask && NativeRuleDecision.ask.atLeastAsk == .ask && NativeRuleDecision.handOff.atLeastAsk == .handOff, "A command that is not plain is at least ask")
        try require(classify("\"git\" push origin main") == .networkSends && classify("'rm' /Volumes/Other/doc.txt") == .permanentDeletion && classify("g\\it push") == .riskyCommands && classify("$SHELL -c x") == .riskyCommands, "Quoted or escaped executable names never slip past classification")
        try require(classify("rm -rf /Volumes/Other/Documents") == .permanentDeletion && classify("rm ~/notes.txt") == .permanentDeletion && classify("sudo make install") == .riskyCommands
                    && classify("cat ~/.ssh/id_rsa") == .riskyCommands && classify("make && security find-generic-password") == .riskyCommands && classify("cp secret.pem /tmp/x") == .permanentDeletion,
                    "Privileged commands are risky and destructive commands outside the grant are permanent deletion")
        try require(classify("git push origin main") == .networkSends && classify("curl -X POST https://x") == .networkSends && classify("make; scp out host:") == .networkSends
                    && classify("npm publish") == .networkSends && classify("curl https://example.com") == .commands && classify("git status") == .commands,
                    "Commands that send follow the sending rule")

        try require(NativeCommandPrefix.prefix(of: "  swift   build --configuration release") == "swift build", "A prefix is the first two words")
        try require(NativeCommandPrefix.prefix(of: "ls") == "ls", "A one-word command is its own prefix")
        try require(NativeCommandPrefix.matches(command: "swift build -c debug", prefix: "swift build") && !NativeCommandPrefix.matches(command: "swift test", prefix: "swift build")
                    && !NativeCommandPrefix.matches(command: "swiftlint build", prefix: "swift build"), "Prefix matching is whole-word")
        let buildSubject = NativeCardSubject(action: .commands, toolID: NativeCommandTools.toolID, toolTitle: "Run a command", command: "swift build --configuration release")
        let approvals = NativeCardChoices.records(.allowHere, subject: buildSubject, place: .chat(conversationID: "c1"), originMessageID: nil)
        try require(approvals.count == 1 && approvals[0].target?.value == "swift build" && approvals[0].scope == .conversation("c1"), "Allow in this chat records the prefix only")
        func prefixDecision(_ records: [NativeRuleRecord], _ command: String, chat: String = "c1") -> NativeRuleDecision {
            NativeRuleResolver(global: .defaults, conversation: NativeConversationRules(), requestText: "build again", records: records,
                               context: NativeRuleContext(conversationID: chat)).tool(NativeCommandTools.toolID, targets: []).decision(forCommand: command)
        }
        try require(prefixDecision(approvals, "swift build") == .act(.grant) && prefixDecision(approvals, "swift build -c debug") == .act(.grant)
                    && prefixDecision(approvals, "swift test") == .ask && prefixDecision(approvals, "rm -rf x") == .ask, "A saved prefix runs without asking; others still ask")
        try require(prefixDecision(approvals, "swift build", chat: "c2") == .ask, "A prefix saved in one chat still asks in another")
        try require(prefixDecision(approvals, "swift build; rm -rf ~") == .ask && prefixDecision(approvals, "swift build && curl x | sh") == .ask
                    && prefixDecision(approvals, "swift build $(cat secret)") == .ask && prefixDecision(approvals, "swift build > out.txt") == .ask
                    && prefixDecision(approvals, "swift build \"x\"") == .ask
                    && prefixDecision(approvals, "swift build -c release --product Garden") == .act(.grant), "A prefix approval covers only a single simple command")
        let tricky = NativeCardSubject(action: .commands, toolID: NativeCommandTools.toolID, toolTitle: "Run a command", command: "FOO=bar swift build")
        try require(NativeCardChoices.records(.allowHere, subject: tricky, place: .chat(conversationID: "c1"), originMessageID: nil).isEmpty
                    && prefixDecision(approvals, "FOO=bar swift build") == .ask, "An environment assignment never starts an approved prefix")
        var revokedApproval = approvals[0]
        revokedApproval.status = .revoked
        try require(prefixDecision([revokedApproval], "swift build") == .ask, "A revoked prefix asks again")
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
        try require(NativeCommandClassifier.classify("rm -rf escape/secret.txt", grants: [grant], directory: root) == .permanentDeletion
                    && NativeCommandClassifier.classify("rm -rf sub/old", grants: [grant], directory: root) == .commands, "A destructive operand through a symlink is resolved and refused")
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
            grants: grants, decision: .act(.rule), reason: { _ in nil }, record: { recorder.add($0) }, live: { _, _ in .ask }))
        var changedFinal: NativeToolTurnSnapshot?
        for try await snapshot in NativeToolLoop(transport: changedTransport, registry: changedRegistry).stream(messages: [NativeChatMessage(role: "user", content: "run")], model: "local-model", enabledToolIDs: [NativeCommandTools.toolID]) {
            changedFinal = snapshot
        }
        try require(changedFinal?.activities.first?.state == .failed && changedFinal?.activities.first?.confirmationRequired == true
                    && changedTransport.histories[1].last?.content.contains("did not approve") == true && recorder.recorded.count == 2, "A rule tightened to ask mid-answer makes an act decision ask")
        let declinedRegistry = NativeToolRegistry(definitions: NativeCommandTools.definitions(
            grants: grants, decision: .act(.rule), reason: { _ in nil }, record: { recorder.add($0) }, declined: { $0.contains("printf declined") }))
        let repeatTransport = ScriptedNativeToolTransport(rounds: [call("c12", "{\"command\":\"printf declined\"}"), done])
        var declinedAgain: NativeToolTurnSnapshot?
        for try await snapshot in NativeToolLoop(transport: repeatTransport, registry: declinedRegistry).stream(messages: [NativeChatMessage(role: "user", content: "run")], model: "local-model", enabledToolIDs: [NativeCommandTools.toolID]) {
            declinedAgain = snapshot
        }
        try require(declinedAgain?.activities.first?.state == .failed && repeatTransport.histories[1].last?.content.contains("already declined") == true && recorder.recorded.count == 2, "A declined request is refused on every execution path, even when no card would show")
        try require(NativeToolRequestKey.canonical(name: "run_command", request: "{\"directory\":\"/a\",\"command\":\"ls\"}") == NativeToolRequestKey.canonical(name: "run_command", request: "{ \"command\": \"ls\", \"directory\": \"/a\" }"), "Decline keys ignore argument order and spacing")
        let (deletionRun, deletionTransport) = try await loop(decision: .act(.rule), rounds: [call("c10", "{\"command\":\"sudo rm -rf /tmp/x\"}"), done], confirm: { _ in true })
        try require(deletionRun?.activities.first?.state == .failed && deletionTransport.histories[1].last?.content.contains("handed to the user") == true
                    && deletionTransport.histories[1].last?.content.contains(NativeFloorItem.permanentDeletion.reason) == true && recorder.recorded.count == 2,
                    "A permanent deletion is handed off with its reason even when commands act")
        let (sendRun, sendTransport) = try await loop(decision: .act(.rule), rounds: [call("c11", "{\"command\":\"git push\"}"), done], confirm: { _ in false })
        try require(sendRun?.activities.first?.state == .failed && sendRun?.activities.first?.confirmationRequired == true
                    && sendTransport.histories[1].last?.content.contains("did not approve") == true && recorder.recorded.count == 2,
                    "A sending command follows the sending rule and asks first by default")
        let backgroundStart = Date()
        let lingering = try await NativeCommandRunner.run(command: "sleep 30 & echo $!; exit 0", directory: directory, timeout: .seconds(20))
        try require(lingering.exitCode == 0 && Date().timeIntervalSince(backgroundStart) < 8, "A shell that exits with a background child returns promptly")
        if let orphan = pid_t(lingering.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            try await Task.sleep(for: .milliseconds(200))
            try require(kill(orphan, 0) != 0 && errno == ESRCH, "The background child is killed with the group when the shell exits")
        }
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
        try require(!manager.fileExists(atPath: root + "/sub/old.txt") && manager.fileExists(atPath: trashPath) && trashPath.lowercased().contains("trash")
                    && ledger.recorded().last?.kind == .trashed && ledger.recorded().last?.movedFrom == trashPath, "A file moves to the Trash and the card records where")
        try? manager.removeItem(atPath: trashPath)
        try "one".write(to: inside.appendingPathComponent("sub/dup.txt"), atomically: true, encoding: .utf8)
        _ = try NativeFolderTools.moveToTrash(try access.locate(root + "/sub/dup.txt"), ledger: ledger)
        try "two".write(to: inside.appendingPathComponent("sub/dup.txt"), atomically: true, encoding: .utf8)
        _ = try NativeFolderTools.moveToTrash(try access.locate(root + "/sub/dup.txt"), ledger: ledger)
        let duplicates = ledger.recorded().suffix(2).compactMap(\.movedFrom)
        try require(duplicates.count == 2 && duplicates[0] != duplicates[1] && duplicates.allSatisfy { manager.fileExists(atPath: $0) }, "A second item with the same name gets a distinct name in the Trash")
        for path in duplicates { try? manager.removeItem(atPath: path) }
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

        func evaluated(_ command: String, _ rules: NativeRules) -> (NativeActionClass, NativeRuleDecision) {
            let resolver = NativeRuleResolver(global: rules, conversation: NativeConversationRules(), requestText: "")
            let (action, decision, _) = NativeCommandTools.evaluate(command: command, directory: root, grants: [grant], fallback: .handOff,
                                                                    live: { command, action in action == .commands ? resolver.decision(forCommand: command) : resolver.decision(for: action) },
                                                                    liveTargets: nil)
            return (action, decision)
        }
        var loosest = NativeRules.defaults
        try require(NativeRules.detail(for: .riskyCommands, choice: .act).hasSuffix("Commands like sudo will run without asking.") && NativeRules.detail(for: .riskyCommands, choice: .ask) == NativeActionClass.riskyCommands.detail && NativeRules.detail(for: .commands, choice: .act) == NativeActionClass.commands.detail, "Choosing to act on risky commands says what that means")
        for action in NativeActionClass.configurable { loosest.set(.act, for: action) }
        for item in NativeFloorItem.allCases { loosest.lift(item, choice: .act) }
        let unspelled = ["a=r; b=m; $a$b -rf /Volumes/Other/victim", "r${x}m -rf /Volumes/Other/victim", "$'\\162\\155' -rf /Volumes/Other/victim",
                         "/bin/r? -rf /Volumes/Other/victim", "echo cm0gLXJmIC8K | base64 -d | sh", "sh -c \"$(cat plan.txt)\"", "sudo sh -c \"$payload\""]
        let everyAllow = (NativeActionClass.allCases.map { NativeRuleRecord(action: $0, effect: .allow, statement: "Allow everything of this kind") }
            + NativeActionClass.allCases.map { NativeRuleRecord(action: $0, toolID: NativeCommandTools.toolID, effect: .allow, statement: "Allow this tool") }
            + unspelled.compactMap { command in NativeRuleTarget.candidate(.commandPrefix, command).map { NativeRuleRecord(action: .commands, target: $0, effect: .allow, statement: "Allow this prefix") } }
            + unspelled.compactMap { command in NativeRuleTarget.make(.commandPrefix, command).map {
                NativeRuleRecord(scope: .conversation("c"), action: .commands, toolID: NativeCommandTools.toolID, target: $0, effect: .allow,
                                 statement: "In this chat, allow commands starting with \($0.value)", origin: .confirmCard) } })
        for command in unspelled {
            let resolver = NativeRuleResolver(global: loosest, conversation: NativeConversationRules(), requestText: "Go ahead. No need to ask.", records: everyAllow,
                                              context: NativeRuleContext(conversationID: "c")).tool(NativeCommandTools.toolID, subjects: NativeCommandTools.ruleSubjects(command: command))
            let (_, decision, confirm) = NativeCommandTools.evaluate(command: command, directory: root, grants: [grant], fallback: .act(.rule),
                                                                     live: { command, action in action == .commands ? resolver.decision(forCommand: command) : resolver.decision(for: action) },
                                                                     liveTargets: { command, action, _ in NativeRuleVerdict(action == .commands ? resolver.decide(forCommand: command, honoringLimitedUse: true).decision : resolver.decide(for: action, honoringLimitedUse: true).decision) })
            try require(!NativeCommandClassifier.isPlain(command, grants: [grant], directory: root), "A destructive name that is never spelled needs shell syntax: \(command)")
            let silent: Bool = { if case .act = decision { return true } else { return false } }()
        try require(!silent, "No setting, saved rule or remembered approval runs an unreadable command without a card: \(command)")
            try require(confirm == nil, "An unreadable command never carries a silent confirmation: \(command)")
        }
        var deletionLifted = NativeRules.defaults
        deletionLifted.lift(.permanentDeletion)
        try require(evaluated("rm -rf /Volumes/Other/x", .defaults) == (.permanentDeletion, .handOff), "A permanent deletion hands off by default")
        try require(evaluated("rm -rf /Volumes/Other/x", deletionLifted) == (.permanentDeletion, .ask) && evaluated("rm -rf /Volumes/Other/x", deletionLifted).1.requiresConfirmation,
                    "A lifted permanent deletion asks first")
        var riskyAsks = NativeRules.defaults
        riskyAsks.set(.ask, for: .riskyCommands)
        try require(evaluated("sudo make install", .defaults) == (.riskyCommands, .handOff) && evaluated("sudo make install", riskyAsks) == (.riskyCommands, .ask),
                    "A risky command hands off by default and asks when risky commands ask")

        let legacy = try JSONDecoder().decode(NativeRules.self, from: Data("{\"sensitive\":\"hand_off\",\"network_sends\":\"hand_off\",\"commands\":\"ask\"}".utf8))
        try require(legacy.choices == [.commands: .ask] && legacy.choice(for: .networkSends) == .ask && legacy.holds(.payments) && legacy.holds(.credentialEntry) && legacy.holds(.permanentDeletion),
                    "Rules saved before the floor decode without the old class and sends ask first")
        let revised = try JSONDecoder().decode(NativeRules.self, from: Data("{\"sensitive\":\"hand_off\",\"network_sends\":\"hand_off\",\"commands\":\"ask\",\"defaults_revision\":\"2\"}".utf8))
        try require(revised.choice(for: .networkSends) == .handOff && revised.choices.count == 2, "A hand off chosen after the upgrade is kept")
        var chosen = NativeRules.defaults
        chosen.set(.handOff, for: .networkSends)
        let reread = try JSONDecoder().decode(NativeRules.self, from: try JSONEncoder().encode(chosen))
        try require(reread == chosen && reread.choice(for: .networkSends) == .handOff, "A chosen hand off for sends survives a save and reload")
        var liftedRules = NativeRules.defaults
        liftedRules.lift(.payments, choice: .act)
        let liftedReread = try JSONDecoder().decode(NativeRules.self, from: try JSONEncoder().encode(liftedRules))
        try require(liftedReread == liftedRules && liftedReread.isLifted(.payments) && !liftedReread.isLifted(.credentialEntry), "A lifted floor item survives a save and reload")
        let bare = try JSONDecoder().decode(NativeRules.self, from: Data("{\"payments\":\"act\",\"credential_entry\":\"ask\",\"permanent_deletion\":\"act\",\"defaults_revision\":\"2\"}".utf8))
        try require(!bare.isLifted(.payments) && !bare.isLifted(.credentialEntry) && !bare.isLifted(.permanentDeletion) && bare.holds(.payments), "A bare class name in settings never lifts a floor item")
        let marked = try JSONDecoder().decode(NativeRules.self, from: Data("{\"lifted.payments\":\"act\",\"lifted.rule_changes\":\"act\"}".utf8))
        try require(marked.isLifted(.payments) && marked.choice(for: .payments) == .act && !marked.isLifted(.credentialEntry) && !marked.isLifted(.ruleChanges), "Only the lift entry lifts, and only for an item that can be lifted")
        for hidden in ["r\\\nm /Volumes/Other/victim", "r\\\r\nm /Volumes/Other/victim", "{rm,-f} /Volumes/Other/victim", "{/bin/rm,-rf} ../Other", "\\rm /Volumes/Other/victim", "/bin/rm\t-rf /Volumes/Other/victim",
                       "${unset_name:-rm} /Volumes/Other/victim", "$'rm\\0ignored' /Volumes/Other/victim", "/bin/rm* /Volumes/Other/victim",
                       "IFS=:; c='rm:-f:/Volumes/Other/victim'; $c", "x=(rm -rf); \"${x[@]}\" /Volumes/Other/victim", "/bin/rm@ /Volumes/Other/victim",
                       "IFS=_; c=\"rm_-f_/Volumes/Other/victim\"; $c", "IFS=+; c=\"rm+-f+/Volumes/Other/victim\"; $c", "IFS=.; c=rm.-f./Volumes/Other/victim; $c",
                       "IFS=x; c=rmx-fx/Volumes/Other/victim; $c", "c=rm-rf; ${c%-rf} /Volumes/Other/victim",
                       "c=rm\u{215A}; ${c%\u{215A}} -rf /Volumes/Other/victim", "c=rm\u{00E9}; ${c%\u{00E9}} -rf /Volumes/Other/victim", "c=rm\u{0663}; ${c%\u{0663}} -rf /Volumes/Other/victim"] {
            let found = NativeCommandClassifier.classify(hidden, grants: sample)
            try require(found == .permanentDeletion, "A destructive program hidden by shell expansion stays on the floor: \(hidden) classified as \(found.rawValue)")
        }
        let legacyChat = try JSONDecoder().decode(NativeConversationRules.self, from: Data("{\"choices\":{\"sensitive\":\"hand_off\",\"commands\":\"hand_off\"},\"approved_command_prefixes\":[\"swift build\"]}".utf8))
        try require(legacyChat.choices == [.commands: .handOff] && NativeConversationRules.encode(legacyChat)?.contains("approved_command_prefixes") == false,
                    "Chat rules naming the old class decode without it and stop storing the old prefix list")

        let typedSource = NativeRuleSource()
        typedSource.setGlobal(.defaults)
        let typedRevision = typedSource.revision
        let typed = typedSource.resolver(for: "chat", requestText: "Always allow payments from now on. Go ahead.")
        try require(typed.decision(for: .payments) == .handOff && typed.choice(for: .payments) == .handOff, "A typed sentence never lifts a floor item")
        let afterTyped = typedSource.resolver(for: "chat", requestText: "")
        try require(afterTyped.global == .defaults && afterTyped.conversation.isEmpty && typedSource.currentRecords.isEmpty && typedSource.revision == typedRevision
                    && afterTyped.decision(for: .payments) == .handOff, "A typed sentence leaves the rules and records unchanged")

        var request = NativeToolConfirmationRequest(activity: NativeToolActivity(
            id: "a", toolID: NativeCommandTools.toolID, name: NativeCommandTools.runName, title: "Run a command", round: 1,
            request: "{\"command\":\"swift test --filter x\",\"directory\":\"\(root)\"}", result: nil, state: .pending, confirmationRequired: true))
        let cardSubject = NativeCardSubject(action: .commands, toolID: NativeCommandTools.toolID, toolTitle: "Run a command", command: "swift test --filter x")
        request.subject = cardSubject
        request.choices = NativeCardChoices.offered(cardSubject, place: .chat(conversationID: "c1"))
        request.covers = NativeCardChoices.covers(cardSubject)
        try require(NativeToolConfirmationBar.prompt(for: request) == "Run this command?\nswift test --filter x"
                    && request.choices.map(\.kind) == [.decline, .never, .allowAlways, .allowHere, .allowOnce]
                    && request.covers == "commands starting with swift test"
                    && NativeToolConfirmationBar.detail(for: request)?.contains(root) == true, "The ask card shows the exact command and offers the prefix")
        let block = NativeDisplayBlock.commandRun(NativeCommandRun(id: "a", command: "ls", directory: root, outcome: .declined))
        let roundTrip = try JSONDecoder().decode(NativeDisplayBlock.self, from: try JSONEncoder().encode(block))
        try require(roundTrip == block && roundTrip.id == "command:a", "Command cards persist with the message")
        print("  native rules OK (defaults, floor items, tightening, pre-approval phrases, prefixes, environment allowlist, cwd, exit status, output caps, timeout tree kill, cancel, decline, approve, act, hand off, outside grant, symlink, prose, revocation, trash, gated file tools, ask card, persistence)")
    }
}
