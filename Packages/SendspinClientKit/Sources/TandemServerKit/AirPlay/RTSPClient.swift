import Foundation
import Network
import SendspinClientKit

/// The control connection to an AirPlay speaker: requests and answers, one at a time.
actor RTSPClient {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    enum Failure: Error, CustomStringConvertible {
        case unreachable(String)
        case closed
        case malformed
        case refused(method: String, status: Int)

        var description: String {
            switch self {
            case .unreachable(let reason): "can't be reached (\(reason))"
            case .closed: "closed the connection"
            case .malformed: "sent an answer that can't be read"
            case .refused(let method, let status): "refused \(method) (\(status))"
            }
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "tandem.rtsp")
    private let commonHeaders: [(String, String)]
    private var buffer = Data()
    private var sequence = 0
    private var session: String?
    /// The request before, so that two callers don't mix their answers.
    private var last: Task<Void, Never>?

    init(endpoint: NWEndpoint, headers: [(String, String)]) {
        let parameters = NWParameters.tcp
        // The audio goes over IPv4 sockets of our own, so the control connection does too.
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        connection = NWConnection(to: endpoint, using: parameters)
        commonHeaders = headers
    }

    /// Connect; returns our address and the speaker's, in numbers.
    func open(timeout: Duration = .seconds(5)) async throws -> (local: String, remote: String) {
        let connection = connection
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.claim() { continuation.resume(throwing: Failure.unreachable("\(error)")) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: Failure.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds) * 1_000)) {
                if once.claim() { continuation.resume(throwing: Failure.unreachable("no answer")) }
            }
        }
        guard let path = connection.currentPath, let local = Self.host(path.localEndpoint),
              let remote = Self.host(path.remoteEndpoint) else {
            throw Failure.unreachable("no IPv4 address")
        }
        return (local, remote)
    }

    private static func host(_ endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _)? = endpoint, case .ipv4(let address) = host else { return nil }
        return "\(address)".components(separatedBy: "%").first
    }

    func setSession(_ session: String?) {
        self.session = session
    }

    /// Send a request and wait for its answer. Anything but success throws, unless `lenient`.
    func send(_ method: String, _ uri: String, headers: [(String, String)] = [], body: Data? = nil,
              contentType: String? = nil, lenient: Bool = false) async throws -> Response {
        let previous = last
        let task = Task { () throws -> Response in
            await previous?.value
            return try await self.exchange(method, uri, headers: headers, body: body, contentType: contentType)
        }
        last = Task { _ = try? await task.value }
        let response = try await task.value
        guard lenient || (200..<300).contains(response.status) else {
            throw Failure.refused(method: method, status: response.status)
        }
        return response
    }

    private func exchange(_ method: String, _ uri: String, headers: [(String, String)], body: Data?,
                          contentType: String?) async throws -> Response {
        sequence += 1
        var lines = ["\(method) \(uri) RTSP/1.0", "CSeq: \(sequence)"]
        lines += (commonHeaders + headers).map { "\($0.0): \($0.1)" }
        if let session { lines.append("Session: \(session)") }
        if let body {
            if let contentType { lines.append("Content-Type: \(contentType)") }
            lines.append("Content-Length: \(body.count)")
        }
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + (body ?? Data())
        // A speaker that stopped answering mustn't hold the stream up for good.
        let connection = connection
        let watchdog = Task {
            try await Task.sleep(for: .seconds(6))
            connection.cancel()
        }
        defer { watchdog.cancel() }
        do {
            try await write(request)
            let response = try await readResponse()
            Log.debug("AirPlay \(method): \(response.status)")
            return response
        } catch {
            Log.debug("AirPlay \(method): \(error)")
            throw error
        }
    }

    private func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: Failure.unreachable("\(error)")) } else { continuation.resume() }
            })
        }
    }

    private func readResponse() async throws -> Response {
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            if let end = buffer.range(of: terminator) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                var lines = head.components(separatedBy: "\r\n")
                let statusLine = lines.removeFirst().split(separator: " ")
                guard statusLine.count >= 2, let status = Int(statusLine[1]) else { throw Failure.malformed }
                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let length = headers["content-length"].flatMap(Int.init) ?? 0
                while buffer.distance(from: end.upperBound, to: buffer.endIndex) < length { try await readMore() }
                let bodyEnd = buffer.index(end.upperBound, offsetBy: length)
                let body = Data(buffer[end.upperBound..<bodyEnd])
                buffer = Data(buffer[bodyEnd...])
                return Response(status: status, headers: headers, body: body)
            }
            try await readMore()
        }
    }

    private func readMore() async throws {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: Failure.unreachable("\(error)"))
                } else if isComplete {
                    continuation.resume(throwing: Failure.closed)
                } else {
                    continuation.resume(throwing: Failure.malformed)
                }
            }
        }
        buffer.append(data)
    }

    nonisolated func close() {
        connection.cancel()
    }
}
