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
}

enum NativeMemoryGateAbsence: String, Codable, Sendable {
    case tombstoned
    case superseded
    case unsupported

    var resurrects: Bool { self != .unsupported }
}

enum NativeMemoryGateValue: Decodable, Equatable, Sendable {
    case count(Int)
    case choice(String)
    case flag(Bool)
    case none

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .none }
        else if let flag = try? container.decode(Bool.self) { self = .flag(flag) }
        else if let count = try? container.decode(Int.self) { self = .count(count) }
        else if let choice = try? container.decode(String.self) { self = .choice(choice) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported answer value") }
    }

    var json: String {
        switch self {
        case .count(let value): "\(value)"
        case .choice(let value): String(decoding: (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
        case .flag(let value): value ? "true" : "false"
        case .none: "null"
        }
    }
}

enum NativeMemoryGateFieldKind: Sendable {
    case count
    case choice([String])
    case flag

    func accepts(_ value: NativeMemoryGateValue) -> Bool {
        switch (self, value) {
        case (.count, .count), (.count, .none), (.flag, .flag): true
        case (.choice(let options), .choice(let picked)): options.contains(picked)
        default: false
        }
    }

    var describe: String {
        switch self {
        case .count: "a whole number, or null if you do not know"
        case .choice(let options): "one of " + options.map { "\"\($0)\"" }.joined(separator: ", ")
        case .flag: "true or false"
        }
    }
}

struct NativeMemoryGateField: Sendable {
    let name: String
    let kind: NativeMemoryGateFieldKind
    let expected: NativeMemoryGateValue
    var fabricated: NativeMemoryGateValue? = nil
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
    case compact(chat: String, turns: Int)
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
    let fields: [NativeMemoryGateField]
    let expectation: NativeMemoryGateExpectation

    var question: String {
        query + " Reply with only a JSON object with these fields: "
            + fields.map { "\($0.name) (\($0.kind.describe))" }.joined(separator: "; ") + "."
    }

    var expectedAnswer: String {
        "{" + fields.map { "\"\($0.name)\": \($0.expected.json)" }.joined(separator: ", ") + "}"
    }
}

struct NativeMemoryGateCounts: Codable, Equatable, Sendable {
    var falseRetrievals = 0
    var unnecessaryInsertions = 0
    var resurrections = 0
    var staleFactErrors = 0
    var fabricatedCompletions = 0
    var citationErrors = 0
    var missedRecalls = 0
    var unparsedReplies = 0

    var errors: Int {
        falseRetrievals + unnecessaryInsertions + resurrections + staleFactErrors
            + fabricatedCompletions + citationErrors + missedRecalls + unparsedReplies
    }

    static func + (left: Self, right: Self) -> Self {
        NativeMemoryGateCounts(
            falseRetrievals: left.falseRetrievals + right.falseRetrievals,
            unnecessaryInsertions: left.unnecessaryInsertions + right.unnecessaryInsertions,
            resurrections: left.resurrections + right.resurrections,
            staleFactErrors: left.staleFactErrors + right.staleFactErrors,
            fabricatedCompletions: left.fabricatedCompletions + right.fabricatedCompletions,
            citationErrors: left.citationErrors + right.citationErrors,
            missedRecalls: left.missedRecalls + right.missedRecalls,
            unparsedReplies: left.unparsedReplies + right.unparsedReplies)
    }
}

enum NativeMemoryGateFailure: String, Codable, Sendable {
    case requestFailed = "request failed"
    case replyTimedOut = "reply timed out"
    case setupFailed = "setup failed"
}

struct NativeMemoryGateScenarioResult: Codable, Equatable, Sendable {
    let id: String
    let counts: NativeMemoryGateCounts
    let observations: Int
    let elapsedMilliseconds: Int
    let retrievalMilliseconds: Int
    var failed: NativeMemoryGateFailure? = nil
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
            "| Scenario | Status | False retrievals | Unnecessary insertions | Resurrections | Stale facts | Fabricated completions | Citation errors | Missed recalls | Unparsed replies | Turns | Elapsed ms | Retrieval ms |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|---|",
        ]
        func row(_ name: String, _ status: String, _ counts: NativeMemoryGateCounts, _ turns: String, _ elapsed: String, _ retrieval: String) -> String {
            "| \(name) | \(status) | \(counts.falseRetrievals) | \(counts.unnecessaryInsertions) | \(counts.resurrections) | \(counts.staleFactErrors) | \(counts.fabricatedCompletions) | \(counts.citationErrors) | \(counts.missedRecalls) | \(counts.unparsedReplies) | \(turns) | \(elapsed) | \(retrieval) |"
        }
        for result in scenarios {
            lines.append(row(result.id, result.failed?.rawValue ?? "scored", result.counts, "\(result.observations)", "\(result.elapsedMilliseconds)", "\(result.retrievalMilliseconds)"))
        }
        lines.append(row("Total", "", totals, "\(scenarios.reduce(0) { $0 + $1.observations })", "\(elapsedMilliseconds)", ""))
        lines.append("")
        lines.append("Elapsed \(elapsedMilliseconds) ms against a declared budget of \(budgetMilliseconds) ms.")
        return lines.joined(separator: "\n") + "\n"
    }
}

