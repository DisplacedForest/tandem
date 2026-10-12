import Foundation
import GRDB

protocol NativeRuntimeToolServing: Sendable {
    func revision(scope: PiModelScope) async throws -> String
    func catalog(scope: PiModelScope) async throws -> [NativeToolSchema]
    func call(scope: PiModelScope, id: String, name: String, arguments: NativeJSONValue, expectedRevision: String) async throws -> NativeJSONValue
    func cancel(scope: PiModelScope) async
}

extension NativeRuntimeToolServing {
    func call(scope: PiModelScope, id: String, name: String, arguments: NativeJSONValue) async throws -> NativeJSONValue {
        let expected = try await revision(scope: scope)
        return try await call(scope: scope, id: id, name: name, arguments: arguments, expectedRevision: expected)
    }
}

struct PiRuntimeToolSnapshot: Equatable, Sendable {
    let revision: String?
    let schemas: [NativeToolSchema]
    static func capture(scope: PiModelScope, authority: (any NativeRuntimeToolServing)?) async throws -> Self {
        guard let authority else { return Self(revision: nil, schemas: []) }
        try Task.checkCancellation()
        let before = try await authority.revision(scope: scope)
        try piCheck(!before.isEmpty && before.utf8.count <= 1024, .unauthorized)
        let schemas = try await authority.catalog(scope: scope)
        let after = try await authority.revision(scope: scope)
        try Task.checkCancellation()
        try piCheck(before == after, .unauthorized)
        try PiRuntimeTools.validate(schemas)
        return Self(revision: before, schemas: schemas)
    }
}

enum PiRuntimeTools {
    static func validate(_ schemas: [NativeToolSchema]) throws {
        try piCheck(schemas.count <= 16)
        var names = Set<String>()
        for schema in schemas {
            try piCheck(schema.name.utf8.count == 44 && schema.name.range(of: #"^mcp_[a-f0-9]{40}$"#, options: .regularExpression) != nil && names.insert(schema.name).inserted)
            try piCheck(schema.description.utf8.count <= 2048 && schema.parameters.pi("type") == .string("object"))
            _ = try NativeMCPJSONSchema(schema.parameters)
        }
        try piCheck(try wire(schemas).piData().count <= 8192)
    }
    static func wire(_ schemas: [NativeToolSchema]) -> PiValue {
        .array(schemas.map { .object(["name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters]) })
    }
}

extension PiModelLedger {
    func reserveTool(scope: PiModelScope, id: String, digest: String) throws -> PiValue? {
        try database.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM runtime_tools WHERE subject=? AND id=?", arguments: [scope.subject, id]) {
                let digestValue: DatabaseValue = row["digest"], stateValue: DatabaseValue = row["state"], resultValue: DatabaseValue = row["result"]
                guard case .string(let savedDigest) = digestValue.storage, case .string(let state) = stateValue.storage else { throw PiBrokerError.storage }
                try piCheck(savedDigest == digest, .duplicate)
                try piCheck(state == "completed", .uncertain)
                guard case .blob(let data) = resultValue.storage else { throw PiBrokerError.storage }
                try piCheck(data.count <= 8192, .storage)
                return try PiValue.piRead(data)
            }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runtime_tools WHERE subject=?", arguments: [scope.subject]) ?? 0
            try piCheck(count < 8, .budget)
            try db.execute(sql: "INSERT INTO runtime_tools VALUES(?,?,?,'reserved',NULL)", arguments: [scope.subject, id, digest])
            return nil
        }
    }
    func settleTool(scope: PiModelScope, id: String, result: PiValue) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE runtime_tools SET state='completed',result=? WHERE subject=? AND id=? AND state='reserved'", arguments: [try result.piData(), scope.subject, id])
            try piCheck(db.changesCount == 1, .uncertain)
        }
    }
    func uncertainTool(scope: PiModelScope, id: String) {
        try? database.write { db in
            try db.execute(sql: "UPDATE runtime_tools SET state='uncertain',result=NULL WHERE subject=? AND id=? AND state='reserved'", arguments: [scope.subject, id])
        }
    }
}
