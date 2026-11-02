import Foundation

struct NativeMemoryGateFact: Sendable {
    let id: String
    let title: String
    let details: [String]
    var category: NativeMemoryCategory = .other
}

struct NativeMemoryGateQualifiedFact: Sendable {
    let subject: String
    let qualifier: String
    let subjects: [String]
    let claims: [String]
}

enum NativeMemoryGateAbsence: String, Codable, Sendable {
    case tombstoned
    case superseded
    case unsupported

    var resurrects: Bool { self != .unsupported }
}

enum NativeMemoryGateStep: Sendable {
    case say(chat: String, label: String, text: String, remember: NativeMemoryGateFact?)
    case correct(target: String, chat: String, label: String, text: String, replacement: NativeMemoryGateFact)
    case recordLoss(chat: String, label: String, text: String, fact: NativeMemoryGateFact)
    case planCare(chat: String, label: String, text: String, fact: NativeMemoryGateFact)
    case deleteConversation(String)
    case excludeConversation(String)
    case removeMemory(String)
    case referenceMissingAttachment(chat: String, label: String, text: String, fileName: String, fact: NativeMemoryGateFact)
    case compact(chat: String, turns: Int, query: String)
    case restart
}

struct NativeMemoryGateExpectation: Sendable {
    var recalled: Set<String>
    var required: [String] = []
    var absent: [String: NativeMemoryGateAbsence] = [:]
    var decisiveSource: String?
    var stalePhrases: [String] = []
    var qualified: [NativeMemoryGateQualifiedFact] = []
}

struct NativeMemoryGateScenario: Sendable {
    let id: String
    let steps: [NativeMemoryGateStep]
    let query: String
    let expectation: NativeMemoryGateExpectation
}

struct NativeMemoryGateCounts: Codable, Equatable, Sendable {
    var falseRetrievals = 0
    var unnecessaryInsertions = 0
    var resurrections = 0
    var staleFactErrors = 0
    var fabricatedCompletions = 0
    var citationErrors = 0
    var missedRecalls = 0

    var errors: Int {
        falseRetrievals + unnecessaryInsertions + resurrections + staleFactErrors
            + fabricatedCompletions + citationErrors + missedRecalls
    }

    static func + (left: Self, right: Self) -> Self {
        NativeMemoryGateCounts(
            falseRetrievals: left.falseRetrievals + right.falseRetrievals,
            unnecessaryInsertions: left.unnecessaryInsertions + right.unnecessaryInsertions,
            resurrections: left.resurrections + right.resurrections,
            staleFactErrors: left.staleFactErrors + right.staleFactErrors,
            fabricatedCompletions: left.fabricatedCompletions + right.fabricatedCompletions,
            citationErrors: left.citationErrors + right.citationErrors,
            missedRecalls: left.missedRecalls + right.missedRecalls)
    }
}

struct NativeMemoryGateScenarioResult: Codable, Equatable, Sendable {
    let id: String
    let counts: NativeMemoryGateCounts
    let observations: Int
    let elapsedMilliseconds: Int
    let retrievalMilliseconds: Int
}

struct NativeMemoryGateReport: Codable, Equatable, Sendable {
    let runDate: String
    let mode: String
    let model: String
    let endpointHost: String
    let memoryEndpointHost: String
    let scenarios: [NativeMemoryGateScenarioResult]
    let totals: NativeMemoryGateCounts
    let elapsedMilliseconds: Int
    let budgetMilliseconds: Int
    let passed: Bool

    var markdown: String {
        var lines = [
            "# Memory gate report",
            "",
            "Run \(runDate), \(mode) mode, \(passed ? "passed" : "failed").",
            "",
            "Chat model \(model) at \(endpointHost). Memory endpoint at \(memoryEndpointHost).",
            "",
            "| Scenario | False retrievals | Unnecessary insertions | Resurrections | Stale facts | Fabricated completions | Citation errors | Missed recalls | Turns | Elapsed ms | Retrieval ms |",
            "|---|---|---|---|---|---|---|---|---|---|---|",
        ]
        func row(_ name: String, _ counts: NativeMemoryGateCounts, _ turns: String, _ elapsed: String, _ retrieval: String) -> String {
            "| \(name) | \(counts.falseRetrievals) | \(counts.unnecessaryInsertions) | \(counts.resurrections) | \(counts.staleFactErrors) | \(counts.fabricatedCompletions) | \(counts.citationErrors) | \(counts.missedRecalls) | \(turns) | \(elapsed) | \(retrieval) |"
        }
        for result in scenarios {
            lines.append(row(result.id, result.counts, "\(result.observations)", "\(result.elapsedMilliseconds)", "\(result.retrievalMilliseconds)"))
        }
        lines.append(row("Total", totals, "\(scenarios.reduce(0) { $0 + $1.observations })", "\(elapsedMilliseconds)", ""))
        lines.append("")
        lines.append("Elapsed \(elapsedMilliseconds) ms against a declared budget of \(budgetMilliseconds) ms.")
        return lines.joined(separator: "\n") + "\n"
    }
}

