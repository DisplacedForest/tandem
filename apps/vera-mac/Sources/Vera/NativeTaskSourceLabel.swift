import Foundation

extension NativeTaskSource {
    var label: String {
        let shown = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = shown.rangeOfCharacter(from: .whitespacesAndNewlines) == nil && Self.webHost(shown) != nil
        guard shown.isEmpty || shown == address || bare else { return Self.bounded(shown) }
        guard let host = Self.webHost(address) ?? Self.webHost(shown) else { return "Saved page" }
        return Self.bounded(host)
    }

    static let labelScalars = 200

    static func bounded(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(labelScalars)))
    }

    static func webHost(_ text: String) -> String? {
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty else { return nil }
        let lowered = host.lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }
}
