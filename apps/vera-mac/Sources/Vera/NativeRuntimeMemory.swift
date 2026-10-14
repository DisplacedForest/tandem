import Foundation
import GRDB

struct NativeRuntimeMemoryReference: Codable, Equatable, Sendable {
    let id: String
    let revision: Int
}

struct NativeRuntimeMemoryContext: Sendable {
    let authority: UUID
    let binding: PiValue
    let generation: String
    let selected: [NativeMemoryRanked]
    let prompt: String
    let digest: String
}

@MainActor
final class NativeRuntimeMemoryBridge {
    private struct Grant {
        let binding: PiValue
        let query: String
        let generation: String
        var context: NativeRuntimeMemoryContext?
    }
    private weak var store: ChatStore?
    private let authority = UUID()
    private var assistant: String?
    private var grants: [String: Grant] = [:]
    private var closed = false
    private var revoked = Set<String>()
    private var paused = Set<String>()

    init(store: ChatStore) { self.store = store }

    func bindAssistant(_ id: String) throws {
        _ = try piUUID(.string(id))
        try piCheck(!closed && (assistant == nil || assistant == id), .unauthorized)
        assistant = id
    }

    func authorize(_ binding: PiValue, query: String, generation: String? = nil) throws {
        let scope = try PiModelScope(binding, profile: "host")
        try piCheck(!closed && !revoked.contains(scope.subject) && store != nil && scope.assistant == assistant && !query.isEmpty && query.count <= 8000, .unauthorized)
        let generation = generation ?? scope.subject
        _ = try piUUID(.string(generation))
        if let existing = grants[scope.subject] {
            try piCheck(existing.binding == binding && existing.query == query, .unauthorized)
            if existing.generation == generation { return }
            try piCheck(scope.role == "worker", .unauthorized)
        }
        grants[scope.subject] = Grant(binding: binding, query: query, generation: generation)
    }

    func pause(_ subject: String) { paused.insert(subject) }
    func resume(_ subject: String) { paused.remove(subject) }

    func revoke(_ subject: String) { revoked.insert(subject); grants.removeValue(forKey: subject) }
    func close() { closed = true; grants.removeAll() }

    private func binding(_ scope: PiModelScope) -> PiValue {
        .object(["subject": .string(scope.subject), "assistant": .string(scope.assistant),
            "conversation": .string(scope.conversation), "role": .string(scope.role), "mode": .string(scope.mode)])
    }