final class NativeMemoryGateCapture: NativeChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let inner: any NativeChatTransport
    private var captured: [[NativeChatMessage]] = []

    init(_ inner: any NativeChatTransport) { self.inner = inner }

    var histories: [[NativeChatMessage]] { lock.withLock { captured } }

    func discoverModels() async throws -> [String] { try await inner.discoverModels() }

    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        lock.withLock { captured.append(messages) }
        return inner.stream(messages: messages, model: model, tools: tools)
    }

    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema],
                validateRequest: @escaping @Sendable () async throws -> Void) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        lock.withLock { captured.append(messages) }
        return inner.stream(messages: messages, model: model, tools: tools, validateRequest: validateRequest)
    }
}

@MainActor
protocol NativeMemoryGateDriver {
    var mode: String { get }
    var chatConfig: NativeChatConfig { get }
    var memoryService: any NativeMemoryServing { get }
    var memoryEndpointHost: String { get }
    var settings: NativeMemorySettings { get }
    var replyTimeout: Duration { get }
    var backfillTimeout: Duration { get }
    var budgetMilliseconds: Int { get }
    func transport() -> any NativeChatTransport
}

struct NativeMemoryGateFixtureDriver: NativeMemoryGateDriver {
    let mode = "fixture"
    var contextCeiling: Int? = NativeMemoryGate.contextCeiling
    let memoryService: any NativeMemoryServing = NativeMemoryFixtureService(model: "fixture-embed", reranker: "fixture-rerank")
    let memoryEndpointHost = "fixture"
    let replyTimeout: Duration = .seconds(5)
    let backfillTimeout: Duration = .seconds(5)
    let budgetMilliseconds = NativeMemoryGate.fixtureBudgetMilliseconds

    var chatConfig: NativeChatConfig {
        var options = NativeChatRequestOptions.none
        options.contextCeiling = contextCeiling
        return NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil,
                                model: "fixture-model", chatTemplateKwargs: nil, options: options)
    }

    var settings: NativeMemorySettings {
        NativeMemorySettings(enabled: true, embeddingsModel: "fixture-embed", extractionModel: "fixture-extract",
                             bankScope: NativeMemoryGate.bank, searchPastChats: true, generateFromChats: true)
    }

    func transport() -> any NativeChatTransport { SelfTestNativeTransport() }
}

struct NativeMemoryGateLiveDriver: NativeMemoryGateDriver {
    let mode = "live"
    let chatConfig: NativeChatConfig
    let memoryService: any NativeMemoryServing
    let memoryEndpointHost: String
    let settings: NativeMemorySettings
    let replyTimeout: Duration = .seconds(240)
    let backfillTimeout: Duration = .seconds(180)
    let budgetMilliseconds = NativeMemoryGate.liveBudgetMilliseconds

    func transport() -> any NativeChatTransport { NativeChatClient.foreground(config: chatConfig) }
}

struct NativeMemoryGateObservation: Sendable {
    var recalled: [String]
    var unmatchedLines: Int
    var contextLines: [String]
    var reply: String
    var retrievalMilliseconds: Int
}

enum NativeMemoryGateError: LocalizedError {
    case setup(String, String)
    var errorDescription: String? {
        switch self {
        case .setup(let scenario, let reason): "Scenario \(scenario) could not run: \(reason)"
        }
    }
}

@MainActor
enum NativeMemoryGate {
    static let fixtureBudgetMilliseconds = 20_000
    static let liveBudgetMilliseconds = 1_800_000
    static let contextCeiling = 2_000
    static let bank = "household"
    static let contextStart = "USER-APPROVED MEMORY CONTEXT"
    static let contextEnd = "END USER-APPROVED MEMORY CONTEXT"
    static let reportFieldLimit = 96
    static let reportFieldCharacters = [("a", "z"), ("A", "Z"), ("0", "9")].reduce(CharacterSet(charactersIn: ".-_:/")) { set, bounds in
        set.union(CharacterSet(charactersIn: Unicode.Scalar(bounds.0)...Unicode.Scalar(bounds.1)))
    }
    static let negations: Set<String> = ["not", "no", "never", "none", "nothing", "neither", "nor", "without", "cannot"]
    static let hedges: Set<String> = ["will", "would", "should", "could", "might", "may", "once", "if", "when", "until", "unless", "before"]

