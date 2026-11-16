import Foundation
import Network
import SendspinClientKit

struct HTTPRequest: Sendable {
    var method: String
    /// The path without its query, percent-decoded.
    var path: String
    var query: [String: String]
    /// By lower-cased name.
    var headers: [String: String] = [:]
    var body: Data
}

struct HTTPResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        // Fragments allowed: a command's result may be a bare `null` or `true`.
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data("null".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: body)
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }
}

/// A small HTTP/1.1 server for the library API: requests with a `Content-Length` body,
/// answered one at a time per connection, which stays open for the next.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    /// More than a request to this API ever needs.
    private static let maxRequestBytes = 1 << 20

    private let handler: Handler
    private let queue = DispatchQueue(label: "tandem.http")
    // Guarded by `queue`.
    private var listener: NWListener?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Listen on `port`, or on any free one when it's taken; returns the port in use.
    func start(port: UInt16) async throws -> UInt16 {
        do {
            return try await listen(on: NWEndpoint.Port(rawValue: port) ?? .any)
        } catch {
            Log.info("Port \(port) is taken; serving the library on another one")
            return try await listen(on: .any)
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func listen(on port: NWEndpoint.Port) async throws -> UInt16 {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: queue)
            receive(on: connection, buffered: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    self?.listener = listener
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.cancel()
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Read until a whole request is in, answer it, then wait for the next.
    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }
            guard error == nil, buffer.count <= Self.maxRequestBytes else {
                connection.cancel()
                return
            }
            switch Self.parse(buffer) {
            case .incomplete:
                if isComplete { connection.cancel() } else { receive(on: connection, buffered: buffer) }
            case .malformed:
                send(.error(400, "Bad request"), on: connection, then: nil)
            case .request(let request, let rest):
                Task {
                    let response = await self.handler(request)
                    self.send(response, on: connection, then: isComplete ? nil : rest)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, then rest: Data?) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 500: "Internal Server Error"][response.status] ?? "OK"
        var message = Data(("HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\n"
                + "Content-Length: \(response.body.count)\r\nCache-Control: no-store\r\n"
                + "Connection: \(rest == nil ? "close" : "keep-alive")\r\n\r\n").utf8)
        message.append(response.body)
        connection.send(content: message, completion: .contentProcessed { [weak self] error in
            if let rest, error == nil {
                self?.receive(on: connection, buffered: rest)
            } else {
                connection.cancel()
            }
        })
    }

    enum Parsed {
        case incomplete
        case malformed
        /// A whole request, and the bytes after it.
        case request(HTTPRequest, rest: Data)
    }

    static func parse(_ buffer: Data) -> Parsed {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else { return .malformed }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .malformed }
        var headers: [String: String] = [:]
        for line in lines {
            let field = line.split(separator: ":", maxSplits: 1)
            guard field.count == 2 else { continue }
            headers[field[0].lowercased()] = field[1].trimmingCharacters(in: .whitespaces)
        }
        var length = 0
        if let stated = headers["content-length"] {
            guard let value = Int(stated), value >= 0 else { return .malformed }
            length = value
        }
        let bodyStart = headEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let target = String(parts[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let request = HTTPRequest(method: String(parts[0]), path: components?.path ?? target, query: query,
                                  headers: headers, body: Data(buffer[bodyStart..<(bodyStart + length)]))
        return .request(request, rest: Data(buffer[(bodyStart + length)...]))
    }
}

/// Resumes a continuation once, whichever of several callbacks comes first.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
