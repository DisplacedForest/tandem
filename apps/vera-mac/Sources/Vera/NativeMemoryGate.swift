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
    let contradictions: [String]
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
    let chatConfig = NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil,
                                      model: "fixture-model", chatTemplateKwargs: nil)
    let memoryService: any NativeMemoryServing = NativeMemoryFixtureService(model: "fixture-embed", reranker: "fixture-rerank")
    let memoryEndpointHost = "fixture"
    let replyTimeout: Duration = .seconds(5)
    let backfillTimeout: Duration = .seconds(5)
    let budgetMilliseconds = NativeMemoryGate.fixtureBudgetMilliseconds

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

typealias NativeMemoryGateSabotage = @MainActor (inout NativeMemoryGateObservation, NativeMemoryGateExpectation, [String: NativeMemoryRecord]) -> Void

struct NativeMemoryGateObservation: Sendable {
    var recalled: [String]
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
    static let contextCeiling = 1_500
    static let bank = "household"
    static let contextStart = "USER-APPROVED MEMORY CONTEXT"
    static let contextEnd = "END USER-APPROVED MEMORY CONTEXT"

    static let resurrect: NativeMemoryGateSabotage = { observation, expectation, ledger in
        for (id, absence) in expectation.absent.sorted(by: { $0.key < $1.key }) where absence.resurrects {
            guard let record = ledger[id], !observation.recalled.contains(id) else { continue }
            observation.recalled.append(id)
            observation.contextLines.append(NativeMemoryRetrieval.renderedLine(record))
        }
    }

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
                recalled: ["stock", "care", "loss"], absent: ["stock-old": .superseded], decisiveSource: "correction",
                stalePhrases: ["twelve hens"],
                qualified: [NativeMemoryGateQualifiedFact(subject: "vaccination", qualifier: "not completed", contradictions: [
                    "vaccination was completed", "vaccination is complete", "vaccination has been completed", "vaccination was done",
                    "hens were vaccinated", "hens have been vaccinated", "already vaccinated"])])),
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
                recalled: ["tea"], absent: ["tea-old": .superseded, "tea-sugar": .tombstoned], decisiveSource: "switch",
                stalePhrases: ["with milk", "two sugars"])),
        NativeMemoryGateScenario(
            id: "unfinished-task",
            steps: [
                .say(chat: "chores", label: "task", text: "I started repainting the shed but it is not finished yet.",
                     remember: NativeMemoryGateFact(id: "shed", title: "Shed repainting", details: ["Repainting the shed was started and is unfinished, not completed."], category: .project)),
                .restart,
            ],
            query: "Did I finish repainting the shed?",
            expectation: NativeMemoryGateExpectation(
                recalled: ["shed"], decisiveSource: "task",
                qualified: [NativeMemoryGateQualifiedFact(subject: "shed", qualifier: "unfinished", contradictions: [
                    "shed was repainted", "shed is repainted", "shed has been repainted", "finished repainting",
                    "repainting is done", "repainting was completed", "repainting is complete"])])),
        NativeMemoryGateScenario(
            id: "failed-approach",
            steps: [
                .say(chat: "garden", label: "attempt", text: "I tried copper tape around the beds to stop slugs and it did not work.",
                     remember: NativeMemoryGateFact(id: "slugs", title: "Slug control attempt", details: ["Copper tape around the beds failed to stop slugs; it did not work."])),
                .restart,
            ],
            query: "What should I use to stop slugs in the beds?",
            expectation: NativeMemoryGateExpectation(
                recalled: ["slugs"], decisiveSource: "attempt",
                qualified: [NativeMemoryGateQualifiedFact(subject: "copper tape", qualifier: "did not work", contradictions: [
                    "copper tape works", "copper tape worked", "copper tape stopped", "use copper tape", "try copper tape",
                    "recommend copper tape"])])),
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
                recalled: ["bike-hallway"], absent: ["bike-garage": .unsupported], decisiveSource: "hallway",
                stalePhrases: ["garage"])),
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
                recalled: ["hose-shed"], absent: ["hose-door": .unsupported], decisiveSource: "shed",
                stalePhrases: ["back door"])),
        NativeMemoryGateScenario(
            id: "missing-attachment",
            steps: [
                .referenceMissingAttachment(chat: "coop", label: "photo", text: "Here is a photo of the coop layout.", fileName: "coop-layout.png",
                                            fact: NativeMemoryGateFact(id: "coop", title: "Coop layout photo", details: ["A photo of the coop layout was shared; the file is not available."])),
                .restart,
            ],
            query: "What does the coop layout photo show?",
            expectation: NativeMemoryGateExpectation(
                recalled: ["coop"], decisiveSource: "photo",
                qualified: [NativeMemoryGateQualifiedFact(subject: "coop layout", qualifier: "not available", contradictions: [
                    "the photo shows", "the image shows", "the layout shows", "the picture shows", "in the photo"])])),
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
                recalled: ["geese"], absent: ["geese-old": .superseded], decisiveSource: "correction",
                stalePhrases: ["eleven geese"])),
    ]

    static func run(driver: any NativeMemoryGateDriver, sabotage: NativeMemoryGateSabotage? = nil,
                    mode: String? = nil) async throws -> NativeMemoryGateReport {
        let started = ContinuousClock.now
        var results: [NativeMemoryGateScenarioResult] = []
        for scenario in scenarios {
            results.append(try await NativeMemoryGateRunner(scenario: scenario, driver: driver, sabotage: sabotage).run())
        }
        let elapsed = milliseconds(started.duration(to: .now))
        let totals = results.reduce(NativeMemoryGateCounts()) { $0 + $1.counts }
        let resolvedMode = mode ?? driver.mode
        let passed = driver.mode == "live"
            ? totals.resurrections == 0 && totals.fabricatedCompletions == 0
            : totals.errors == 0 && elapsed <= driver.budgetMilliseconds
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return NativeMemoryGateReport(
            runDate: formatter.string(from: Date()), mode: resolvedMode, model: driver.chatConfig.model,
            endpointHost: driver.chatConfig.baseURL.host ?? "unknown", memoryEndpointHost: driver.memoryEndpointHost,
            scenarios: results, totals: totals, elapsedMilliseconds: elapsed,
            budgetMilliseconds: driver.budgetMilliseconds, passed: passed)
    }

    static func selftest() async throws {
        let driver = NativeMemoryGateFixtureDriver()
        let clean = try await run(driver: driver)
        guard clean.passed, clean.totals.errors == 0 else {
            let failing = clean.scenarios.filter { $0.counts.errors > 0 }.map(\.id)
            throw NativeMemoryGateError.setup("fixture", "clean run reported \(clean.totals.errors) errors in \(failing) after \(clean.elapsedMilliseconds) ms")
        }
        guard clean.elapsedMilliseconds <= fixtureBudgetMilliseconds else {
            throw NativeMemoryGateError.setup("fixture", "clean run took \(clean.elapsedMilliseconds) ms, over the \(fixtureBudgetMilliseconds) ms budget")
        }
        try scoringChecks()
        let broken = try await run(driver: driver, sabotage: resurrect, mode: "fixture with broken retrieval")
        guard !broken.passed, broken.totals.resurrections > 0 else {
            throw NativeMemoryGateError.setup("sabotage", "broken retrieval was not caught (resurrections \(broken.totals.resurrections))")
        }
        let encoded = String(decoding: try JSONEncoder().encode(clean), as: UTF8.self) + clean.markdown
        let leaked = scenarios.flatMap { scenario in
            scenario.steps.flatMap(phrases) + scenario.expectation.stalePhrases
        }.filter { encoded.lowercased().contains($0.lowercased()) }
        guard leaked.isEmpty else { throw NativeMemoryGateError.setup("report", "report contains memory content") }
        print("memory-gate: PASS (\(scenarios.count) scenarios clean in \(clean.elapsedMilliseconds) ms of \(fixtureBudgetMilliseconds) ms; broken retrieval caught with \(broken.totals.resurrections) resurrections; report carries ids and counts only)")
    }

    static func scoringChecks() throws {
        let expectation = scenarios[0].expectation
        let completed = NativeMemoryGateObservation(
            recalled: ["care", "loss"], contextLines: ["- Planned livestock care: Livestock vaccination is planned for Friday. [10001]"],
            reply: "The hens were vaccinated on Friday.", retrievalMilliseconds: 0)
        let counts = score(completed, expectation: expectation, sources: ["care": "chat-a"], decisive: "chat-b")
        guard counts.fabricatedCompletions == 2, counts.citationErrors == 1, counts.missedRecalls == 1, counts.falseRetrievals == 0 else {
            throw NativeMemoryGateError.setup("scoring", "a completed claim, a missing qualifier or a missing citation went uncounted")
        }
        guard !asserts("hens were vaccinated", in: "the hens were not yet vaccinated, and no hens were vaccinated"),
              asserts("hens were vaccinated", in: "no shots yet. later the hens were vaccinated") else {
            throw NativeMemoryGateError.setup("scoring", "negated claims were not told apart from assertions")
        }
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
                                                memoryEndpointHost: endpoint.baseURL.host ?? "unknown", settings: settings)
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
        counts.falseRetrievals = recalled.subtracting(expectation.recalled).subtracting(expectation.absent.keys).count
        let inserted = recalled.intersection(expectation.absent.keys)
        counts.unnecessaryInsertions = inserted.count
        counts.resurrections = inserted.filter { expectation.absent[$0]?.resurrects == true }.count
        counts.missedRecalls = expectation.recalled.subtracting(recalled).count
        let context = observation.contextLines.joined(separator: "\n").lowercased()
        counts.staleFactErrors = expectation.stalePhrases.filter { context.contains($0.lowercased()) }.count
        let reply = observation.reply.lowercased()
        for fact in expectation.qualified {
            let subject = fact.subject.lowercased()
            for line in observation.contextLines.map({ $0.lowercased() }) where line.contains(subject) {
                if !line.contains(fact.qualifier.lowercased()) { counts.fabricatedCompletions += 1 }
            }
            for phrase in fact.contradictions where asserts(phrase, in: context) || asserts(phrase, in: reply) {
                counts.fabricatedCompletions += 1
            }
        }
        if let decisive, !observation.recalled.contains(where: { sources[$0] == decisive }) {
            counts.citationErrors = 1
        }
        return counts
    }

    static func asserts(_ phrase: String, in text: String) -> Bool {
        let needle = phrase.lowercased()
        var searchStart = text.startIndex
        while let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            let lead = text[text.index(range.lowerBound, offsetBy: -min(16, text.distance(from: text.startIndex, to: range.lowerBound)))..<range.lowerBound]
            let negated = ["not ", "n't ", "never ", "no "].contains { lead.contains($0) }
            if !negated { return true }
            searchStart = range.upperBound
        }
        return false
    }

    static func memoryContextLines(_ prompt: String) -> [String] {
        guard let start = prompt.range(of: contextStart + "\n"),
              let end = prompt.range(of: contextEnd, range: start.upperBound..<prompt.endIndex) else { return [] }
        return prompt[start.upperBound..<end.lowerBound].split(separator: "\n").map(String.init).filter { $0.hasPrefix("- ") }
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
    let sabotage: NativeMemoryGateSabotage?
    let directory: URL
    var repository: LocalChatRepository
    var ledger: [String: NativeMemoryRecord] = [:]
    var messageIDs: [String: String] = [:]
    var observations: [NativeMemoryGateObservation] = []
    var clock = Date()

    init(scenario: NativeMemoryGateScenario, driver: any NativeMemoryGateDriver, sabotage: NativeMemoryGateSabotage?) throws {
        self.scenario = scenario
        self.driver = driver
        self.sabotage = sabotage
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vera-memory-gate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        repository = try LocalChatRepository(url: directory.appendingPathComponent("gate.sqlite"))
    }

    func run() async throws -> NativeMemoryGateScenarioResult {
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = ContinuousClock.now
        for step in scenario.steps { try await apply(step) }
        try await ask(nil, query: scenario.query)
        let sources = ledger.compactMapValues(\.sourceMessageID)
        let decisive = scenario.expectation.decisiveSource.flatMap { messageIDs[$0] }
        if scenario.expectation.decisiveSource != nil, decisive == nil { throw failure("decisive source was never said") }
        var counts = NativeMemoryGateCounts()
        for var observation in observations {
            sabotage?(&observation, scenario.expectation, ledger)
            counts = counts + NativeMemoryGate.score(observation, expectation: scenario.expectation, sources: sources, decisive: decisive)
        }
        return NativeMemoryGateScenarioResult(
            id: scenario.id, counts: counts, observations: observations.count,
            elapsedMilliseconds: NativeMemoryGate.milliseconds(started.duration(to: .now)),
            retrievalMilliseconds: observations.map(\.retrievalMilliseconds).max() ?? 0)
    }

    private func failure(_ reason: String) -> NativeMemoryGateError { .setup(scenario.id, reason) }

    private func tick() -> Date {
        clock = clock.addingTimeInterval(1)
        return clock
    }

    private func say(_ chat: String, label: String?, text: String, attachments: [MessageAttachment] = []) throws -> Message {
        let now = tick()
        if !(try repository.listConversations().contains { $0.id == chat }) {
            try repository.saveConversation(Conversation(id: chat, title: chat, messages: [], updatedAt: now))
        }
        let message = Message(role: .user, text: text, createdAt: now, attachments: attachments)
        try repository.saveMessage(message, conversationID: chat, ordinal: try repository.messages(conversationID: chat).count)
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
                try repository.saveMessage(Message(role: .user, text: "Filler turn \(index): the weather stayed mild today.", createdAt: tick()),
                                           conversationID: chat, ordinal: ordinal)
                try repository.saveMessage(Message(role: .assistant, text: "Noted, mild weather for turn \(index).", createdAt: tick()),
                                           conversationID: chat, ordinal: ordinal + 1)
                ordinal += 2
            }
            let stored = try repository.messages(conversationID: chat).count
            let sent = try await ask(chat, query: query)
            guard sent < stored + 1 else { throw failure("the long chat was sent without folding") }
        case .restart:
            repository = try LocalChatRepository(url: directory.appendingPathComponent("gate.sqlite"))
        }
    }

    @discardableResult
    private func ask(_ chat: String?, query: String) async throws -> Int {
        let capture = NativeMemoryGateCapture(driver.transport())
        let store = ChatStore(nativeConfig: driver.chatConfig, nativeTransport: capture, repository: repository,
                              nativeTransportFactory: { _ in capture },
                              nativeMemorySettings: driver.settings, nativeMemoryService: driver.memoryService,
                              attachmentStore: NativeAttachmentStore(directory: directory.appendingPathComponent("attachments", isDirectory: true)))
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
        observations.append(NativeMemoryGateObservation(
            recalled: reply.sources.compactMap { NativeMemoryCitation.recordID($0.url) },
            contextLines: NativeMemoryGate.memoryContextLines(prompt), reply: reply.text,
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
