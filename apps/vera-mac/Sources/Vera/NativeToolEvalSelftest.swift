import Foundation

extension NativeToolEval {
    static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw NativeToolEvalError.check(message()) }
    }

    static func selftest() async -> Int32 {
        do {
            let judged = try judgeChecks()
            let accounting = try await accountingChecks()
            let groups = try await groupChecks()
            let reported = try reportChecks(groups, accounting: accounting.results)
            try await incompleteCheck()
            try liveShapeChecks()
            print("TOOL EVAL SELFTEST OK (\(judged) judge checks on hand-built observations; \(accounting.results.count) accounting fixtures through the real chat loop matched their recorded category and blockers; \(groups.report.totals.total) case runs across the document, folder and repair groups matched their scripts; \(reported); an unreachable model is reported as incomplete with exit status 4; the live request leaves out the output cap when a case asks for none)")
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
                          arguments: [String: NativeJSONValue]? = ["path": .string(probeRoot + "/seeds.txt"), "content": .string("Beans")],
                          fault: String? = nil, notRun: Bool = false, error: Bool = false, write: Bool = true,
                          declined: Bool = false) -> NativeToolEvalCall {
        var call = NativeToolEvalCall(id: id, name: name, rawArguments: arguments.map(NativeToolEvalCases.encoded) ?? "{not json",
                                      parsed: arguments, state: state)
        call.fault = fault
        call.notRun = notRun
        call.errorPresent = error
        call.write = write
        call.declined = declined
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
        observation.sharedRoots = [probeRoot]
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
                   probeObservation([probeCall(arguments: ["path": .string("/elsewhere/seeds.txt"), "content": .string("Beans")])], after: []), .arguments)
        try expect("a relative path that climbs out", write,
                   probeObservation([probeCall(arguments: ["path": .string("../seeds.txt"), "content": .string("Beans")])], after: []), .arguments)
        try expect("the wrong file name", write,
                   probeObservation([probeCall(arguments: ["path": .string(probeRoot + "/notes.txt"), "content": .string("Beans")])], after: ["notes.txt"]), .arguments)

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

        let answers: [(String, Bool?)] = [("Yes.", true), ("no", false), ("NO!", false), ("<think>hm</think>\nYES", true),
                                          ("maybe", nil), ("Yes, it was saved.", nil), ("", nil)]
        for (raw, expected) in answers {
            try require(NativeToolEvalClaimQuestion.read(raw) == expected, "judge: the claim answer \(raw) was read as \(String(describing: NativeToolEvalClaimQuestion.read(raw)))")
            checked += 1
        }
        try require(NativeToolEvalJudge.needsClaim(document, claiming) && !NativeToolEvalJudge.needsClaim(document, silent)
                    && !NativeToolEvalJudge.needsClaim(probeCase(positive: false, tool: nil, createsFile: nil), claiming),
                    "judge: the claim question is asked only when an action was expected, nothing succeeded and there is a reply")
        checked += 1
        return checked
    }

    struct AccountingRun {
        let results: [NativeToolEvalCaseResult]
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
            results.append(NativeToolEvalCaseResult(caseID: evalCase.id, group: evalCase.group.rawValue, run: 1, category: verdict.category,
                                                    blockers: NativeToolEvalBlocker.allCases.filter { verdict.blockers.contains($0) },
                                                    reason: verdict.reason, judgedTo: observation.judgedTo, heldOut: evalCase.heldOut,
                                                    positive: evalCase.positive, walkthrough: evalCase.walkthrough))
        }
        return AccountingRun(results: results)
    }

    static func groupChecks() async throws -> Outcome {
        let cases = NativeToolEvalCases.documentCases + NativeToolEvalCases.folderCases + NativeToolEvalCases.repairCases
        let outcome = await evaluate(driver: NativeToolEvalFixtureDriver(), cases: cases, runs: 1, revision: "fixture", preferences: true)
        try require(outcome.report.complete && outcome.report.results.count == cases.count,
                    "groups: every ready case ran once (\(outcome.report.results.count) of \(cases.count)): \(outcome.report.incompleteReason ?? "")")
        for evalCase in cases {
            guard let script = NativeToolEvalCases.script(evalCase.id, shared: probeRoot),
                  let result = outcome.report.results.first(where: { $0.caseID == evalCase.id }) else {
                throw NativeToolEvalError.check("groups: \(evalCase.id) has no script or no result")
            }
            let observation = outcome.observations[evalCase.id + "#1"]
            try require(result.category == script.expected && Set(result.blockers) == script.blockers,
                        "groups: \(evalCase.id) gave \(result.category.rawValue) with \(result.blockers.map(\.rawValue)) (\(result.reason)), its script expects \(script.expected.rawValue) with \(script.blockers.map(\.rawValue).sorted()); offered \(observation?.offered ?? []), calls \(observation?.calls.map { "\($0.name) \($0.state.rawValue) \($0.fault ?? "")" } ?? []), files \(observation?.filesAfter ?? [])")
            if evalCase.expectation.startsWork == true && script.expected == .pass {
                try require(result.judgedTo == NativeToolEvalJudge.handoff && observation?.work.isEmpty == false,
                            "groups: \(evalCase.id) saved its work and was judged to the hand-off")
            }
        }
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tool-eval-report-" + UUID().uuidString.lowercased(), isDirectory: true)
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

        let clean = report.results.filter { $0.group == NativeToolEvalGroup.document.rawValue || $0.group == NativeToolEvalGroup.folder.rawValue }
        func built(_ results: [NativeToolEvalCaseResult], complete: Bool = true, model: String = "fixture-model", host: String = "model.example") -> NativeToolEvalReport {
            NativeToolEvalReport.build(results: results, preferences: report.preferences, model: model, host: host, revision: "fixture",
                                       started: Date(), finished: Date(), runs: 1, complete: complete,
                                       incompleteReason: complete ? nil : "the model could not be reached (unreachable)", unreadableClaims: 0)
        }
        try require(built(clean).passed, "report: an all-pass fixture passes")
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

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tool-eval-home-" + UUID().uuidString.lowercased(), isDirectory: true)
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
        return "the report decodes back equal, holds no said text, scripted reply or key, refuses folders holding real settings or data, and passes only when complete, unblocked and with every walkthrough case passing"
    }

    static func incompleteCheck() async throws {
        var driver = NativeToolEvalFixtureDriver()
        driver.failsProbe = true
        let outcome = await evaluate(driver: driver, cases: NativeToolEvalCases.documentCases, runs: coreRuns, revision: "fixture", preferences: true)
        let report = outcome.report
        try require(!report.complete && !report.passed && report.exitStatus == 4 && report.incompleteReason?.contains("could not be reached") == true
                    && report.results.isEmpty && report.preferences.isEmpty,
                    "incomplete: a model that cannot be reached gives an incomplete report that never passes")
    }

    static func liveShapeChecks() throws {
        guard let base = URL(string: "http://127.0.0.1:1/v1") else { throw NativeToolEvalError.check("live: the probe address is valid") }
        let driver = NativeToolEvalLiveDriver(base: base, model: "probe-model", key: nil, outputCap: 512)
        guard let capped = NativeToolEvalCases.documentCases.first(where: { !$0.noOutputCap }),
              let uncapped = NativeToolEvalCases.documentCases.first(where: { $0.noOutputCap }) else {
            throw NativeToolEvalError.check("live: the document group has a case with and without the output cap")
        }
        let cappedSends = driver.config(for: capped).options.topLevel.contains { $0.key == "max_tokens" }
        let uncappedSends = driver.config(for: uncapped).options.topLevel.contains { $0.key == "max_tokens" }
        let defaultSends = !NativeToolEvalLiveDriver(base: base, model: "probe-model", key: nil).config(for: capped).options.topLevel.isEmpty
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