    func prepare(_ request: PiModelRequest) async throws -> PiModelRequest {
        try Task.checkCancellation()
        let deadline = ContinuousClock.now + .seconds(3)
        while paused.contains(request.scope.subject) {
            try piCheck(!closed && !revoked.contains(request.scope.subject) && ContinuousClock.now < deadline, .unauthorized)
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !closed, let store, var grant = grants[request.scope.subject], grant.binding == binding(request.scope) else { throw PiBrokerError.unauthorized }
        if request.memoryContext != nil { try validate(request); return request }
        if grant.context == nil {
            let selected = await store.selectApprovedMemory(grant.query)
            try Task.checkCancellation()
            guard !closed, grants[request.scope.subject]?.binding == grant.binding, grants[request.scope.subject]?.generation == grant.generation else { throw PiBrokerError.canceled }
            let assembly = NativeContextAssembler.assemble(NativeContextInput(persona: "", timestamp: .distantPast,
                timeZone: TimeZone(secondsFromGMT: 0)!, memories: selected, contracts: selected.isEmpty ? [] : [.citations]))
            let prompt = assembly.sections.filter { ["policy", "memory", "format:citations"].contains($0.name) }.map(\.content).joined(separator: "\n\n")
            let references = selected.map { NativeRuntimeMemoryReference(id: $0.id, revision: $0.revision ?? 0) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let digest = piHash(try encoder.encode(references) + Data((grant.generation + ":" + prompt).utf8))
            grant.context = NativeRuntimeMemoryContext(authority: authority, binding: grant.binding, generation: grant.generation, selected: selected, prompt: prompt, digest: digest)
            grants[request.scope.subject] = grant
        }
        let result = try request.withMemoryContext(grant.context!, authority: self)
        try validate(result)
        guard let local = store.repository as? LocalChatRepository else { throw PiBrokerError.unavailable }
        try local.saveRuntimeMemorySources(assistant: request.scope.assistant, conversation: request.scope.conversation,
            message: "subject:" + request.scope.subject,
            references: grant.context!.selected.map { NativeRuntimeMemoryReference(id: $0.id, revision: $0.revision ?? 0) },
            replace: request.scope.role == "worker")
        if request.scope.role == "worker" { try recordDelivery(subject: request.scope.subject, messageID: "task:" + request.scope.subject) }
        return result
    }

    func validate(_ request: PiModelRequest) throws {
        try Task.checkCancellation()
        guard !closed, !paused.contains(request.scope.subject), let store, let context = request.memoryContext,
              context.authority == authority, context.binding == binding(request.scope),
              let grant = grants[request.scope.subject], grant.binding == context.binding,
              grant.generation == context.generation, grant.context?.digest == context.digest, store.memorySelectionIsCurrent(context.selected) else { throw PiBrokerError.unauthorized }
    }

    func recordDelivery(subject: String, messageID: String) throws {
        guard !closed, let store, let local = store.repository as? LocalChatRepository,
              let grant = grants[subject],
              let assistant = grant.binding.pi("assistant").piString,
              let conversation = grant.binding.pi("conversation").piString else { throw PiBrokerError.unavailable }
        let references = try local.runtimeMemoryReferences(assistant: assistant, conversation: conversation, message: "subject:" + subject)
        try local.saveRuntimeMemorySources(assistant: assistant, conversation: conversation, message: messageID,
            references: references, replace: grant.binding.pi("role").piString == "worker")
    }

    func learn(conversation: String, message: String, user: String, reply: String) {
        guard !closed, let store else { return }
        Task {
            await store.learnFromCompletedTurn(
                user: user, assistant: Message(role: .assistant, text: reply), source: nil,
                turnKey: "runtime|" + conversation + "|" + message, conversationExcluded: false)
        }
    }

    func sources(conversation: String, message: String) -> [PulseSource] {
        guard let assistant, let local = store?.repository as? LocalChatRepository else { return [] }
        return (try? local.runtimeMemorySources(assistant: assistant, conversation: conversation, message: message)) ?? []
    }
}

extension LocalChatRepository {
    static func migrateRuntimeMemorySources(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE runtime_memory_sources (
                assistant TEXT NOT NULL,
                conversation TEXT NOT NULL,
                message TEXT NOT NULL,
                references_json BLOB NOT NULL,
                PRIMARY KEY(assistant, conversation, message)
            )
            """)
    }

    func saveRuntimeMemorySources(assistant: String, conversation: String, message: String,
                                  references: [NativeRuntimeMemoryReference], replace: Bool = true) throws {
        let bytes = try JSONEncoder().encode(references)
        try database.write { db in
            if !replace, let existing = try Data.fetchOne(db, sql: "SELECT references_json FROM runtime_memory_sources WHERE assistant=? AND conversation=? AND message=?", arguments: [assistant, conversation, message]) {
                guard try JSONDecoder().decode([NativeRuntimeMemoryReference].self, from: existing) == references else { throw PiBrokerError.duplicate }
                return
            }
            try db.execute(sql: "INSERT INTO runtime_memory_sources VALUES(?,?,?,?) ON CONFLICT(assistant,conversation,message) DO UPDATE SET references_json=excluded.references_json",
                arguments: [assistant, conversation, message, bytes])
        }
    }

    func runtimeMemoryReferences(assistant: String, conversation: String, message: String) throws -> [NativeRuntimeMemoryReference] {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT references_json FROM runtime_memory_sources WHERE assistant=? AND conversation=? AND message=?",
                arguments: [assistant, conversation, message]) else { return [] }
            return try JSONDecoder().decode([NativeRuntimeMemoryReference].self, from: data)
        }
    }

    func runtimeMemorySources(assistant: String, conversation: String, message: String) throws -> [PulseSource] {
        let references = try runtimeMemoryReferences(assistant: assistant, conversation: conversation, message: message)
        return references.enumerated().map { index, reference in
            let record = try? memoryEvidence(reference.id).first { $0.revision == reference.revision }?.record
            var url = URLComponents()
            url.scheme = "vera-memory"; url.host = "record"
            url.queryItems = [URLQueryItem(name: "id", value: reference.id), URLQueryItem(name: "revision", value: String(reference.revision))]
            return PulseSource(n: NativeMemoryCitation.offset + index, title: record.map { "Memory: " + $0.title } ?? "Saved memory", url: url.string ?? "")
        }
    }
}