    static let scenarios: [NativeMemoryGateScenario] = [
        NativeMemoryGateScenario(
            id: "livestock-correction",
            steps: [
                .say(chat: "chat-a", label: "count", text: "Current livestock: twelve hens.",
                     remember: NativeMemoryGateFact(id: "stock-old", title: "Current livestock", details: ["Current livestock: twelve hens"], category: .project)),
                .planCare(chat: "chat-a", label: "care", text: "Vaccination for the hens is planned for Friday.",
                          fact: NativeMemoryGateFact(id: "care", title: "Planned livestock care", details: ["Livestock vaccination is planned for Friday, not completed."])),
                .correct(target: "stock-old", chat: "chat-b", label: "correction", text: "Correction: current livestock is ten hens.",
                         replacement: NativeMemoryGateFact(id: "stock", title: "Current livestock", details: ["Current livestock: ten hens"], category: .project)),
                .recordLoss(chat: "chat-b", label: "loss", text: "Two hens left the flock this week.",
                            fact: NativeMemoryGateFact(id: "loss", title: "Livestock loss", details: ["Two hens left the flock this week"])),
                .restart,
            ],
            query: "How many hens are in the current livestock, and what livestock care is planned?",
            expectation: NativeMemoryGateExpectation(
                recalled: ["stock", "care", "loss"], required: ["ten hens", "planned for friday, not completed", "two hens left"],
                absent: ["stock-old": .superseded], decisiveSource: "correction", stalePhrases: ["twelve hens"],
                qualified: [NativeMemoryGateQualifiedFact(subject: "vaccination", qualifier: "not completed",
                    subjects: ["vaccination", "vaccinations", "vaccine", "hens", "flock", "care"],
                    claims: ["vaccinated", "completed", "complete", "done", "finished", "given", "administered"])])),
        NativeMemoryGateScenario(
            id: "stale-preference",
            steps: [
                .say(chat: "tea-old", label: "milk", text: "I take my tea with milk.",
                     remember: NativeMemoryGateFact(id: "tea-old", title: "Tea preference", details: ["Takes tea with milk"], category: .preference)),
                .say(chat: "tea-old", label: "sugar", text: "I also take two sugars in my tea.",
                     remember: NativeMemoryGateFact(id: "tea-sugar", title: "Tea sweetener", details: ["Takes two sugars in tea"], category: .preference)),
                .correct(target: "tea-old", chat: "tea-new", label: "switch", text: "I switched, I take my tea black now.",
                         replacement: NativeMemoryGateFact(id: "tea", title: "Tea preference", details: ["Takes tea black"], category: .preference)),
                .removeMemory("tea-sugar"),
                .restart,
            ],
            query: "How do I take my tea?",
            expectation: NativeMemoryGateExpectation(
                recalled: ["tea"], required: ["tea black"], absent: ["tea-old": .superseded, "tea-sugar": .tombstoned],
                decisiveSource: "switch", stalePhrases: ["with milk", "two sugars"])),
        NativeMemoryGateScenario(
            id: "unfinished-task",
            steps: [
                .say(chat: "chores", label: "task", text: "I started repainting the shed but it is not finished yet.",
                     remember: NativeMemoryGateFact(id: "shed", title: "Shed repainting", details: ["Repainting the shed was started and is unfinished, not completed."], category: .project)),
                .restart,
            ],
            query: "Did I finish repainting the shed?",
            expectation: NativeMemoryGateExpectation(
                recalled: ["shed"], required: ["unfinished"], decisiveSource: "task",
                qualified: [NativeMemoryGateQualifiedFact(subject: "shed", qualifier: "unfinished",
                    subjects: ["shed", "repainting", "painting"],
                    claims: ["completed", "complete", "done", "finished", "repainted", "painted", "wrapped"])])),
        NativeMemoryGateScenario(
            id: "failed-approach",
            steps: [
                .say(chat: "garden", label: "attempt", text: "I tried copper tape around the beds to stop slugs and it did not work.",
                     remember: NativeMemoryGateFact(id: "slugs", title: "Slug control attempt", details: ["Copper tape around the beds failed to stop slugs; it did not work."])),
                .restart,
            ],
            query: "What should I use to stop slugs in the beds?",
            expectation: NativeMemoryGateExpectation(
                recalled: ["slugs"], required: ["did not work"], decisiveSource: "attempt",
                qualified: [NativeMemoryGateQualifiedFact(subject: "copper tape", qualifier: "did not work",
                    subjects: ["copper tape", "copper"],
                    claims: ["works", "worked", "stopped", "effective", "succeeded", "solved", "recommend", "recommended", "use", "try"])])),
        NativeMemoryGateScenario(
            id: "evidence-deleted",
            steps: [
                .say(chat: "bike-old", label: "garage", text: "My bicycle is stored in the garage.",
                     remember: NativeMemoryGateFact(id: "bike-garage", title: "Bicycle storage", details: ["The bicycle is stored in the garage"])),
                .say(chat: "bike-new", label: "hallway", text: "I keep the bicycle in the hallway now.",
                     remember: NativeMemoryGateFact(id: "bike-hallway", title: "Bicycle storage", details: ["The bicycle is kept in the hallway"])),
                .deleteConversation("bike-old"),
                .restart,
            ],
            query: "Where is my bicycle stored?",
            expectation: NativeMemoryGateExpectation(
                recalled: ["bike-hallway"], required: ["hallway"], absent: ["bike-garage": .unsupported],
                decisiveSource: "hallway", stalePhrases: ["garage"])),
        NativeMemoryGateScenario(
            id: "evidence-excluded",
            steps: [
                .say(chat: "hose-private", label: "door", text: "The garden hose is coiled by the back door.",
                     remember: NativeMemoryGateFact(id: "hose-door", title: "Garden hose", details: ["The garden hose is coiled by the back door"])),
                .say(chat: "hose-shared", label: "shed", text: "The garden hose lives in the tool shed.",
                     remember: NativeMemoryGateFact(id: "hose-shed", title: "Garden hose", details: ["The garden hose is in the tool shed"])),
                .excludeConversation("hose-private"),
                .restart,
            ],
            query: "Where is the garden hose?",
            expectation: NativeMemoryGateExpectation(
                recalled: ["hose-shed"], required: ["tool shed"], absent: ["hose-door": .unsupported],
                decisiveSource: "shed", stalePhrases: ["back door"])),
        NativeMemoryGateScenario(
            id: "missing-attachment",
            steps: [
                .referenceMissingAttachment(chat: "coop", label: "photo", text: "Here is a photo of the coop layout.", fileName: "coop-layout.png",
                                            fact: NativeMemoryGateFact(id: "coop", title: "Coop layout photo", details: ["A photo of the coop layout was shared; the file is not available."])),
                .restart,
            ],
            query: "What does the coop layout photo show?",
            expectation: NativeMemoryGateExpectation(
                recalled: ["coop"], required: ["not available"], decisiveSource: "photo",
                qualified: [NativeMemoryGateQualifiedFact(subject: "coop layout", qualifier: "not available",
                    subjects: ["photo", "image", "picture", "layout"],
                    claims: ["shows", "show", "showing", "shown", "depicts", "contains", "displays", "includes"])])),
        NativeMemoryGateScenario(
            id: "repeated-compaction",
            steps: [
                .say(chat: "geese-a", label: "count", text: "We keep eleven geese.",
                     remember: NativeMemoryGateFact(id: "geese-old", title: "Geese count", details: ["The household keeps eleven geese"], category: .project)),
                .correct(target: "geese-old", chat: "geese-long", label: "correction", text: "Correction: we keep nine geese.",
                         replacement: NativeMemoryGateFact(id: "geese", title: "Geese count", details: ["The household keeps nine geese"], category: .project)),
                .compact(chat: "geese-long", turns: 40, query: "How many geese do we keep?"),
                .compact(chat: "geese-long", turns: 40, query: "How many geese do we keep?"),
                .restart,
                .compact(chat: "geese-long", turns: 40, query: "How many geese do we keep?"),
                .restart,
            ],
            query: "How many geese do we keep?",
            expectation: NativeMemoryGateExpectation(
                recalled: ["geese"], required: ["nine geese"], absent: ["geese-old": .superseded],
                decisiveSource: "correction", stalePhrases: ["eleven geese"])),
    ]

