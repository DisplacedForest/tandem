import Foundation
import Network

enum NativePageTransport {
    static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]
    static let chunkSize = 65536

    static func get(_ url: URL, maximumBytes: Int, timeout: TimeInterval) async throws -> NativePageResponse {
        var current = url
        for _ in 0...NativePageFetch.maximumRedirects {
            guard let target = NativePageFetch.allowed(current.absoluteString), let host = target.host else {
                throw NativeToolError.failed("The page redirected to an address that cannot be read")
            }
            let address = try await pinnedAddress(host)
            let raw = try await exchange(target, host: host, address: address, maximumBytes: maximumBytes, timeout: timeout)
            let response = try parse(raw.data, closed: raw.closed, maximumBytes: maximumBytes, finalURL: target)
            if redirectStatuses.contains(response.status) {
                guard let location = response.location, let next = URL(string: location, relativeTo: target)?.absoluteURL else {
                    throw NativeToolError.failed("The page redirected without a destination")
                }
                current = next
                continue
            }
            return NativePageResponse(status: response.status, contentType: response.contentType, body: response.body,
                                      truncated: response.truncated, finalURL: target)
        }
        throw NativeToolError.failed("The page redirected too many times")
    }

    static func pinnedAddress(_ host: String) async throws -> String {
        let address: String? = await Task.detached {
            guard !NativePageFetch.hostIsPrivate(host) else { return nil }
            var bare = host.lowercased()
            if bare.hasPrefix("["), bare.hasSuffix("]") { bare = String(bare.dropFirst().dropLast()) }
            let addresses = NativePageFetch.resolvedAddresses(bare)
            guard !addresses.isEmpty, !addresses.contains(where: NativePageFetch.hostIsPrivate) else { return nil }
            return addresses.first
        }.value
        guard let address else {
            throw NativeToolError.failed("The page address resolves to a private network and cannot be read")
        }
        return address
    }

    private struct Raw: Sendable {
        let data: Data
        let closed: Bool
    }

    private static func exchange(_ url: URL, host: String, address: String, maximumBytes: Int, timeout: TimeInterval) async throws -> Raw {
        let secure = url.scheme?.lowercased() == "https"
        let port = UInt16(url.port ?? (secure ? 443 : 80))
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw NativeToolError.failed("The page address uses an invalid port") }
        let parameters: NWParameters
        if secure {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = NWParameters.tcp
        }
        parameters.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(address), port: endpointPort, using: parameters)
        let session = NativePageConnection(connection: connection)
        defer { session.cancel() }
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty { path += "?" + query }
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        let request = "GET \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nUser-Agent: Tandem/1.0\r\nAccept: text/html, application/xhtml+xml, text/plain;q=0.9, */*;q=0.1\r\nAccept-Language: en\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"
        return try await withThrowingTaskGroup(of: Raw.self) { group in
            group.addTask {
                try await session.start()
                try await session.send(Data(request.utf8))
                let received = try await session.receiveAll(limit: maximumBytes + 1)
                return Raw(data: received.data, closed: received.closed)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw NativeToolError.failed("The page took too long to answer")
            }
            guard let first = try await group.next() else { throw NativeToolError.failed("The page did not answer") }
            group.cancelAll()
            return first
        }
    }

    struct Parsed: Sendable {
        let status: Int
        let contentType: String?
        let location: String?
        let body: Data
        let truncated: Bool
    }

    static func parse(_ data: Data, closed: Bool, maximumBytes: Int, finalURL: URL) throws -> Parsed {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw NativeToolError.failed("The page did not return an HTTP response")
        }
        let head = String(decoding: data[data.startIndex..<separator.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
            throw NativeToolError.failed("The page did not return an HTTP response")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        if let encoding = headers["content-encoding"]?.lowercased(), encoding != "identity" {
            throw NativeToolError.failed("The page is compressed with \(encoding), not readable text")
        }
        var body = Data(data[separator.upperBound...])
        var truncated = false
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            let decoded = dechunk(body)
            body = decoded.data
            truncated = !decoded.complete
        } else if let length = headers["content-length"].flatMap({ Int($0) }) {
            if body.count > length { body = body.prefix(length) }
            truncated = body.count < length
        } else {
            truncated = !closed
        }
        if body.count > maximumBytes {
            body = body.prefix(maximumBytes)
            truncated = true
        }
        if data.count > maximumBytes { truncated = true }
        return Parsed(status: status, contentType: headers["content-type"], location: headers["location"], body: body, truncated: truncated)
    }

    static func dechunk(_ data: Data) -> (data: Data, complete: Bool) {
        var output = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while index < data.endIndex {
            guard let lineEnd = data[index...].range(of: crlf) else { return (output, false) }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return (output, false) }
            if size == 0 { return (output, true) }
            let start = lineEnd.upperBound
            guard let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) else {
                output.append(data[start...])
                return (output, false)
            }
            output.append(data[start..<end])
            index = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return (output, false)
    }
}

final class NativePageConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.vera.page-fetch")

    init(connection: NWConnection) {
        self.connection = connection
    }

    func cancel() {
        connection.cancel()
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func receiveAll(limit: Int) async throws -> (data: Data, closed: Bool) {
        var buffer = Data()
        while buffer.count < limit {
            try Task.checkCancellation()
            let (chunk, complete) = try await receive()
            if let chunk { buffer.append(chunk) }
            if complete { return (buffer, true) }
        }
        return (buffer, false)
    }

    private func receive() async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: NativePageTransport.chunkSize) { content, _, complete, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (content, complete)) }
            }
        }
    }
}
