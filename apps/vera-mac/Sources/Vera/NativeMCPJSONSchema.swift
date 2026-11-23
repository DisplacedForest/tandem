import Foundation

struct NativeMCPJSONSchema: Sendable {
    enum Failure: Error, Equatable, LocalizedError {
        case unsupportedSchema
        case invalidArguments
        case resourceLimit

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema: return "This tool uses an unsupported argument schema"
            case .invalidArguments: return "The tool arguments do not match its schema"
            case .resourceLimit: return "The tool schema or arguments exceed validation limits"
            }
        }
    }

    private enum Dialect: String {
        case draft7 = "http://json-schema.org/draft-07/schema#"
        case draft2020 = "https://json-schema.org/draft/2020-12/schema"
    }

    let schema: NativeJSONValue
    private let dialect: Dialect
    private let definitions: [String: NativeJSONValue]
    private static let types: Set<String> = ["object", "array", "string", "number", "integer", "boolean", "null"]
    private static let annotations: Set<String> = ["title", "description", "$comment", "default", "examples", "deprecated", "readOnly", "writeOnly"]
    private static let keywords: Set<String> = ["$schema", "$defs", "$ref", "type", "properties", "required", "additionalProperties", "items", "prefixItems", "enum", "const", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties", "uniqueItems", "allOf", "anyOf", "oneOf", "not"]

    private static let largestValue = 1_048_576

    init(_ schema: NativeJSONValue) throws {
        var nodes = 0
        var bytes = 0
        try Self.measure(schema, depth: 0, nodes: &nodes, bytes: &bytes)
        self.schema = schema
        if case .object(let root) = schema, let declaration = root["$schema"] {
            guard case .string(let identifier) = declaration, let dialect = Dialect(rawValue: identifier) else { throw Failure.unsupportedSchema }
            self.dialect = dialect
        } else {
            dialect = .draft2020
        }
        if case .object(let root) = schema, case .object(let definitions)? = root["$defs"] {
            self.definitions = definitions
        } else {
            definitions = [:]
        }
        var budget = Self.steps(nodes: nodes, bytes: bytes)
        var inspected: Set<String> = []
        try inspect(schema, depth: 0, references: [], inspected: &inspected, budget: &budget)
    }

    func validate(_ value: NativeJSONValue) throws {
        var nodes = 0
        var bytes = 0
        try Self.measure(value, depth: 0, nodes: &nodes, bytes: &bytes)
        var budget = Self.steps(nodes: nodes, bytes: bytes)
        guard try matches(value, schema: schema, depth: 0, budget: &budget) else {
            throw Failure.invalidArguments
        }
    }

    private static func steps(nodes: Int, bytes: Int) -> Int { 50_000 + nodes * 16 + bytes * 2 }

    func validateResult(_ value: NativeJSONValue) throws {
        guard !Self.holdsLongNumber(value) else { return }
        do { try validate(value) } catch Failure.resourceLimit { return }
    }

    private static func holdsLongNumber(_ value: NativeJSONValue) -> Bool {
        switch value {
        case .string(let text): return NativeMCPWireJSON.carries(text)
        case .array(let items): return items.contains(where: holdsLongNumber)
        case .object(let fields): return fields.values.contains(where: holdsLongNumber)
        default: return false
        }
    }

    private static func bound(_ value: NativeJSONValue?) -> Double? {
        switch value {
        case .number(let number): return number
        case .string(let text) where NativeMCPWireJSON.carries(text): return Double(text)
        default: return nil
        }
    }

    func violation(_ value: NativeJSONValue) -> String? {
        do {
            try validate(value)
            return nil
        } catch Failure.resourceLimit {
            return "The arguments are too large to check"
        } catch Failure.unsupportedSchema {
            return "This tool's argument schema is not supported"
        } catch {}
        guard case .object(let schema) = self.schema, case .object(let values) = value else { return "Expected a JSON object" }
        if let required = schema["required"], let names = try? strings(required) {
            for name in names where Self.exactValue(name, in: values) == nil { return "Missing required field '\(Self.shown(name))'" }
        }
        let declared: [String: NativeJSONValue]
        if case .object(let properties)? = schema["properties"] { declared = properties } else { declared = [:] }
        if schema["additionalProperties"] == .bool(false),
           let name = values.keys.filter({ Self.exactValue($0, in: declared) == nil }).sorted().first {
            return "Unknown field '\(Self.shown(name))'"
        }
        for name in values.keys.sorted() {
            guard let item = values[name], let property = Self.exactValue(name, in: declared) else { continue }
            var budget = 50_000
            if (try? matches(item, schema: property, depth: 1, budget: &budget)) == true { continue }
            return "Field '\(Self.shown(name))' " + Self.expectation(item, property)
        }
        return "The arguments do not match this tool's schema"
    }

    static let vague = "does not match its schema"
    static let itemBlame = "has an item that does not match its schema"
    static let countedEndings = [" character", " characters", " item", " items", " field", " fields"]

    static func counted(_ number: Double, _ noun: String) -> String {
        plain(number) + " " + (number == 1 ? noun : noun + "s")
    }

    static let required = "is required"
    static let undeclared = "is not a field this call accepts"

    func problems(_ value: NativeJSONValue, limit: Int = 4) -> [NativeSchemaProblem] {
        var found: [NativeSchemaProblem] = []
        var budget = 50_000
        do {
            var nodes = 0
            var bytes = 0
            try Self.measure(value, depth: 0, nodes: &nodes, bytes: &bytes)
            try collect(value, schema: schema, path: "", depth: 0, limit: max(1, limit), into: &found, budget: &budget)
        } catch {
            return []
        }
        return found
    }

    private func collect(_ value: NativeJSONValue, schema: NativeJSONValue, path: String, depth: Int, limit: Int,
                         into found: inout [NativeSchemaProblem], budget: inout Int) throws {
        guard found.count < limit else { return }
        if try matches(value, schema: schema, depth: depth, budget: &budget) { return }
        var target = schema
        let before = found.count
        if case .object(var object) = schema, let ref = object["$ref"] {
            try collect(value, schema: reference(ref).1, path: path, depth: depth + 1, limit: limit, into: &found, budget: &budget)
            guard found.count == before else { return }
            object["$ref"] = nil
            target = .object(object)
        }
        if case .object(let object) = target {
            switch value {
            case .object(let properties):
                let declared: [String: NativeJSONValue]
                if case .object(let schemas)? = object["properties"] { declared = schemas } else { declared = [:] }
                if let required = object["required"] {
                    for name in try strings(required) where Self.exactValue(name, in: properties) == nil && found.count < limit {
                        found.append(NativeSchemaProblem(path: Self.joined(path, name), expected: Self.required))
                    }
                }
                for name in properties.keys.sorted() where found.count < limit {
                    guard let item = properties[name] else { continue }
                    if let child = Self.exactValue(name, in: declared) {
                        try collect(item, schema: child, path: Self.joined(path, name), depth: depth + 1, limit: limit, into: &found, budget: &budget)
                    } else if object["additionalProperties"] == .bool(false) {
                        found.append(NativeSchemaProblem(path: Self.joined(path, name), expected: Self.undeclared))
                    } else if let child = object["additionalProperties"] {
                        try collect(item, schema: child, path: Self.joined(path, name), depth: depth + 1, limit: limit, into: &found, budget: &budget)
                    }
                }
            case .array(let items):
                let prefix: [NativeJSONValue]
                if case .array(let schemas)? = object["prefixItems"] { prefix = schemas } else { prefix = [] }
                if Self.within(items.count, object) {
                    for (index, item) in items.enumerated() where found.count < limit {
                        guard let child = index < prefix.count ? prefix[index] : object["items"] else { continue }
                        try collect(item, schema: child, path: path + "[\(index)]", depth: depth + 1, limit: limit, into: &found, budget: &budget)
                    }
                }
            default: break
            }
        }
        if found.count == before, case .object(let object) = target, try typed(value, object) {
            if case .array(let members)? = object["allOf"] {
                for member in members where found.count < limit {
                    try collect(value, schema: member, path: path, depth: depth + 1, limit: limit, into: &found, budget: &budget)
                }
            }
            for key in ["anyOf", "oneOf"] where found.count == before {
                guard case .array(let forms)? = object[key] else { continue }
                var fitting = 0
                for form in forms {
                    if try matches(value, schema: form, depth: depth + 1, budget: &budget) { fitting += 1 }
                }
                if fitting == 0 {
                    found.append(NativeSchemaProblem(path: path.isEmpty ? "arguments" : path, expected: "must fit one of the allowed forms"))
                } else if key == "oneOf", fitting > 1 {
                    found.append(NativeSchemaProblem(path: path.isEmpty ? "arguments" : path, expected: "must fit only one of the allowed forms"))
                }
            }
        }
        if found.count == before, found.count < limit {
            var expected = Self.expectation(value, target)
            if expected == Self.itemBlame { expected = Self.vague }
            if case .string = value, expected == "must be a non-empty string" {
                expected += Self.measured(value, target)
            } else if Self.countedEndings.contains(where: { expected.hasSuffix($0) }) {
                expected += Self.measured(value, target)
            }
            found.append(NativeSchemaProblem(path: path.isEmpty ? "arguments" : path, expected: expected))
        }
    }

    private func typed(_ value: NativeJSONValue, _ object: [String: NativeJSONValue]) throws -> Bool {
        guard let type = object["type"] else { return true }
        let names: [String]
        if case .string(let name) = type { names = [name] } else { names = try strings(type) }
        return names.contains { isType(value, $0) }
    }

    private static func within(_ count: Int, _ object: [String: NativeJSONValue]) -> Bool {
        if case .number(let bound)? = object["minItems"], Double(count) < bound { return false }
        if case .number(let bound)? = object["maxItems"], Double(count) > bound { return false }
        return true
    }

    private static func measured(_ value: NativeJSONValue, _ schema: NativeJSONValue) -> String {
        guard case .object(let object) = schema else { return "" }
        func outside(_ count: Int, _ low: String, _ high: String) -> Bool {
            if case .number(let bound)? = object[low], Double(count) < bound { return true }
            if case .number(let bound)? = object[high], Double(count) > bound { return true }
            return false
        }
        switch value {
        case .string(let text) where outside(text.unicodeScalars.count, "minLength", "maxLength"):
            return ", and this one has \(text.unicodeScalars.count)"
        case .array(let items) where outside(items.count, "minItems", "maxItems"):
            return ", and this one has \(items.count)"
        case .object(let fields) where outside(fields.count, "minProperties", "maxProperties"):
            return ", and this one has \(fields.count)"
        default: return ""
        }
    }

    static func shown(_ name: String) -> String {
        let clean = NativeToolRepair.plain(name).replacingOccurrences(of: "'", with: " ")
        return String(String.UnicodeScalarView(clean.unicodeScalars.prefix(64)))
    }

    private static func joined(_ path: String, _ name: String) -> String {
        let shown = Self.shown(name)
        return path.isEmpty ? shown : path + "." + shown
    }

    private static func expectation(_ value: NativeJSONValue, _ schema: NativeJSONValue) -> String {
        guard case .object(let object) = schema else { return "is not accepted" }
        var declared: String?
        if case .string(let name)? = object["type"] { declared = name }
        if case .array(let names)? = object["type"] {
            let kinds = names.compactMap { name -> String? in if case .string(let text) = name { text } else { nil } }
            let fits = kinds.contains { kind in
                switch (value, kind) {
                case (.object, "object"), (.array, "array"), (.string, "string"), (.number, "number"), (.bool, "boolean"), (.null, "null"): return true
                case (.number(let number), "integer"): return number.rounded(.towardZero) == number
                default: return false
                }
            }
            if !fits, !kinds.isEmpty { return "must be one of these kinds: " + kinds.joined(separator: ", ") }
        }
        let type: String
        if let declared {
            type = declared
        } else {
            switch value {
            case .string: type = "string"
            case .number: type = "number"
            case .array: type = "array"
            case .object: type = "object"
            case .bool: type = "boolean"
            case .null: type = "null"
            }
        }
        switch (type, value) {
        case ("string", .string(let text)):
            if case .number(let minimum)? = object["minLength"], Double(text.unicodeScalars.count) < minimum {
                return minimum <= 1 ? "must be a non-empty string" : "must be at least " + counted(minimum, "character")
            }
            if case .number(let maximum)? = object["maxLength"], Double(text.unicodeScalars.count) > maximum {
                return "must be at most " + counted(maximum, "character")
            }
        case ("string", _):
            if case .number(let minimum)? = object["minLength"], minimum >= 1 { return "must be a non-empty string" }
            return "must be a string"
        case ("boolean", .bool): break
        case ("boolean", _): return "must be a boolean"
        case ("integer", .number(let number)), ("number", .number(let number)):
            if type == "integer", number.rounded(.towardZero) != number { return "must be a whole number" }
            if case .number(let minimum)? = object["minimum"], number < minimum { return "must be at least \(plain(minimum))" }
            if case .number(let maximum)? = object["maximum"], number > maximum { return "must be at most \(plain(maximum))" }
            if case .number(let bound)? = object["exclusiveMinimum"], number <= bound { return "must be more than \(plain(bound))" }
            if case .number(let bound)? = object["exclusiveMaximum"], number >= bound { return "must be less than \(plain(bound))" }
        case ("integer", _): return "must be a whole number"
        case ("number", _): return "must be a number"
        case ("array", .array(let items)):
            if case .number(let minimum)? = object["minItems"], Double(items.count) < minimum { return "must have at least " + counted(minimum, "item") }
            if case .number(let maximum)? = object["maxItems"], Double(items.count) > maximum { return "must have at most " + counted(maximum, "item") }
            if case .bool(true)? = object["uniqueItems"], Set(items.map(ExactValue.init)).count != items.count { return "must not repeat an item" }
            if declared == "array", !items.isEmpty, object["items"] != nil || object["prefixItems"] != nil, object["const"] == nil, object["enum"] == nil {
                return itemBlame
            }
        case ("array", _): return "must be a list"
        case ("object", .object(let fields)):
            if case .number(let minimum)? = object["minProperties"], Double(fields.count) < minimum { return "must have at least " + counted(minimum, "field") }
            if case .number(let maximum)? = object["maxProperties"], Double(fields.count) > maximum { return "must have at most " + counted(maximum, "field") }
        case ("object", _): return "must be an object"
        case ("null", .null): break
        case ("null", _): return "must be null"
        default: break
        }
        if let fixed = object["const"], ExactValue(fixed) != ExactValue(value) {
            switch fixed {
            case .string(let text):
                let simple = text.unicodeScalars.count <= 80 && !text.isEmpty && NativeToolRepair.plain(text) == text && !text.contains("\"")
                return simple ? "must be exactly \"" + text + "\"" : "must be one fixed value"
            case .number(let number): return "must be exactly \(plain(number))"
            case .bool(let flag): return "must be exactly \(flag ? "true" : "false")"
            case .null: return "must be null"
            default: return "must be one fixed value"
            }
        }
        if case .array(let choices)? = object["enum"], !choices.contains(where: { ExactValue($0) == ExactValue(value) }) {
            let names = choices.compactMap { choice -> String? in
                switch choice {
                case .string(let text): return text
                case .number(let number): return plain(number)
                case .bool(let flag): return flag ? "true" : "false"
                case .null: return "null"
                default: return nil
                }
            }
            if names.count == choices.count, !names.isEmpty { return "must be one of: " + names.joined(separator: ", ") }
            return "must be one of the listed values"
        }
        return vague
    }

    private static func plain(_ number: Double) -> String {
        number.rounded(.towardZero) == number && abs(number) < 1e18 ? String(Int(number)) : String(number)
    }

    private static func measure(_ value: NativeJSONValue, depth: Int, nodes: inout Int, bytes: inout Int) throws {
        nodes += 1
        guard depth <= 48, nodes <= largestValue, bytes <= largestValue else { throw Failure.resourceLimit }
        switch value {
        case .object(let object):
            for (key, item) in object {
                bytes += key.utf8.count
                try measure(item, depth: depth + 1, nodes: &nodes, bytes: &bytes)
            }
        case .array(let array):
            for item in array { try measure(item, depth: depth + 1, nodes: &nodes, bytes: &bytes) }
        case .string(let string): bytes += string.utf8.count
        case .number(let number):
            guard number.isFinite else { throw Failure.resourceLimit }
        case .bool, .null: break
        }
        guard bytes <= largestValue else { throw Failure.resourceLimit }
    }

    private func spend(_ budget: inout Int, depth: Int) throws {
        budget -= 1
        guard depth <= 48, budget >= 0 else { throw Failure.resourceLimit }
    }

    private func reference(_ value: NativeJSONValue) throws -> (String, NativeJSONValue) {
        guard case .string(let path) = value, path.hasPrefix("#/$defs/") else { throw Failure.unsupportedSchema }
        let token = String(path.dropFirst(8))
        guard !token.contains("/"), !token.contains("%") else { throw Failure.unsupportedSchema }
        var index = token.startIndex
        var name = ""
        while index < token.endIndex {
            let character = token[index]
            index = token.index(after: index)
            if character == "~" {
                guard index < token.endIndex else { throw Failure.unsupportedSchema }
                let escaped = token[index]
                guard escaped == "0" || escaped == "1" else { throw Failure.unsupportedSchema }
                name.append(escaped == "0" ? "~" : "/")
                index = token.index(after: index)
            } else {
                name.append(character)
            }
        }
        guard let target = Self.exactValue(name, in: definitions) else { throw Failure.unsupportedSchema }
        return (name, target)
    }

    private func inspect(_ value: NativeJSONValue, depth: Int, references: Set<String>, inspected: inout Set<String>, budget: inout Int) throws {
        try spend(&budget, depth: depth)
        if case .bool = value { return }
        guard case .object(let object) = value,
              Set(object.keys).isSubset(of: Self.keywords.union(Self.annotations)) else { throw Failure.unsupportedSchema }
        if dialect == .draft7, !Set(object.keys).isDisjoint(with: ["$ref", "$defs", "prefixItems", "deprecated"]) { throw Failure.unsupportedSchema }
        for (key, value) in object {
            switch key {
            case "$schema":
                guard case .string(let identifier) = value, identifier == dialect.rawValue, depth == 0 else { throw Failure.unsupportedSchema }
            case "$defs":
                guard depth == 0, case .object(let definitions) = value else { throw Failure.unsupportedSchema }
                for (name, definition) in definitions where !inspected.contains(name) {
                    try inspect(definition, depth: depth + 1, references: references.union([name]), inspected: &inspected, budget: &budget)
                    inspected.insert(name)
                }
            case "$ref":
                let (name, target) = try reference(value)
                guard !references.contains(name) else { throw Failure.unsupportedSchema }
                if inspected.contains(name) { continue }
                try inspect(target, depth: depth + 1, references: references.union([name]), inspected: &inspected, budget: &budget)
                inspected.insert(name)
            case "type":
                let names: [String]
                if case .string(let name) = value { names = [name] }
                else { names = try strings(value) }
                guard !names.isEmpty, Set(names).count == names.count, Set(names).isSubset(of: Self.types) else { throw Failure.unsupportedSchema }
            case "properties":
                guard case .object(let properties) = value else { throw Failure.unsupportedSchema }
                for property in properties.values { try inspect(property, depth: depth + 1, references: references, inspected: &inspected, budget: &budget) }
            case "required":
                let names = try strings(value)
                guard Set(names).count == names.count else { throw Failure.unsupportedSchema }
            case "additionalProperties", "items", "not":
                try inspect(value, depth: depth + 1, references: references, inspected: &inspected, budget: &budget)
            case "prefixItems", "allOf", "anyOf", "oneOf":
                guard case .array(let children) = value, !children.isEmpty else { throw Failure.unsupportedSchema }
                for child in children { try inspect(child, depth: depth + 1, references: references, inspected: &inspected, budget: &budget) }
            case "enum":
                guard case .array(let choices) = value, !choices.isEmpty, Set(choices.map(ExactValue.init)).count == choices.count else { throw Failure.unsupportedSchema }
            case "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum":
                guard Self.bound(value) != nil else { throw Failure.unsupportedSchema }
            case "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties":
                guard let number = Self.bound(value), number >= 0, number.rounded(.towardZero) == number else { throw Failure.unsupportedSchema }
            case "uniqueItems", "deprecated", "readOnly", "writeOnly":
                guard case .bool = value else { throw Failure.unsupportedSchema }
            case "title", "description", "$comment":
                guard case .string = value else { throw Failure.unsupportedSchema }
            case "examples":
                guard case .array = value else { throw Failure.unsupportedSchema }
            case "const", "default": break
            default: throw Failure.unsupportedSchema
            }
        }
    }

    private func strings(_ value: NativeJSONValue) throws -> [String] {
        guard case .array(let array) = value else { throw Failure.unsupportedSchema }
        return try array.map {
            guard case .string(let string) = $0 else { throw Failure.unsupportedSchema }
            return string
        }
    }

    private func isType(_ value: NativeJSONValue, _ type: String) -> Bool {
        switch (value, type) {
        case (.object, "object"), (.array, "array"), (.string, "string"), (.number, "number"), (.bool, "boolean"), (.null, "null"): return true
        case (.number(let number), "integer"): return number.rounded(.towardZero) == number
        default: return false
        }
    }

    private func within(_ number: Double, _ object: [String: NativeJSONValue], min: String, max: String) -> Bool {
        if let bound = Self.bound(object[min]), number < bound { return false }
        if let bound = Self.bound(object[max]), number > bound { return false }
        return true
    }

    private static func exactValue(_ key: String, in object: [String: NativeJSONValue]) -> NativeJSONValue? {
        guard let index = object.index(forKey: key), object.keys[index].utf8.elementsEqual(key.utf8) else { return nil }
        return object.values[index]
    }

    private struct ExactValue: Hashable {
        let value: NativeJSONValue
        init(_ value: NativeJSONValue) { self.value = value }

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs.value, rhs.value) {
            case (.string(let a), .string(let b)): return a.utf8.elementsEqual(b.utf8)
            case (.array(let a), .array(let b)):
                return a.count == b.count && zip(a, b).allSatisfy { Self($0) == Self($1) }
            case (.object(let a), .object(let b)):
                return a.count == b.count && a.allSatisfy { key, value in
                    guard let other = NativeMCPJSONSchema.exactValue(key, in: b) else { return false }
                    return Self(value) == Self(other)
                }
            default: return lhs.value == rhs.value
            }
        }

        func hash(into hasher: inout Hasher) {
            switch value {
            case .string(let text): hasher.combine(0); hasher.combine(Array(text.utf8))
            case .array(let items):
                hasher.combine(1); hasher.combine(items.count)
                for item in items { hasher.combine(Self(item)) }
            case .object(let properties):
                hasher.combine(2); hasher.combine(properties.count)
                for key in properties.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                    hasher.combine(Array(key.utf8)); hasher.combine(Self(properties[key]!))
                }
            default: hasher.combine(3); hasher.combine(value)
            }
        }
    }

    private func equal(_ a: NativeJSONValue, _ b: NativeJSONValue, budget: inout Int) throws -> Bool {
        try spend(&budget, depth: 0)
        switch (a, b) {
        case (.string(let a), .string(let b)):
            budget -= a.utf8.count + b.utf8.count
            guard budget >= 0 else { throw Failure.resourceLimit }
            return a.utf8.elementsEqual(b.utf8)
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return false }
            for (left, right) in zip(a, b) { if try !equal(left, right, budget: &budget) { return false } }
            return true
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for (key, value) in a {
                budget -= key.utf8.count
                guard budget >= 0 else { throw Failure.resourceLimit }
                guard let other = Self.exactValue(key, in: b), try equal(value, other, budget: &budget) else { return false }
            }
            return true
        default: return a == b
        }
    }

    private func matches(_ value: NativeJSONValue, schema: NativeJSONValue, depth: Int, budget: inout Int) throws -> Bool {
        try spend(&budget, depth: depth)
        if case .bool(let allowed) = schema { return allowed }
        guard case .object(let object) = schema else { throw Failure.unsupportedSchema }
        if let ref = object["$ref"], try !matches(value, schema: reference(ref).1, depth: depth + 1, budget: &budget) { return false }
        if let type = object["type"] {
            let names: [String]
            if case .string(let name) = type { names = [name] } else { names = try strings(type) }
            if !names.contains(where: { isType(value, $0) }) { return false }
        }
        if let constant = object["const"], try !equal(value, constant, budget: &budget) { return false }
        if case .array(let choices)? = object["enum"] {
            var found = false
            for choice in choices {
                if try equal(value, choice, budget: &budget) { found = true; break }
            }
            if !found { return false }
        }
        for key in ["allOf", "anyOf", "oneOf"] {
            if case .array(let alternatives)? = object[key] {
                var count = 0
                for alternative in alternatives {
                    if try matches(value, schema: alternative, depth: depth + 1, budget: &budget) { count += 1 }
                }
                if key == "allOf" && count != alternatives.count { return false }
                if key == "anyOf" && count == 0 { return false }
                if key == "oneOf" && count != 1 { return false }
            }
        }
        if let inverse = object["not"], try matches(value, schema: inverse, depth: depth + 1, budget: &budget) { return false }
        switch value {
        case .object(let properties):
            if !within(Double(properties.count), object, min: "minProperties", max: "maxProperties") { return false }
            if let required = object["required"], try !strings(required).allSatisfy({ Self.exactValue($0, in: properties) != nil }) { return false }
            let declared: [String: NativeJSONValue]
            if case .object(let schemas)? = object["properties"] { declared = schemas } else { declared = [:] }
            for (name, property) in properties {
                if let child = Self.exactValue(name, in: declared) ?? object["additionalProperties"],
                   try !matches(property, schema: child, depth: depth + 1, budget: &budget) { return false }
            }
        case .array(let items):
            if !within(Double(items.count), object, min: "minItems", max: "maxItems") { return false }
            if case .bool(true)? = object["uniqueItems"], Set(items.map(ExactValue.init)).count != items.count { return false }
            let prefix: [NativeJSONValue]
            if case .array(let schemas)? = object["prefixItems"] { prefix = schemas } else { prefix = [] }
            for (index, item) in items.enumerated() {
                if let child = index < prefix.count ? prefix[index] : object["items"],
                   try !matches(item, schema: child, depth: depth + 1, budget: &budget) { return false }
            }
        case .string(let string):
            if !within(Double(string.unicodeScalars.count), object, min: "minLength", max: "maxLength") { return false }
        case .number(let number):
            if !within(number, object, min: "minimum", max: "maximum") { return false }
            if let bound = Self.bound(object["exclusiveMinimum"]), number <= bound { return false }
            if let bound = Self.bound(object["exclusiveMaximum"]), number >= bound { return false }
        case .bool, .null: break
        }
        return true
    }
}

