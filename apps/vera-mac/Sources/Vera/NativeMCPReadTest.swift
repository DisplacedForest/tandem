import Foundation
import Combine

struct NativeMCPReadTestResult: Equatable, Sendable {
    let text: String
    let source: String
}

@MainActor
final class NativeMCPReadTestController: ObservableObject, Identifiable {
    let id = UUID()
    let record: NativeMCPToolRecord
    let scope: String
    let usesPageURL: Bool
    @Published private(set) var input = ""
    @Published private(set) var running = false
    @Published private(set) var error: String?
    @Published private(set) var invalidated = false
    @Published private var storedResult: NativeMCPReadTestResult?
    private let authority: NativeMCPAuthority
    private let revision: Int
    private var observer: AnyCancellable?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var closed = false
    private var inputRejected = false

    init?(manager: NativeMCPManager, record: NativeMCPToolRecord) {
        guard let scope = Self.scope(authority: manager.authority, record: record) else { return nil }
        self.authority = manager.authority
        self.record = record
        self.scope = scope
        self.revision = manager.authority.access.permissionRevision()
        usesPageURL = Self.pageURLSchema(record.schema)
        observer = manager.$servers.sink { [weak self] _ in self?.checkCurrent() }
    }

    deinit { operation?.cancel() }

    static func scope(authority: NativeMCPAuthority, record: NativeMCPToolRecord) -> String? {
        ["focused", "assistant"].first { authority.access.allowed(record, scope: $0) }
    }

    static func pageURLSchema(_ schema: NativeJSONValue) -> Bool {
        guard case .object(let object) = schema, object["type"] == .string("object"),
              case .object(let properties) = object["properties"], Set(properties.keys) == ["url"],
              case .object(let url) = properties["url"], url["type"] == .string("string"),
              object["required"] == .array([.string("url")]) else { return false }
        return true
    }

    var current: Bool { !closed && authority.access.allowed(record, scope: scope, revision: revision) }
    var result: NativeMCPReadTestResult? { current ? storedResult : nil }
    var canRun: Bool { current && !running && !inputRejected && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func updateInput(_ value: String) {
        guard !closed else { return }
        if !inputRejected && value.utf8.elementsEqual(input.utf8) { return }
        cancelOperation()
        guard value.utf8.count <= (usesPageURL ? 2048 : 16384) else {
            inputRejected = true
            error = usesPageURL ? "Use a shorter page URL." : "Arguments must fit within 16 KB."
            return
        }
        inputRejected = false
        input = value
        error = nil
    }

    func run() {
        guard canRun else { checkCurrent(); return }
        let arguments: [String: NativeJSONValue]
        do {
            arguments = try validatedArguments()
        } catch {
            self.error = usesPageURL ? "Enter a valid public page URL that matches this tool's requirements." : "Check the JSON object against the argument format."
            return
        }
        guard let definition = authority.definitions(scope: scope).first(where: { $0.id == record.id }), definition.isAvailable(), current else { checkCurrent(); return }
        cancelOperation()
        error = nil
        running = true
        let generation = generation
        operation = Task { [weak self] in
            do {
                let value = try await definition.execute(arguments)
                try Task.checkCancellation()
                guard let self, self.current, self.generation == generation else { return }
                let result = try Self.render(value, source: self.record.server.endpoint.absoluteString)
                guard self.current, self.generation == generation else { return }
                self.storedResult = result
                self.running = false
                self.operation = nil
            } catch {
                guard let self, !self.closed, self.generation == generation else { return }
                self.running = false
                self.operation = nil
                self.storedResult = nil
                if !self.current { self.checkCurrent(); return }
                self.error = error is CancellationError ? "Read canceled." : "The read couldn't finish. Check the service connection and try again."
            }
        }
    }

    func checkCurrent() {
        guard !closed, !current else { return }
        cancelOperation()
        invalidated = true
    }

    func close() {
        guard !closed else { return }
        closed = true
        cancelOperation()
        input = ""
        error = nil
        observer = nil
    }

    private func cancelOperation() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        running = false
        storedResult = nil
    }

    private func validatedArguments() throws -> [String: NativeJSONValue] {
        let object: [String: NativeJSONValue]
        if usesPageURL {
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URLComponents(string: text), let scheme = url.scheme, ["https", "http"].contains(scheme), url.host?.isEmpty == false,
                  url.user == nil, url.password == nil, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw NativeToolError.unavailable }
            object = ["url": .string(text)]
        } else {
            let data = Data(input.utf8)
            try NativeMCPWireJSON.validate(data, maximumBytes: 16384)
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeToolError.unavailable }
            object = try parsed.mapValues { try NativeJSONValue.piDecode($0) }
        }
        guard current, let validator = record.validator else { throw NativeToolError.unavailable }
        try validator.validate(.object(object))
        return object
    }

    static func render(_ value: NativeJSONValue, source: String) throws -> NativeMCPReadTestResult {
        guard (try value.piData()).count <= 4096, case .object(let wrapped) = value,
              Set(wrapped.keys) == ["source", "content"], wrapped["source"] == .string(source), let content = wrapped["content"] else { throw NativeToolError.unavailable }
        let text: String
        if case .array(let blocks) = content.pi("content") {
            let texts = blocks.compactMap { block -> String? in
                guard block.pi("type") == .string("text"), case .string(let text) = block.pi("text") else { return nil }
                return text
            }
            if !texts.isEmpty { text = texts.joined(separator: "\n\n") }
            else { text = String(decoding: try content.piData(), as: UTF8.self) }
        } else { text = String(decoding: try content.piData(), as: UTF8.self) }
        return NativeMCPReadTestResult(text: text, source: source)
    }
}
