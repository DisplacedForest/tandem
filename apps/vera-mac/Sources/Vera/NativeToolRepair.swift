import Foundation

enum NativeToolCallFault: String, Codable, Equatable, Sendable {
    case malformedArguments = "malformed_arguments"
    case unknownTool = "unknown_tool"
    case invalidArguments = "invalid_arguments"
    case unsupportedValue = "unsupported_value"
    case invalidResult = "invalid_result"
}

struct NativeToolCallProblem: Error, LocalizedError, Equatable, Sendable {
    let message: String
    var fields: [String: NativeJSONValue] = [:]

    var errorDescription: String? { message }

    var fault: NativeToolCallFault? {
        guard case .string(let name)? = fields["fault"] else { return nil }
        return NativeToolCallFault(rawValue: name)
    }

    var value: NativeJSONValue {
        var object = fields
        let leading = String(message.prefix(NativeToolRepair.maximumMessage))
        object["error"] = .string(leading)
        if leading != message {
            object["truncated"] = .bool(true)
            object["truncation_reason"] = .string(NativeToolResultBudget.errorCut)
        }
        return .object(object)
    }
}

struct NativeToolRepairs: Codable, Equatable, Sendable {
    static let maximumRepairs = 2
    static let unknownKey = "\u{0}unknown"

    private(set) var counts: [String: Int] = [:]
    private(set) var closed: [String] = []

    func isClosed(_ key: String) -> Bool { closed.contains(key) }

    mutating func settled(_ key: String) {
        guard !isClosed(key) else { return }
        counts[key] = nil
    }

    mutating func answer(_ problem: NativeToolCallProblem, key: String) -> NativeToolCallProblem {
        guard !isClosed(key) else { return NativeToolRepair.closed(problem) }
        let failures = counts[key, default: 0] + 1
        counts[key] = failures
        guard failures <= Self.maximumRepairs else {
            closed.append(key)
            counts[key] = nil
            return NativeToolRepair.closed(problem)
        }
        var answer = problem
        answer.fields["repairs_left"] = .number(Double(Self.maximumRepairs - failures + 1))
        return answer
    }
}

struct NativeToolNeverRan: Equatable, Sendable {
    private(set) var any = false

    mutating func record(_ problem: NativeToolCallProblem) {
        guard problem.fields["not_run"] == .bool(true), problem.fields["outcome"] == nil else { return }
        any = true
    }

    var line: String { any ? NativeToolRepair.neverRan : "" }
}

enum NativeToolRepair {
    static let maximumMessage = 500
    static let maximumProblems = 4
    static let maximumOffered = 24
    static let unsupportedDetail = "Arguments contain an unsupported JSON value"
    static let correct = "Nothing ran. Correct the arguments and send this call again."
    static let choose = "Nothing ran. Use one of the offered names exactly as written."
    static let stop = "Nothing ran, so nothing was started, saved or sent. This call is closed for now. Do not send it again and do not say it was done. Tell the person plainly what could not be done."
    static let neverRan = " Some calls in this turn were refused and never ran, so nothing they asked for was started, saved or sent. Their results above say which. Say that plainly and do not describe any of it as done."
    static let unconfirmed = "This may or may not have happened. Do not send it again. Tell the person it could not be confirmed and that they should check."
    static let neverRanOutcome = "never ran"
    static let unknownStep = "A step that isn't available here"
    static let notAvailable = "It isn't something I can do in this work, so it never ran."
    static let notCorrected = "The request I put together for it wasn't valid, and I couldn't correct it in \(NativeToolRepairs.maximumRepairs + 1) tries, so it never ran. Asking again, or asking for less at once, may work."

    static func reason(_ fault: NativeToolCallFault?) -> String {
        fault == .unknownTool ? notAvailable : notCorrected
    }

    static let refusedTooOften = "This call was refused too many times"
    static let repeated = "An earlier call with these exact arguments may already have happened, so this one was not run."
    static let emptyResult = "Nothing came back, so this can't be counted as done."
    static let mismatchedResult = "What came back didn't have the declared shape, so it can't be counted as done."
    static let hidden: Set<String> = ["not_run", "fault", "problems", "offered", "fix", "repairs_left", "closed", "outcome", "action"]
    static let maximumNamed = 80