typealias NativeJSONSchema = NativeMCPJSONSchema

struct NativeSchemaProblem: Codable, Equatable, Sendable {
    let path: String
    let expected: String
}

final class NativeToolSchemaCache: @unchecked Sendable {
    static let shared = NativeToolSchemaCache()
    private let lock = NSLock()
    private var compiled: [[UInt8]: NativeJSONSchema?] = [:]

    func validator(_ schema: NativeJSONValue) -> NativeJSONSchema? {
        let key = Self.exactKey(schema)
        lock.lock()
        defer { lock.unlock() }
        if let known = compiled[key] { return known }
        if compiled.count >= 1_024 { compiled.removeAll() }
        let built = try? NativeJSONSchema(schema)
        compiled[key] = built
        return built
    }

    static func exactKey(_ value: NativeJSONValue) -> [UInt8] {
        var bytes: [UInt8] = []
        append(value, to: &bytes)
        return bytes
    }

    private static func append(_ text: String, to bytes: inout [UInt8]) {
        let utf8 = Array(text.utf8)
        bytes.append(contentsOf: String(utf8.count).utf8)
        bytes.append(0x3A)
        bytes.append(contentsOf: utf8)
    }

    private static func append(_ value: NativeJSONValue, to bytes: inout [UInt8]) {
        switch value {
        case .null: bytes.append(0x6E)
        case .bool(let flag): bytes.append(flag ? 0x74 : 0x66)
        case .number(let number):
            bytes.append(0x23)
            withUnsafeBytes(of: number.bitPattern.bigEndian) { bytes.append(contentsOf: $0) }
        case .string(let text):
            bytes.append(0x73)
            append(text, to: &bytes)
        case .array(let items):
            bytes.append(0x5B)
            bytes.append(contentsOf: String(items.count).utf8)
            bytes.append(0x3A)
            for item in items { append(item, to: &bytes) }
            bytes.append(0x5D)
        case .object(let object):
            bytes.append(0x7B)
            bytes.append(contentsOf: String(object.count).utf8)
            bytes.append(0x3A)
            for (key, item) in object.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }) {
                append(key, to: &bytes)
                append(item, to: &bytes)
            }
            bytes.append(0x7D)
        }
    }
}
