import Foundation
import Darwin

@MainActor
enum NativePiProduction {
    struct Failure: Error { let message: String }
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vera/Assistant", isDirectory: true)
    }
    static func presentation(config: ConfigStore, store: ChatStore, root: URL = defaultRoot,
                             http: PiProviderHTTP = PiProviderHTTP(), admission: NativeInferenceAdmission? = nil,
                             arguments: [String] = []) -> NativePiPresentation {
        NativePiPresentation(factory: {
            let ownership = try PiExperimentRoot(root)
            let policy = try NativePiSpendingPolicy(root: ownership.url)
            let binding: PiSelectedProfileBinding
            do { binding = try config.piSelectedProfileBinding() }
            catch { throw Failure(message: "The saved model connection isn't available. Check the selected model and existing credential in Settings, then connect again.") }
            guard let admission = admission ?? NativeInferenceAdmission.configured() else {
                throw Failure(message: "Connect Vera's engine in Settings before starting the assistant.")
            }
            let provider = try await PiPreparedProvider.production(owner: config, binding: binding, policy: policy,
                accountingRoot: root.appendingPathComponent("accounting"), admission: admission, http: http)
            let session = try await NativePiPreparedSession.create(arguments: arguments + ["--root", root.appendingPathComponent("model").path],
                uiRoot: root.appendingPathComponent("ui"), provider: provider, store: store, persistent: true)
            return NativePiConnection(workspace: session.workspace, memoryBridge: session.memoryBridge, stop: {
                await session.owner.stop()
                _ = ownership
            })
        })
    }
}

@MainActor
final class NativePiSpendingPolicy {
    struct State: Codable {
        var schema: Int
        var id: UUID
        var ceilingNanos: Int64
        var historicalHoldsNanos: Int64
        var allowanceNanos: Int64
        var observedUsageNanos: Int64
        var checkedAt: Date?
    }
    private let url: URL
    private(set) var state: State
    var binding: String { piHash(Data(("native-assistant-spending-v1:" + state.id.uuidString).utf8)) }
    init(root: URL) throws {
        url = root.appendingPathComponent("spending.json")
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            throw NativePiProduction.Failure(message: "The assistant needs a saved spending allowance before connecting. Your saved work is preserved.")
        }
        let bytes = try Data(contentsOf: url)
        try piCheck(bytes.count <= 4096, .storage)
        state = try JSONDecoder().decode(State.self, from: bytes)
        try Self.validate(state)
    }
    static func validate(_ state: State) throws {
        try piCheck(state.schema == 1 && (1...200_000_000_000).contains(state.ceilingNanos)
            && (0...200_000_000_000).contains(state.historicalHoldsNanos)
            && (1_000_000...1_000_000_000).contains(state.allowanceNanos)
            && (0...200_000_000_000).contains(state.observedUsageNanos), .budget)
        try piCheck(state.historicalHoldsNanos + state.observedUsageNanos + state.allowanceNanos <= state.ceilingNanos, .budget)
    }
    func observe(_ usage: Int64) throws {
        var next = state
        next.observedUsageNanos = max(next.observedUsageNanos, usage)
        next.checkedAt = Date()
        do { try Self.validate(next) }
        catch { throw NativePiProduction.Failure(message: "The assistant's spending limit has been reached. Your saved work is preserved.") }
        let bytes = try JSONEncoder().encode(next)
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        state = next
    }
}

struct PiProductionPricing: Sendable {
    let signature: String
    let prompt: Decimal
    let completion: Decimal
    init(catalog: Data) throws {
        let parsed = try PiProviderPreflight.parse(catalog, limit: 8_000_000)
        guard let models = parsed.pi("data").piArray?.filter({ $0.pi("id").piString == PiCheckpointPricing.model }),
              models.count == 1, let pricing = models[0].pi("pricing").piObject else { throw PiBrokerError.invalid }
        signature = piHash(try PiValue.object(pricing).piData())
        let model = models[0]
        try piCheck(model.pi("alias_target") == .null && model.pi("reasoning").pi("mandatory") == .bool(false))
        let supported = Set(model.pi("supported_parameters").piArray?.compactMap(\.piString) ?? [])
        try piCheck(Set(["tools", "max_tokens", "reasoning"]).isSubset(of: supported))
        prompt = PiCheckpointPricing.ceiling(try PiProviderPreflight.amount(pricing["prompt"] ?? .null))
        completion = PiCheckpointPricing.ceiling(try PiProviderPreflight.amount(pricing["completion"] ?? .null))
        var extras = Decimal(0)
        for (name, value) in pricing where !["prompt", "completion"].contains(name) {
            let amount = try PiProviderPreflight.amount(value)
            if ["input_cache_read", "input_cache_write"].contains(name) { extras += PiCheckpointPricing.ceiling(amount) }
            else { try piCheck(amount == 0, .budget) }
        }
        try piCheck(((prompt + extras) * 16384 + completion * 1024) / 1_000_000 <= Decimal(string: "0.01")!, .budget)
    }
    func body(_ request: PiModelRequest) throws -> Data {
        var body = try PiProviderCodec.body(request, model: PiCheckpointPricing.model).piObject!
        body["provider"] = .object(["allow_fallbacks": .bool(false), "require_parameters": .bool(true), "max_price": .object([
            "prompt": .number(NSDecimalNumber(decimal: prompt).doubleValue),
            "completion": .number(NSDecimalNumber(decimal: completion).doubleValue), "request": .number(0), "image": .number(0)])])
        let data = try PiValue.object(body).piData()
        try piCheck(data.count + 4096 <= 16384, .budget)
        return data
    }
}