    static func plain(_ text: String) -> String {
        let hidden: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate]
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let joiner = scalar.value == 0x200C || scalar.value == 0x200D
            scalars.append(!joiner && hidden.contains(scalar.properties.generalCategory) ? " " : scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    static func titled(_ definition: NativeToolDefinition) -> String {
        String(String.UnicodeScalarView(plain(definition.title).unicodeScalars.prefix(120)))
    }

    static func quoted(_ text: String) -> String? {
        let line = plain(text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
        guard !line.isEmpty else { return nil }
        let shown = line.unicodeScalars.count > maximumNamed ? String(String.UnicodeScalarView(line.unicodeScalars.prefix(maximumNamed))) + "..." : line
        return "\"" + shown.replacingOccurrences(of: "\"", with: "'") + "\""
    }

    static func described(_ definition: NativeToolDefinition?, raw: String) -> String {
        guard let definition else { return unknownStep }
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let values = try? object.mapValues({ try NativeJSONValue(any: $0) }) else { return titled(definition) }
        if let own = definition.summary?(values) { return own }
        guard let subject = NativeCompanionWorker.subject(values).flatMap(quoted) else { return titled(definition) }
        return titled(definition) + " " + subject
    }

    static func named(_ problem: NativeToolCallProblem, _ definition: NativeToolDefinition?, raw: String) -> NativeToolCallProblem {
        var named = problem
        named.fields["action"] = .string(described(definition, raw: raw))
        return named
    }


    static func problem(_ definition: NativeToolDefinition, raw: String, error: Error) -> NativeToolCallProblem {
        guard case .invalidArguments(let detail)? = error as? NativeToolError else {
            return make(NativeToolError.invalidArguments(unsupportedDetail).localizedDescription, .unsupportedValue,
                        problems: [NativeSchemaProblem(path: "arguments", expected: "must be a smaller, plainer JSON object with no repeated names")])
        }
        let message = error.localizedDescription
        guard let data = raw.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return make(message, .malformedArguments, problems: [NativeSchemaProblem(path: "arguments", expected: "must be one valid JSON object")])
        }
        guard let object = any as? [String: Any] else {
            return make(message, .invalidArguments, problems: [NativeSchemaProblem(path: "arguments", expected: "must be a JSON object")])
        }
        guard let converted = try? object.mapValues({ try NativeJSONValue(any: $0) }), detail != unsupportedDetail else {
            return make(message, .unsupportedValue, problems: [])
        }
        guard let validator = NativeToolSchemaCache.shared.validator(definition.parameters) else {
            return make(message, .invalidArguments, problems: [])
        }
        let values = NativeJSONValue.object(definition.withoutSpareNulls(converted))
        do { try validator.validate(values) } catch NativeMCPJSONSchema.Failure.resourceLimit {
            return make(message, .unsupportedValue, problems: [NativeSchemaProblem(path: "arguments", expected: "must be smaller")])
        } catch {}
        let problems = validator.problems(values, limit: maximumProblems)
        guard let first = problems.first else { return make(message, .invalidArguments, problems: problems) }
        if first.path == "arguments" {
            guard first.expected != NativeMCPJSONSchema.vague else { return make(message, .invalidArguments, problems: problems) }
            let whole = NativeToolError.invalidArguments("The arguments " + String(first.expected.prefix(200))).localizedDescription
            return make(whole, .invalidArguments, problems: problems)
        }
        let nested = first.path.contains(".") || first.path.contains("[")
        if !nested, first.expected == NativeMCPJSONSchema.required || first.expected == NativeMCPJSONSchema.undeclared {
            return make(message, .invalidArguments, problems: problems)
        }
        let specific = NativeToolError.invalidArguments("Field '\(first.path.prefix(160))' \(first.expected.prefix(200))").localizedDescription
        return make(specific, .invalidArguments, problems: problems)
    }

    static func unknown(_ message: String, offered: [String]) -> NativeToolCallProblem {
        let names = offered.sorted().prefix(maximumOffered).map { NativeJSONValue.string(String($0.prefix(64))) }
        return NativeToolCallProblem(message: message, fields: [
            "not_run": .bool(true), "fault": .string(NativeToolCallFault.unknownTool.rawValue),
            "offered": .array(Array(names)), "fix": .string(choose),
        ])
    }

    static func closed(_ problem: NativeToolCallProblem) -> NativeToolCallProblem {
        var fields = problem.fields
        fields["offered"] = nil
        fields["repairs_left"] = .number(0)
        fields["closed"] = .bool(true)
        fields["not_run"] = .bool(true)
        fields["fix"] = .string(stop)
        return NativeToolCallProblem(message: problem.message, fields: fields)
    }

    static func closed(key: String, unknown: String) -> NativeToolCallProblem {
        let missing = key == NativeToolRepairs.unknownKey
        let message = missing ? unknown : NativeToolError.invalidArguments(refusedTooOften).localizedDescription
        let fault: NativeToolCallFault = missing ? .unknownTool : .invalidArguments
        return closed(NativeToolCallProblem(message: message, fields: ["fault": .string(fault.rawValue)]))
    }

    static func uncertain(_ message: String) -> NativeToolCallProblem {
        NativeToolCallProblem(message: message, fields: ["outcome": .string("uncertain"), "fix": .string(unconfirmed)])
    }

    static func repeatedWrite() -> NativeToolCallProblem {
        NativeToolCallProblem(message: repeated, fields: ["not_run": .bool(true), "outcome": .string("uncertain"), "fix": .string(unconfirmed)])
    }

    static func resultProblem(_ definition: NativeToolDefinition, _ value: NativeJSONValue, write: Bool) -> NativeToolCallProblem? {
        var message: String?
        switch value {
        case .null: message = emptyResult
        case .string(let text) where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: message = emptyResult
        default: break
        }
        if message == nil, !definition.checksOwnResult, let schema = definition.outputSchema,
           !NativeToolLoop.resultFailed(value, toolName: definition.name),
           let validator = NativeToolSchemaCache.shared.validator(schema), validator.violation(value) != nil {
            message = mismatchedResult
        }
        guard let message else { return nil }
        var fields: [String: NativeJSONValue] = ["fault": .string(NativeToolCallFault.invalidResult.rawValue)]
        if write {
            fields["outcome"] = .string("uncertain")
            fields["fix"] = .string(unconfirmed)
        }
        return NativeToolCallProblem(message: message, fields: fields)
    }

    static func handlerFault(_ message: String) -> NativeToolCallProblem {
        make(message, .invalidArguments, problems: [])
    }

    private static func make(_ message: String, _ fault: NativeToolCallFault, problems: [NativeSchemaProblem]) -> NativeToolCallProblem {
        var fields: [String: NativeJSONValue] = [
            "not_run": .bool(true), "fault": .string(fault.rawValue), "fix": .string(correct),
        ]
        if !problems.isEmpty {
            fields["problems"] = .array(problems.prefix(maximumProblems).map {
                .object(["at": .string(String($0.path.prefix(160))), "expected": .string(String($0.expected.prefix(200)))])
            })
        }
        return NativeToolCallProblem(message: message, fields: fields)
    }
}
