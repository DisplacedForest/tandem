import Foundation
import Darwin

final class PiCheckpointLedger: @unchecked Sendable {
    let path: URL
    let id: String
    private let mutex = NSLock()
    private var fileLock: Int32 = -1
    private var directory: Int32 = -1
    private var value: [String: PiValue]
    private var fields: [String: PiValue]
    init(path: URL, id: String) throws {
        _ = try piUUID(.string(id))
        var leaf = stat()
        try piCheck(lstat(path.path, &leaf) == 0 && leaf.st_mode & S_IFMT == S_IFREG, .storage)
        let canonical = try piCanonical(path)
        var ancestor = canonical.deletingLastPathComponent()
        while true {
            var info = stat()
            try piCheck(lstat(ancestor.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && [0, getuid()].contains(info.st_uid), .storage)
            try piCheck(info.st_mode & 0o022 == 0 || (info.st_uid == 0 && info.st_mode & S_ISVTX != 0), .storage)
            if ancestor.path == "/" { break }
            ancestor.deleteLastPathComponent()
        }
        let parent = open(canonical.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try piCheck(parent >= 0, .storage)
        var parentInfo = stat()
        guard fstat(parent, &parentInfo) == 0, parentInfo.st_uid == getuid(), parentInfo.st_mode & 0o022 == 0 else { close(parent); throw PiBrokerError.storage }
        directory = parent
        self.path = canonical; self.id = id
        let lockPath = canonical.appendingPathExtension("checkpoint-lock")
        let descriptor = openat(parent, lockPath.lastPathComponent, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { close(parent); directory = -1; throw PiBrokerError.storage }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_mode & S_IFMT == S_IFREG, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); close(parent); directory = -1; throw PiBrokerError.storage }
        fileLock = descriptor
        do {
            let file = openat(parent, canonical.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            try piCheck(file >= 0, .storage)
            defer { close(file) }
            try piCheck(fstat(file, &info) == 0 && info.st_uid == getuid() && info.st_nlink == 1 && info.st_mode & 0o077 == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size > 0 && info.st_size <= 65536, .storage)
            var bytes = [UInt8](repeating: 0, count: 65537)
            let count = read(file, &bytes, bytes.count)
            try piCheck(count == info.st_size, .storage)
            let parsed = try PiValue.piRead(Data(bytes.prefix(count)))
            guard let root = parsed.piObject, let authorizations = root["checkpoint_authorizations"]?.piObject, let fields = authorizations[id]?.piObject else { throw PiBrokerError.unauthorized }
            self.value = root; self.fields = fields
            try piCheck(root["total_authorized_usd"] == .number(200) && fields["state"] == .string("ready") && fields["model"] == .string(PiCheckpointPricing.model) && fields["prompt_digest"] == .string(PiCheckpointPricing.promptDigest) && fields["exclusive_owner"] == .bool(true) && fields["maximum_usd"] == .number(1), .unauthorized)
            guard case .number(let expiry) = fields["expires"] else { throw PiBrokerError.unauthorized }
            try piCheck(expiry.isFinite && expiry > Date().timeIntervalSince1970 && expiry <= Date().timeIntervalSince1970 + 600, .unauthorized)
            let known = try PiProviderPreflight.nanos(root["prior_plus_cli_and_uncertainty_holds_usd"] ?? .null)
            let other = try PiProviderPreflight.nanos(parsed.pi("code_review_cli").pi("total_reported_cost_usd"))
            let prior = try PiProviderPreflight.nanos(root["last_known_prior_account_usage_usd"] ?? .null)
            let holds = try PiProviderPreflight.nanos(fields["uncertainty_holds_usd"] ?? .null)
            try piCheck(other + prior + holds == known && known <= 199_000_000_000, .budget)
        } catch { close(descriptor); close(parent); fileLock = -1; directory = -1; throw error }
    }
    deinit { if fileLock >= 0 { close(fileLock) }; if directory >= 0 { close(directory) } }
    private func save() throws {
        var authorizations = value["checkpoint_authorizations"]!.piObject!
        authorizations[id] = .object(fields)
        value["checkpoint_authorizations"] = .object(authorizations)
        let bytes = try PiValue.object(value).piData()
        try piCheck(bytes.count <= 65536, .storage)
        let temporary = path.deletingLastPathComponent().appendingPathComponent(".checkpoint-" + UUID().uuidString)
        let descriptor = openat(directory, temporary.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        try piCheck(descriptor >= 0, .storage)
        defer { close(descriptor); _ = unlinkat(directory, temporary.lastPathComponent, 0) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                try piCheck(count > 0, .storage); offset += count
            }
        }
        try piCheck(fsync(descriptor) == 0, .storage)
        var original = stat()
        try piCheck(fstatat(directory, path.lastPathComponent, &original, AT_SYMLINK_NOFOLLOW) == 0 && original.st_uid == getuid() && original.st_nlink == 1 && original.st_mode & S_IFMT == S_IFREG && original.st_mode & 0o077 == 0, .storage)
        try piCheck(renameat(directory, temporary.lastPathComponent, directory, path.lastPathComponent) == 0, .storage)
        try piCheck(fsync(directory) == 0, .storage)
    }
    func consume() throws {
        mutex.lock(); defer { mutex.unlock() }
        try piCheck(fields["state"] == .string("ready"), .unauthorized)
        fields["state"] = .string("consumed"); fields["stage"] = .string("credential_pending")
        fields["models_requests"] = .number(0); fields["usage_requests"] = .number(0); fields["inference_requests"] = .number(0)
        try save()
    }
    func permit(binding: PiSelectedProfileBinding) throws -> PiCumulativeBudget {
        mutex.lock(); defer { mutex.unlock() }
        try piCheck(fields["state"] == .string("consumed"), .unauthorized)
        guard case .number(let expiry) = fields["expires"] else { throw PiBrokerError.invalid }
        return try PiCumulativeBudget(id: id, ownerBinding: binding.digest, otherTestSpend: PiProviderPreflight.nanos(value["code_review_cli"]!.pi("total_reported_cost_usd")), priorProviderUsage: PiProviderPreflight.nanos(value["last_known_prior_account_usage_usd"]!), uncertaintyHolds: PiProviderPreflight.nanos(fields["uncertainty_holds_usd"]!), externalReservations: 0, runAllowance: PiCheckpointPricing.reservation, expires: Date(timeIntervalSince1970: expiry), exclusiveOwner: true)
    }
    func stage(_ stage: String, additions: [String: PiValue] = [:]) throws {
        mutex.lock(); defer { mutex.unlock() }
        fields["stage"] = .string(stage)
        for (key, value) in additions { fields[key] = value }
        try save()
    }
    func metadata(_ kind: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        let key = kind == "models" ? "models_requests" : "usage_requests"
        try piCheck(["models", "usage"].contains(kind) && fields[key] == .number(0) && fields["state"] == .string("consumed"), .unauthorized)
        fields[key] = .number(1); fields["stage"] = .string(kind + "_pending")
        try save()
    }
    func reserve(baseline: Int64, body: Data) throws {
        mutex.lock(); defer { mutex.unlock() }
        try piCheck(fields["state"] == .string("consumed") && fields["inference_requests"] == .number(0) && fields["models_requests"] == .number(1) && fields["usage_requests"] == .number(1) && baseline <= 200_000_000_000 - PiCheckpointPricing.reservation, .unauthorized)
        fields["inference_requests"] = .number(1); fields["reserved_nanos"] = .number(Double(PiCheckpointPricing.reservation)); fields["baseline_nanos"] = .number(Double(baseline)); fields["body_digest"] = .string(piHash(body)); fields["stage"] = .string("inference_pending")
        value["prior_plus_cli_and_uncertainty_holds_usd"] = .string(NSDecimalNumber(decimal: Decimal(baseline + PiCheckpointPricing.reservation) / 1_000_000_000).stringValue)
        try save()
    }
    func settle(_ reply: PiValue) throws {
        mutex.lock(); defer { mutex.unlock() }
        let cost = PiModelReply.costNanos(reply)
        guard case .number(let baseline) = fields["baseline_nanos"] else { throw PiBrokerError.storage }
        try piCheck(fields["stage"] == .string("inference_pending") && cost >= 0 && cost <= PiCheckpointPricing.reservation, .storage)
        fields["charged_nanos"] = .number(Double(cost)); fields["reserved_nanos"] = .number(0); fields["state"] = .string("completed"); fields["stage"] = .string("settled")
        value["prior_plus_cli_and_uncertainty_holds_usd"] = .string(NSDecimalNumber(decimal: (Decimal(Int64(baseline)) + Decimal(cost)) / 1_000_000_000).stringValue)
        try save()
    }
    func report() -> PiValue { mutex.lock(); defer { mutex.unlock() }; return .object(fields) }
}
