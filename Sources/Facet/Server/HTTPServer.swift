import Foundation
import Network

struct HTTPRequest {
    var method: String = "GET"
    var path: String = "/"
    var query: [String: String] = [:]
    var headers: [String: String] = [:]   // keys lowercased
    var body: Data = Data()
    var clientAddress: String = "?"

    var cookies: [String: String] {
        guard let raw = headers["cookie"] else { return [:] }
        var out: [String: String] = [:]
        for part in raw.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            out[kv[0].trimmed] = kv[1].trimmed
        }
        return out
    }

    /// True when Tailscale Funnel (or any TLS terminator) handled HTTPS for us.
    var isSecure: Bool { headers["x-forwarded-proto"]?.lowercased() == "https" }

    var formFields: [String: String] {
        guard headers["content-type"]?.contains("application/x-www-form-urlencoded") == true,
              let s = String(data: body, encoding: .utf8) else { return [:] }
        return HTTPServer.parseQuery(s)
    }
}

struct HTTPResponse {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ value: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }
    static func text(_ s: String, status: Int = 200, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": type], body: Data(s.utf8))
    }
    static func html(_ s: String, status: Int = 200) -> HTTPResponse {
        text(s, status: status, type: "text/html; charset=utf-8")
    }
    static func bytes(_ d: Data, type: String, cacheSeconds: Int = 0, filename: String? = nil) -> HTTPResponse {
        var h = ["Content-Type": type]
        if cacheSeconds > 0 { h["Cache-Control"] = "private, max-age=\(cacheSeconds)" }
        if let filename {
            // RFC 5987 so non-ASCII filenames survive.
            let safe = filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "photo"
            h["Content-Disposition"] = "attachment; filename*=UTF-8''\(safe)"
        }
        return HTTPResponse(status: 200, headers: h, body: d)
    }
    static func status(_ code: Int, _ message: String? = nil) -> HTTPResponse {
        .json(["error": message ?? HTTPServer.reason(code)], status: code)
    }
}

