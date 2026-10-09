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
        var budget = 50_000
        try inspect(schema, depth: 0, references: [], budget: &budget)
    }

    func validate(_ value: NativeJSONValue) throws {
        var nodes = 0
        var bytes = 0
        try Self.measure(value, depth: 0, nodes: &nodes, bytes: &bytes)
        var budget = 50_000
        guard try matches(value, schema: schema, depth: 0, budget: &budget) else {
            throw Failure.invalidArguments
        }
    }

    private static func measure(_ value: NativeJSONValue, depth: Int, nodes: inout Int, bytes: inout Int) throws {
        nodes += 1
        guard depth <= 48, nodes <= 8_192, bytes <= 1_048_576 else { throw Failure.resourceLimit }
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
        guard bytes <= 1_048_576 else { throw Failure.resourceLimit }
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

    private func inspect(_ value: NativeJSONValue, depth: Int, references: Set<String>, budget: inout Int) throws {
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
                for (name, definition) in definitions {
                    try inspect(definition, depth: depth + 1, references: references.union([name]), budget: &budget)
                }
            case "$ref":
                let (name, target) = try reference(value)
                guard !references.contains(name) else { throw Failure.unsupportedSchema }
                try inspect(target, depth: depth + 1, references: references.union([name]), budget: &budget)
            case "type":
                let names: [String]
                if case .string(let name) = value { names = [name] }
                else { names = try strings(value) }
                guard !names.isEmpty, Set(names).count == names.count, Set(names).isSubset(of: Self.types) else { throw Failure.unsupportedSchema }
            case "properties":
                guard case .object(let properties) = value else { throw Failure.unsupportedSchema }
                for property in properties.values { try inspect(property, depth: depth + 1, references: references, budget: &budget) }
            case "required":
                let names = try strings(value)
                guard Set(names).count == names.count else { throw Failure.unsupportedSchema }
            case "additionalProperties", "items", "not":
                try inspect(value, depth: depth + 1, references: references, budget: &budget)
            case "prefixItems", "allOf", "anyOf", "oneOf":
                guard case .array(let children) = value, !children.isEmpty else { throw Failure.unsupportedSchema }
                for child in children { try inspect(child, depth: depth + 1, references: references, budget: &budget) }
            case "enum":
                guard case .array(let choices) = value, !choices.isEmpty, Set(choices.map(ExactValue.init)).count == choices.count else { throw Failure.unsupportedSchema }
            case "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum":
                guard case .number = value else { throw Failure.unsupportedSchema }
            case "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties":
                guard case .number(let number) = value, number >= 0, number.rounded(.towardZero) == number else { throw Failure.unsupportedSchema }
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
        if case .number(let bound)? = object[min], number < bound { return false }
        if case .number(let bound)? = object[max], number > bound { return false }
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
            if case .number(let bound)? = object["exclusiveMinimum"], number <= bound { return false }
            if case .number(let bound)? = object["exclusiveMaximum"], number >= bound { return false }
        case .bool, .null: break
        }
        return true
    }
}
