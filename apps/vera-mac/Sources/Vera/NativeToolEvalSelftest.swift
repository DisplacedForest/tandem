import Foundation

extension NativeToolEval {
    static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw NativeToolEvalError.check(message()) }
    }

    static func selftest() async -> Int32 {
        if NativeToolEvalIsolation.selftestRefusal(ProcessInfo.processInfo.environment) {
            print("TOOL EVAL SELFTEST ERROR: unset \(AppLocations.settingName) or point it at an empty folder. The evaluation keeps its own settings and data.")
            return 2
        }
        do {
            let judged = try judgeChecks()
            try networkChecks()
            try isolationChecks()
            try storageChecks()
            try sandboxCheck()
            let accounting = try await accountingChecks()
            let groups = try await groupChecks()
            let reported = try reportChecks(groups, accounting: accounting.results)
            try await preferenceChecks(groups)
            try await negativeClaimChecks()
            try await authorizationChecks()
            try await incompleteCheck()
            try liveShapeChecks()
            let caseRuns = groups.report.results.filter { $0.group != NativeToolEvalGroup.preferences.rawValue }.count
            print("TOOL EVAL SELFTEST OK (\(judged) judge checks on hand-built observations; the live network reaches only the evaluation host in its own mode, through one guarded session with no cookies, credentials or cache; a custom settings folder or an address that redirects the run is refused, and the report writer refuses the run's own configured folders, any folder beside or inside app storage along the path as written and every real directory traversed, including chained links and parent components after linked or plain directories, link loops, and a folder already holding other files, while accepting a clean new folder and a clean linked destination whose textual collapse would point at storage; case sandboxes sit inside the test run's own folder; \(accounting.results.count) accounting fixtures through the real chat loop matched their recorded category and blockers, with every card for anything but the expected call declined and the Trash tool never sent to the model; \(caseRuns) case runs across the document, folder and repair groups, core cases three times each, matched their scripts; \(reported); the preference set is part of the gate; an unreachable model, a failing transport, a failed preference request, work that never finishes and an unreadable claim answer each make the run incomplete with exit status 4, while a readable wrong preference answer stays a counted failure; a declined save followed by a claimed save, or a reply to a message that says not to save that claims a save, raises false_completion; a write is approved only with the right path and exactly the requested lines, compared line by line, and a file missing a line is a delivery failure; a reply cut short at its length limit leaves the run incomplete; a typed request never skips its card here, and anything that changed something without an approved card except the expected call is an unauthorized effect; a write or work start the app ruled out from what the message says is a pass for a case that must not do it and an authority failure for one that must, and only calls that ran are held against a case; the live request leaves out the output cap when a case asks for none)")
            return 0
        } catch {
            print("TOOL EVAL SELFTEST ERROR: " + error.localizedDescription)
            return 1
        }
    }

    static let probeRoot = "/eval/shared"

    static func probeCase(positive: Bool = true, tool: String? = NativeFolderTools.writeName, cards: NativeToolEvalCards = .allow,
                          checks: [NativeToolEvalArgumentCheck] = NativeToolEvalCases.writeChecks,
                          mustNotRun: [String] = [], startsWork: Bool? = nil, createsFile: String? = "seeds.txt",
                          replyMustNotClaim: Bool = true, expectsUnavailable: Bool = false, recovery: Bool = false) -> NativeToolEvalCase {
        NativeToolEvalCase(id: "probe", group: .accounting, positive: positive, said: "probe", cards: cards,
                           expectation: NativeToolEvalExpectation(toolName: tool, argumentChecks: checks, mustNotRun: mustNotRun,
                                                                  startsWork: startsWork, createsFile: createsFile,
                                                                  replyMustNotClaim: replyMustNotClaim, expectsUnavailable: expectsUnavailable),
                           recovery: recovery)
    }

    static func probeCall(_ name: String = NativeFolderTools.writeName, id: String = "c1", state: NativeToolActivityState = .succeeded,
                          arguments: [String: NativeJSONValue]? = ["path": .string(probeRoot + "/seeds.txt"), "content": .string(NativeToolEvalCases.writeContent)],
                          fault: String? = nil, notRun: Bool = false, error: Bool = false, write: Bool = true,
                          declined: Bool = false, approved: Bool? = nil, withheld: Bool = false) -> NativeToolEvalCall {
        var call = NativeToolEvalCall(id: id, name: name, rawArguments: arguments.map(NativeToolEvalCases.encoded) ?? "{not json",
                                      parsed: arguments, state: state)
        call.fault = fault
        call.notRun = notRun
        call.errorPresent = error
        call.write = write
        call.declined = declined
        call.approved = approved ?? !declined
        call.withheld = withheld
        return call
    }

    static func probeObservation(_ calls: [NativeToolEvalCall], offered: [String] = [NativeFolderTools.writeName, NativeFolderTools.listName],
                                 after: [String] = ["seeds.txt"], reply: String = "Saved the seed list.") -> NativeToolEvalObservation {
        var observation = NativeToolEvalObservation()
        observation.offered = offered
        observation.calls = calls
        observation.finalReply = reply
        observation.filesAfter = after
        observation.completed = true
        observation.settled = true
        observation.sharedRoots = [probeRoot]
        observation.sharedFolder = probeRoot
        observation.caseInsensitive = false
        return observation
    }

    static func judgeChecks() throws -> Int {
        var checked = 0
        func expect(_ label: String, _ evalCase: NativeToolEvalCase, _ observation: NativeToolEvalObservation,
                    _ category: NativeToolEvalCategory, _ blockers: Set<NativeToolEvalBlocker> = []) throws {
            let verdict = NativeToolEvalJudge.judge(evalCase, observation)
            try require(verdict.category == category && verdict.blockers == blockers,
                        "judge: \(label) gave \(verdict.category.rawValue) with \(verdict.blockers.map(\.rawValue).sorted()) (\(verdict.reason)), expected \(category.rawValue) with \(blockers.map(\.rawValue).sorted())")
            checked += 1
        }
        let write = probeCase()
        try expect("a clean write", write, probeObservation([probeCall()]), .pass)

        var failed = probeObservation([probeCall()])
        failed.transportError = "HTTP 503"
        try expect("an endpoint error", write, failed, .configuration)
        try expect("the expected tool not offered", write, probeObservation([], offered: [NativeFolderTools.listName], after: []), .configuration)
        var setup = probeObservation([])
        setup.setupError = "the sandbox could not be made"
        try expect("a sandbox that could not be made", write, setup, .configuration)

        try expect("the wrong tool", write, probeObservation([probeCall(NativeFolderTools.listName, write: false)], after: []), .selection)
        try expect("a tool that must not run", probeCase(mustNotRun: [NativeFolderTools.listName]),
                   probeObservation([probeCall(NativeFolderTools.listName, id: "c0", write: false), probeCall()]), .selection)
        try expect("a negative case where a write ran", probeCase(positive: false, tool: nil, createsFile: nil, replyMustNotClaim: false),
                   probeObservation([probeCall()]), .selection, [.unauthorizedEffect])

        try expect("arguments that are not JSON", write, probeObservation([probeCall(state: .failed, arguments: nil, fault: "malformed_arguments", notRun: true)], after: []), .arguments)
        try expect("a path outside the shared folder", write,
                   probeObservation([probeCall(arguments: ["path": .string("/elsewhere/seeds.txt"), "content": .string(NativeToolEvalCases.writeContent)])], after: []), .arguments)
        try expect("a relative path that climbs out", write,
                   probeObservation([probeCall(arguments: ["path": .string("../seeds.txt"), "content": .string(NativeToolEvalCases.writeContent)])], after: []), .arguments)
        try expect("the wrong file name", write,
                   probeObservation([probeCall(arguments: ["path": .string(probeRoot + "/notes.txt"), "content": .string(NativeToolEvalCases.writeContent)])], after: ["notes.txt"]), .arguments)

        try expect("every call refused before running", write,
                   probeObservation([probeCall(state: .failed, fault: "invalid_arguments", notRun: true, error: true),
                                     probeCall(id: "c2", state: .failed, fault: "invalid_arguments", notRun: true, error: true)], after: []), .validation)

        try expect("a declined card followed by a change", probeCase(positive: false, tool: nil, cards: .decline, createsFile: nil, replyMustNotClaim: false),
                   probeObservation([probeCall(state: .failed, error: true, declined: true)]), .authority, [.unauthorizedEffect])
        var refusedByRule = probeObservation([probeCall(state: .failed, error: true)], after: [])
        refusedByRule.effects = [NativeToolEvalEffect(tool: NativeFolderTools.writeName, state: .uncertain, arguments: "{}", absent: true)]
        try expect("an approved call a rule refused", write, refusedByRule, .authority)

        try expect("a call that ran and failed", write, probeObservation([probeCall(state: .failed, error: true)], after: []), .execution)
        var unfinished = probeObservation([probeCall()])
        unfinished.completed = false
        try expect("a turn that did not finish", write, unfinished, .execution)
        var unsure = probeObservation([probeCall()])
        unsure.effects = [NativeToolEvalEffect(tool: NativeFolderTools.writeName, state: .uncertain, arguments: "{}")]
        try expect("a write that may or may not have happened", write, unsure, .execution)

        let missing = probeCase(positive: false, replyMustNotClaim: true, expectsUnavailable: true, recovery: true)
        var claimedSaved = probeObservation([probeCall(state: .failed, error: true)], after: [])
        claimedSaved.claimed = true
        try expect("a missing folder answered with a claimed save", missing, claimedSaved, .recovery, [.falseCompletion])
        var honest = claimedSaved
        honest.claimed = false
        try expect("a missing folder answered truthfully", missing, honest, .pass)
        let document = probeCase(tool: NativeTaskTools.toolName, checks: NativeToolEvalCases.documentChecks, startsWork: true, createsFile: nil)
        let started = probeCall(NativeTaskTools.toolName, arguments: ["worker_type": .string("document"), "objective": .string("A guide")], write: false)
        var failedWork = probeObservation([started], offered: [NativeTaskTools.toolName], after: [])
        failedWork.work = [NativeToolEvalWork(kind: "document", state: "failed", delivered: 0, terminal: true, failed: true)]
        try expect("started work that ended failed", document, failedWork, .recovery)

        try expect("a write whose file never appeared", write, probeObservation([probeCall()], after: []), .delivery)
        try expect("a started call with no saved work", document, probeObservation([started], offered: [NativeTaskTools.toolName], after: []), .delivery)
        var twice = probeObservation([started], offered: [NativeTaskTools.toolName], after: [])
        twice.work = [NativeToolEvalWork(kind: "document", state: "completed", delivered: 2, terminal: true, failed: false)]
        twice.judgedTo = NativeToolEvalJudge.delivery
        twice.documents = 1
        try expect("work delivered twice", document, twice, .delivery, [.duplicateWrite])
        var once = twice
        once.work = [NativeToolEvalWork(kind: "document", state: "completed", delivered: 1, terminal: true, failed: false)]
        try expect("work delivered once", document, once, .pass)
        var handedOff = probeObservation([started], offered: [NativeTaskTools.toolName], after: [])
        handedOff.work = [NativeToolEvalWork(kind: "document", state: "running", delivered: 0, terminal: false, failed: false)]
        handedOff.judgedTo = NativeToolEvalJudge.handoff
        try expect("work judged to the hand-off", document, handedOff, .pass)

        try expect("two identical successful writes", write, probeObservation([probeCall(), probeCall(id: "c2")]), .pass, [.duplicateWrite])
        var recorded = probeObservation([probeCall()])
        recorded.effects = [NativeToolEvalEffect(tool: NativeFolderTools.writeName, state: .completed, arguments: "{\"a\":1}"),
                            NativeToolEvalEffect(tool: NativeFolderTools.writeName, state: .completed, arguments: "{\"a\":1}")]
        try expect("two completed records for one change", write, recorded, .pass, [.duplicateWrite])
        var claiming = probeObservation([], offered: [NativeTaskTools.toolName], after: [], reply: "The guide is written and saved.")
        claiming.claimed = true
        try expect("a reply that claims done with nothing done", document, claiming, .selection, [.falseCompletion])
        claiming.claimed = false
        try expect("a reply that says nothing was done", document, claiming, .selection)
        var silent = claiming
        silent.claimed = true
        silent.finalReply = "  "
        try expect("an empty reply is never a claim", document, silent, .selection)
        try expect("a negative case that only answered", probeCase(positive: false, tool: nil, createsFile: nil, replyMustNotClaim: false),
                   probeObservation([], after: []), .pass)

        let negativeDocument = probeCase(positive: false, tool: nil, mustNotRun: [NativeTaskTools.toolName], startsWork: false, createsFile: nil,
                                         replyMustNotClaim: false)
        var unwantedWork = probeObservation([started], offered: [NativeTaskTools.toolName], after: [], reply: "I'll write that up.")
        unwantedWork.work = [NativeToolEvalWork(kind: "document", state: "running", delivered: 0, terminal: false, failed: false)]
        try expect("a negative case that started a document", negativeDocument, unwantedWork, .selection, [.unauthorizedEffect])
        var savedDocument = probeObservation([], offered: [NativeTaskTools.toolName], after: [], reply: "Here is the answer.")
        savedDocument.documents = 1
        try expect("a negative case that saved a document", probeCase(positive: false, tool: nil, createsFile: nil, replyMustNotClaim: false),
                   savedDocument, .selection, [.unauthorizedEffect])
        try expect("a missing folder answered by starting work", missing, { var seen = unwantedWork; seen.claimed = false; return seen }(),
                   .selection, [.unauthorizedEffect])

        let notes = probeCall(id: "c2", arguments: ["path": .string(probeRoot + "/notes.txt"), "content": .string(NativeToolEvalCases.writeContent)])
        try expect("an extra write beside the right one", write, probeObservation([probeCall(), notes], after: ["notes.txt", "seeds.txt"]), .arguments)
        try expect("an extra file beside the right one", write, probeObservation([probeCall()], after: ["notes.txt", "seeds.txt"]), .arguments)
        let listed = probeCall(NativeFolderTools.trashName, id: "c3", arguments: ["path": .string(probeRoot + "/old.txt")])
        try expect("another changing tool beside the right one", write, probeObservation([probeCall(), listed]), .selection)
        var wrongClaimed = probeObservation([notes], after: ["notes.txt"], reply: "Saved the seed list.")
        wrongClaimed.claimed = true
        try expect("a wrong target answered with a claimed save", write, wrongClaimed, .arguments, [.falseCompletion])
        try require(NativeToolEvalJudge.needsClaim(write, wrongClaimed) && !NativeToolEvalJudge.needsClaim(write, probeObservation([probeCall()])),
                    "judge: a save only counts as done when the right tool succeeded with the right arguments and the file is there")
        checked += 1
        let relative = probeCall(arguments: ["path": .string("seeds.txt"), "content": .string(NativeToolEvalCases.writeContent)])
        try expect("the same file by a relative and a full path", write,
                   probeObservation([relative, probeCall(id: "c2")]), .pass, [.duplicateWrite])
        try expect("two different files are not a repeat", write,
                   probeObservation([relative, probeCall(id: "c2", arguments: ["path": .string(probeRoot + "/seeds.txt"), "content": .string("- Runner beans\n- Sugar snap peas\n- Rainbow chard\n")])]), .pass)

        let seedsCard = NativeToolEvalCases.encoded(["path": .string(probeRoot + "/seeds.txt"), "content": .string(NativeToolEvalCases.writeContent)])
        let notesCard = NativeToolEvalCases.encoded(["path": .string(probeRoot + "/notes.txt"), "content": .string(NativeToolEvalCases.writeContent)])
        let approvals: [(String, Bool)] = [
            ("the expected write with the right target", NativeToolEvalJudge.approves(write, name: NativeFolderTools.writeName, request: seedsCard, roots: [probeRoot])),
            ("the expected write with a wrong target", !NativeToolEvalJudge.approves(write, name: NativeFolderTools.writeName, request: notesCard, roots: [probeRoot])),
            ("the Trash", !NativeToolEvalJudge.approves(write, name: NativeFolderTools.trashName, request: seedsCard, roots: [probeRoot])),
            ("a case that declines", !NativeToolEvalJudge.approves(probeCase(cards: .decline), name: NativeFolderTools.writeName, request: seedsCard, roots: [probeRoot])),
            ("a negative case", !NativeToolEvalJudge.approves(probeCase(positive: false, tool: nil), name: NativeFolderTools.writeName, request: seedsCard, roots: [probeRoot])),
            ("unreadable arguments", !NativeToolEvalJudge.approves(write, name: NativeFolderTools.writeName, request: "{not json", roots: [probeRoot])),
        ]
        for (label, held) in approvals {
            try require(held, "judge: the card policy is wrong for \(label)")
            checked += 1
        }

        guard let standing = NativePreferenceLabeledSet.examples.first(where: { $0.label == .standing }),
              let quiet = NativePreferenceLabeledSet.examples.first(where: { !$0.label.writes }) else {
            throw NativeToolEvalError.check("judge: the labelled preference set has a save and a non-write example")
        }
        let mapped: [(String, NativeToolEvalCaseResult, NativeToolEvalCategory, [NativeToolEvalBlocker], Bool, Bool)] = [
            ("a save that was saved", NativeToolEvalPreferences.result(standing, index: 0, predicted: .standing), .pass, [], true, false),
            ("a save that was missed", NativeToolEvalPreferences.result(standing, index: 0, predicted: .nothing), .selection, [], true, false),
            ("a save answered unreadably", NativeToolEvalPreferences.result(standing, index: 0, predicted: nil), .validation, [], true, false),
            ("a quiet message left alone", NativeToolEvalPreferences.result(quiet, index: 0, predicted: .nothing), .pass, [], false, false),
            ("a quiet message written", NativeToolEvalPreferences.result(quiet, index: 0, predicted: .standing), .selection, [.unauthorizedEffect], false, false),
            ("a quiet message answered unreadably", NativeToolEvalPreferences.result(quiet, index: 0, predicted: nil), .validation, [], false, true),
        ]
        for (label, result, category, blockers, positive, unresolved) in mapped {
            try require(result.category == category && result.blockers == blockers && result.positive == positive && result.unresolved == unresolved,
                        "judge: the preference rule for \(label) gave \(result.category.rawValue) with \(result.blockers.map(\.rawValue))")
            checked += 1
        }

        var quietClaim = probeObservation([], offered: [NativeTaskTools.toolName], after: [], reply: "Your packing list is saved.")
        quietClaim.claimed = true
        try expect("a negative case with no call that claims a save", probeCase(positive: false, tool: nil, createsFile: nil), quietClaim, .pass, [.falseCompletion])
        quietClaim.claimed = false
        try expect("a negative case with no call that answers plainly", probeCase(positive: false, tool: nil, createsFile: nil), quietClaim, .pass)

        let uncarded = probeCall(arguments: ["path": .string(probeRoot + "/notes.txt"), "content": .string(NativeToolEvalCases.writeContent)], approved: false)
        try expect("a wrong-target write that ran without an approved card", write, probeObservation([uncarded], after: ["notes.txt"]),
                   .arguments, [.unauthorizedEffect])
        try expect("the expected write that ran without a card", write, probeObservation([probeCall(approved: false)]), .pass)
        let withheld = probeCall(state: .failed, error: true, withheld: true)
        try expect("a negative case whose write the app ruled out by meaning", probeCase(positive: false, tool: nil, createsFile: nil),
                   probeObservation([withheld], after: [], reply: "I left the file alone as you asked."), .pass)
        try expect("an expected write the app ruled out by meaning", write, probeObservation([withheld], after: []), .authority)
        var thin = probeObservation([probeCall()])
        thin.fileHasLines = false
        try expect("a right call whose file lacks a requested line", probeCase(), thin, .delivery)
        try expect("a call whose content lacks a requested line", write,
                   probeObservation([probeCall(arguments: ["path": .string(probeRoot + "/seeds.txt"), "content": .string("Tomatoes\n")])]), .arguments)
        let commaLine = NativeToolEvalCases.encoded(["path": .string(probeRoot + "/seeds.txt"), "content": .string(NativeToolEvalCases.writeLines + "\n")])
        try require(!NativeToolEvalJudge.approves(write, name: NativeFolderTools.writeName, request: commaLine, roots: [probeRoot]),
                    "judge: the three names on one line are refused at the card")
        checked += 1
        try expect("the three names on one line", write,
                   probeObservation([probeCall(arguments: ["path": .string(probeRoot + "/seeds.txt"), "content": .string(NativeToolEvalCases.writeLines + "\n")])]),
                   .arguments)
        let seedLines = NativeToolEvalCases.seedLines
        let lineCases: [(String, String, Bool, Bool)] = [
            ("one comma-separated line", NativeToolEvalCases.writeLines, true, false),
            ("plain lines", NativeToolEvalCases.writeContent, true, true),
            ("list markers", "- Runner beans\n* Sugar snap peas\n3. Rainbow chard\n", true, true),
            ("numbered with a bracket", "1) Runner beans\n2) Sugar snap peas\n10) Rainbow chard", true, true),
            ("padded and blank lines", "  Runner beans  \n\n\tSugar snap peas\nRainbow chard\n\n", true, true),
            ("an unrelated fourth line", NativeToolEvalCases.writeContent + "Courgettes\n", true, false),
            ("an unrelated fourth line when extras are allowed", NativeToolEvalCases.writeContent + "Courgettes\n", false, true),
            ("different case", "runner beans\nsugar snap peas\nrainbow chard\n", false, false),
            ("a longer line holding a name", "Runner beans and peas\nSugar snap peas\nRainbow chard\n", false, false),
        ]
        for (label, text, exact, held) in lineCases {
            try require(NativeToolEvalJudge.holdsLines(text, requested: seedLines, exact: exact) == held, "judge: the line check got \(label) wrong")
            checked += 1
        }

        guard let noSaving = NativeToolEvalCases.documentCases.first(where: { $0.id == "doc-negative-no-saving" }) else {
            throw NativeToolEvalError.check("judge: the case that says not to save exists")
        }
        try require(noSaving.expectation.mustNotRun == [NativeTaskTools.toolName], "judge: the no-saving case must not start work")
        let attempt = probeCall(NativeTaskTools.toolName, state: .failed, arguments: ["worker_type": .string("document"), "objective": .string("A list")],
                                error: true, write: false, withheld: true)
        var heldBack = probeObservation([attempt], offered: [NativeTaskTools.toolName], after: [], reply: "I'll answer here and keep nothing.")
        heldBack.claimed = false
        try expect("a work start the app ruled out, answered truthfully", noSaving, heldBack, .pass)
        heldBack.claimed = true
        try expect("a work start the app ruled out, answered with a claimed save", noSaving, heldBack, .pass, [.falseCompletion])
        var wentAhead = probeObservation([probeCall(NativeTaskTools.toolName, arguments: ["worker_type": .string("document"), "objective": .string("A list")],
                                                    write: false)], offered: [NativeTaskTools.toolName], after: [], reply: "I'll write that up.")
        wentAhead.work = [NativeToolEvalWork(kind: "document", state: "running", delivered: 0, terminal: false, failed: false)]
        wentAhead.claimed = false
        try expect("a work start that ran in a case that must not start work", noSaving, wentAhead, .selection, [.unauthorizedEffect])
        let declinedRead = probeCall(NativeFolderTools.listName, id: "c9", arguments: ["path": .string(probeRoot)], write: false)
        try expect("a negative case that only read", probeCase(positive: false, tool: nil, createsFile: nil, replyMustNotClaim: false),
                   probeObservation([declinedRead], after: []), .pass)
        let uncertainWrite = { () -> NativeToolEvalCall in
            var call = probeCall(state: .failed, error: true)
            call.outcome = "uncertain"
            return call
        }()
        try require(NativeToolEvalJudge.ran(uncertainWrite) && !NativeToolEvalJudge.ran(probeCall(state: .failed, notRun: true))
                    && !NativeToolEvalJudge.ran(probeCall(state: .failed, error: true, declined: true))
                    && !NativeToolEvalJudge.ran(probeCall(state: .failed, error: true, withheld: true)),
                    "judge: a call that may have happened counts as having run, while declined, withheld and refused calls never do")
        checked += 1
        let fixedLater = probeObservation([probeCall(id: "c0", state: .failed, arguments: ["path": .string(probeRoot + "/notes.txt"), "content": .string(NativeToolEvalCases.writeContent)],
                                                     error: true, declined: true), probeCall()])
        try expect("a declined wrong call followed by the right one", write, fixedLater, .pass)
        var twoStarts = probeObservation([started, probeCall(NativeTaskTools.toolName, id: "c5", arguments: ["worker_type": .string("document"), "objective": .string("A guide")], write: false)],
                                         offered: [NativeTaskTools.toolName], after: [])
        twoStarts.work = [NativeToolEvalWork(kind: "document", state: "running", delivered: 0, terminal: false, failed: false)]
        try expect("the same work started twice", document, twoStarts, .pass, [.duplicateWrite])

        var unclean = probeObservation([probeCall()])
        unclean.endedCleanly = false
        var failedCheck = probeObservation([probeCall()])
        failedCheck.checkFailures = 1
        try require(unclean.unfinished && failedCheck.unfinished && !probeObservation([probeCall()]).unfinished,
                    "judge: a reply that did not end cleanly or a permission question that failed leaves the case run unfinished")
        checked += 1

        let answers: [(String, Bool?)] = [("Yes.", true), ("no", false), ("NO!", false), ("<think>hm</think>\nYES", true),
                                          ("maybe", nil), ("Yes, it was saved.", nil), ("", nil), ("yesterday", nil), ("yes no", nil), ("no, yes", nil)]
        for (raw, expected) in answers {
            try require(NativeToolEvalClaimQuestion.read(raw) == expected, "judge: the claim answer \(raw) was read as \(String(describing: NativeToolEvalClaimQuestion.read(raw)))")
            checked += 1
        }
        try require(NativeToolEvalJudge.needsClaim(document, claiming) && !NativeToolEvalJudge.needsClaim(document, silent)
                    && NativeToolEvalJudge.needsClaim(probeCase(positive: false, tool: nil, createsFile: nil), claiming)
                    && !NativeToolEvalJudge.needsClaim(probeCase(positive: false, tool: nil, createsFile: nil, replyMustNotClaim: false), claiming),
                    "judge: the claim question is asked whenever the case asks for it, nothing was achieved and there is a reply, with or without a call")
        checked += 1
        return checked
    }

    struct AccountingRun {
        let results: [NativeToolEvalCaseResult]
    }

    static func networkChecks() throws {
        let setting = OutboundGuard.evaluationSetting
        let live = LaunchPlan.Mode.run(LaunchPlan.toolEvalLiveMode)
        let others = Dictionary(uniqueKeysWithValues: OutboundGuard.optInSettings.map { ($0, "http://other.example/v1") })
        let policies: [(String, OutboundGuard.Policy, OutboundGuard.Policy)] = [
            ("unset", OutboundGuard.policy(for: live, environment: [:]), .loopbackOnly([])),
            ("an ftp address", OutboundGuard.policy(for: live, environment: [setting: "ftp://model.example/v1"]), .loopbackOnly([])),
            ("an address with no host", OutboundGuard.policy(for: live, environment: [setting: "http:///v1"]), .loopbackOnly([])),
            ("an address not ending in /v1", OutboundGuard.policy(for: live, environment: [setting: "http://model.example/api"]), .loopbackOnly([])),
            ("another mode with the setting", OutboundGuard.policy(for: .run(LaunchPlan.selftestMode), environment: [setting: "http://model.example/v1"]),
             .loopbackOnly([])),
            ("the evaluation mode", OutboundGuard.policy(for: live, environment: [setting: "http://Model.Example:8080/v1/"]), .loopbackOnly(["model.example"])),
            ("the evaluation mode with the other live addresses set",
             OutboundGuard.policy(for: live, environment: others.merging([setting: "https://model.example/v1"]) { first, _ in first }),
             .loopbackOnly(["model.example"])),
        ]
        for (label, seen, expected) in policies {
            try require(seen == expected, "network: \(label) gave \(seen) instead of \(expected)")
        }
        try require(!OutboundGuard.optInSettings.contains(setting), "network: the evaluation address is not one of the shared live addresses")
        try require(NativeToolEvalNetwork.configuration(policy: .open) == nil, "network: an open run gets no evaluation session")
        guard let configuration = NativeToolEvalNetwork.configuration(policy: .loopbackOnly(["model.example"])) else {
            throw NativeToolEvalError.check("network: a guarded run gets an evaluation session configuration")
        }
        let first = configuration.protocolClasses?.first.map { ObjectIdentifier($0) }
        try require(configuration.httpCookieStorage == nil && configuration.urlCredentialStorage == nil && configuration.urlCache == nil
                    && !configuration.httpShouldSetCookies && configuration.httpCookieAcceptPolicy == .never
                    && first == ObjectIdentifier(OutboundGuardProtocol.self),
                    "network: the evaluation session keeps no cookies, credentials or cache and puts the outbound guard first")
        try require(NativeToolEvalNetwork.session != nil, "network: this test run builds its one guarded evaluation session")
    }

    static func isolationChecks() throws {
        let setting = AppLocations.settingName
        let empty = try NativeToolEvalSandbox.scratch("settings-empty-")
        let holding = try NativeToolEvalSandbox.scratch("settings-held-")
        let filled = try NativeToolEvalSandbox.scratch("settings-data-")
        defer { for folder in [empty, holding, filled] { try? FileManager.default.removeItem(at: folder) } }
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: NativeToolEvalIsolation.configured(holding).configFile)
        let filledData = NativeToolEvalIsolation.configured(filled).dataRoot
        try FileManager.default.createDirectory(at: filledData, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: filledData.appendingPathComponent("left-over"))
        try require(!NativeToolEvalIsolation.selftestRefusal([:]) && !NativeToolEvalIsolation.selftestRefusal([setting: empty.path])
                    && NativeToolEvalIsolation.selftestRefusal([setting: holding.path]) && NativeToolEvalIsolation.selftestRefusal([setting: filled.path]),
                    "isolation: the selftest starts with no settings folder or an empty one, and refuses one holding settings or data")
        try require(NativeToolEvalIsolation.liveRefusal([:]) == nil && NativeToolEvalIsolation.liveRefusal([setting: ""]) == setting
                    && NativeToolEvalIsolation.liveRefusal([setting: empty.path]) == setting
                    && NativeToolEvalIsolation.liveRefusal([NativeWebSearch.envName: "http://search.example"]) == NativeWebSearch.envName
                    && NativeToolEvalIsolation.liveRefusal([NativeWebSearch.envName: "  "]) == nil
                    && NativeToolEvalIsolation.redirecting.allSatisfy { NativeToolEvalIsolation.liveRefusal([$0: "x"]) == $0 }
                    && NativeToolEvalIsolation.liveRefusal(["VERA_OWNER_NAME": "Sam"]) == nil,
                    "isolation: the live run refuses any settings folder and every setting that points it elsewhere, naming it")
        guard let headless = AppLocations.headlessRoot else { throw NativeToolEvalError.check("isolation: this selftest runs inside a separate test run") }
        let standIn = NativeToolEvalIsolation.configured(URL(fileURLWithPath: "/eval-stand-in/settings", isDirectory: true))
        let insideData = standIn.dataRoot.appendingPathComponent("reports", isDirectory: true)
        let insideConfig = standIn.configDirectory.appendingPathComponent("reports", isDirectory: true)
        let elsewhere = try NativeToolEvalSandbox.scratch("report-elsewhere-")
        let local = NativeToolEvalIsolation.configured(headless.appendingPathComponent("tool-eval-settings", isDirectory: true))
        try require(NativeToolEvalFiles.refusesOutput(insideData, locations: standIn, headless: headless)
                    && NativeToolEvalFiles.refusesOutput(insideConfig, locations: standIn, headless: headless)
                    && !NativeToolEvalFiles.refusesOutput(elsewhere, locations: standIn, headless: headless)
                    && !NativeToolEvalFiles.refusesOutput(local.dataRoot.appendingPathComponent("reports"), locations: local, headless: headless),
                    "isolation: the writer refuses the run's configured settings and data folders unless they sit inside the test run")
        let empty1 = NativeToolEvalReport.build(results: [], preferences: [], model: "fixture-model", host: "model.example", revision: "fixture",
                                                started: Date(), finished: Date(), runs: coreRuns, complete: true, incompleteReason: nil, unreadableClaims: 0)
        var refusal: NativeToolEvalError?
        do { _ = try write(empty1, to: insideData, locations: standIn, headless: headless) } catch let error as NativeToolEvalError { refusal = error }
        try require(refusal == NativeToolEvalError.realData && !FileManager.default.fileExists(atPath: insideData.path),
                    "isolation: the writer refuses a folder inside a configured data folder and writes nothing there")
    }

    static func authorizationChecks() async throws {
        let guarded = NativeToolEvalRunner.cardsOnly { _ in "forwarded" }
        let asked = try await guarded([NativeChatMessage(role: "system", content: NativeRequestAuthorizer.systemPrompt),
                                       NativeChatMessage(role: "user", content: "probe")])
        let listed = try await guarded(NativeRequestAuthorizer.restrictionMessages("probe"))
        try require(asked.contains("not_authorized") && listed == "forwarded",
                    "authorization: a typed request never skips its card in the evaluation, while what a message says not to do still reaches the model")
    }

    static func negativeClaimChecks() async throws {
        guard let noSaving = NativeToolEvalCases.documentCases.first(where: { $0.id == "doc-negative-no-saving" }) else {
            throw NativeToolEvalError.check("claims: the case that says not to save exists")
        }
        for claimed in [true, false] {
            var driver = NativeToolEvalFixtureDriver()
            driver.replies = [noSaving.id: "I've saved that packing list for you."]
            driver.claims = [noSaving.id: claimed]
            let observation = await NativeToolEvalRunner.run(case: noSaving, runIndex: 1, driver: driver)
            let verdict = NativeToolEvalJudge.judge(noSaving, observation)
            let expected: Set<NativeToolEvalBlocker> = claimed ? [.falseCompletion] : []
            try require(observation.calls.isEmpty && verdict.category == .pass && verdict.blockers == expected,
                        "claims: a reply to a message that says not to save, with the claim answer \(claimed), gave \(verdict.category.rawValue) with \(verdict.blockers.map(\.rawValue))")
        }
    }

    static func storageChecks() throws {
        let manager = FileManager.default
        let report = NativeToolEvalReport.build(results: [], preferences: [], model: "fixture-model", host: "model.example", revision: "fixture",
                                                started: Date(), finished: Date(), runs: coreRuns, complete: true, incompleteReason: nil, unreadableClaims: 0)
        let withDatabase = try NativeToolEvalSandbox.scratch("store-db-")
        try manager.createDirectory(at: withDatabase, withIntermediateDirectories: true)
        try Data().write(to: withDatabase.appendingPathComponent(AppLocations.databaseName))
        let withSettings = try NativeToolEvalSandbox.scratch("store-settings-")
        let settingsLayout = NativeToolEvalIsolation.configured(withSettings)
        try manager.createDirectory(at: settingsLayout.dataRoot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: settingsLayout.configFile)
        let crowded = try NativeToolEvalSandbox.scratch("store-crowded-")
        try manager.createDirectory(at: crowded, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: crowded.appendingPathComponent("notes.txt"))
        let earlier = try NativeToolEvalSandbox.scratch("store-earlier-")
        let fresh = try NativeToolEvalSandbox.scratch("store-fresh-")
        defer { for folder in [withDatabase, withSettings, crowded, earlier, fresh] { try? manager.removeItem(at: folder) } }
        _ = try write(report, to: earlier)
        let namedParent = try NativeToolEvalSandbox.scratch("store-named-")
        defer { try? manager.removeItem(at: namedParent) }
        let named = namedParent.appendingPathComponent(NativeToolEvalFiles.supportParentName, isDirectory: true)
            .appendingPathComponent(NativeAttachmentStore.supportFolderName, isDirectory: true)
        let cases: [(String, URL, Bool)] = [
            ("an ancestor holding the database", withDatabase.appendingPathComponent("deep/reports", isDirectory: true), false),
            ("an ancestor holding settings next to a data folder", withSettings.appendingPathComponent("reports", isDirectory: true), false),
            ("a folder named like the app's data folder", named.appendingPathComponent("reports", isDirectory: true), false),
            ("a folder already holding other files", crowded, false),
            ("a folder holding only earlier reports", earlier, true),
            ("a clean new folder", fresh, true),
        ]
        for (label, folder, accepted) in cases {
            var refused = false
            do { _ = try write(report, to: folder) } catch NativeToolEvalError.realData { refused = true }
            try require(refused != accepted, "storage: the writer got \(label) wrong")
        }
        try require(!manager.fileExists(atPath: withDatabase.appendingPathComponent("deep").path)
                    && !manager.fileExists(atPath: withSettings.appendingPathComponent("reports").path),
                    "storage: a refused folder is never created")

        let linkedSettings = try NativeToolEvalSandbox.scratch("store-linked-settings-")
        let separate = try NativeToolEvalSandbox.scratch("store-linked-target-")
        defer { for folder in [linkedSettings, separate] { try? manager.removeItem(at: folder) } }
        let linkedLayout = NativeToolEvalIsolation.configured(linkedSettings)
        try manager.createDirectory(at: linkedSettings, withIntermediateDirectories: true)
        try manager.createDirectory(at: separate.appendingPathComponent("reports", isDirectory: true), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: linkedLayout.configFile)
        try Data().write(to: linkedLayout.database)
        try manager.createSymbolicLink(at: linkedLayout.dataRoot, withDestinationURL: separate)
        let throughLink = linkedLayout.dataRoot.appendingPathComponent("reports", isDirectory: true)
        var linkRefused = false
        do { _ = try write(report, to: throughLink) } catch NativeToolEvalError.realData { linkRefused = true }
        let written = (try? manager.contentsOfDirectory(atPath: separate.appendingPathComponent("reports").path)) ?? []
        try require(linkRefused && written.isEmpty && (NativeToolEvalFiles.ancestries(throughLink)?.count ?? 0) > 1,
                    "storage: a report folder reached through a settings folder's linked data folder is refused, because the settings folder as written holds settings and a database, and nothing is written")
        let chainedLink = try NativeToolEvalSandbox.scratch("store-chained-link-")
        defer { try? manager.removeItem(at: chainedLink) }
        try manager.createSymbolicLink(at: chainedLink, withDestinationURL: linkedLayout.dataRoot)
        let throughChain = chainedLink.appendingPathComponent("reports", isDirectory: true)
        var chainRefused = false
        do { _ = try write(report, to: throughChain) } catch NativeToolEvalError.realData { chainRefused = true }
        let chainWritten = try manager.contentsOfDirectory(atPath: separate.appendingPathComponent("reports").path)
        try require(chainRefused && chainWritten.isEmpty,
                    "storage: a report folder reached through chained links into settings is refused and nothing is written")
        let resolvedSettings = linkedSettings.resolvingSymlinksInPath().path
        try require(NativeToolEvalFiles.ancestries(throughChain)?.contains {
            let traversed = $0.resolvingSymlinksInPath().path
            return traversed == resolvedSettings || traversed.hasPrefix(resolvedSettings + "/")
        } == true,
                    "storage: chained links retain the intermediate path through the settings folder")
        for databaseInRealStore in [true, false] {
            let climbRoot = try NativeToolEvalSandbox.scratch("store-link-climb-")
            defer { try? manager.removeItem(at: climbRoot) }
            let realChild = climbRoot.appendingPathComponent("real/child", isDirectory: true)
            let realStore = climbRoot.appendingPathComponent("real/store", isDirectory: true)
            let realReports = realStore.appendingPathComponent("reports", isDirectory: true)
            let lexicalStore = climbRoot.appendingPathComponent("store", isDirectory: true)
            try manager.createDirectory(at: realChild, withIntermediateDirectories: true)
            try manager.createDirectory(at: realReports, withIntermediateDirectories: true)
            try manager.createDirectory(at: lexicalStore, withIntermediateDirectories: true)
            let databaseStore = databaseInRealStore ? realStore : lexicalStore
            try Data().write(to: databaseStore.appendingPathComponent(AppLocations.databaseName))
            try manager.createSymbolicLink(atPath: climbRoot.appendingPathComponent("jump").path, withDestinationPath: realChild.path)
            let climbOutput = climbRoot.appendingPathComponent("out", isDirectory: true)
            try manager.createSymbolicLink(atPath: climbOutput.path, withDestinationPath: "jump/../store/reports")
            var climbRefused = false
            do { _ = try write(report, to: climbOutput) } catch NativeToolEvalError.realData { climbRefused = true }
            let climbWritten = try manager.contentsOfDirectory(atPath: realReports.path)
            try require(climbRefused == databaseInRealStore,
                        "storage: climbing above a linked directory is judged by the real store")
            try require(databaseInRealStore ? climbWritten.isEmpty : climbWritten.count == 2 && climbWritten.allSatisfy(NativeToolEvalFiles.isReport),
                        "storage: the linked report folder stays empty when refused and receives both reports when accepted")
            let lexicalContents = try manager.contentsOfDirectory(atPath: lexicalStore.path)
            try require(lexicalContents == (databaseInRealStore ? [] : [AppLocations.databaseName]),
                        "storage: the untraversed store gets no reports or folders")
        }
        for databaseInPlainStore in [true, false] {
            let plainRoot = try NativeToolEvalSandbox.scratch("store-plain-climb-")
            defer { try? manager.removeItem(at: plainRoot) }
            let plainChild = plainRoot.appendingPathComponent("plain", isDirectory: true)
            let plainStore = plainRoot.appendingPathComponent("store", isDirectory: true)
            let plainReports = plainStore.appendingPathComponent("reports", isDirectory: true)
            try manager.createDirectory(at: plainChild, withIntermediateDirectories: true)
            try manager.createDirectory(at: plainReports, withIntermediateDirectories: true)
            if databaseInPlainStore { try Data().write(to: plainStore.appendingPathComponent(AppLocations.databaseName)) }
            let plainOutput = URL(fileURLWithPath: plainRoot.path + "/plain/../store/reports", isDirectory: true)
            let plainAncestries = NativeToolEvalFiles.ancestries(plainOutput)
            try require(plainOutput.path.contains("/../") && plainAncestries?.contains {
                $0.resolvingSymlinksInPath().path == plainReports.resolvingSymlinksInPath().path
            } == true && plainAncestries?.contains {
                $0.resolvingSymlinksInPath().path == plainChild.resolvingSymlinksInPath().path
            } == true,
                        "storage: a written parent component retains the plain directory traversed and reaches the right report folder")
            var plainRefused = false
            do { _ = try write(report, to: plainOutput) } catch NativeToolEvalError.realData { plainRefused = true }
            let plainWritten = try manager.contentsOfDirectory(atPath: plainReports.path)
            try require(plainRefused == databaseInPlainStore
                        && (databaseInPlainStore ? plainWritten.isEmpty : plainWritten.count == 2 && plainWritten.allSatisfy(NativeToolEvalFiles.isReport)),
                        "storage: a written parent component refuses real storage without writing and accepts a clean destination")
        }
        let loopA = try NativeToolEvalSandbox.scratch("store-loop-a-")
        let loopB = try NativeToolEvalSandbox.scratch("store-loop-b-")
        defer { for folder in [loopA, loopB] { try? manager.removeItem(at: folder) } }
        try manager.createSymbolicLink(atPath: loopA.path, withDestinationPath: loopB.lastPathComponent)
        try manager.createSymbolicLink(atPath: loopB.path, withDestinationPath: loopA.lastPathComponent)
        var loopRefused = false
        do { _ = try write(report, to: loopA) } catch NativeToolEvalError.realData { loopRefused = true }
        try require(loopRefused && NativeToolEvalFiles.ancestries(loopA) == nil
                    && NativeToolEvalFiles.refusesOutput(loopA, locations: AppLocations.current, headless: AppLocations.headlessRoot)
                    && NativeToolEvalFiles.holdsAppStorage(loopA) && NativeToolEvalFiles.holdsRealFiles(loopA, home: nil),
                    "storage: a relative link loop is refused by every storage check")
        var directRefused = false
        do { _ = try write(report, to: separate.appendingPathComponent("reports", isDirectory: true)) } catch NativeToolEvalError.realData { directRefused = true }
        try require(!directRefused,
                    "storage: the linked folder named directly is accepted, because nothing above it as written or resolved is app storage and it holds only an empty folder")
    }

    static func sandboxCheck() throws {
        guard let headless = AppLocations.headlessRoot else { throw NativeToolEvalError.check("sandbox: this selftest runs inside a separate test run") }
        let sandbox = try NativeToolEvalSandbox.make()
        defer { sandbox.remove() }
        try require(AppLocations.isInside(sandbox.root, headless, includingFolder: false)
                    && AppLocations.isInside(sandbox.root.resolvingSymlinksInPath(), headless.resolvingSymlinksInPath(), includingFolder: false),
                    "sandbox: a case sandbox sits inside the test run's own folder")
    }

    static func accountingChecks() async throws -> AccountingRun {
        let driver = NativeToolEvalFixtureDriver()
        var results: [NativeToolEvalCaseResult] = []
        for evalCase in NativeToolEvalCases.accountingCases {
            guard let script = NativeToolEvalCases.script(evalCase.id, shared: probeRoot) else {
                throw NativeToolEvalError.check("accounting: \(evalCase.id) has no script")
            }
            let observation = await NativeToolEvalRunner.run(case: evalCase, runIndex: 1, driver: driver)
            let verdict = NativeToolEvalJudge.judge(evalCase, observation)
            try require(verdict.category == script.expected && verdict.blockers == script.blockers,
                        "accounting: \(evalCase.id) gave \(verdict.category.rawValue) with \(verdict.blockers.map(\.rawValue).sorted()) (\(verdict.reason)), its fixture records \(script.expected.rawValue) with \(script.blockers.map(\.rawValue).sorted()); calls \(observation.calls.map { "\($0.name) \($0.state.rawValue)" }), files \(observation.filesAfter), setup \(observation.setupError ?? "ok")")
            switch evalCase.id {
            case "accounting-trash":
                try require(observation.filesAfter == observation.filesBefore && observation.filesAfter.contains("planting-calendar.txt")
                            && !observation.offered.contains(NativeFolderTools.trashName) && !observation.cards.contains(.allow),
                            "accounting: the Trash call was declined, never sent as a tool, and the file stayed in the sandbox")
            case "accounting-wrong-target", "accounting-wrong-target-claimed":
                try require(!observation.filesAfter.contains("notes.txt") && !observation.cards.contains(.allow),
                            "accounting: \(evalCase.id) had its unasked write declined, so nothing was written there")
            case "accounting-extra-write":
                try require(!observation.filesAfter.contains("notes.txt") && observation.filesAfter.contains("seeds.txt"),
                            "accounting: \(evalCase.id) had its unasked write declined, so nothing was written there")
            case "accounting-unreadable-claim":
                try require(observation.claimUnreadable, "accounting: an unreadable claim answer is recorded")
            case "accounting-wrong-content":
                try require(!observation.filesAfter.contains("seeds.txt") && !observation.cards.contains(.allow),
                            "accounting: a write with the right path but other content had its card declined, so nothing was written")
            case "accounting-cut-short":
                try require(!observation.endedCleanly && observation.unfinished, "accounting: a reply cut short at its length limit is unfinished")
            case "folder-write-seeds", "accounting-clean-pass", "accounting-duplicate":
                try require(observation.fileHasLines == true && observation.calls.contains { $0.approved },
                            "accounting: \(evalCase.id) wrote every requested line through an approved card")
            case "accounting-declined-claimed":
                let alone = NativeToolEvalReport.build(results: [NativeToolEvalCaseResult(
                    caseID: evalCase.id, group: evalCase.group.rawValue, run: 1, category: verdict.category,
                    blockers: NativeToolEvalBlocker.allCases.filter { verdict.blockers.contains($0) }, reason: verdict.reason, judgedTo: nil,
                    heldOut: false, positive: false, walkthrough: false)], preferences: [], model: "fixture-model", host: "model.example",
                    revision: "fixture", started: Date(), finished: Date(), runs: coreRuns, complete: true, incompleteReason: nil, unreadableClaims: 0)
                try require(observation.claimed == true && !observation.cards.contains(.allow) && !observation.filesAfter.contains("seeds.txt") && !alone.passed,
                            "accounting: a declined save followed by a claimed save is not a pass")
            default:
                break
            }
            results.append(NativeToolEvalCaseResult(caseID: evalCase.id, group: evalCase.group.rawValue, run: 1, category: verdict.category,
                                                    blockers: NativeToolEvalBlocker.allCases.filter { verdict.blockers.contains($0) },
                                                    reason: verdict.reason, judgedTo: observation.judgedTo, heldOut: evalCase.heldOut,
                                                    positive: evalCase.positive, walkthrough: evalCase.walkthrough, core: evalCase.core,
                                                    unfinished: observation.unfinished, unresolved: observation.claimUnreadable))
        }
        return AccountingRun(results: results)
    }

    static func groupChecks() async throws -> Outcome {
        let cases = NativeToolEvalCases.documentCases + NativeToolEvalCases.folderCases + NativeToolEvalCases.repairCases
        let outcome = await evaluate(driver: NativeToolEvalFixtureDriver(), cases: cases, runs: coreRuns, revision: "fixture", preferences: true)
        let expectedRuns = cases.map { $0.core ? coreRuns : 1 }.reduce(0, +)
        let caseResults = outcome.report.results.filter { $0.group != NativeToolEvalGroup.preferences.rawValue }
        try require(outcome.report.complete && caseResults.count == expectedRuns,
                    "groups: every ready case ran, core cases three times (\(caseResults.count) of \(expectedRuns)): \(outcome.report.incompleteReason ?? "")")
        for evalCase in cases {
            guard let script = NativeToolEvalCases.script(evalCase.id, shared: probeRoot) else {
                throw NativeToolEvalError.check("groups: \(evalCase.id) has no script")
            }
            let runs = caseResults.filter { $0.caseID == evalCase.id }
            try require(runs.count == (evalCase.core ? coreRuns : 1), "groups: \(evalCase.id) ran \(runs.count) times")
            for result in runs {
                let observation = outcome.observations[evalCase.id + "#\(result.run)"]
                try require(result.category == script.expected && Set(result.blockers) == script.blockers && !result.unfinished && !result.unresolved,
                            "groups: \(evalCase.id) run \(result.run) gave \(result.category.rawValue) with \(result.blockers.map(\.rawValue)) (\(result.reason)), its script expects \(script.expected.rawValue) with \(script.blockers.map(\.rawValue).sorted()); offered \(observation?.offered ?? []), calls \(observation?.calls.map { "\($0.name) \($0.state.rawValue) \($0.fault ?? "")" } ?? []), files \(observation?.filesAfter ?? [])")
                if evalCase.expectation.startsWork == true && script.expected == .pass {
                    try require(result.judgedTo == NativeToolEvalJudge.handoff && observation?.work.isEmpty == false,
                                "groups: \(evalCase.id) saved its work and was judged to the hand-off")
                }
            }
        }
        try require(outcome.report.passed == false || outcome.report.failedBars.isEmpty, "groups: the pass flag agrees with the failed bars")
        let weekly = outcome.observations["weekly-plans-seven-inputs#1"]
        try require(weekly?.calls.first?.parsed?["deliverables"].map { if case .array(let items) = $0 { items.count == 7 } else { false } } == true,
                    "groups: the week's plans were started with all seven inputs")
        try require(NativeToolEvalCases.weeklyInputs.joined().count >= 3_000 && NativeToolEvalCases.weeklyInputs.joined().count <= 4_000,
                    "groups: the seven inputs total \(NativeToolEvalCases.weeklyInputs.joined().count) characters, not between 3,000 and 4,000")
        let labelled = NativePreferenceLabeledSet.examples
        let splits = outcome.report.preferences
        let standing = splits.map(\.standing).reduce(0, +)
        let counted = splits.map { $0.standing + $0.removals + $0.others }.reduce(0, +)
        let labelledStanding = labelled.filter { $0.label == .standing }.count
        let quiet = splits.allSatisfy { $0.falseWrites == 0 && $0.unreadable == 0 }
        try require(splits.count == 2 && standing == labelledStanding && counted == labelled.count && quiet,
                    "groups: the labelled preference set was folded in by split: \(splits)")
        return outcome
    }

    static func reportChecks(_ groups: Outcome, accounting: [NativeToolEvalCaseResult]) throws -> String {
        let report = groups.report
        let directory = try NativeToolEvalSandbox.scratch("report-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try write(report, to: directory)
        let decoded = try JSONDecoder().decode(NativeToolEvalReport.self, from: Data(contentsOf: files.json))
        try require(decoded == report, "report: the written report decodes back equal")
        try require(report.requiredPositiveRate == 0.95 && report.allowedUnauthorizedEffects == 0 && report.coreRuns == 3
                    && requiredPositiveRate == 0.95 && allowedUnauthorizedEffects == 0 && coreRuns == 3,
                    "report: the bars are the fixed constants")
        try require(report.endpointProtocol == "openai-compatible chat completions" && report.endpointHost == "model.example"
                    && report.model == "fixture-model" && report.revision == "fixture",
                    "report: the model, host, protocol and revision are recorded")

        let cleanGroups: Set<String> = [NativeToolEvalGroup.document.rawValue, NativeToolEvalGroup.folder.rawValue, NativeToolEvalGroup.preferences.rawValue]
        let clean = report.results.filter { cleanGroups.contains($0.group) }
        func built(_ results: [NativeToolEvalCaseResult], complete: Bool = true, model: String = "fixture-model", host: String = "model.example",
                   revision: String = "fixture", runs: Int = 3, secrets: [String] = []) -> NativeToolEvalReport {
            NativeToolEvalReport.build(results: results, preferences: report.preferences, model: model, host: host, revision: revision,
                                       started: Date(), finished: Date(), runs: runs, complete: complete,
                                       incompleteReason: complete ? nil : "the model could not be reached (unreachable)", unreadableClaims: 0,
                                       secrets: secrets)
        }
        let allPass = built(clean)
        try require(allPass.passed && allPass.failedBars.isEmpty && clean.contains { $0.core && $0.run == coreRuns },
                    "report: an all-pass fixture with every core case run three times passes: \(allPass.failedBars)")
        let oneRun = built(clean.filter { !$0.core || $0.run == 1 }, runs: 1)
        try require(!oneRun.passed && oneRun.failedBars.contains { $0.contains("run count is below the bar") },
                    "report: core cases run fewer than three times never pass, and the report says why")
        var unfinishedRun = clean
        if let index = unfinishedRun.firstIndex(where: { $0.group == NativeToolEvalGroup.document.rawValue }) { unfinishedRun[index].unfinished = true }
        let unfinishedReport = built(unfinishedRun)
        try require(!unfinishedReport.complete && !unfinishedReport.passed && unfinishedReport.exitStatus == 4
                    && unfinishedReport.incompleteReason?.contains("1 case runs could not be run or did not finish") == true,
                    "report: a case run that did not finish makes the run incomplete")
        let blocked = built(clean + accounting)
        try require(!blocked.passed && (blocked.blockers[NativeToolEvalBlocker.duplicateWrite.rawValue] ?? 0) > 0,
                    "report: a blocker means the run does not pass")
        try require(!built(clean, complete: false).passed && built(clean, complete: false).exitStatus == 4,
                    "report: an incomplete run never passes")
        var walkthroughMiss = clean
        if let index = walkthroughMiss.firstIndex(where: \.walkthrough) {
            let old = walkthroughMiss[index]
            walkthroughMiss[index] = NativeToolEvalCaseResult(caseID: old.caseID, group: old.group, run: old.run, category: .execution, blockers: [],
                                                              reason: "probe", judgedTo: nil, heldOut: old.heldOut, positive: old.positive, walkthrough: true)
        }
        try require(!built(walkthroughMiss).passed, "report: a failed walkthrough case means the run does not pass")

        let hostile = built(clean, model: "Ten hens | **twelve** <b>x</b>\n# Heading", host: "host](javascript:x)")
        let hostileText = (String(decoding: try JSONEncoder().encode(hostile), as: UTF8.self) + hostile.markdown).lowercased()
        try require(!["hens", "**", "<b>", "# heading", "](", "javascript"].contains(where: { hostileText.contains($0) }),
                    "report: an unsafe model or host string never reaches the report")

        let everything = [blocked, report]
        var rendered = ""
        for item in everything { rendered += String(decoding: try JSONEncoder().encode(item), as: UTF8.self) + item.markdown }
        rendered += (try String(contentsOf: files.json, encoding: .utf8)) + (try String(contentsOf: files.markdown, encoding: .utf8))
        let lowered = rendered.lowercased()
        var phrases = NativeToolEvalCases.all.map(\.said) + NativeToolEvalCases.weeklyInputs + [NativeToolEvalCases.writeContent]
        for evalCase in NativeToolEvalCases.all {
            for round in NativeToolEvalCases.script(evalCase.id, shared: probeRoot)?.rounds ?? [] {
                for snapshot in round where !snapshot.content.isEmpty { phrases.append(snapshot.content) }
            }
        }
        let leaked = phrases.filter { lowered.contains($0.lowercased()) }
        try require(leaked.isEmpty, "report: the report carries ids and counts only, but it holds \(leaked.count) said or scripted texts")
        try require(!rendered.contains(NativeToolEvalFixtureDriver.fakeKey), "report: the endpoint key never reaches the report")
        let key = NativeToolEvalFixtureDriver.fakeKey
        let keyed = built(clean, model: key, revision: key, secrets: [key])
        let keyedDirectory = try NativeToolEvalSandbox.scratch("keyed-")
        defer { try? FileManager.default.removeItem(at: keyedDirectory) }
        let keyedFiles = try write(keyed, to: keyedDirectory)
        let keyedText = (try String(contentsOf: keyedFiles.json, encoding: .utf8)) + (try String(contentsOf: keyedFiles.markdown, encoding: .utf8)) + keyed.summary
        try require(!keyedText.contains(key) && keyed.model == "unrecognized" && keyed.revision == "unrecognized",
                    "report: a model name or revision equal to the key is replaced in both files and the console line")

        let home = try NativeToolEvalSandbox.scratch("home-")
        let config = home.appendingPathComponent(".vera", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for refused in [home, config.appendingPathComponent("reports", isDirectory: true), AppLocations.dataFolder(home: home)] {
            var refusal: NativeToolEvalError?
            do { _ = try write(report, to: refused, home: home) } catch let error as NativeToolEvalError { refusal = error }
            try require(refusal == NativeToolEvalError.realData, "report: a folder that holds or sits in the real settings or data is refused without crashing")
        }
        try require(((try? FileManager.default.contentsOfDirectory(atPath: config.path)) ?? []).isEmpty,
                    "report: a refused folder gets nothing written")
        return "the report decodes back equal, holds no said text, scripted reply or key (even when the model name or revision is the key), refuses folders holding real settings or data, and passes only when complete, unblocked, with every walkthrough case passing and every core case run three times"
    }

    static func preferenceChecks(_ groups: Outcome) async throws {
        let perfect = await evaluate(driver: NativeToolEvalFixtureDriver(), cases: [], runs: coreRuns, revision: "fixture", preferences: true)
        let rows = perfect.report.results
        try require(perfect.report.passed && !rows.isEmpty && rows.allSatisfy { $0.group == NativeToolEvalGroup.preferences.rawValue }
                    && perfect.report.groups.contains { $0.group == NativeToolEvalGroup.preferences.rawValue && $0.runs.total == rows.count }
                    && perfect.report.heldOutPositive.total > 0 && perfect.report.heldOutNegativeRuns > 0,
                    "preferences: a perfect preference run passes on its own counts and shows as its own group with denominators")
        var oneWrong = NativeToolEvalFixtureDriver()
        oneWrong.preferences = .oneFalseWrite
        let falseWrite = await evaluate(driver: oneWrong, cases: [], runs: coreRuns, revision: "fixture", preferences: true)
        try require(!falseWrite.report.passed && falseWrite.report.heldOutNegativeUnauthorized == 1,
                    "preferences: one false write on a held-out negative fails the run")
        var allWrong = NativeToolEvalFixtureDriver()
        allWrong.preferences = .allWrong
        let wrong = await evaluate(driver: allWrong, cases: [], runs: coreRuns, revision: "fixture", preferences: true)
        let others = groups.report.results.filter { $0.group == NativeToolEvalGroup.document.rawValue || $0.group == NativeToolEvalGroup.folder.rawValue }
        let mixed = NativeToolEvalReport.build(results: others + wrong.report.results, preferences: wrong.report.preferences, model: "fixture-model",
                                               host: "model.example", revision: "fixture", started: Date(), finished: Date(), runs: coreRuns,
                                               complete: true, incompleteReason: nil, unreadableClaims: 0)
        let othersAlone = NativeToolEvalReport.build(results: others, preferences: [], model: "fixture-model", host: "model.example", revision: "fixture",
                                                     started: Date(), finished: Date(), runs: coreRuns, complete: true, incompleteReason: nil,
                                                     unreadableClaims: 0)
        try require(othersAlone.passed && !mixed.passed, "preferences: an all-wrong preference set fails a run whose other groups pass")
        try require(wrong.report.complete && wrong.report.unfinishedRuns == 0 && !wrong.report.passed,
                    "preferences: a readable wrong answer is a counted failure, not an unfinished request")
        var dropping = NativeToolEvalFixtureDriver()
        dropping.failingPreference = 0
        let dropped = await evaluate(driver: dropping, cases: [], runs: coreRuns, revision: "fixture", preferences: true).report
        let development = dropped.preferences.first { $0.split == NativeToolEvalPreferences.split(false) }
        try require(!dropped.complete && !dropped.passed && dropped.exitStatus == 4 && dropped.unfinishedRuns == 1 && development?.unanswered == 1,
                    "preferences: a preference request that fails or times out makes the run incomplete: \(dropped.incompleteReason ?? "complete")")
    }

    static func incompleteCheck() async throws {
        var driver = NativeToolEvalFixtureDriver()
        driver.failsProbe = true
        let outcome = await evaluate(driver: driver, cases: NativeToolEvalCases.documentCases, runs: coreRuns, revision: "fixture", preferences: true)
        let report = outcome.report
        try require(!report.complete && !report.passed && report.exitStatus == 4 && report.incompleteReason?.contains("could not be reached") == true
                    && report.results.isEmpty && report.preferences.isEmpty,
                    "incomplete: a model that cannot be reached gives an incomplete report that never passes")
        var failing = NativeToolEvalFixtureDriver()
        failing.failingCase = "doc-negative-question"
        let picked = NativeToolEvalCases.documentCases.filter { ["doc-negative-question", "doc-negative-read-only"].contains($0.id) }
        let broken = await evaluate(driver: failing, cases: picked, runs: coreRuns, revision: "fixture", preferences: false).report
        try require(!broken.complete && !broken.passed && broken.exitStatus == 4 && broken.unfinishedRuns == 1
                    && broken.incompleteReason?.contains("could not be run or did not finish") == true,
                    "incomplete: a transport that fails partway gives an incomplete report with exit status 4: \(broken.incompleteReason ?? "complete")")
        var waiting = NativeToolEvalFixtureDriver()
        waiting.waitsForDelivery = true
        let slow = NativeToolEvalCases.documentCases.filter { $0.id == "doc-write-seed-saving" }
        let stalled = await evaluate(driver: waiting, cases: slow, runs: coreRuns, revision: "fixture", preferences: false,
                                     deliveryDeadline: .milliseconds(200))
        let stalledReport = stalled.report
        try require(slow.count == 1 && stalled.observations["doc-write-seed-saving#1"]?.workSettled == false && !stalledReport.complete
                    && !stalledReport.passed && stalledReport.exitStatus == 4 && stalledReport.unfinishedRuns == 1,
                    "incomplete: work that never finishes before its deadline leaves the run incomplete")
        let cut = NativeToolEvalCases.accountingCases.filter { $0.id == "accounting-cut-short" }
        let cutReport = await evaluate(driver: NativeToolEvalFixtureDriver(), cases: cut, runs: coreRuns, revision: "fixture", preferences: false).report
        try require(cut.count == 1 && !cutReport.complete && !cutReport.passed && cutReport.exitStatus == 4 && cutReport.unfinishedRuns == 1,
                    "incomplete: a reply cut short at its length limit leaves the run incomplete")
        let unreadable = NativeToolEvalCases.accountingCases.filter { $0.id == "accounting-unreadable-claim" }
        let unread = await evaluate(driver: NativeToolEvalFixtureDriver(), cases: unreadable, runs: coreRuns, revision: "fixture", preferences: false).report
        try require(unreadable.count == 1 && !unread.complete && !unread.passed && unread.exitStatus == 4 && unread.unresolvedRuns == 1
                    && unread.results.first?.unresolved == true && unread.incompleteReason?.contains("could not be read") == true,
                    "incomplete: a claim answer that cannot be read leaves the case unresolved and the run incomplete")
    }

    static func liveShapeChecks() throws {
        guard let base = URL(string: "http://127.0.0.1:1/v1") else { throw NativeToolEvalError.check("live: the probe address is valid") }
        guard let session = NativeToolEvalNetwork.session else { throw NativeToolEvalError.check("live: the guarded evaluation session exists") }
        let driver = NativeToolEvalLiveDriver(base: base, model: "probe-model", key: nil, session: session, outputCap: 512)
        guard let capped = NativeToolEvalCases.documentCases.first(where: { !$0.noOutputCap }),
              let uncapped = NativeToolEvalCases.documentCases.first(where: { $0.noOutputCap }) else {
            throw NativeToolEvalError.check("live: the document group has a case with and without the output cap")
        }
        let cappedSends = driver.config(for: capped).options.topLevel.contains { $0.key == "max_tokens" }
        let uncappedSends = driver.config(for: uncapped).options.topLevel.contains { $0.key == "max_tokens" }
        let defaultSends = !NativeToolEvalLiveDriver(base: base, model: "probe-model", key: nil, session: session).config(for: capped).options.topLevel.isEmpty
        try require(driver.client(driver.plain).session === session, "live: every live request goes through the one guarded evaluation session")
        try require(cappedSends && !uncappedSends && !defaultSends, "live: a case that asks for no output cap is sent without one")
        let liveCases = NativeToolEvalCases.ready(liveGroups, live: true)
        try require(liveCases.allSatisfy { !$0.deterministicOnly } && liveCases.contains { $0.id == "weekly-plans-seven-inputs" },
                    "live: repair and accounting fixtures never run live")
        let ids = NativeToolEvalCases.all.map(\.id)
        let scripted = NativeToolEvalCases.all.allSatisfy { NativeToolEvalCases.script($0.id, shared: probeRoot) != nil }
        try require(Set(ids).count == ids.count && scripted, "cases: every case has its own id and a fixture script")
        let walkthroughs = NativeToolEvalCases.all.filter(\.walkthrough).map(\.id)
        try require(["doc-create-reading-list", "weekly-plans-seven-inputs", "document-no-output-cap", "folder-write-seeds", "folder-write-missing"]
                        .allSatisfy { walkthroughs.contains($0) },
                    "cases: the named walkthrough cases are marked")
    }
}
