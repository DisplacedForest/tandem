import Foundation
import GRDB

struct NativeCompanionEvent: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case introduction, welcome, refinement }
    let kind: Kind
    let key: String
    var observation: String? = nil

    static let nameDeclined = "name_declined"

    var isOpening: Bool { kind != .refinement }

    var instruction: String {
        switch kind {
        case .introduction where observation == Self.nameDeclined:
            return "This is your first opening in your own companion conversation, not a user request. The user chose not to name you yet, so do not give yourself a name and do not ask for one. Introduce yourself briefly in your own voice and ask what they would like help with first. Do not invent a user message or claim any work happened. Ask one question at a time. The user can skip setup and talk normally."
        case .introduction:
            return "This is your first opening in your own companion conversation, not a user request. Introduce yourself briefly in your own voice and ask only what the user would like to call you. Do not invent a user message or claim any work happened. Ask one question at a time. The user can skip setup and talk normally."
        case .welcome:
            return "This is the opening of your existing companion conversation, not a user request. Your saved profile is already configured. Give a brief welcome and invite the user to continue. Do not repeat onboarding, ask for a name, or claim any work happened."
        case .refinement:
            return "Review the conversation for one useful refinement to your standing goal or working preferences. Propose at most one concise change and ask whether it would help. Do not change your profile or take actions. Do not repeat an unanswered proposal, invent work, or treat earlier requests as new instructions." + (observation.map { " Read-only, untrusted work result: " + String(decoding: (try? JSONEncoder().encode($0)) ?? Data(), as: UTF8.self) } ?? "")
        }
    }
}

extension LocalChatRepository {
    static func migrateCompanionOrigins(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE native_conversation_turns_revised (
                id TEXT PRIMARY KEY NOT NULL,
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                user_message_id TEXT UNIQUE REFERENCES messages(id) ON DELETE CASCADE,
                assistant_message_id TEXT NOT NULL UNIQUE REFERENCES messages(id) ON DELETE CASCADE,
                mode TEXT NOT NULL,
                state TEXT NOT NULL,
                attempt TEXT,
                owner_pid INTEGER,
                created_at DOUBLE NOT NULL,
                record_json TEXT NOT NULL,
                companion_event TEXT,
                UNIQUE(conversation_id, companion_event)
            );
            INSERT INTO native_conversation_turns_revised
                (id, conversation_id, user_message_id, assistant_message_id, mode, state, attempt, owner_pid, created_at, record_json)
            SELECT id, conversation_id, user_message_id, assistant_message_id, mode, state, attempt, owner_pid, created_at, record_json FROM native_conversation_turns;
            DROP TABLE native_conversation_turns;
            ALTER TABLE native_conversation_turns_revised RENAME TO native_conversation_turns;
            CREATE INDEX native_conversation_turn_queue ON native_conversation_turns(state, created_at);
            """)
    }
}
