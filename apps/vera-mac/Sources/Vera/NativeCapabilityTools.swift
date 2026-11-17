import Foundation

struct NativeHTTPToolClient: Sendable {
    let send: @Sendable (URL, String, Data?, TimeInterval) async throws -> (Data, Int)

    static let live = NativeHTTPToolClient { url, method, body, timeout in
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let limit = NativeCapabilityTools.responseByteCap + 1
        var data = Data()
        data.reserveCapacity(limit)
        for try await byte in stream {
            data.append(byte)
            if data.count >= limit { break }
        }
        return (data, status)
    }
}

enum NativeToolHTTPMethod: String, Equatable, Hashable, Sendable {
    case get = "GET"
    case post = "POST"
}

enum NativeToolPropertyType: String, Equatable, Hashable, Sendable {
    case string
    case boolean
    case integer
    case number
}

struct NativeToolProperty: Equatable, Hashable, Sendable {
    let name: String
    let type: NativeToolPropertyType
    let description: String
    var keywords: [String: NativeJSONValue] = [:]
}

enum NativeToolDeclarationProblem: Equatable, Hashable, Sendable {
    case unreadable
    case notJSON
    case missing(String)
    case badName
    case badParameters
    case badField(String)
    case unsupportedType(field: String, type: String)
    case unsupportedKeyword(String)
    case badValue(field: String, keyword: String)
    case badRequired
    case repeatedRequired
    case badEndpoint
    case badMethod
    case badConfirmation
    case badTimeout
    case badEnabled
    case badJSONFields
    case badSendsTo
    case badVerbs
    case duplicateName(String)
    case reservedName(String)
    case other
}

struct NativeToolDeclarationError: Error, Equatable {
    let reason: String
    var problem: NativeToolDeclarationProblem = .other
}

struct NativeToolDeclarationFailure: Equatable, Hashable, Sendable, Identifiable {
    let file: String
    let reason: String
    var problem: NativeToolDeclarationProblem = .other

    var id: String { "\(file)|\(reason)" }
}

struct NativeToolDeclaration: Equatable, Hashable, Sendable, Identifiable {
    let name: String
    let title: String
    let description: String
    var summary: String? = nil
    let properties: [NativeToolProperty]
    let required: [String]
    let endpoint: String
    let method: NativeToolHTTPMethod
    let confirmation: NativeToolConfirmation
    let timeoutSeconds: Double
    let enabled: Bool
    let jsonFields: [String: String]
    let source: String
    var sendsTo: [String]? = nil
    var verbs: [String] = []

    var id: String { NativeCapabilityTools.identifier(name: name) }

