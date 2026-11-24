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

    func state(conversationID: String, key: String) throws -> RuleOfferState {
        try database.read { db in try Self.state(db, conversationID: conversationID, key: key) }
    }

    func turnedOff(_ key: String) throws -> Bool {
        try database.read { db in try Self.off(db, key) }
    }

    @discardableResult
    func record(_ event: RuleOfferEvent, conversationID: String, key: String) throws -> Bool {
        guard !conversationID.isEmpty else { return false }
        return try database.write { db in
            let current = try Self.state(db, conversationID: conversationID, key: key)
            let off = try Self.off(db, key)
            let (next, offer) = RuleOffer.apply(event, to: current, turnedOff: off)
            if next != current { try Self.write(db, next, conversationID: conversationID, key: key) }
            return offer
        }
    }

    func settle(conversationID: String, key: String, everyChat: Bool) throws {
        guard !conversationID.isEmpty else { return }
        try database.write { db in
            let current = try Self.state(db, conversationID: conversationID, key: key)
            try Self.write(db, RuleOffer.apply(.answered, to: current, turnedOff: false).state, conversationID: conversationID, key: key)
            if everyChat { try Self.write(db, RuleOfferState(approvals: 0, answered: true), conversationID: RuleOffer.everyChat, key: key) }
        }
    }

    func turnOff(_ key: String) throws {
        try database.write { db in
            try Self.write(db, RuleOfferState(approvals: 0, answered: true), conversationID: RuleOffer.everyChat, key: key)
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

    private static func off(_ db: Database, _ key: String) throws -> Bool {
        if try state(db, conversationID: RuleOffer.everyChat, key: key).answered { return true }
        guard key.hasPrefix(RuleOfferSubject.toolName + ":") else { return false }
        return try state(db, conversationID: RuleOffer.everyChat, key: NativeActionClass.serviceChanges.rawValue).answered
    }

    private static func state(_ db: Database, conversationID: String, key: String) throws -> RuleOfferState {
        guard let row = try Row.fetchOne(db, sql: "SELECT approvals, answered FROM native_rule_offers WHERE conversation_id = ? AND action = ?",
                                         arguments: [conversationID, key]) else { return RuleOfferState() }
        let approvals: Int = row["approvals"]
        let answered: Int = row["answered"]
        return RuleOfferState(approvals: approvals, answered: answered != 0)
    }

    private static func write(_ db: Database, _ state: RuleOfferState, conversationID: String, key: String) throws {
        try db.execute(sql: """
            INSERT INTO native_rule_offers(conversation_id, action, approvals, answered) VALUES (?, ?, ?, ?)
            ON CONFLICT(conversation_id, action) DO UPDATE SET approvals = excluded.approvals, answered = excluded.answered
            """, arguments: [conversationID, key, state.approvals, state.answered ? 1 : 0])
    }

    func state(conversationID: String, action: NativeActionClass) throws -> RuleOfferState { try state(conversationID: conversationID, key: action.rawValue) }
    func turnedOff(_ action: NativeActionClass) throws -> Bool { try turnedOff(action.rawValue) }
    @discardableResult
    func record(_ event: RuleOfferEvent, conversationID: String, action: NativeActionClass) throws -> Bool {
        try record(event, conversationID: conversationID, key: action.rawValue)
    }
    func turnOff(_ action: NativeActionClass) throws { try turnOff(action.rawValue) }
}
