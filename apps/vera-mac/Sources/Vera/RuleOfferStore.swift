import Foundation
import GRDB

struct RuleOfferStore: Sendable {
    let database: DatabaseQueue

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE native_rule_offers (
                conversation_id TEXT NOT NULL,
                action TEXT NOT NULL,
                approvals INTEGER NOT NULL DEFAULT 0,
                answered INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(conversation_id, action)
            );
            """)
    }

    func state(conversationID: String, action: NativeActionClass) throws -> RuleOfferState {
        try database.read { db in try Self.state(db, conversationID: conversationID, action: action) }
    }

    func turnedOff(_ action: NativeActionClass) throws -> Bool {
        try state(conversationID: RuleOffer.everyChat, action: action).answered
    }

    @discardableResult
    func record(_ event: RuleOfferEvent, conversationID: String, action: NativeActionClass) throws -> Bool {
        guard !conversationID.isEmpty else { return false }
        return try database.write { db in
            let current = try Self.state(db, conversationID: conversationID, action: action)
            let off = try Self.state(db, conversationID: RuleOffer.everyChat, action: action).answered
            let (next, offer) = RuleOffer.apply(event, to: current, turnedOff: off)
            if next != current { try Self.write(db, next, conversationID: conversationID, action: action) }
            return offer
        }
    }

    func settle(conversationID: String, action: NativeActionClass, everyChat: Bool) throws {
        guard !conversationID.isEmpty else { return }
        try database.write { db in
            let current = try Self.state(db, conversationID: conversationID, action: action)
            try Self.write(db, RuleOffer.apply(.answered, to: current, turnedOff: false).state, conversationID: conversationID, action: action)
            if everyChat { try Self.write(db, RuleOfferState(approvals: 0, answered: true), conversationID: RuleOffer.everyChat, action: action) }
        }
    }

    func turnOff(_ action: NativeActionClass) throws {
        try database.write { db in
            try Self.write(db, RuleOfferState(approvals: 0, answered: true), conversationID: RuleOffer.everyChat, action: action)
        }
    }

    func remove(conversationID: String) throws {
        guard !conversationID.isEmpty else { return }
        try database.write { db in
            try db.execute(sql: "DELETE FROM native_rule_offers WHERE conversation_id = ?", arguments: [conversationID])
        }
    }

    func rows(conversationID: String) throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_rule_offers WHERE conversation_id = ?", arguments: [conversationID]) ?? 0
        }
    }

    static let leftPrefix = "left:"

    func leftAnswer(reportID: String, action: NativeActionClass) throws -> Int {
        guard !reportID.isEmpty else { return 0 }
        let state = try state(conversationID: Self.leftPrefix + reportID, action: action)
        return state.answered ? state.approvals : 0
    }

    func setLeftAnswer(_ code: Int, reportID: String, action: NativeActionClass) throws {
        guard !reportID.isEmpty else { return }
        try database.write { db in
            try Self.write(db, RuleOfferState(approvals: code, answered: true), conversationID: Self.leftPrefix + reportID, action: action)
        }
    }

    func leftAnswers() throws -> [String: Int] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT conversation_id, approvals FROM native_rule_offers WHERE conversation_id LIKE ? AND answered = 1",
                                        arguments: [Self.leftPrefix + "%"])
            var answers: [String: Int] = [:]
            for row in rows {
                let key: String = row["conversation_id"]
                let code: Int = row["approvals"]
                answers[String(key.dropFirst(Self.leftPrefix.count))] = code
            }
            return answers
        }
    }

    private static func state(_ db: Database, conversationID: String, action: NativeActionClass) throws -> RuleOfferState {
        guard let row = try Row.fetchOne(db, sql: "SELECT approvals, answered FROM native_rule_offers WHERE conversation_id = ? AND action = ?",
                                         arguments: [conversationID, action.rawValue]) else { return RuleOfferState() }
        let approvals: Int = row["approvals"]
        let answered: Int = row["answered"]
        return RuleOfferState(approvals: approvals, answered: answered != 0)
    }

    private static func write(_ db: Database, _ state: RuleOfferState, conversationID: String, action: NativeActionClass) throws {
        try db.execute(sql: """
            INSERT INTO native_rule_offers(conversation_id, action, approvals, answered) VALUES (?, ?, ?, ?)
            ON CONFLICT(conversation_id, action) DO UPDATE SET approvals = excluded.approvals, answered = excluded.answered
            """, arguments: [conversationID, action.rawValue, state.approvals, state.answered ? 1 : 0])
    }
}