/// Minimal HTTP/1.1 server. Serves this app's read-only API and web UI; it is not
/// a general-purpose server (no chunked requests, no ranges, no uploads).
final class HTTPServer: @unchecked Sendable {
    typealias Handler = (HTTPRequest) -> HTTPResponse

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "facet.http", attributes: .concurrent)
    private let handler: Handler
    private(set) var port: UInt16
    private let maxRequestBytes = 1 << 20   // 1 MB — this API never takes uploads
    private let maxConnections = 64
    private var connections: [ObjectIdentifier: Connection] = [:]
    private let connLock = NSLock()

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind all interfaces so Tailscale (and the LAN) can reach it; every route
        // below requires a session cookie, so exposure alone grants nothing.
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            let c = Connection(conn: conn, queue: self.queue, maxBytes: self.maxRequestBytes,
                               handler: self.handler) { [weak self] finished in
                self?.remove(finished)
            }
            guard self.add(c) else { conn.cancel(); return }
            c.start()
        }
        l.stateUpdateHandler = { state in
            if case .failed(let e) = state { NSLog("Facet HTTP listener failed: \(e)") }
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connLock.lock()
        let live = connections.values
        connections.removeAll()
        connLock.unlock()
        live.forEach { $0.close() }
    }

    /// Retains the connection for its lifetime. Returns false when at capacity.
    private func add(_ c: Connection) -> Bool {
        connLock.lock(); defer { connLock.unlock() }
        guard connections.count < maxConnections else { return false }
        connections[ObjectIdentifier(c)] = c
        return true
    }

    private func remove(_ c: Connection) {
        connLock.lock(); defer { connLock.unlock() }
        connections.removeValue(forKey: ObjectIdentifier(c))
    }

    // MARK: helpers

    static func parseQuery(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let key = String(kv[0]).removingPercentEncodingPlus
            let value = kv.count > 1 ? String(kv[1]).removingPercentEncodingPlus : ""
            out[key] = value
        }
        return out
    }

    static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default: return "Status \(code)"
        }
    }

    /// One connection, handling sequential keep-alive requests.
    private final class Connection {
        private let conn: NWConnection
        private let queue: DispatchQueue
        private let maxBytes: Int
        private let handler: Handler
        private let onClose: (Connection) -> Void
        private var buffer = Data()
        private var closed = false

        init(conn: NWConnection, queue: DispatchQueue, maxBytes: Int,
             handler: @escaping Handler, onClose: @escaping (Connection) -> Void) {
            self.conn = conn
            self.queue = queue
            self.maxBytes = maxBytes
            self.handler = handler
            self.onClose = onClose
        }

        func start() {
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
            conn.start(queue: queue)
            receive()
        }

        func close() {
            guard !closed else { return }
            closed = true
            conn.cancel()
            onClose(self)
        }

        private var clientAddress: String {
            if case let .hostPort(host, _) = conn.endpoint { return "\(host)" }
            return "?"
        }

        private func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data, !data.isEmpty { self.buffer.append(data) }
                if self.buffer.count > self.maxBytes {
                    self.respond(HTTPResponse.status(413), close: true); return
                }
                if (error != nil || isComplete) && self.buffer.isEmpty { self.close(); return }
                self.drain(connectionClosing: isComplete || error != nil)
            }
        }

        private func drain(connectionClosing: Bool) {
            guard let headerEnd = Self.find(Data("\r\n\r\n".utf8), in: buffer) else {
                if connectionClosing { close() } else { receive() }
                return
            }
            let headerData = Data(buffer.prefix(headerEnd))
            guard var request = Self.parseHead(headerData) else {
                respond(HTTPResponse.status(400), close: true); return
            }
            request.clientAddress = clientAddress

            let bodyStart = headerEnd + 4
            let contentLength = Int(request.headers["content-length"] ?? "0") ?? 0
            guard contentLength <= maxBytes else { respond(HTTPResponse.status(413), close: true); return }
            let available = buffer.count - bodyStart
            if available < contentLength {
                if connectionClosing { close() } else { receive() }
                return
            }
            if contentLength > 0 {
                request.body = Data(buffer.dropFirst(bodyStart).prefix(contentLength))
            }
            buffer = Data(buffer.dropFirst(bodyStart + contentLength))

            let keepAlive = request.headers["connection"]?.lowercased() != "close"
            let response = handler(request)
            respond(response, close: !keepAlive, thenContinue: keepAlive)
        }

        private func respond(_ res: HTTPResponse, close: Bool, thenContinue: Bool = false) {
            var head = "HTTP/1.1 \(res.status) \(HTTPServer.reason(res.status))\r\n"
            var headers = res.headers
            headers["Content-Length"] = String(res.body.count)
            headers["Connection"] = close ? "close" : "keep-alive"
            headers["X-Content-Type-Options"] = "nosniff"
            headers["X-Frame-Options"] = "DENY"
            headers["Referrer-Policy"] = "no-referrer"
            for (k, v) in headers { head += "\(k): \(v)\r\n" }
            head += "\r\n"

            var out = Data(head.utf8)
            out.append(res.body)
            conn.send(content: out, completion: .contentProcessed { _ in
                if close { self.close() }
                else if thenContinue {
                    if self.buffer.isEmpty { self.receive() } else { self.drain(connectionClosing: false) }
                }
            })
        }

        private static func find(_ needle: Data, in haystack: Data) -> Int? {
            guard haystack.count >= needle.count else { return nil }
            return haystack.withUnsafeBytes { h -> Int? in
                let hp = h.bindMemory(to: UInt8.self)
                return needle.withUnsafeBytes { n -> Int? in
                    let np = n.bindMemory(to: UInt8.self)
                    outer: for i in 0...(hp.count - np.count) {
                        for j in 0..<np.count where hp[i + j] != np[j] { continue outer }
                        return i
                    }
                    return nil
                }
            }
        }

        private static func parseHead(_ data: Data) -> HTTPRequest? {
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            var lines = text.components(separatedBy: "\r\n")
            guard !lines.isEmpty else { return nil }
            let requestLine = lines.removeFirst().split(separator: " ")
            guard requestLine.count >= 2 else { return nil }

            var req = HTTPRequest()
            req.method = String(requestLine[0]).uppercased()
            let target = String(requestLine[1])
            if let q = target.firstIndex(of: "?") {
                req.path = String(target[target.startIndex..<q]).removingPercentEncoding ?? String(target[target.startIndex..<q])
                req.query = HTTPServer.parseQuery(String(target[target.index(after: q)...]))
            } else {
                req.path = target.removingPercentEncoding ?? target
            }
            for line in lines where !line.isEmpty {
                guard let c = line.firstIndex(of: ":") else { continue }
                let key = String(line[line.startIndex..<c]).lowercased()
                let value = String(line[line.index(after: c)...]).trimmed
                req.headers[key] = value
            }
            return req
        }
    }
}

extension String {
    var removingPercentEncodingPlus: String {
        replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? self
    }
}

extension Substring {
    var trimmed: String { String(self).trimmingCharacters(in: .whitespaces) }
}