final class NativeMemoryGateCapture: NativeChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let inner: any NativeChatTransport
    private var captured: [[NativeChatMessage]] = []
    private var thrown: Error?

    init(_ inner: any NativeChatTransport) { self.inner = inner }

    var histories: [[NativeChatMessage]] { lock.withLock { captured } }
    var lastError: Error? { lock.withLock { thrown } }

    func discoverModels() async throws -> [String] { try await inner.discoverModels() }

    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        lock.withLock { captured.append(messages) }
        return relay(inner.stream(messages: messages, model: model, tools: tools))
    }

    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema],
                validateRequest: @escaping @Sendable () async throws -> Void) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        lock.withLock { captured.append(messages) }
        return relay(inner.stream(messages: messages, model: model, tools: tools, validateRequest: validateRequest))
    }

    private func relay(_ source: AsyncThrowingStream<NativeChatStreamSnapshot, Error>) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await snapshot in source { continuation.yield(snapshot) }
                    continuation.finish()
                } catch {
                    self.lock.withLock { self.thrown = error }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class NativeMemoryGateCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func count(_ id: String) -> Int { lock.withLock { counts[id] ?? 0 } }
    func next(_ id: String) -> Int {
        lock.withLock {
            counts[id, default: 0] += 1
            return counts[id] ?? 0
        }
    }
}

private final class NativeMemoryGateScriptedTransport: NativeChatTransport, @unchecked Sendable {
    let reply: String?

    init(reply: String?) { self.reply = reply }

    func discoverModels() async throws -> [String] { ["fixture-model"] }

    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        let reply = reply
        return AsyncThrowingStream { continuation in
            guard let reply else {
                continuation.finish(throwing: NativeChatClient.ClientError.server("fixture transport failure"))
                return
            }
            continuation.yield(NativeChatStreamSnapshot(content: reply, toolCalls: [], finishReason: "stop"))
            continuation.finish()
        }
    }
}

enum NativeMemoryGateFixtureReply: Sendable {
    case answer
    case artifact
    case prose
    case failure
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
    var tolerant: Bool { get }
    var announces: Bool { get }
    var pause: Duration { get }
    func transport(scenario: NativeMemoryGateScenario) -> any NativeChatTransport
}

struct NativeMemoryGateFixtureDriver: NativeMemoryGateDriver {
    let mode = "fixture"
    var contextCeiling: Int? = NativeMemoryGate.contextCeiling
    var reply = NativeMemoryGateFixtureReply.answer
    var tolerant = false
    var failingScenario: String?
    var failingCalls: [String: Set<Int>] = [:]
    let calls = NativeMemoryGateCalls()
    let announces = false
    let pause: Duration = .zero
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

    func transport(scenario: NativeMemoryGateScenario) -> any NativeChatTransport {
        let answer = scenario.expectedAnswer
        let call = calls.next(scenario.id)
        if scenario.id == failingScenario || failingCalls[scenario.id]?.contains(call) == true {
            return NativeMemoryGateScriptedTransport(reply: nil)
        }
        return switch reply {
        case .answer: NativeMemoryGateScriptedTransport(reply: answer)
        case .artifact: NativeMemoryGateScriptedTransport(reply: NativeMemoryGate.fixtureArtifact + "\n" + answer)
        case .prose: NativeMemoryGateScriptedTransport(reply: "Native reply")
        case .failure: NativeMemoryGateScriptedTransport(reply: nil)
        }
    }
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
    let tolerant = true
    let announces = true
    let pause: Duration = .seconds(NativeMemoryGate.livePauseSeconds)

    func transport(scenario: NativeMemoryGateScenario) -> any NativeChatTransport { NativeChatClient.foreground(config: chatConfig) }
}

struct NativeMemoryGateEntry: Sendable {
    let id: String?
    let marker: Int?
}

struct NativeMemoryGateObservation: Sendable {
    var entries: [NativeMemoryGateEntry]
    var contextLines: [String]
    var answer: [String: NativeMemoryGateValue]?
    var retrievalMilliseconds: Int

    var recalled: [String] { entries.compactMap(\.id) }
    var unmatchedLines: Int { entries.filter { $0.id == nil }.count }
}

enum NativeMemoryGateError: LocalizedError {
    case setup(String, String)
    case request(String, String, NativeMemoryGateFailure)
    var errorDescription: String? {
        switch self {
        case .setup(let scenario, let reason), .request(let scenario, let reason, _): "Scenario \(scenario) could not run: \(reason)"
        }
    }

    var failure: NativeMemoryGateFailure {
        switch self {
        case .setup: .setupFailed
        case .request(_, _, let kind): kind
        }
    }
}

