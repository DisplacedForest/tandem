import Foundation

enum NativeMCPJSONSchemaSelftest {
    private enum TestFailure: Error { case assertion(Int) }

    static func run() throws {
        var checks = 0
        func check(_ condition: Bool) throws {
            checks += 1
            guard condition else { throw TestFailure.assertion(checks) }
        }
        func json(_ raw: String) throws -> NativeJSONValue {
            try NativeJSONValue.piDecode(JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]))
        }
        func accepts(_ schema: String, _ value: String) throws {
            let original = try json(schema)
            let validator = try NativeMCPJSONSchema(original)
            try check(validator.schema == original)
            try validator.validate(json(value))
        }
        func fails(_ expected: NativeMCPJSONSchema.Failure, _ operation: () throws -> Void) throws {
            do {
                try operation()
                throw TestFailure.assertion(checks + 1)
            } catch let error as NativeMCPJSONSchema.Failure {
                try check(error == expected)
            }
        }
        func rejects(_ schema: String, _ value: String) throws {
            let validator = try NativeMCPJSONSchema(json(schema))
            try fails(.invalidArguments) { try validator.validate(json(value)) }
        }
        func unsupported(_ schema: String) throws {
            try fails(.unsupportedSchema) { _ = try NativeMCPJSONSchema(json(schema)) }
        }

        try accepts("true", "null")
        try rejects("false", "{}")
        try accepts("{}", "[1,true,null]")
        try accepts(#"{"type":"integer"}"#, "1")
        try rejects(#"{"type":"integer"}"#, "true")
        try rejects(#"{"type":"boolean"}"#, "1")
        try rejects(#"{"type":"number"}"#, "false")
        try rejects(#"{"type":"integer"}"#, "1.5")
        try accepts(#"{"type":["string","null"]}"#, "null")
        try accepts(#"{"type":["string","null"]}"#, #""valid""#)
        try rejects(#"{"type":["string","null"]}"#, "1")
        try accepts(#"{"type":"object","required":["id"]}"#, #"{"id":null}"#)
        try rejects(#"{"type":"object","required":["id"]}"#, "{}")
        try rejects(#"{"required":["id"],"properties":{}}"#, "{}")
        try accepts(#"{"required":["id"]}"#, "null")
        try rejects(#"{"properties":{"id":false}}"#, #"{"id":1}"#)
        try rejects(#"{"additionalProperties":false}"#, #"{"extra":1}"#)
        try accepts(#"{"properties":{"id":{"type":"integer"}},"additionalProperties":{"type":"string"}}"#, #"{"id":2,"extra":"ok"}"#)
        try rejects(#"{"properties":{"id":{"type":"integer"}},"additionalProperties":{"type":"string"}}"#, #"{"id":2,"extra":3}"#)
        try rejects(#"{"required":["\u00e9"]}"#, #"{"e\u0301":1}"#)
        try rejects(#"{"properties":{"\u00e9":true},"additionalProperties":false}"#, #"{"e\u0301":1}"#)
        try rejects(#"{"const":"\u00e9"}"#, #""e\u0301""#)
        try rejects(#"{"enum":["\u00e9"]}"#, #""e\u0301""#)
        try rejects(#"{"const":{"\u00e9":1}}"#, #"{"e\u0301":1}"#)
        try accepts(#"{"enum":["\u00e9","e\u0301"]}"#, #""e\u0301""#)
        try accepts(#"{"uniqueItems":true}"#, #"["\u00e9","e\u0301"]"#)
        let nested = #"{"type":"object","properties":{"records":{"type":"array","items":{"type":"object","required":["name"],"properties":{"name":{"type":"string"}},"additionalProperties":false}}},"required":["records"],"additionalProperties":false}"#
        try accepts(nested, #"{"records":[{"name":"one"},{"name":"two"}]}"#)
        try rejects(nested, #"{"records":[{"name":"one"},{}]}"#)
        try rejects(nested, #"{"records":[{"name":"one","unexpected":1}]}"#)
        try rejects(nested, #"{"records":[{"name":1}]}"#)
        try accepts(#"{"prefixItems":[{"type":"integer"},{"type":"string"}],"items":false}"#, #"[1,"two"]"#)
        try rejects(#"{"prefixItems":[{"type":"integer"},{"type":"string"}],"items":false}"#, #"[1,"two",3]"#)
        try accepts(#"{"items":{"type":"boolean"}}"#, "[true,false]")
        try rejects(#"{"items":{"type":"boolean"}}"#, "[true,0]")
        try accepts(#"{"enum":[1,true,null]}"#, "1")
        try rejects(#"{"enum":[true,null]}"#, "1")
        try accepts(#"{"const":{"a":[1,2]}}"#, #"{"a":[1,2]}"#)
        try rejects(#"{"const":{"a":[1,2]}}"#, #"{"a":[2,1]}"#)
        try accepts(#"{"minimum":1,"maximum":2}"#, "1")
        try rejects(#"{"minimum":1,"maximum":2}"#, "3")
        try rejects(#"{"minimum":1,"maximum":2}"#, "0")
        try rejects(#"{"exclusiveMinimum":1,"exclusiveMaximum":2}"#, "1")
        try rejects(#"{"exclusiveMinimum":1,"exclusiveMaximum":2}"#, "2")
        try accepts(#"{"exclusiveMinimum":1,"exclusiveMaximum":2}"#, "1.5")
        try accepts(#"{"minLength":2,"maxLength":2}"#, #""e\u0301""#)
        try accepts(#"{"minLength":1,"maxLength":1}"#, #""\ud83d\ude00""#)
        try rejects(#"{"minLength":2}"#, #""a""#)
        try rejects(#"{"maxLength":1}"#, #""e\u0301""#)
        try accepts(#"{"minItems":1,"maxItems":2,"uniqueItems":true}"#, "[1,true]")
        try rejects(#"{"uniqueItems":true}"#, #"[{"a":1},{"a":1}]"#)
        try rejects(#"{"minItems":1}"#, "[]")
        try rejects(#"{"maxItems":1}"#, "[1,2]")
        try accepts(#"{"minProperties":1,"maxProperties":1}"#, #"{"a":1}"#)
        try rejects(#"{"minProperties":1}"#, "{}")
        try rejects(#"{"maxProperties":1}"#, #"{"a":1,"b":2}"#)
        try accepts(#"{"allOf":[{"type":"integer"},{"minimum":2}]}"#, "2")
        try rejects(#"{"allOf":[{"type":"integer"},{"minimum":2}]}"#, "1")
        try accepts(#"{"anyOf":[{"type":"integer"},{"type":"null"}]}"#, "null")
        try rejects(#"{"anyOf":[{"type":"integer"},{"type":"null"}]}"#, "true")
        try accepts(#"{"oneOf":[{"type":"number"},{"type":"integer"}]}"#, "1.5")
        try rejects(#"{"oneOf":[{"type":"number"},{"type":"integer"}]}"#, "1")
        try rejects(#"{"oneOf":[{"type":"number"},{"type":"integer"}]}"#, "true")
        try accepts(#"{"not":{"type":"null"}}"#, "1")
        try rejects(#"{"not":{"type":"null"}}"#, "null")
        let reference = ##"{"$defs":{"a/b~c":{"type":"integer","minimum":1}},"$ref":"#/$defs/a~1b~0c","maximum":3}"##
        try accepts(reference, "2")
        try rejects(reference, "0")
        try rejects(reference, "4")
        try accepts(#"{"$schema":"https://json-schema.org/draft/2020-12/schema","title":"Example","description":"Description","$comment":"Comment","default":0,"examples":[1],"deprecated":false,"readOnly":true,"writeOnly":false}"#, "null")

        for schema in [
            "null", "1", "[]", #"{"type":[]}"#, #"{"type":["string","string"]}"#,
            #"{"type":"bool"}"#, #"{"type":["string",1]}"#, #"{"required":"id"}"#,
            #"{"required":[1]}"#, #"{"required":["id","id"]}"#, #"{"properties":[]}"#,
            #"{"properties":{"unused":{"format":"uri"}}}"#, #"{"additionalProperties":1}"#,
            #"{"items":[]}"#, #"{"prefixItems":[]}"#, #"{"prefixItems":[1]}"#,
            #"{"enum":[]}"#, #"{"enum":[1,1]}"#, #"{"enum":true}"#,
            #"{"minimum":true}"#, #"{"exclusiveMinimum":true}"#, #"{"minItems":-1}"#,
            #"{"maxLength":1.5}"#, #"{"uniqueItems":1}"#, #"{"allOf":[]}"#,
            #"{"anyOf":[true,{"unknown":false}]}"#, #"{"oneOf":{}}"#, #"{"not":0}"#,
            #"{"pattern":".*"}"#, #"{"format":"email"}"#, #"{"multipleOf":2}"#,
            #"{"unevaluatedProperties":false}"#, #"{"if":true,"then":false}"#,
            #"{"dependencies":{}}"#, #"{"x-unknown":true}"#, #"{"title":1}"#,
            #"{"examples":1}"#, #"{"readOnly":1}"#, #"{"$defs":[]}"#,
            #"{"$schema":"http://json-schema.org/draft-07/schema#"}"#,
            #"{"$ref":"https://example.invalid/schema"}"#, ##"{"$ref":"#"}"##,
            ##"{"$ref":"#/$defs/missing"}"##,
            ##"{"$defs":{"a":true},"$ref":"#/$defs/a~2"}"##,
            ##"{"$defs":{"a":true},"$ref":"#/$defs/%61"}"##,
            ##"{"$defs":{"a":{"$ref":"#/$defs/a"}},"$ref":"#/$defs/a"}"##,
            ##"{"$defs":{"a":{"$ref":"#/$defs/b"},"b":{"$ref":"#/$defs/a"}}}"##,
            #"{"properties":{"a":{"$defs":{"nested":true}}}}"#,
        ] { try unsupported(schema) }

        var deep: NativeJSONValue = .bool(true)
        for _ in 0..<50 { deep = .object(["not": deep]) }
        try fails(.resourceLimit) { _ = try NativeMCPJSONSchema(deep) }
        let permissive = try NativeMCPJSONSchema(.bool(true))
        var deepArgument: NativeJSONValue = .null
        for _ in 0..<50 { deepArgument = .array([deepArgument]) }
        try fails(.resourceLimit) { try permissive.validate(deepArgument) }
        try fails(.resourceLimit) { try permissive.validate(.array(Array(repeating: .null, count: 8_192))) }
        try fails(.resourceLimit) { _ = try NativeMCPJSONSchema(.object(["description": .string(String(repeating: "a", count: 1_048_577))])) }
        try fails(.resourceLimit) { try permissive.validate(.string(String(repeating: "a", count: 1_048_577))) }
        try fails(.resourceLimit) { _ = try NativeMCPJSONSchema(.object(["minimum": .number(.infinity)])) }
        try fails(.resourceLimit) { try permissive.validate(.number(.nan)) }
        var definitions: [String: NativeJSONValue] = ["leaf": .bool(true)]
        var previous = "leaf"
        for index in 0..<16 {
            let name = "level\(index)"
            let ref = NativeJSONValue.object(["$ref": .string("#/$defs/" + previous)])
            definitions[name] = .object(["allOf": .array([ref, ref])])
            previous = name
        }
        try fails(.resourceLimit) {
            _ = try NativeMCPJSONSchema(.object(["$defs": .object(definitions), "$ref": .string("#/$defs/" + previous)]))
        }
        let expensive = try NativeMCPJSONSchema(.object(["items": .object(["allOf": .array(Array(repeating: .bool(true), count: 64))])]))
        try fails(.resourceLimit) { try expensive.validate(.array(Array(repeating: .null, count: 1_000))) }
    }
}
