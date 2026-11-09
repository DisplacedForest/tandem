import Foundation
import cmark_gfm
import cmark_gfm_extensions

enum NativeCompanionShape {
    static let answer = "answer"
    static let document = "document"
    static let inlineLimit = 1500
    static let classifierAttempt = "-shape"
    static let classifierSeconds: Double = 60

    static let classifierPrompt = "Decide whether the person asked for something to keep: a document, plan, list, draft, letter, email or other written piece to save. Questions, lookups, reminders, errands and actions are not. Reply with only JSON: {\"keep\": true} or {\"keep\": false}."

    static func classifierMessages(assignment: String) -> [NativeTaskGenerationMessage] {
        [NativeTaskGenerationMessage(role: "system", content: classifierPrompt),
         NativeTaskGenerationMessage(role: "user", content: assignment)]
    }

    static func parseKeep(_ reply: String) -> Bool {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = try? JSONDecoder().decode([String: Bool].self, from: Data(trimmed.utf8)),
              decoded.count == 1, let keep = decoded["keep"] else { return false }
        return keep
    }

    static func decide(keep: Bool, text: String) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if keep || body.count > inlineLimit || hasStructure(text) { return document }
        return answer
    }

    static func hasStructure(_ text: String) -> Bool {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return false }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            if let syntax = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, syntax) }
        }
        cmark_parser_feed(parser, text, text.utf8.count)
        guard let root = cmark_parser_finish(parser) else { return false }
        defer { cmark_node_free(root) }
        guard let iterator = cmark_iter_new(root) else { return false }
        defer { cmark_iter_free(iterator) }
        while true {
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { return false }
            guard event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator),
                  let type = cmark_node_get_type_string(node) else { continue }
            if ["heading", "table"].contains(String(cString: type)) { return true }
        }
    }
}