    func recipients(_ arguments: [String: NativeJSONValue]) -> [NativeRuleTarget] {
        var found: [NativeRuleTarget] = []
        for field in sendsTo ?? [] {
            guard case .string(let value)? = arguments[field] else { continue }
            for piece in value.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }) {
                guard let target = NativeRuleTarget.make(.recipient, String(piece)), !found.contains(target) else { continue }
                found.append(target)
            }
        }
        return found
    }

    var needsAPIBase: Bool { URL(string: endpoint)?.scheme == nil }

    var reads: Bool { method == .get && confirmation != .required }

    var parameters: NativeJSONValue {
        var fields: [String: NativeJSONValue] = [:]
        for property in properties {
            fields[property.name] = .object(Self.entry(property))
        }
        return .object([
            "type": .string("object"),
            "properties": .object(fields),
            "required": .array(required.map(NativeJSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    static func entry(_ property: NativeToolProperty) -> [String: NativeJSONValue] {
        var entry = property.keywords
        entry["type"] = .string(property.type.rawValue)
        if property.type == .string, entry["minLength"] == nil {
            entry["minLength"] = .number(1)
        }
        if !property.description.isEmpty {
            entry["description"] = .string(property.description)
        }
        return entry
    }
}

struct NativeCapabilityToolCatalog: Equatable, Sendable {
    var declarations: [NativeToolDeclaration] = []
    var failures: [NativeToolDeclarationFailure] = []

    static let empty = NativeCapabilityToolCatalog()
}

enum NativeCapabilityTools {
    static let responseByteCap = 32_768
    static let defaultTimeoutSeconds: Double = 20
    static let maximumTimeoutSeconds: Double = 300
    static let directoryName = "tools.d"
    static let parameterKeywords: Set<String> = ["type", "properties", "required", "additionalProperties"]
    static let propertyKeywords: Set<String> = ["type", "description", "enum", "const", "minLength", "maxLength", "minimum", "maximum", "default", "title", "examples"]

    static func identifier(name: String) -> String { "capability-\(name)" }

    static var defaultDirectory: URL {
        ConfigFile.defaultURL.deletingLastPathComponent()
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func catalog(
        directory: URL = defaultDirectory, reservedNames: Set<String> = []
    ) -> NativeCapabilityToolCatalog {
        var declarations = bundled
        var taken = Set(declarations.map(\.name)).union(reservedNames)
        var failures: [NativeToolDeclarationFailure] = []
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            let label = file.lastPathComponent
            AppLocations.refuseRealFile(file)
            guard let data = try? Data(contentsOf: file) else {
                failures.append(NativeToolDeclarationFailure(
                    file: label, reason: "The file could not be read", problem: .unreadable))
                continue
            }
            do {
                let declaration = try parse(data: data, source: label)
                guard !taken.contains(declaration.name) else {
                    let reserved = reservedNames.contains(declaration.name)
                    failures.append(NativeToolDeclarationFailure(
                        file: label,
                        reason: reserved
                            ? "The name '\(declaration.name)' is reserved by a built-in tool"
                            : "A tool named '\(declaration.name)' is already loaded",
                        problem: reserved ? .reservedName(declaration.name) : .duplicateName(declaration.name)))
                    continue
                }
                guard NativeToolSchemaCache.shared.validator(declaration.parameters) != nil else {
                    failures.append(NativeToolDeclarationFailure(
                        file: label, reason: "The parameters can't be checked as written", problem: .badParameters))
                    continue
                }
                taken.insert(declaration.name)
                declarations.append(declaration)
            } catch let error as NativeToolDeclarationError {
                failures.append(NativeToolDeclarationFailure(file: label, reason: error.reason, problem: error.problem))
            } catch {
                failures.append(NativeToolDeclarationFailure(
                    file: label, reason: error.localizedDescription))
            }
        }
        return NativeCapabilityToolCatalog(declarations: declarations, failures: failures)
    }

    static func definitions(
        _ declarations: [NativeToolDeclaration],
        base: @escaping @Sendable () -> URL?,
        client: NativeHTTPToolClient = .live
    ) -> [NativeToolDefinition] {
        declarations.filter(\.enabled).map { definition($0, base: base, client: client) }
    }

    static let proposing: Set<String> = ["propose_action"]
    static let drafting: [String: String] = [:]

    static func definition(
        _ declaration: NativeToolDeclaration,
        base: @escaping @Sendable () -> URL?,
        client: NativeHTTPToolClient = .live
    ) -> NativeToolDefinition {
        var definition = plainDefinition(declaration, base: base, client: client)
        if let fields = declaration.sendsTo, !declaration.reads, declaration.method == .post {
            definition.fixedDestination = fields.isEmpty
            definition.verbs = declaration.verbs
            definition.namesNothing = fields.isEmpty
            if !fields.isEmpty {
                definition.ruleSubjects = { arguments in
                    let targets = declaration.recipients(arguments)
                    return targets.map { [$0] }
                }
            }
        }
        guard declaration.source == bundledSource else { return definition }
        definition.proposes = proposing.contains(declaration.name)
        if let mode = drafting[declaration.name] {
            definition.proposesFor = { $0["mode"] == .string(mode) }
        }
        return definition
    }

    static func plainDefinition(
        _ declaration: NativeToolDeclaration,
        base: @escaping @Sendable () -> URL?,
        client: NativeHTTPToolClient
    ) -> NativeToolDefinition {
        NativeToolDefinition(
            id: declaration.id,
            name: declaration.name,
            title: declaration.title,
            description: declaration.description,
            parameters: declaration.parameters,
            confirmation: declaration.confirmation,
            timeout: .seconds(declaration.timeoutSeconds),
            effect: declaration.reads ? .read : .write,
            action: declaration.reads ? nil : declaration.method == .get ? .otherChanges : .networkSends,
            isAvailable: { resolve(declaration, base: base()) != nil },
            execute: { arguments in
                try await call(declaration, arguments: arguments, base: base(), client: client)
            },
            preflight: { arguments in
                _ = try prepared(declaration, arguments: arguments, base: base())
            }, marksEffect: true)
    }

    static func descriptors(
        _ declarations: [NativeToolDeclaration], veraAPIConfigured: Bool
    ) -> [NativeChatToolDescriptor] {
        declarations.filter(\.enabled).map { declaration in
            let available = !declaration.needsAPIBase || veraAPIConfigured
            return NativeChatToolDescriptor(
                id: declaration.id,
                name: declaration.title,
                summary: declaration.summary ?? "",
                available: available,
                setup: "Connect your Tandem server to use this.")
        }
    }

    static func resolve(_ declaration: NativeToolDeclaration, base: URL?) -> URL? {
        guard let url = URL(string: declaration.endpoint) else { return nil }
        guard url.scheme == nil else { return url }
        guard let base else { return nil }
        let parts = declaration.endpoint.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var resolved = base
        for component in parts[0].split(separator: "/") where !component.isEmpty {
            resolved = resolved.appendingPathComponent(String(component))
        }
        guard parts.count > 1, !parts[1].isEmpty else { return resolved }
        guard var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
            return resolved
        }
        components.percentEncodedQuery = String(parts[1])
        return components.url ?? resolved
    }

    static func prepared(
        _ declaration: NativeToolDeclaration,
        arguments: [String: NativeJSONValue],
        base: URL?
    ) throws -> (target: URL, body: Data?) {
        for name in arguments.keys.sorted() {
            if case .string(let text)? = arguments[name], text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw NativeToolError.invalidArguments("Field '\(name)' must be a non-empty string")
            }
        }
        guard let endpoint = resolve(declaration, base: base) else {
            throw NativeToolError.unavailable
        }
        var target = endpoint
        var body: Data?
        switch declaration.method {
        case .get:
            guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
                throw NativeToolError.failed("The tool endpoint is not a valid URL")
            }
            var items = components.queryItems ?? []
            for key in arguments.keys.sorted() {
                guard let value = queryValue(arguments[key]) else { continue }
                items.append(URLQueryItem(name: key, value: value))
            }
            if !items.isEmpty { components.queryItems = items }
            guard let resolved = components.url else {
                throw NativeToolError.failed("The tool endpoint is not a valid URL")
            }
            target = resolved
        case .post:
            var payload: [String: Any] = [:]
            for (key, value) in arguments {
                guard let field = declaration.jsonFields[key] else {
                    payload[key] = value.any
                    continue
                }
                guard case .string(let text) = value,
                      let data = text.data(using: .utf8),
                      let decoded = try? JSONSerialization.jsonObject(with: data),
                      let object = decoded as? [String: Any] else {
                    throw NativeToolError.invalidArguments(
                        "Field '\(key)' must contain a JSON object")
                }
                payload[field] = object
            }
            guard let encoded = try? JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys]) else {
                throw NativeToolError.invalidArguments("The arguments are not encodable as JSON")
            }
            body = encoded
        }
        return (target, body)
    }

    private static func call(
        _ declaration: NativeToolDeclaration,
        arguments: [String: NativeJSONValue],
        base: URL?,
        client: NativeHTTPToolClient
    ) async throws -> NativeJSONValue {
        let (target, body) = try prepared(declaration, arguments: arguments, base: base)
        let requestTimeout = max(declaration.timeoutSeconds - 1, 1)
        let data: Data
        let status: Int
        NativeToolCallContext.effectStarts()
        do {
            (data, status) = try await client.send(
                target, declaration.method.rawValue, body, requestTimeout)
        } catch let error as NativeToolError {
            throw error
        } catch {
            throw NativeToolError.failed("The request failed: \(error.localizedDescription)")
        }
        guard (200..<300).contains(status) else {
            throw NativeToolError.failed(
                "The request failed with HTTP \(status): \(errorDetail(data))")
        }
        return value(from: data)
    }

    static func value(from data: Data) -> NativeJSONValue {
        if data.count <= responseByteCap,
           let object = try? JSONSerialization.jsonObject(with: data),
           let parsed = try? NativeJSONValue(any: object) {
            let candidate: NativeJSONValue
            if case .object = parsed {
                candidate = parsed
            } else {
                candidate = .object(["result": parsed])
            }
            if serializedSize(candidate) <= responseByteCap { return candidate }
        }
        let (text, truncated) = boundedText(data)
        return fitted(text, truncated: truncated)
    }

    static func serializedSize(_ value: NativeJSONValue) -> Int {
        guard let serialized = try? NativeToolLoop.serializedResult(value) else { return Int.max }
        return serialized.utf8.count
    }

    private static func wrapped(_ text: String, truncated: Bool) -> NativeJSONValue {
        .object(["text": .string(text), "truncated": .bool(truncated)])
    }

    private static func fitted(_ text: String, truncated: Bool) -> NativeJSONValue {
        var body = text
        var shortened = truncated
        guard serializedSize(wrapped(body, truncated: shortened)) > responseByteCap else {
            return wrapped(body, truncated: shortened)
        }
        shortened = true
        while !body.isEmpty {
            let size = serializedSize(wrapped(body, truncated: true))
            guard size > responseByteCap else { break }
            let overflow = size - responseByteCap
            body.removeLast(max(1, min(body.count, overflow / maximumEscapedCharacterBytes + 1)))
        }
        return wrapped(body, truncated: shortened)
    }

    private static let maximumEscapedCharacterBytes = 6

    static func boundedText(_ data: Data) -> (String, Bool) {
        guard data.count > responseByteCap else {
            return (String(decoding: data, as: UTF8.self), false)
        }
        var slice = data.prefix(responseByteCap)
        while !slice.isEmpty, String(data: slice, encoding: .utf8) == nil {
            slice = slice.dropLast()
        }
        return (String(decoding: slice, as: UTF8.self), true)
    }

    static func errorDetail(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = object["detail"] as? String, !detail.isEmpty {
            return detail
        }
        let (text, _) = boundedText(data)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "no response body" : String(trimmed.prefix(300))
    }

    private static func queryValue(_ value: NativeJSONValue?) -> String? {
        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            return number.rounded(.towardZero) == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
        default:
            return nil
        }
    }

    static func parse(data: Data, source: String) throws -> NativeToolDeclaration {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? [String: Any] else {
            throw NativeToolDeclarationError(reason: "The file is not a JSON object", problem: .notJSON)
        }
        return try parse(object: object, source: source)
    }

    static func parse(object: [String: Any], source: String) throws -> NativeToolDeclaration {
        let name = text(object["name"])
        guard !name.isEmpty else {
            throw NativeToolDeclarationError(reason: "A non-empty 'name' is required", problem: .missing("name"))
        }
        guard isFunctionName(name) else {
            throw NativeToolDeclarationError(
                reason: "'name' must start with a letter and use only letters, digits, or underscores", problem: .badName)
        }
        let title = text(object["title"])
        guard !title.isEmpty else {
            throw NativeToolDeclarationError(reason: "A non-empty 'title' is required", problem: .missing("title"))
        }
        let description = text(object["description"])
        guard !description.isEmpty else {
            throw NativeToolDeclarationError(reason: "A non-empty 'description' is required", problem: .missing("description"))
        }
        guard let schema = object["parameters"] as? [String: Any] else {
            throw NativeToolDeclarationError(reason: "'parameters' must be a JSON Schema object", problem: .badParameters)
        }
        guard (schema["type"] as? String) == "object" else {
            throw NativeToolDeclarationError(reason: "'parameters.type' must be \"object\"", problem: .badParameters)
        }
        if let unknown = schema.keys.sorted().first(where: { !parameterKeywords.contains($0) }) {
            throw NativeToolDeclarationError(
                reason: "'parameters' uses '\(unknown)', which is not supported", problem: .unsupportedKeyword(unknown))
        }
        guard let rawProperties = schema["properties"] as? [String: Any] else {
            throw NativeToolDeclarationError(reason: "'parameters.properties' must be an object", problem: .badParameters)
        }
        if let additional = schema["additionalProperties"] {
            guard let flag = additional as? Bool, flag == false else {
                throw NativeToolDeclarationError(
                    reason: "'parameters.additionalProperties' must be false", problem: .unsupportedKeyword("additionalProperties"))
            }
        }
        var properties: [NativeToolProperty] = []
        for key in rawProperties.keys.sorted() {
            guard let entry = rawProperties[key] as? [String: Any] else {
                throw NativeToolDeclarationError(reason: "Property '\(key)' must be an object", problem: .badField(key))
            }
            if let rawType = entry["type"] as? String, NativeToolPropertyType(rawValue: rawType) == nil {
                throw NativeToolDeclarationError(
                    reason: "Property '\(key)' uses unsupported type '\(rawType)'; use string, boolean, integer or number",
                    problem: .unsupportedType(field: key, type: rawType))
            }
            if let unknown = entry.keys.sorted().first(where: { !propertyKeywords.contains($0) }) {
                throw NativeToolDeclarationError(
                    reason: "Property '\(key)' uses '\(unknown)', which is not supported", problem: .unsupportedKeyword(unknown))
            }
            guard let rawType = entry["type"] as? String, let type = NativeToolPropertyType(rawValue: rawType) else {
                throw NativeToolDeclarationError(reason: "Property '\(key)' needs a 'type'", problem: .badField(key))
            }
            var keywords: [String: NativeJSONValue] = [:]
            for keyword in entry.keys.sorted() where keyword != "type" && keyword != "description" {
                guard let raw = entry[keyword], let value = try? NativeJSONValue(any: raw),
                      (try? NativeJSONSchema(.object(["type": .string(rawType), keyword: value]))) != nil else {
                    throw NativeToolDeclarationError(
                        reason: "Property '\(key)' has a '\(keyword)' value that can't be used", problem: .badValue(field: key, keyword: keyword))
                }
                keywords[keyword] = value
            }
            let property = NativeToolProperty(name: key, type: type, description: text(entry["description"]), keywords: keywords)
            guard (try? NativeJSONSchema(.object(NativeToolDeclaration.entry(property)))) != nil else {
                throw NativeToolDeclarationError(reason: "Property '\(key)' can't be checked as written", problem: .badField(key))
            }
            properties.append(property)
        }
        var required: [String] = []
        if let raw = schema["required"] {
            guard let names = raw as? [String] else {
                throw NativeToolDeclarationError(
                    reason: "'parameters.required' must be an array of strings", problem: .badRequired)
            }
            guard Set(names.map { Array($0.utf8) }).count == names.count else {
                throw NativeToolDeclarationError(
                    reason: "'required' lists a field more than once", problem: .repeatedRequired)
            }
            for entry in names {
                guard properties.contains(where: { $0.name == entry }) else {
                    throw NativeToolDeclarationError(
                        reason: "'required' names '\(entry)', which is not a declared property", problem: .badRequired)
                }
            }
            required = names.sorted()
        }
        let endpoint = text(object["endpoint"])
        guard !endpoint.isEmpty else {
            throw NativeToolDeclarationError(reason: "An 'endpoint' is required", problem: .missing("endpoint"))
        }
        guard let endpointURL = URL(string: endpoint) else {
            throw NativeToolDeclarationError(reason: "'endpoint' is not a valid URL or path", problem: .badEndpoint)
        }
        if let scheme = endpointURL.scheme?.lowercased() {
            guard scheme == "http" || scheme == "https" else {
                throw NativeToolDeclarationError(
                    reason: "'endpoint' must be an http or https URL, or a path", problem: .badEndpoint)
            }
            guard endpointURL.host?.isEmpty == false else {
                throw NativeToolDeclarationError(reason: "'endpoint' needs a host", problem: .badEndpoint)
            }
        }
        guard let rawMethod = object["method"] as? String,
              let method = NativeToolHTTPMethod(rawValue: rawMethod.uppercased()) else {
            throw NativeToolDeclarationError(reason: "'method' must be \"GET\" or \"POST\"", problem: .badMethod)
        }
        guard let rawConfirmation = object["confirmation"] as? String,
              let confirmation = NativeToolConfirmation(rawValue: rawConfirmation.lowercased()) else {
            throw NativeToolDeclarationError(
                reason: "'confirmation' must be \"none\" or \"required\"", problem: .badConfirmation)
        }
        var timeout = defaultTimeoutSeconds
        if let raw = object["timeout_s"] {
            guard let number = raw as? NSNumber, !(raw is Bool) else {
                throw NativeToolDeclarationError(reason: "'timeout_s' must be a number", problem: .badTimeout)
            }
            let value = number.doubleValue
            guard value >= 1, value <= maximumTimeoutSeconds else {
                throw NativeToolDeclarationError(
                    reason: "'timeout_s' must be between 1 and \(Int(maximumTimeoutSeconds))", problem: .badTimeout)
            }
            timeout = value
        }
        var enabled = true
        if let raw = object["enabled"] {
            guard let flag = raw as? Bool else {
                throw NativeToolDeclarationError(reason: "'enabled' must be true or false", problem: .badEnabled)
            }
            enabled = flag
        }
        var jsonFields: [String: String] = [:]
        if let raw = object["json_fields"] {
            guard let mapping = raw as? [String: String] else {
                throw NativeToolDeclarationError(
                    reason: "'json_fields' must map a declared string field to a request body field", problem: .badJSONFields)
            }
            guard method == .post else {
                throw NativeToolDeclarationError(reason: "'json_fields' requires the POST method", problem: .badJSONFields)
            }
            var claimed: [String: String] = [:]
            for key in mapping.keys.sorted() {
                let field = mapping[key] ?? ""
                guard properties.contains(where: { $0.name == key && $0.type == .string }) else {
                    throw NativeToolDeclarationError(
                        reason: "'json_fields' names '\(key)', which is not a declared string property", problem: .badJSONFields)
                }
                guard !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw NativeToolDeclarationError(
                        reason: "'json_fields' needs a request body field name for '\(key)'", problem: .badJSONFields)
                }
                if let existing = claimed[field] {
                    throw NativeToolDeclarationError(
                        reason: "'json_fields' maps both '\(existing)' and '\(key)' onto the request body field '\(field)'", problem: .badJSONFields)
                }
                claimed[field] = key
                if field != key, properties.contains(where: { $0.name == field }) {
                    throw NativeToolDeclarationError(
                        reason: "'json_fields' sends '\(key)' as '\(field)', which would overwrite the declared property '\(field)'", problem: .badJSONFields)
                }
            }
            jsonFields = mapping
        }
        var sendsTo: [String]?
        if let raw = object["sends_to"] {
            guard let fields = raw as? [String] else {
                throw NativeToolDeclarationError(reason: "'sends_to' must be a list of declared string fields, or an empty list for a tool that always sends to the same place", problem: .badSendsTo)
            }
            guard method == .post else {
                throw NativeToolDeclarationError(reason: "'sends_to' requires the POST method", problem: .badSendsTo)
            }
            for field in fields {
                guard properties.contains(where: { $0.name == field && $0.type == .string }) else {
                    throw NativeToolDeclarationError(
                        reason: "'sends_to' names '\(field)', which is not a declared string property", problem: .badSendsTo)
                }
            }
            guard Set(fields).count == fields.count else {
                throw NativeToolDeclarationError(reason: "'sends_to' lists the same field twice", problem: .badSendsTo)
            }
            sendsTo = fields
        }
        var verbs: [String] = []
        if let raw = object["verbs"] {
            guard let words = raw as? [String], !words.isEmpty, words.count <= 8 else {
                throw NativeToolDeclarationError(reason: "'verbs' must be a list of one to eight action words, such as [\"send\", \"post\"]", problem: .badVerbs)
            }
            guard !(method == .get && confirmation != .required) else {
                throw NativeToolDeclarationError(reason: "'verbs' only applies to a tool that changes something, not one that only reads", problem: .badVerbs)
            }
            for word in words {
                guard (1...24).contains(word.count),
                      word.allSatisfy({ ("a"..."z").contains($0) || $0 == " " }),
                      word.first != " ", word.last != " ", !word.contains("  ") else {
                    throw NativeToolDeclarationError(
                        reason: "'verbs' lists '\(word)', but each must be 1 to 24 lowercase letters, with single spaces between words", problem: .badVerbs)
                }
            }
            guard Set(words).count == words.count else {
                throw NativeToolDeclarationError(reason: "'verbs' lists the same word twice", problem: .badVerbs)
            }
            verbs = words
        }
        var declaration = NativeToolDeclaration(
            name: name, title: title, description: description, properties: properties,
            required: required, endpoint: endpoint, method: method, confirmation: confirmation,
            timeoutSeconds: timeout, enabled: enabled, jsonFields: jsonFields, source: source, sendsTo: sendsTo)
        declaration.verbs = verbs
        let summary = text(object["summary"])
        declaration.summary = summary.isEmpty ? nil : summary
        return declaration
    }

    private static func text(_ value: Any?) -> String {
        guard let value = value as? String else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isFunctionName(_ value: String) -> Bool {
        guard value.utf8.count <= 64, let first = value.unicodeScalars.first,
              first.isASCII, CharacterSet.letters.contains(first) || first == "_" else {
            return false
        }
        return value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
    }

    static let bundledSource = "bundled"

    static let bundled: [NativeToolDeclaration] = bundledDefinitions.compactMap {
        try? parse(data: Data($0.utf8), source: bundledSource)
    }

    private static let bundledDefinitions: [String] = [
        """
        {
          "name": "actions_registry",
          "title": "List available actions",
          "description": "Lists the actions the connected server can propose, with the arguments each one takes. When to use: before calling propose_action, to find a real verb and its arguments, or when the person wants to know which actions the server offers. When not to use: to carry out or propose anything, since this only reads. Effects: read only; it changes nothing. Returns verbs, each with verb, summary, args showing the shape of its arguments, risk, reversible and autonomous, and the server may add further catalog fields. Use only verbs and argument names from this result. If it fails, say plainly that the list of actions could not be loaded, and never guess a verb.",
          "parameters": {"type": "object", "properties": {}, "required": [], "additionalProperties": false},
          "endpoint": "/actions/registry",
          "method": "GET",
          "confirmation": "none",
          "summary": "Lists what your Tandem server can do for you."
        }
        """,
        """
        {
          "name": "propose_action",
          "title": "Propose an action",
          "description": "Proposes one action from the server's list for the person to approve or dismiss; nothing runs now. When to use: a specific action from that list is worth taking and the person should decide on it. When not to use: before actions_registry has given you the verb and its arguments in this conversation, so call it first; for something another tool here can do directly. Effects: the server checks the verb and arguments and, if they are valid, posts the proposal for the person's decision; the action runs only if the person approves it. Inputs: verb exactly as actions_registry lists it; args_json holding that verb's arguments as a JSON object written as a string, omitted when the verb takes none; a short title; and a body of one or two sentences on why it is worth doing. Returns ok and, on success, a preview with the risk and whether it can be reversed; when ok is false, error says what was wrong. If ok is false, fix the verb or arguments from actions_registry and retry once, otherwise tell the person it could not be proposed.",
          "parameters": {
            "type": "object",
            "properties": {
              "verb": {"type": "string", "description": "An action verb exactly as actions_registry lists it."},
              "args_json": {"type": "string", "description": "The verb's arguments as a JSON object written as a string. Omit it when the verb takes none."},
              "title": {"type": "string", "description": "A short headline for the proposal."},
              "body": {"type": "string", "description": "One or two sentences on why the action is worth taking."}
            },
            "required": ["verb", "title", "body"],
            "additionalProperties": false
          },
          "json_fields": {"args_json": "args"},
          "endpoint": "/actions/propose_card",
          "method": "POST",
          "confirmation": "none",
          "summary": "Suggests something for your Tandem server to do. You decide before anything happens."
        }
        """,
        """
        {
          "name": "author_skill",
          "title": "Write a skill",
          "description": "Proposes saving a named skill, a stored set of step-by-step instructions that can be followed again later, or replacing the skill with that name. When to use: the person wants a repeatable procedure kept so it can be reused. When not to use: a one-off answer or a preference, which you handle in the conversation; a document meant for reading, which create_background_task writes when it is offered. Effects: the app asks the person first, and the server then holds the change for approval before the skill is saved; a skill with the same name is replaced. Inputs: name, the full content, and optionally a one-line description. Returns proposed and a preview of the change. If it fails, say plainly that the skill could not be saved.",
          "parameters": {
            "type": "object",
            "properties": {
              "name": {"type": "string", "description": "The skill's name. A skill with the same name is replaced."},
              "content": {"type": "string", "description": "The full text of the skill: the steps to follow, in order."},
              "description": {"type": "string", "description": "One line summing up what the skill covers. Optional."}
            },
            "required": ["name", "content"],
            "additionalProperties": false
          },
          "endpoint": "/authoring/skill",
          "method": "POST",
          "confirmation": "required",
          "summary": "Saves a repeatable set of steps when you ask for one."
        }
        """,
    ]
}