@MainActor
enum NativeMemoryGate {
    static let fixtureBudgetMilliseconds = 20_000
    static let liveBudgetMilliseconds = 1_800_000
    static let livePauseSeconds = 2
    static let diagnosticLimit = 200
    static let contextCeiling = 2_000
    static let bank = "household"
    static let contextStart = "USER-APPROVED MEMORY CONTEXT"
    static let contextEnd = "END USER-APPROVED MEMORY CONTEXT"
    static let reportFieldLimit = 96
    static let reportFieldCharacters = [("a", "z"), ("A", "Z"), ("0", "9")].reduce(CharacterSet(charactersIn: ".-_:/")) { set, bounds in
        set.union(CharacterSet(charactersIn: Unicode.Scalar(bounds.0)...Unicode.Scalar(bounds.1)))
    }
    static let fixtureArtifact = ":::vera-artifact id=\"gate-note\" title=\"Gate note\" type=\"markdown\"\n# Gate note\n:::"

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
            fields: [
                NativeMemoryGateField(name: "current_count", kind: .count, expected: .count(10)),
                NativeMemoryGateField(name: "care_status", kind: .choice(["planned", "completed", "unknown"]),
                                      expected: .choice("planned"), fabricated: .choice("completed")),
            ],
            expectation: NativeMemoryGateExpectation(
                recalled: ["stock", "care", "loss"], required: ["ten hens", "planned for friday, not completed", "two hens left"],
                absent: ["stock-old": .superseded], decisiveSource: "correction", stalePhrases: ["twelve hens"],
                qualified: [NativeMemoryGateQualifiedFact(subject: "vaccination", qualifier: "not completed")])),
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
            fields: [NativeMemoryGateField(name: "tea_style", kind: .choice(["black", "with milk", "unknown"]), expected: .choice("black"))],
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
            fields: [NativeMemoryGateField(name: "task_status", kind: .choice(["unfinished", "done", "unknown"]),
                                           expected: .choice("unfinished"), fabricated: .choice("done"))],
            expectation: NativeMemoryGateExpectation(
                recalled: ["shed"], required: ["unfinished"], decisiveSource: "task",
                qualified: [NativeMemoryGateQualifiedFact(subject: "shed", qualifier: "unfinished")])),
        NativeMemoryGateScenario(
            id: "failed-approach",
            steps: [
                .say(chat: "garden", label: "attempt", text: "I tried copper tape around the beds to stop slugs and it did not work.",
                     remember: NativeMemoryGateFact(id: "slugs", title: "Slug control attempt", details: ["Copper tape around the beds failed to stop slugs; it did not work."])),
                .restart,
            ],
            query: "What should I use to stop slugs in the beds?",
            fields: [NativeMemoryGateField(name: "copper_tape_outcome", kind: .choice(["failed", "worked", "unknown"]),
                                           expected: .choice("failed"), fabricated: .choice("worked"))],
            expectation: NativeMemoryGateExpectation(
                recalled: ["slugs"], required: ["did not work"], decisiveSource: "attempt",
                qualified: [NativeMemoryGateQualifiedFact(subject: "copper tape", qualifier: "did not work")])),
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
            fields: [NativeMemoryGateField(name: "bicycle_location", kind: .choice(["hallway", "garage", "unknown"]), expected: .choice("hallway"))],
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
            fields: [NativeMemoryGateField(name: "hose_location", kind: .choice(["tool shed", "back door", "unknown"]), expected: .choice("tool shed"))],
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
            fields: [NativeMemoryGateField(name: "attachment_content_known", kind: .flag, expected: .flag(false), fabricated: .flag(true))],
            expectation: NativeMemoryGateExpectation(
                recalled: ["coop"], required: ["not available"], decisiveSource: "photo",
                qualified: [NativeMemoryGateQualifiedFact(subject: "coop layout", qualifier: "not available")])),
        NativeMemoryGateScenario(
            id: "repeated-compaction",
            steps: [
                .say(chat: "geese-a", label: "count", text: "We keep eleven geese.",
                     remember: NativeMemoryGateFact(id: "geese-old", title: "Geese count", details: ["The household keeps eleven geese"], category: .project)),
                .correct(target: "geese-old", chat: "geese-long", label: "correction", text: "Correction: we keep nine geese.",
                         replacement: NativeMemoryGateFact(id: "geese", title: "Geese count", details: ["The household keeps nine geese"], category: .project)),
                .compact(chat: "geese-long", turns: 40),
                .compact(chat: "geese-long", turns: 40),
                .restart,
                .compact(chat: "geese-long", turns: 40),
                .restart,
            ],
            query: "How many geese do we keep?",
            fields: [NativeMemoryGateField(name: "geese_count", kind: .count, expected: .count(9))],
            expectation: NativeMemoryGateExpectation(
                recalled: ["geese"], required: ["nine geese"], absent: ["geese-old": .superseded],
                decisiveSource: "correction", stalePhrases: ["eleven geese"])),
    ]

    static func run(driver: any NativeMemoryGateDriver, sabotage: Bool = false, mode: String? = nil) async throws -> NativeMemoryGateReport {
        let started = ContinuousClock.now
        var results: [NativeMemoryGateScenarioResult] = []
        for (index, scenario) in scenarios.enumerated() {
            if index > 0, driver.pause > .zero { try await Task.sleep(for: driver.pause) }
            results.append(try await attempt(scenario, driver: driver, sabotage: sabotage))
        }
        let elapsed = milliseconds(started.duration(to: .now))
        let totals = results.reduce(NativeMemoryGateCounts()) { $0 + $1.counts }
        let passed = driver.tolerant
            ? results.allSatisfy { $0.failed == nil } && totals.resurrections == 0 && totals.fabricatedCompletions == 0
            : totals.errors == 0 && elapsed <= driver.budgetMilliseconds
        return report(mode: mode ?? driver.mode, model: driver.chatConfig.model, endpointHost: driver.chatConfig.baseURL.host ?? "",
                      memoryEndpointHost: driver.memoryEndpointHost, scenarios: results, elapsed: elapsed,
                      budget: driver.budgetMilliseconds, passed: passed)
    }

    static func attempt(_ scenario: NativeMemoryGateScenario, driver: any NativeMemoryGateDriver,
                        sabotage: Bool) async throws -> NativeMemoryGateScenarioResult {
        do {
            return try await NativeMemoryGateRunner(scenario: scenario, driver: driver, sabotage: sabotage).run().result
        } catch {
            guard driver.tolerant else { throw error }
            announce(scenario.id, error: error, diagnostic: nil, announces: driver.announces)
            return NativeMemoryGateScenarioResult(id: scenario.id, counts: NativeMemoryGateCounts(), observations: 0,
                                                  elapsedMilliseconds: 0, retrievalMilliseconds: 0, failed: .setupFailed)
        }
    }

    static func announce(_ id: String, error: Error, diagnostic: String?, announces: Bool) {
        guard announces else { return }
        print(consoleLine(id, error: error, diagnostic: diagnostic))
    }

    static func consoleLine(_ id: String, error: Error, diagnostic: String?) -> String {
        let failure = (error as? NativeMemoryGateError)?.failure ?? .setupFailed
        let detail = diagnostic.map { " Provider said: " + $0 } ?? ""
        return "memory-gate: \(id): \(failure.rawValue). " + NativeDiagnosticRedaction.console(error.localizedDescription) + "." + detail
    }

    static func diagnostic(_ error: Error) -> String {
        let text: String = switch error as? NativeChatClient.ClientError {
        case .http(let status, let detail)?: "HTTP \(status): " + NativeDiagnosticRedaction.console(detail)
        case .provider(_, let raw)?: "provider error " + NativeDiagnosticRedaction.console(raw)
        default: NativeDiagnosticRedaction.console(error.localizedDescription)
        }
        return String(text.prefix(diagnosticLimit + 32))
    }

    static func write(_ report: NativeMemoryGateReport, to directory: URL) throws -> (json: URL, markdown: URL) {
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
        return (json, markdown)
    }

    static func exitStatus(_ report: NativeMemoryGateReport) -> Int32 { report.passed ? 0 : 1 }

    static func summary(_ report: NativeMemoryGateReport) -> String {
        let totals = report.totals
        let failed = report.scenarios.compactMap { result in result.failed.map { "\(result.id) (\($0.rawValue))" } }
        return "memory-gate: \(report.passed ? "PASS" : "FAIL") live run with \(report.model): resurrections \(totals.resurrections), fabricated completions \(totals.fabricatedCompletions), false retrievals \(totals.falseRetrievals), unnecessary insertions \(totals.unnecessaryInsertions), stale facts \(totals.staleFactErrors), citation errors \(totals.citationErrors), missed recalls \(totals.missedRecalls), unparsed replies \(totals.unparsedReplies), \(report.elapsedMilliseconds) ms"
            + (failed.isEmpty ? "" : "; could not run: " + failed.joined(separator: ", "))
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
        for scenario in scenarios where !scenario.expectation.absent.isEmpty {
            let counts = try await NativeMemoryGateRunner(scenario: scenario, driver: driver, sabotage: true).run().result.counts
            let revivable = scenario.expectation.absent.values.contains { $0.resurrects }
            guard counts.errors > 0, revivable ? counts.resurrections > 0 : counts.unnecessaryInsertions > 0 else {
                throw NativeMemoryGateError.setup("sabotage", "broken retrieval was not caught in \(scenario.id) on its own")
            }
        }
        let unfinished = scenarios.first { $0.id == "unfinished-task" }!
        for (reply, refusal) in [(NativeMemoryGateFixtureReply.failure, "did not complete"), (.prose, "the model answer did not parse")] {
            var refusing = driver
            refusing.reply = reply
            do {
                _ = try await NativeMemoryGateRunner(scenario: unfinished, driver: refusing, sabotage: false).run()
                throw NativeMemoryGateError.setup("refusal", "a reply that should be refused was scored")
            } catch let error as NativeMemoryGateError where error.localizedDescription.contains("Scenario \(unfinished.id) ") && error.localizedDescription.contains(refusal) { }
        }
        try await artifactCheck(driver, scenario: unfinished)
        try await liveShapedCheck()
        try redactionChecks()
        try await retryScopeCheck()
        driver.contextCeiling = nil
        let compaction = scenarios.first { $0.id == "repeated-compaction" }!
        do {
            _ = try await NativeMemoryGateRunner(scenario: compaction, driver: driver, sabotage: false).run()
            throw NativeMemoryGateError.setup("compaction", "a long chat without a context ceiling was accepted as folded")
        } catch NativeMemoryGateError.setup(let id, let reason) where id == compaction.id && reason.contains("sent without folding") { }
        print("memory-gate: PASS (\(scenarios.count) scenarios clean in \(clean.elapsedMilliseconds) ms of \(fixtureBudgetMilliseconds) ms; broken retrieval reached the request and was caught with \(broken.totals.resurrections) resurrections; each sabotaged scenario failed on its own; failed, unparsed and unfolded replies refused; a live-shaped run recorded its failed scenario, retried only the failed request, kept earlier observations and wrote its report; provider errors redacted; artifacts stayed in the run directory; report carries ids and counts only)")
    }

    static func liveShapedCheck() async throws {
        let failing = "stale-preference"
        var driver = NativeMemoryGateFixtureDriver()
        driver.tolerant = true
        driver.failingScenario = failing
        let report = try await run(driver: driver, mode: "live-shaped fixture")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vera-memory-gate-report-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try write(report, to: directory)
        let written = try JSONDecoder().decode(NativeMemoryGateReport.self, from: Data(contentsOf: files.json))
        let markdown = try String(contentsOf: files.markdown, encoding: .utf8)
        let raw = (try String(contentsOf: files.json, encoding: .utf8)) + markdown
        let others = written.scenarios.filter { $0.id != failing }
        guard written.scenarios.count == scenarios.count,
              written.scenarios.first(where: { $0.id == failing })?.failed == .requestFailed,
              others.allSatisfy({ $0.failed == nil && $0.observations > 0 && $0.counts.errors == 0 }),
              exitStatus(written) == 1, !written.passed, driver.calls.count(failing) == 2,
              markdown.contains("| \(failing) | request failed |"), !raw.contains("fixture transport failure"),
              summary(written).contains("could not run: \(failing) (request failed)") else {
            throw NativeMemoryGateError.setup("live-shaped", "a scenario that could not run was not recorded, retried once and written to the report")
        }
        let probe = try NativeMemoryGateRunner(scenario: scenarios.first { $0.id == failing }!, driver: driver, sabotage: false)
        do { _ = try await probe.run() } catch { }
        let provider = NativeChatClient.ClientError.provider(["message": "Provider returned error", "code": 429, "metadata": ["raw": "upstream rate limit"]])
        let providerDetail = diagnostic(provider)
        guard probe.diagnostic == "fixture transport failure", provider.localizedDescription == "Provider returned error",
              providerDetail.contains("429"), providerDetail.contains("upstream rate limit"),
              diagnostic(NativeChatClient.ClientError.http(503, String(repeating: "x ", count: 500))).count <= diagnosticLimit + 32 else {
            throw NativeMemoryGateError.setup("live-shaped", "the provider error was not kept for the console")
        }
        var strict = NativeMemoryGateFixtureDriver()
        strict.failingScenario = failing
        do {
            _ = try await run(driver: strict)
            throw NativeMemoryGateError.setup("live-shaped", "fixture mode accepted a scenario that could not run")
        } catch NativeMemoryGateError.request(let id, _, .requestFailed) where id == failing { }
    }

    static func redactionChecks() throws {
        let secret = "sk-live-0123456789abcdefABCDEF"
        let echoed = NativeChatClient.ClientError.provider(["message": "Rate limited", "code": 429, "metadata": ["api_key": secret]])
        let nested = NativeChatClient.ClientError.provider(["message": "Upstream refused", "metadata": [
            "attempts": [["session_token": "short-value", "headers": ["Authorization": "Basic short"]]], "provider_name": "fixture"]])
        let inline = NativeChatClient.ClientError.provider(["message": "Invalid key \(secret) and Bearer abc.def-ghi supplied"])
        let ordinary = "Provider returned error: rate limit exceeded, try again in 20 seconds"
        let longModel = "vendor/name-2025-preview-instruct"
        let modelMessage = "model \(longModel) is not available"
        let longRun = String(repeating: "q7Z", count: 10)
        let printed = [echoed, nested, inline].map { error in
            consoleLine("probe", error: NativeMemoryGateError.request("probe", error.localizedDescription, .requestFailed), diagnostic: diagnostic(error))
        }
        guard !printed.contains(where: { $0.contains(secret) || $0.contains("short-value") || $0.contains("Basic short") || $0.contains("abc.def-ghi") }),
              printed[0].contains("429"), printed[0].contains("Rate limited"), printed[1].contains("provider_name"),
              printed[2].contains("Invalid key"), printed.allSatisfy({ $0.contains(NativeDiagnosticRedaction.placeholder) }),
              NativeDiagnosticRedaction.text(ordinary) == ordinary, NativeDiagnosticRedaction.console(ordinary) == ordinary,
              NativeChatClient.ClientError.provider(["message": modelMessage]).localizedDescription == modelMessage,
              !consoleLine("probe", error: NativeMemoryGateError.request("probe", modelMessage, .requestFailed), diagnostic: nil).contains(longModel),
              NativeDiagnosticRedaction.console("opaque " + longRun).contains(NativeDiagnosticRedaction.placeholder),
              NativeChatClient.ClientError.provider(["message": "Provider returned error", "code": 429]).localizedDescription == "Provider returned error" else {
            throw NativeMemoryGateError.setup("redaction", "a credential reached the console or an ordinary message was changed")
        }
    }

    static func retryScopeCheck() async throws {
        let compaction = scenarios.first { $0.id == "repeated-compaction" }!
        var flaky = NativeMemoryGateFixtureDriver()
        flaky.tolerant = true
        flaky.failingCalls = [compaction.id: [3]]
        let report = try await run(driver: flaky, sabotage: true, mode: "live-shaped fixture with broken retrieval")
        let recovered = report.scenarios.first { $0.id == compaction.id }
        guard let recovered, recovered.failed == nil, recovered.observations == 4, recovered.counts.resurrections == 4,
              flaky.calls.count(compaction.id) == 5, !report.passed, exitStatus(report) == 1 else {
            throw NativeMemoryGateError.setup("retry", "a retried request lost the observations made before it")
        }
        var broken = NativeMemoryGateFixtureDriver()
        broken.tolerant = true
        broken.failingCalls = [compaction.id: [3, 4]]
        let partial = try await NativeMemoryGateRunner(scenario: compaction, driver: broken, sabotage: true).run()
        guard partial.result.failed == .requestFailed, partial.result.observations == 2, partial.result.counts.resurrections == 2,
              partial.observations.first?.recalled.contains("geese-old") == true else {
            throw NativeMemoryGateError.setup("retry", "a scenario that failed partway dropped the resurrections it had already seen")
        }
    }

    static func artifactCheck(_ base: NativeMemoryGateFixtureDriver, scenario: NativeMemoryGateScenario) async throws {
        func listing() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: NativeAttachmentStore.standardDirectory.path)) ?? [])
        }
        var driver = base
        driver.reply = .artifact
        let before = listing()
        let run = try await NativeMemoryGateRunner(scenario: scenario, driver: driver, sabotage: false).run()
        guard run.artifactFiles > 0 else {
            throw NativeMemoryGateError.setup("artifacts", "the artifact reply did not produce a file inside the run directory")
        }
        guard listing() == before else {
            throw NativeMemoryGateError.setup("artifacts", "a gate run wrote outside its own directory")
        }
    }

    static func scoringChecks() throws {
        let livestock = scenarios[0]
        let expectation = livestock.expectation
        let completed = NativeMemoryGateObservation(
            entries: [NativeMemoryGateEntry(id: "care", marker: citationOffset), NativeMemoryGateEntry(id: "loss", marker: citationOffset + 1)],
            contextLines: ["- Planned livestock care: Livestock vaccination is planned for Friday. [10001]"],
            answer: parseAnswer("{\"current_count\": 12, \"care_status\": \"completed\"}", fields: livestock.fields),
            retrievalMilliseconds: 0)
        let counts = score(completed, expectation: expectation, fields: livestock.fields, sources: ["care": "chat-a"], decisive: "chat-b")
        guard counts.fabricatedCompletions == 2, counts.staleFactErrors == 1, counts.citationErrors == 1,
              counts.missedRecalls == 4, counts.falseRetrievals == 0, counts.unparsedReplies == 0 else {
            throw NativeMemoryGateError.setup("scoring", "a completed claim, a stale count, a missing qualifier, a missing phrase or a missing citation went uncounted")
        }
        let unparsed = NativeMemoryGateObservation(entries: [], contextLines: [], answer: nil, retrievalMilliseconds: 0)
        guard score(unparsed, expectation: expectation, fields: livestock.fields, sources: [:], decisive: nil).unparsedReplies == 1 else {
            throw NativeMemoryGateError.setup("scoring", "an unparsed reply was not counted")
        }
        let fields = livestock.fields
        let accepted = [
            "{\"current_count\": 10, \"care_status\": \"planned\"}",
            "Here you go: {\"care_status\": \"planned\", \"current_count\": null, \"note\": \"a } brace\"} and more {text}",
        ]
        let refused = [
            "Native reply", "{\"current_count\": 10}", "{\"current_count\": 10, \"care_status\": \"vaccinated\"}",
            "{\"current_count\": 10.5, \"care_status\": \"planned\"}", "{\"current_count\": \"ten\", \"care_status\": \"planned\"}",
            "{\"current_count\": 10, \"care_status\": \"planned\"", "{\"current_count\": 10, \"care_status\": {\"value\": \"planned\"}}",
        ]
        guard accepted.allSatisfy({ parseAnswer($0, fields: fields) != nil }), refused.allSatisfy({ parseAnswer($0, fields: fields) == nil }) else {
            throw NativeMemoryGateError.setup("scoring", "structured answers were not parsed strictly")
        }
        let sources = ["stock": "correction", "care": "care", "loss": "loss"]
        func cited(_ markers: [Int?]) -> Int {
            let entries = zip(["stock", "care", "loss"], markers).map { NativeMemoryGateEntry(id: $0.0, marker: $0.1) }
            let observation = NativeMemoryGateObservation(entries: entries, contextLines: [], answer: [:], retrievalMilliseconds: 0)
            return score(observation, expectation: expectation, fields: [], sources: sources, decisive: "correction").citationErrors
        }
        let first = citationOffset
        guard cited([first, first + 1, first + 2]) == 0, cited([nil, first + 1, first + 2]) == 1,
              cited([99_999, first + 1, first + 2]) == 1, cited([first + 1, first, first + 2]) == 1 else {
            throw NativeMemoryGateError.setup("scoring", "a missing, wrong or swapped citation number was not counted")
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
            scenario.steps.flatMap(phrases) + scenario.expectation.stalePhrases + [scenario.query]
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
            let files = try write(report, to: directory)
            print(summary(report))
            print("memory-gate: report written to \(files.json.path) and \(files.markdown.path)")
            return exitStatus(report)
        } catch {
            print("memory-gate: FAIL \(error.localizedDescription)")
            return 1
        }
    }

    static func score(_ observation: NativeMemoryGateObservation, expectation: NativeMemoryGateExpectation,
                      fields: [NativeMemoryGateField], sources: [String: String], decisive: String?) -> NativeMemoryGateCounts {
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
            for line in observation.contextLines.map({ $0.lowercased() }) where line.contains(fact.subject.lowercased()) {
                if !line.contains(fact.qualifier.lowercased()) { counts.fabricatedCompletions += 1 }
            }
        }
        if let answer = observation.answer {
            for field in fields {
                guard let value = answer[field.name], value != field.expected else { continue }
                if let fabricated = field.fabricated, value == fabricated { counts.fabricatedCompletions += 1 } else { counts.staleFactErrors += 1 }
            }
        } else {
            counts.unparsedReplies = 1
        }
        if let decisive {
            let lines = observation.entries.enumerated().filter { $0.element.id.map { sources[$0] == decisive } ?? false }
            if lines.isEmpty || lines.contains(where: { $0.element.marker != citationOffset + $0.offset }) { counts.citationErrors = 1 }
        }
        return counts
    }

    static func firstJSONObject(_ text: String) -> Substring? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var quoted = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if quoted {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return text[start...index] }
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func parseAnswer(_ reply: String, fields: [NativeMemoryGateField]) -> [String: NativeMemoryGateValue]? {
        guard let raw = firstJSONObject(reply),
              let object = try? JSONDecoder().decode([String: NativeMemoryGateValue].self, from: Data(raw.utf8)) else { return nil }
        for field in fields {
            guard let value = object[field.name], field.kind.accepts(value) else { return nil }
        }
        return object
    }

    static var citationOffset: Int { NativeMemoryCitation.offset }

    static func citationMarker(_ line: String) -> Int? {
        guard let range = line.range(of: #"\[(\d+)\]$"#, options: .regularExpression) else { return nil }
        return Int(line[range].dropFirst().dropLast())
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
        case .compact, .deleteConversation, .excludeConversation, .removeMemory, .restart: []
        }
    }
}

