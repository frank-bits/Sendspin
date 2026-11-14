import Foundation

/// Music Assistant's HTTP API (`POST /api`): one command with arguments per request, answered
/// with that command's JSON result. Sendspin itself has no way to browse or choose music, so
/// an app does that part against the server's own API.
public struct MusicAssistantAPI: Sendable {
    public enum APIError: Error, Equatable, CustomStringConvertible {
        /// The token is missing, expired or revoked; or the username and password were wrong.
        case unauthorized(String?)
        case server(status: Int, message: String)
        case unreachable(String)
        case invalidResponse

        public var description: String {
            switch self {
            case .unauthorized(let message): message ?? "Music Assistant didn't accept the sign-in."
            case .server(_, let message): message.isEmpty ? "Music Assistant reported an error." : message
            case .unreachable(let message): "Music Assistant can't be reached: \(message)"
            case .invalidResponse: "Music Assistant sent a reply this app doesn't understand."
            }
        }
    }

    /// The server's web address, e.g. `http://192.168.1.20:8095`.
    public let baseURL: URL
    public let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    /// Sign in with a Music Assistant username and password; returns an access token, which
    /// the server lists under `deviceName`.
    public static func login(baseURL: URL, username: String, password: String, deviceName: String,
                             session: URLSession = .shared) async throws -> String {
        struct Reply: Decodable {
            var success: Bool?
            var token: String?
            var error: String?
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider_id": "builtin",
            "credentials": ["username": username, "password": password],
            "device_name": deviceName,
        ])
        let (data, status) = try await perform(request, session: session)
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        if let token = reply?.token, reply?.success != false { return token }
        if status == 401 || status == 400 { throw APIError.unauthorized(reply?.error) }
        throw APIError.server(status: status, message: reply?.error ?? Self.text(data))
    }

    // MARK: Requests

    /// The request for `command`. `arguments` holds JSON values; nil ones are left out.
    func request(_ command: String, _ arguments: [String: Any?] = [:]) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["command": command, "args": arguments.compactMapValues { $0 }]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Run a prepared request and decode the command's result.
    func result<Result: Decodable>(_ request: URLRequest, as type: Result.Type = Result.self) async throws -> Result {
        let data = try await data(request)
        do {
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// Run a prepared request whose result doesn't matter.
    func data(_ request: URLRequest) async throws -> Data {
        let (data, status) = try await Self.perform(request, session: session)
        switch status {
        case 200..<300: return data
        case 401, 403: throw APIError.unauthorized(nil)
        default: throw APIError.server(status: status, message: Self.text(data))
        }
    }

    private static func perform(_ request: URLRequest, session: URLSession) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            return (data, http.statusCode)
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.unreachable(error.localizedDescription)
        }
    }

    private static func text(_ data: Data) -> String {
        String(String(decoding: data, as: UTF8.self).prefix(200))
    }
}

/// A list that keeps the elements it can decode and drops the rest, so one item of a kind
/// this app doesn't know can't empty a whole screen.
struct LossyList<Element: Decodable>: Decodable {
    private struct Skipped: Decodable {}

    var elements: [Element] = []

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try container.decode(Skipped.self)
            }
        }
    }
}
