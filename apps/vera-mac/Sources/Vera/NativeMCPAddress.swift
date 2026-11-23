import Foundation
import Darwin

enum NativeMCPAddress {
    static let publicNeedsHTTPS = "A plain http address needs to be on your own network. Otherwise use https."
    static let listNeedsHTTPS = "The service address must be a plain https address."
    static let unreadable = "Enter the service's full address, starting with https:// or http://."
    static let extras = "The service address can't include a sign-in, a question mark part or a # part."
    static let reasons: Set<String> = [publicNeedsHTTPS, listNeedsHTTPS, unreadable, extras]

    static func validate(_ url: URL, personSupplied: Bool) throws {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty else { throw NativeToolError.failed(unreadable) }
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw NativeToolError.failed(extras) }
        guard scheme == "http" else { return }
        guard personSupplied else { throw NativeToolError.failed(listNeedsHTTPS) }
        guard isLocal(host) else { throw NativeToolError.failed(publicNeedsHTTPS) }
    }

    static let localEndings = [".local", ".lan", ".home.arpa"]

    static func isLocal(_ host: String) -> Bool {
        let bare = OutboundGuard.normalized(host)
        var v4 = in_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 {
            let plain = bare.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { $0 == "0" || !$0.hasPrefix("0") }
            guard plain else { return false }
            let value = UInt32(bigEndian: v4.s_addr)
            return value >> 24 == 10 || value >> 20 == 0xac1 || value >> 16 == 0xc0a8 || value >> 16 == 0xa9fe || value >> 24 == 127
        }
        if OutboundGuard.isLoopback(host) { return true }
        var v6 = in6_addr()
        let unscoped = bare.split(separator: "%", maxSplits: 1).first.map(String.init) ?? bare
        if inet_pton(AF_INET6, unscoped, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { ($0[0] == 0xfe && $0[1] & 0xc0 == 0x80) || $0[0] & 0xfe == 0xfc }
        }
        if localEndings.contains(where: { bare.hasSuffix($0) && bare.count > $0.count }) { return true }
        var legacy = in_addr()
        return !bare.isEmpty && inet_aton(bare, &legacy) == 0
            && bare.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
}