@MainActor
private final class NativeMemoryGateRunner {
    let scenario: NativeMemoryGateScenario
    let driver: any NativeMemoryGateDriver
    let sabotage: Bool
    let directory: URL
    let artifacts: URL
    var repository: LocalChatRepository
    var ledger: [String: NativeMemoryRecord] = [:]
    var messageIDs: [String: String] = [:]
    var observations: [NativeMemoryGateObservation] = []
    var artifactFiles = 0
    var diagnostic: String?
    var clock = Date()

    init(scenario: NativeMemoryGateScenario, driver: any NativeMemoryGateDriver, sabotage: Bool) throws {
        self.scenario = scenario
        self.driver = driver
        self.sabotage = sabotage
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vera-memory-gate-" + UUID().uuidString)
        artifacts = directory.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        repository = try LocalChatRepository(url: directory.appendingPathComponent("gate.sqlite"), artifactDirectory: artifacts)
    }

    func run() async throws -> (result: NativeMemoryGateScenarioResult, observations: [NativeMemoryGateObservation], artifactFiles: Int) {
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = ContinuousClock.now
        var failed: NativeMemoryGateFailure?
        do {
            for step in scenario.steps { try await apply(step) }
            try await ask(nil)
        } catch {
            guard driver.tolerant else { throw error }
            NativeMemoryGate.announce(scenario.id, error: error, diagnostic: diagnostic, announces: driver.announces)
            failed = (error as? NativeMemoryGateError)?.failure ?? .setupFailed
        }
        let sources = ledger.compactMapValues(\.sourceMessageID)
        let decisive = scenario.expectation.decisiveSource.flatMap { messageIDs[$0] }
        if failed == nil, scenario.expectation.decisiveSource != nil, decisive == nil { throw failure("decisive source was never said") }
        let counts = observations.reduce(NativeMemoryGateCounts()) {
            $0 + NativeMemoryGate.score($1, expectation: scenario.expectation, fields: scenario.fields, sources: sources, decisive: decisive)
        }
        let result = NativeMemoryGateScenarioResult(
            id: scenario.id, counts: counts, observations: observations.count,
            elapsedMilliseconds: NativeMemoryGate.milliseconds(started.duration(to: .now)),
            retrievalMilliseconds: observations.map(\.retrievalMilliseconds).max() ?? 0, failed: failed)
        return (result, observations, artifactFiles)
    }