    static func run(driver: any NativeMemoryGateDriver, sabotage: Bool = false, mode: String? = nil) async throws -> NativeMemoryGateReport {
        let started = ContinuousClock.now
        var results: [NativeMemoryGateScenarioResult] = []
        for scenario in scenarios {
            results.append(try await NativeMemoryGateRunner(scenario: scenario, driver: driver, sabotage: sabotage).run().result)
        }
        let elapsed = milliseconds(started.duration(to: .now))
        let totals = results.reduce(NativeMemoryGateCounts()) { $0 + $1.counts }
        let passed = driver.mode == "live"
            ? totals.resurrections == 0 && totals.fabricatedCompletions == 0
            : totals.errors == 0 && elapsed <= driver.budgetMilliseconds
        return report(mode: mode ?? driver.mode, model: driver.chatConfig.model, endpointHost: driver.chatConfig.baseURL.host ?? "",
                      memoryEndpointHost: driver.memoryEndpointHost, scenarios: results, elapsed: elapsed,
                      budget: driver.budgetMilliseconds, passed: passed)
    }

    static func report(mode: String, model: String, endpointHost: String, memoryEndpointHost: String,
                       scenarios results: [NativeMemoryGateScenarioResult], elapsed: Int, budget: Int, passed: Bool) -> NativeMemoryGateReport {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return NativeMemoryGateReport(
            runDate: formatter.string(from: Date()), mode: mode, model: reportField(model),
            endpointHost: reportField(endpointHost), memoryEndpointHost: reportField(memoryEndpointHost),
            scenarios: results, totals: results.reduce(NativeMemoryGateCounts()) { $0 + $1.counts },
            elapsedMilliseconds: elapsed, budgetMilliseconds: budget, passed: passed)
    }

    static func reportField(_ value: String) -> String {
        guard !value.isEmpty, value.count <= reportFieldLimit,
              value.unicodeScalars.allSatisfy({ reportFieldCharacters.contains($0) }) else { return "unrecognized" }
        return value
    }

