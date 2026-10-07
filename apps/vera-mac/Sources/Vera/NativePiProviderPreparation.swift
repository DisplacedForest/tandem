import Foundation

enum PiTransportKind: String, Sendable {
    case mock = "app-owned-mock"
    case providerFixture = "app-owned-provider-fixture"
    case openRouter = "app-owned-openrouter"
    var isCloud: Bool { self == .openRouter }
}

struct PiCumulativeBudget: Sendable {
    let id: String
    let ownerBinding: String
    let otherTestSpend: Int64
    let priorProviderUsage: Int64
    let uncertaintyHolds: Int64
    let externalReservations: Int64
    let runAllowance: Int64
    let expires: Date
    init(id: String, ownerBinding: String, otherTestSpend: Int64, priorProviderUsage: Int64, uncertaintyHolds: Int64, externalReservations: Int64, runAllowance: Int64, expires: Date, exclusiveOwner: Bool, now: Date = Date()) throws {
        _ = try piUUID(.string(id))
        try piCheck(exclusiveOwner && ownerBinding.count == 64 && ownerBinding.allSatisfy { "0123456789abcdef".contains($0) } && expires > now && expires.timeIntervalSince(now) <= 600, .unauthorized)
        try piCheck([otherTestSpend, priorProviderUsage, uncertaintyHolds, externalReservations].allSatisfy { (0...200_000_000_000).contains($0) } && (1_000_000...1_000_000_000).contains(runAllowance), .budget)
        self.id = id; self.ownerBinding = ownerBinding; self.otherTestSpend = otherTestSpend
        self.priorProviderUsage = priorProviderUsage; self.uncertaintyHolds = uncertaintyHolds
        self.externalReservations = externalReservations; self.runAllowance = runAllowance; self.expires = expires
        _ = try baseline(observedProviderUsage: priorProviderUsage)
    }
    func validate(_ binding: PiSelectedProfileBinding, now: Date = Date()) throws {
        try piCheck(binding.digest == ownerBinding && now < expires, .unauthorized)
    }
    func baseline(observedProviderUsage: Int64) throws -> Int64 {
        try piCheck(observedProviderUsage >= priorProviderUsage && observedProviderUsage <= 200_000_000_000, .budget)
        let baseline = otherTestSpend + observedProviderUsage + uncertaintyHolds + externalReservations
        try piCheck(baseline <= 200_000_000_000 - runAllowance, .budget)
        return baseline
    }
    var digest: String {
        piHash(Data([id, ownerBinding, String(otherTestSpend), String(priorProviderUsage), String(uncertaintyHolds), String(externalReservations), String(runAllowance), String(expires.timeIntervalSince1970)].joined(separator: ":").utf8))
    }
}

enum PiProviderPreflight {
    static func amount(_ value: PiValue) throws -> Decimal {
        let text: String
        if let string = value.piString { text = string }
        else if case .number(let number) = value, number.isFinite { text = String(number) }
        else { throw PiBrokerError.invalid }
        guard text.count <= 80, text.range(of: #"^[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z"#, options: .regularExpression) != nil, let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !decimal.isNaN, decimal >= 0, decimal <= 200 else { throw PiBrokerError.invalid }
        return decimal
    }
    static func nanos(_ value: PiValue) throws -> Int64 {
        var amount = try amount(value) * 1_000_000_000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &amount, 0, .up)
        return NSDecimalNumber(decimal: rounded).int64Value
    }
    static func parse(_ data: Data, limit: Int) throws -> PiValue {
        try piCheck(data.count <= limit)
        try NativeTaskJSON.validate(data, maximumBytes: limit)
        return try PiValue.piDecode(JSONSerialization.jsonObject(with: data))
    }
    static func catalog(_ data: Data, model: String) throws {
        let value = try parse(data, limit: 8_000_000)
        guard let entries = value.pi("data").piArray else { throw PiBrokerError.invalid }
        let matching = entries.filter { $0.pi("id").piString == model }
        try piCheck(matching.count == 1)
        let selected = matching[0]
        try piCheck(selected.pi("alias_target") == .null && selected.pi("reasoning").pi("mandatory") == .bool(false))
        let supported = Set(selected.pi("supported_parameters").piArray?.compactMap(\.piString) ?? [])
        try piCheck(Set(["tools", "max_tokens", "reasoning"]).isSubset(of: supported))
        guard let fields = selected.pi("pricing").piObject else { throw PiBrokerError.invalid }
        let input = try amount(fields["prompt"] ?? .null), output = try amount(fields["completion"] ?? .null)
        try piCheck(input <= Decimal(string: "0.00000005")! && output <= Decimal(string: "0.0000001")!)
        for (name, value) in fields where !["prompt", "completion"].contains(name) {
            try piCheck(try amount(value) <= (["input_cache_read", "input_cache_write"].contains(name) ? input : 0))
        }
        try piCheck(input * 16384 + output * 256 <= Decimal(string: "0.001")!)
    }
    static func usage(_ data: Data) throws -> Int64 {
        try nanos(parse(data, limit: 65536).pi("data").pi("usage"))
    }
}

struct PiPreparedExecutor: PiMockModelExecutor {
    let operation: PiSelectedProfileOperation
    let permit: PiCumulativeBudget
    func validateOwner() async throws { try permit.validate(operation.binding); try await operation.validateOwner() }
    func complete(_ request: PiModelRequest) async throws -> PiValue {
        try await validateOwner()
        let reply = try await operation.complete(request)
        try await validateOwner()
        return reply
    }
}

@MainActor
final class PiPreparedProvider {
    let binding: PiSelectedProfileBinding
    let accounting: PiSharedAccounting
    let executor: PiPreparedExecutor
    let transport: PiTransportKind
    private let owner: ConfigStore
    private init(owner: ConfigStore, binding: PiSelectedProfileBinding, accounting: PiSharedAccounting, executor: PiPreparedExecutor, transport: PiTransportKind) {
        self.owner = owner; self.binding = binding; self.accounting = accounting; self.executor = executor; self.transport = transport
    }
    static func prepare(owner: ConfigStore, admission: NativeInferenceAdmission?, permit: PiCumulativeBudget, accountingRoot: URL, http: PiProviderHTTP, transport: PiTransportKind) async throws -> PiPreparedProvider {
        guard let admission, transport != .mock else { throw PiBrokerError.unauthorized }
        let binding = try owner.piSelectedProfileBinding()
        try permit.validate(binding)
        let catalog = try await owner.piProviderMetadata(binding: binding, path: "models", http: http)
        try PiProviderPreflight.catalog(catalog, model: binding.model)
        try permit.validate(binding)
        let usage = try PiProviderPreflight.usage(await owner.piProviderMetadata(binding: binding, path: "key", http: http))
        try permit.validate(binding)
        let baseline = try permit.baseline(observedProviderUsage: usage)
        let accounting = try PiSharedAccounting(root: accountingRoot, baselineNanos: baseline, budgetNanos: baseline + permit.runAllowance, ownerBinding: permit.digest, transport: transport)
        let baseOperation = try owner.piSelectedProfileOperation(binding: binding, admission: admission, accounting: accounting) { request, _ in
            try permit.validate(binding)
            let response = try await http.send(request)
            try permit.validate(binding)
            return response
        }
        let operation = PiSelectedProfileOperation(binding: binding, admission: admission, accounting: accounting, validate: {
            try permit.validate(binding)
            try await baseOperation.validateOwner()
        }, send: baseOperation.send)
        return PiPreparedProvider(owner: owner, binding: binding, accounting: accounting, executor: PiPreparedExecutor(operation: operation, permit: permit), transport: transport)
    }
}