    private func failure(_ reason: String) -> NativeMemoryGateError { .setup(scenario.id, reason) }

    private func requestFailure(_ reason: String, _ kind: NativeMemoryGateFailure = .requestFailed) -> NativeMemoryGateError {
        .request(scenario.id, reason, kind)
    }

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
        guard !NativeMemoryRetrieval.renderedLine(record).contains(where: \.isNewline) else {
            throw failure("record \(fact.id) renders to more than one line, which the block matcher does not support")
        }
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
        case .compact(let chat, let turns):
            var ordinal = try repository.messages(conversationID: chat).count
            for index in 0..<turns {
                try repository.saveMessage(Message(role: .user, text: "Filler turn \(index): the weather stayed mild today and the garden path was swept again before lunch.", createdAt: tick()),
                                           conversationID: chat, ordinal: ordinal)
                try repository.saveMessage(Message(role: .assistant, text: "Noted, mild weather and a swept path for turn \(index).", createdAt: tick()),
                                           conversationID: chat, ordinal: ordinal + 1)
                ordinal += 2
            }
            let stored = try repository.messages(conversationID: chat).count
            let sent = try await ask(chat)
            guard sent * 2 <= stored + 1 else { throw failure("the long chat was sent without folding (\(sent) of \(stored + 1) messages)") }
            guard driver.tolerant || sent > 2 else { throw failure("folding dropped every earlier turn (\(sent) of \(stored + 1) messages)") }
        case .restart:
            repository = try LocalChatRepository(url: directory.appendingPathComponent("gate.sqlite"), artifactDirectory: artifacts)
        }
    }

    private func resurrections() -> [NativeMemoryRanked] {
        scenario.expectation.absent.sorted { $0.key < $1.key }.compactMap { id, _ in
            guard let record = ledger[id] else { return nil }
            return NativeMemoryRanked(record: record, score: 0)
        }
    }

    @discardableResult
    private func ask(_ chat: String?) async throws -> Int {
        do {
            return try await askOnce(chat)
        } catch let error as NativeMemoryGateError where driver.tolerant && error.failure != .setupFailed {
            NativeMemoryGate.announce(scenario.id, error: error, diagnostic: diagnostic, announces: driver.announces)
            if driver.pause > .zero { try await Task.sleep(for: driver.pause) }
            if driver.announces { print("memory-gate: \(scenario.id): retried once") }
            return try await askOnce(chat)
        }
    }

    private func askOnce(_ chat: String?) async throws -> Int {
        diagnostic = nil
        let capture = NativeMemoryGateCapture(driver.transport(scenario: scenario))
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
        guard let conversation = store.selectedID, store.sendText(scenario.question) else { throw failure("the query could not be sent") }
        let finished = try await wait(driver.replyTimeout) {
            guard !store.generating, let last = store.conversations.first(where: { $0.id == conversation })?.messages.last else { return false }
            return last.role == .assistant && last.state != .streaming
        }
        diagnostic = capture.lastError.map(NativeMemoryGate.diagnostic)
        guard finished else { throw requestFailure("the reply did not finish", .replyTimedOut) }
        artifactFiles = max(artifactFiles, ((try? FileManager.default.contentsOfDirectory(atPath: artifacts.path)) ?? []).count)
        guard let history = capture.histories.last else { throw requestFailure("no request reached the transport") }
        let prompt = history.first(where: { $0.role == "system" })?.content ?? ""
        let reply = store.conversations.first(where: { $0.id == conversation })?.messages.last
        guard let reply, reply.role == .assistant else { throw failure("no reply was saved") }
        guard reply.state == .complete, reply.failure == nil, !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw requestFailure("the model request did not complete (\(reply.failure ?? "empty answer"))")
        }
        let answer = NativeMemoryGate.parseAnswer(reply.text, fields: scenario.fields)
        if answer == nil, !driver.tolerant { throw failure("the model answer did not parse") }
        let lines = NativeMemoryGate.memoryContextLines(prompt)
        let rendered = ledger.mapValues { NativeMemoryGate.uncited(NativeMemoryRetrieval.renderedLine($0)) }
        let entries = lines.map { line in
            let text = NativeMemoryGate.uncited(line)
            return NativeMemoryGateEntry(id: rendered.first(where: { $0.value == text })?.key, marker: NativeMemoryGate.citationMarker(line))
        }
        observations.append(NativeMemoryGateObservation(
            entries: entries, contextLines: lines, answer: answer,
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