    static func selftest() async throws {
        var driver = NativeMemoryGateFixtureDriver()
        let clean = try await run(driver: driver)
        guard clean.passed, clean.totals.errors == 0 else {
            let failing = clean.scenarios.filter { $0.counts.errors > 0 }.map(\.id)
            throw NativeMemoryGateError.setup("fixture", "clean run reported \(clean.totals.errors) errors in \(failing) after \(clean.elapsedMilliseconds) ms")
        }
        guard clean.elapsedMilliseconds <= fixtureBudgetMilliseconds else {
            throw NativeMemoryGateError.setup("fixture", "clean run took \(clean.elapsedMilliseconds) ms, over the \(fixtureBudgetMilliseconds) ms budget")
        }
        try scoringChecks()
        try reportChecks(clean)
        let preference = scenarios.first { $0.id == "stale-preference" }!
        let probe = try await NativeMemoryGateRunner(scenario: preference, driver: driver, sabotage: true).run()
        let carried = probe.observations.flatMap(\.contextLines).joined(separator: "\n")
        guard carried.contains("Takes two sugars in tea"), carried.contains("Takes tea with milk"), probe.result.counts.resurrections == 2 else {
            throw NativeMemoryGateError.setup("sabotage", "the broken retrieval did not put the removed and replaced facts into the request")
        }
        let broken = try await run(driver: driver, sabotage: true, mode: "fixture with broken retrieval")
        guard !broken.passed, broken.totals.resurrections > 0 else {
            throw NativeMemoryGateError.setup("sabotage", "broken retrieval was not caught (resurrections \(broken.totals.resurrections))")
        }
        driver.contextCeiling = nil
        let compaction = scenarios.first { $0.id == "repeated-compaction" }!
        do {
            _ = try await NativeMemoryGateRunner(scenario: compaction, driver: driver, sabotage: false).run()
            throw NativeMemoryGateError.setup("compaction", "a long chat without a context ceiling was accepted as folded")
        } catch NativeMemoryGateError.setup(let id, _) where id == compaction.id { }
        print("memory-gate: PASS (\(scenarios.count) scenarios clean in \(clean.elapsedMilliseconds) ms of \(fixtureBudgetMilliseconds) ms; broken retrieval reached the request and was caught with \(broken.totals.resurrections) resurrections; unfolded history refused; report carries ids and counts only)")
    }

    static func scoringChecks() throws {
        let expectation = scenarios[0].expectation
        let care = expectation.qualified[0]
        let completed = NativeMemoryGateObservation(
            recalled: ["care", "loss"], unmatchedLines: 0,
            contextLines: ["- Planned livestock care: Livestock vaccination is planned for Friday. [10001]"],
            reply: "The hens were vaccinated on Friday.", retrievalMilliseconds: 0)
        let counts = score(completed, expectation: expectation, sources: ["care": "chat-a"], decisive: "chat-b")
        guard counts.fabricatedCompletions == 2, counts.citationErrors == 1, counts.missedRecalls == 4, counts.falseRetrievals == 0 else {
            throw NativeMemoryGateError.setup("scoring", "a completed claim, a missing qualifier, a missing phrase or a missing citation went uncounted")
        }
        let shed = scenarios.first { $0.id == "unfinished-task" }!.expectation.qualified[0]
        let asserted: [(NativeMemoryGateQualifiedFact, String)] = [
            (care, "No delay. Hens were vaccinated."), (care, "Not only hens were vaccinated."),
            (shed, "Yes, you completed the shed repainting."),
        ]
        let negated: [(NativeMemoryGateQualifiedFact, String)] = [
            (care, "The hens were not vaccinated."), (care, "The vaccination hasn't been done yet."),
            (care, "Livestock vaccination is planned for Friday, not completed."),
            (shed, "Repainting the shed was started and is unfinished, not completed."),
        ]
        guard asserted.allSatisfy({ claimsCompletion($0.0, in: $0.1) }), !negated.contains(where: { claimsCompletion($0.0, in: $0.1) }) else {
            throw NativeMemoryGateError.setup("scoring", "negated and asserted completions were not told apart")
        }
    }

    static func reportChecks(_ clean: NativeMemoryGateReport) throws {
        guard clean.model == "fixture-model", clean.endpointHost == "model.example", reportField("qwen3-coder:30b/q4_k.m") == "qwen3-coder:30b/q4_k.m" else {
            throw NativeMemoryGateError.setup("report", "an ordinary model or host name was rejected")
        }
        let hostile = report(mode: "fixture", model: "Ten hens | **twelve hens** <b>care</b>\n# Heading",
                             endpointHost: "host](javascript:x)", memoryEndpointHost: "fixture",
                             scenarios: clean.scenarios, elapsed: clean.elapsedMilliseconds, budget: fixtureBudgetMilliseconds, passed: true)
        let rendered = (String(decoding: try JSONEncoder().encode(hostile), as: UTF8.self) + hostile.markdown).lowercased()
        guard !["hens", "**", "<b>", "# heading", "](", "javascript"].contains(where: { rendered.contains($0) }) else {
            throw NativeMemoryGateError.setup("report", "an unsafe model or host string reached the report")
        }
        let encoded = (String(decoding: try JSONEncoder().encode(clean), as: UTF8.self) + clean.markdown).lowercased()
        let leaked = scenarios.flatMap { scenario in
            scenario.steps.flatMap(phrases) + scenario.expectation.stalePhrases
        }.filter { encoded.contains($0.lowercased()) }
        guard leaked.isEmpty else { throw NativeMemoryGateError.setup("report", "report contains memory content") }
    }

