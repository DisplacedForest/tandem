import Foundation

/// One tappable choice in a Vera structured question.
struct VeraAskOption: Hashable, Codable {
    let label: String
    var description: String = ""
}

/// A structured multiple-choice question Vera emits inline, via a fenced block:
///
///     ```vera:ask
///     {"question":"…","multiSelect":false,"options":[{"label":"…","description":"…"}]}
///     ```
///
/// The app parses it out of the streamed reply, hides the raw block, and renders tappable options.
struct VeraAsk: Hashable, Codable {
    let question: String
    var multiSelect: Bool = false
    let options: [VeraAskOption]

    /// Extract a `vera:ask` block from assistant text.
    /// Returns the text with the block removed plus the parsed question (nil if none/incomplete).
    /// An incomplete trailing block (opening fence, no close yet — mid-stream) is stripped from the
    /// visible text but yields no question until it completes.
    static func parse(_ text: String) -> (clean: String, ask: VeraAsk?) {
        let ns = text as NSString
        // Complete block: ```vera:ask ... ```
        if let re = try? NSRegularExpression(pattern: "```vera:ask\\s*\\n([\\s\\S]*?)```", options: []),
           let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            let json = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = json.data(using: .utf8),
               let ask = try? JSONDecoder().decode(VeraAsk.self, from: data),
               !ask.options.isEmpty {
                let clean = (ns.replacingCharacters(in: m.range, with: ""))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (clean, ask)
            }
        }
        // Incomplete trailing block while streaming — hide it, no question yet.
        if let re = try? NSRegularExpression(pattern: "```vera:ask[\\s\\S]*$", options: []),
           let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            let clean = (ns.replacingCharacters(in: m.range, with: ""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (clean, nil)
        }
        return (text, nil)
    }

    var fencedBlock: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func quoted(_ value: String) -> String {
            (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        }
        let options = options.map { "{\"label\":" + quoted($0.label) + ",\"description\":" + quoted($0.description) + "}" }
        let json = "{\"question\":" + quoted(question) + ",\"multiSelect\":" + (multiSelect ? "true" : "false")
            + ",\"options\":[" + options.joined(separator: ",") + "]}"
        return "```vera:ask\n" + json + "\n```"
    }

    static func modelText(_ text: String, ask: VeraAsk?) -> String {
        guard let ask else { return text }
        return text.isEmpty ? ask.fencedBlock : text + "\n\n" + ask.fencedBlock
    }

    static func mock() -> VeraAsk {
        VeraAsk(
            question: "Which Spanish white should we plan next?",
            multiSelect: false,
            options: [
                .init(label: "Albariño", description: "Crisp, saline, coastal (Rías Baixas style)."),
                .init(label: "Verdejo", description: "Aromatic, herbal, a touch of bitterness (Rueda)."),
                .init(label: "Godello", description: "Textured, stone fruit, a step up in body (Valdeorras)."),
            ]
        )
    }
}