    static func live() async -> Int32 {
        let config = ConfigStore(writeConfiguration: { _ in })
        guard let chat = config.nativeResolved else {
            print("memory-gate: no chat profile is configured. Set one up in Settings, then run again.")
            return 2
        }
        guard let endpoint = config.memoryEndpointResolved, let service = config.nativeMemoryService else {
            print("memory-gate: no memory endpoint is configured. Set one up in Settings, Memory, then run again.")
            return 2
        }
        var options = chat.options
        options.contextCeiling = contextCeiling
        let bounded = NativeChatConfig(baseURL: chat.baseURL, apiKey: chat.apiKey, model: chat.model,
                                       chatTemplateKwargs: chat.chatTemplateKwargs, streaming: chat.streaming, options: options)
        var settings = config.nativeSettings.memory
        settings.enabled = true
        settings.bankScope = bank
        settings.searchPastChats = true
        settings.generateFromChats = true
        settings.embeddingsModel = endpoint.embeddingsModel
        settings.extractionModel = endpoint.extractionModel
        let driver = NativeMemoryGateLiveDriver(chatConfig: bounded, memoryService: service,
                                                memoryEndpointHost: endpoint.baseURL.host ?? "", settings: settings)
        do {
            let report = try await run(driver: driver)
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Vera", isDirectory: true).appendingPathComponent("reports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyy-MM-dd-HHmmss"
            let base = "memory-gate-" + stamp.string(from: Date())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = directory.appendingPathComponent(base + ".json")
            let markdown = directory.appendingPathComponent(base + ".md")
            try encoder.encode(report).write(to: json, options: .atomic)
            try Data(report.markdown.utf8).write(to: markdown, options: .atomic)
            let totals = report.totals
            print("memory-gate: \(report.passed ? "PASS" : "FAIL") live run with \(report.model): resurrections \(totals.resurrections), fabricated completions \(totals.fabricatedCompletions), false retrievals \(totals.falseRetrievals), unnecessary insertions \(totals.unnecessaryInsertions), stale facts \(totals.staleFactErrors), citation errors \(totals.citationErrors), missed recalls \(totals.missedRecalls), \(report.elapsedMilliseconds) ms")
            print("memory-gate: report written to \(json.path) and \(markdown.path)")
            return report.passed ? 0 : 1
        } catch {
            print("memory-gate: FAIL \(error.localizedDescription)")
            return 1
        }
    }

    static func score(_ observation: NativeMemoryGateObservation, expectation: NativeMemoryGateExpectation,
                      sources: [String: String], decisive: String?) -> NativeMemoryGateCounts {
        var counts = NativeMemoryGateCounts()
        let recalled = Set(observation.recalled)
        counts.falseRetrievals = recalled.subtracting(expectation.recalled).subtracting(expectation.absent.keys).count + observation.unmatchedLines
        let inserted = recalled.intersection(expectation.absent.keys)
        counts.unnecessaryInsertions = inserted.count
        counts.resurrections = inserted.filter { expectation.absent[$0]?.resurrects == true }.count
        let context = observation.contextLines.joined(separator: "\n").lowercased()
        counts.missedRecalls = expectation.recalled.subtracting(recalled).count
            + expectation.required.filter { !context.contains($0.lowercased()) }.count
        counts.staleFactErrors = expectation.stalePhrases.filter { context.contains($0.lowercased()) }.count
        for fact in expectation.qualified {
            let subject = fact.subject.lowercased()
            for line in observation.contextLines.map({ $0.lowercased() }) where line.contains(subject) {
                if !line.contains(fact.qualifier.lowercased()) { counts.fabricatedCompletions += 1 }
            }
            for text in [context, observation.reply] where claimsCompletion(fact, in: text) {
                counts.fabricatedCompletions += 1
            }
        }
        if let decisive, !observation.recalled.contains(where: { sources[$0] == decisive }) {
            counts.citationErrors = 1
        }
        return counts
    }

    static func claimsCompletion(_ fact: NativeMemoryGateQualifiedFact, in text: String) -> Bool {
        let normalized = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let subjects = fact.subjects.map { $0.lowercased().split(separator: " ").map(String.init) }
        let claims = Set(fact.claims.map { $0.lowercased() })
        for clause in normalized.split(whereSeparator: { ".!?;,\n".contains($0) }) {
            let words = clause.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
            guard subjects.contains(where: { phrase in
                !phrase.isEmpty && words.count >= phrase.count
                    && (0...(words.count - phrase.count)).contains { Array(words[$0..<($0 + phrase.count)]) == phrase }
            }) else { continue }
            for (index, word) in words.enumerated() where claims.contains(word) {
                let cancelled = words[..<index].enumerated().contains { offset, token in
                    if token == "not", offset + 1 < words.count, ["only", "just"].contains(words[offset + 1]) { return false }
                    return negations.contains(token) || hedges.contains(token) || token.hasSuffix("n't")
                }
                if !cancelled { return true }
            }
        }
        return false
    }

    static func memoryContextLines(_ prompt: String) -> [String] {
        guard let start = prompt.range(of: contextStart + "\n"),
              let end = prompt.range(of: contextEnd, range: start.upperBound..<prompt.endIndex) else { return [] }
        return prompt[start.upperBound..<end.lowerBound].split(separator: "\n").map(String.init).filter { $0.hasPrefix("- ") }
    }

    static func uncited(_ line: String) -> String {
        line.replacingOccurrences(of: #"\s\[\d+\]$"#, with: "", options: .regularExpression)
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func phrases(_ step: NativeMemoryGateStep) -> [String] {
        switch step {
        case .say(_, _, let text, let fact): [text] + (fact?.details ?? [])
        case .correct(_, _, _, let text, let fact), .recordLoss(_, _, let text, let fact), .planCare(_, _, let text, let fact),
             .referenceMissingAttachment(_, _, let text, _, let fact): [text] + fact.details
        case .compact(_, _, let query): [query]
        case .deleteConversation, .excludeConversation, .removeMemory, .restart: []
        }
    }
}

@MainActor
private final class NativeMemoryGateRunner {
    let scenario: NativeMemoryGateScenario
    let driver: any NativeMemoryGateDriver
    let sabotage: Bool
    let directory: URL
    var repository: LocalChatRepository
    var ledger: [String: NativeMemoryRecord] = [:]
    var messageIDs: [String: String] = [:]
    var observations: [NativeMemoryGateObservation] = []
    var clock = Date()

    init(scenario: NativeMemoryGateScenario, driver: any NativeMemoryGateDriver, sabotage: Bool) throws {
        self.scenario = scenario
        self.driver = driver
        self.sabotage = sabotage
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vera-memory-gate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        repository = try LocalChatRepository(url: directory.appendingPathComponent("gate.sqlite"))
    }

    func run() async throws -> (result: NativeMemoryGateScenarioResult, observations: [NativeMemoryGateObservation]) {
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = ContinuousClock.now
        for step in scenario.steps { try await apply(step) }
        try await ask(nil, query: scenario.query)
        let sources = ledger.compactMapValues(\.sourceMessageID)
        let decisive = scenario.expectation.decisiveSource.flatMap { messageIDs[$0] }
        if scenario.expectation.decisiveSource != nil, decisive == nil { throw failure("decisive source was never said") }
        let counts = observations.reduce(NativeMemoryGateCounts()) {
            $0 + NativeMemoryGate.score($1, expectation: scenario.expectation, sources: sources, decisive: decisive)
        }
        let result = NativeMemoryGateScenarioResult(
            id: scenario.id, counts: counts, observations: observations.count,
            elapsedMilliseconds: NativeMemoryGate.milliseconds(started.duration(to: .now)),
            retrievalMilliseconds: observations.map(\.retrievalMilliseconds).max() ?? 0)
        return (result, observations)
    }

    private func failure(_ reason: String) -> NativeMemoryGateError { .setup(scenario.id, reason) }

    private func tick() -> Date {
        clock = clock.addingTimeInterval(1)
        return clock
    }

    private func say(_ chat: String, label: String?, text: String, attachments: [MessageAttachment] = []) throws -> Message {
        if !(try repository.listConversations().contains { $0.id == chat }) {
            try repository.saveConversation(Conversation(id: chat, title: chat, messages: [], updatedAt: tick()))
        }
        let ordinal = try repository.messages(conversationID: chat).count
        let message = Message(role: .user, text: text, createdAt: tick(), attachments: attachments)
        try repository.saveMessage(message, conversationID: chat, ordinal: ordinal)
        try repository.saveMessage(Message(role: .assistant, text: "Noted.", createdAt: tick()), conversationID: chat, ordinal: ordinal + 1)
        if let label { messageIDs[label] = message.id.uuidString }
        return message
    }

    private func remember(_ fact: NativeMemoryGateFact, category: NativeMemoryCategory? = nil, chat: String, message: Message) throws {
        let now = tick()
        let kind = category ?? fact.category
        let record = NativeMemoryRecord(
            id: fact.id, title: fact.title, summary: fact.details.first ?? fact.title, details: fact.details,
            group: kind.defaultGroup, category: kind, bank: NativeMemoryGate.bank, durability: .durable, expiry: nil,
            status: .approved, embedding: nil, sourceConversationID: chat, sourceMessageID: message.id.uuidString,
            createdAt: now, updatedAt: now)
        try repository.saveMemory(record, decision: .accepted, note: "Memory gate fixture")
        ledger[fact.id] = record
    }

    private func current(_ id: String) throws -> NativeMemoryRecord {
        guard let record = try repository.allMemories().first(where: { $0.id == id }) else { throw failure("missing record \(id)") }
        return record
    }

    private func apply(_ step: NativeMemoryGateStep) async throws {
        switch step {
        case .say(let chat, let label, let text, let fact):
            let message = try say(chat, label: label, text: text)
            if let fact { try remember(fact, chat: chat, message: message) }
        case .correct(let target, let chat, let label, let text, let replacement):
            let message = try say(chat, label: label, text: text)
            try remember(replacement, chat: chat, message: message)
            let prior = try current(target)
            var superseded = prior
            superseded.status = .suppressed
            superseded.embedding = nil
            superseded.updatedAt = tick()
            try repository.saveMemory(superseded, decision: .suppressed, note: "Memory gate correction", expected: prior)
        case .recordLoss(let chat, let label, let text, let fact):
            try remember(fact, category: .other, chat: chat, message: try say(chat, label: label, text: text))
        case .planCare(let chat, let label, let text, let fact):
            try remember(fact, category: .plan, chat: chat, message: try say(chat, label: label, text: text))
        case .deleteConversation(let chat):
            try repository.deleteConversation(chat)
        case .excludeConversation(let chat):
            guard var conversation = try repository.listConversations().first(where: { $0.id == chat }) else { throw failure("missing chat \(chat)") }
            conversation.memoryExcluded = true
            try repository.saveConversation(conversation)
        case .removeMemory(let id):
            try repository.deleteMemory(id)
        case .referenceMissingAttachment(let chat, let label, let text, let fileName, let fact):
            let attachment = MessageAttachment(name: fileName, ext: "png", isImage: true,
                                               fileName: "missing-" + UUID().uuidString + ".png", mime: "image/png", byteSize: 4_096)
            try remember(fact, chat: chat, message: try say(chat, label: label, text: text, attachments: [attachment]))
        case .compact(let chat, let turns, let query):
            var ordinal = try repository.messages(conversationID: chat).count
            for index in 0..<turns {
                try repository.saveMessage(Message(role: .user, text: "Filler turn \(index): the weather stayed mild today and the garden path was swept again before lunch.", createdAt: tick()),
                                           conversationID: chat, ordinal: ordinal)
                try repository.saveMessage(Message(role: .assistant, text: "Noted, mild weather and a swept path for turn \(index).", createdAt: tick()),
                                           conversationID: chat, ordinal: ordinal + 1)
                ordinal += 2
            }
            let stored = try repository.messages(conversationID: chat).count
            let sent = try await ask(chat, query: query)
            guard sent * 2 <= stored + 1 else { throw failure("the long chat was sent without folding (\(sent) of \(stored + 1) messages)") }
            guard driver.mode != "fixture" || sent > 2 else { throw failure("folding dropped every earlier turn (\(sent) of \(stored + 1) messages)") }
        case .restart:
            repository = try LocalChatRepository(url: directory.appendingPathComponent("gate.sqlite"))
        }
    }

    private func resurrections() -> [NativeMemoryRanked] {
        scenario.expectation.absent.sorted { $0.key < $1.key }.compactMap { id, absence in
            guard absence.resurrects, let record = ledger[id] else { return nil }
            return NativeMemoryRanked(record: record, score: 0)
        }
    }

    @discardableResult
    private func ask(_ chat: String?, query: String) async throws -> Int {
        let capture = NativeMemoryGateCapture(driver.transport())
        let store = ChatStore(nativeConfig: driver.chatConfig, nativeTransport: capture, repository: repository,
                              nativeTransportFactory: { _ in capture },
                              nativeMemorySettings: driver.settings, nativeMemoryService: driver.memoryService,
                              attachmentStore: NativeAttachmentStore(directory: directory.appendingPathComponent("attachments", isDirectory: true)),
                              artifactPersistenceEnabled: false)
        if sabotage {
            let revived = resurrections()
            store.nativeMemorySelectionTransform = { selected in
                selected + revived.filter { item in !selected.contains { $0.record.id == item.record.id } }
            }
        }
        await store.connect()
        if driver.memoryService.supportsSemanticRecall {
            store.backfillMemoryVectorsIfNeeded()
            let ready = try await wait(driver.backfillTimeout) {
                store.memoryIndexingProgress == nil && (store.memoryVectorStatus?.complete ?? false)
            }
            guard ready else { throw failure("vectors were not prepared") }
        }
        if let chat { store.select(chat) } else { store.newConversation() }
        guard let conversation = store.selectedID, store.sendText(query) else { throw failure("the query could not be sent") }
        let finished = try await wait(driver.replyTimeout) {
            guard !store.generating, let last = store.conversations.first(where: { $0.id == conversation })?.messages.last else { return false }
            return last.role == .assistant && last.state != .streaming
        }
        guard finished else { throw failure("the reply did not finish") }
        guard let history = capture.histories.last else { throw failure("no request reached the transport") }
        let prompt = history.first(where: { $0.role == "system" })?.content ?? ""
        let reply = store.conversations.first(where: { $0.id == conversation })?.messages.last
        guard let reply, reply.role == .assistant else { throw failure("no reply was saved") }
        let lines = NativeMemoryGate.memoryContextLines(prompt)
        let rendered = ledger.mapValues { NativeMemoryGate.uncited(NativeMemoryRetrieval.renderedLine($0)) }
        var recalled: [String] = []
        var unmatched = 0
        for line in lines {
            let text = NativeMemoryGate.uncited(line)
            if let id = rendered.first(where: { $0.value == text })?.key { recalled.append(id) } else { unmatched += 1 }
        }
        observations.append(NativeMemoryGateObservation(
            recalled: recalled, unmatchedLines: unmatched, contextLines: lines, reply: reply.text,
            retrievalMilliseconds: store.memoryRetrievalTraces[conversation]?.elapsedMilliseconds ?? 0))
        return history.filter { $0.role != "system" }.count
    }

    private func wait(_ timeout: Duration, _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
