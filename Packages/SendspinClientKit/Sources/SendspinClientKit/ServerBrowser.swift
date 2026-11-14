import Foundation
import Network

/// A Sendspin server advertised over mDNS for client-initiated connections
/// (connection.md, Client Initiated Connections).
public struct DiscoveredServer: Sendable, Hashable, Identifiable {
    /// The mDNS instance name; Music Assistant uses an opaque identifier here.
    public var instanceName: String
    /// The friendly name from the TXT record: a hint only, server/hello is authoritative.
    public var name: String?
    /// The WebSocket path from the TXT record.
    public var path: String
    /// The port of the server's own library API, when it announces one: a Tandem server does,
    /// under the TXT key `api_port`.
    public var libraryPort: Int?
    let endpoint: NWEndpoint

    public var id: String { instanceName }
}

public enum ServerBrowser {
    public static let serviceType = "_sendspin-server._tcp"

    public enum ResolveError: Error {
        case timedOut
        case noAddress
    }

    /// Browse continuously; yields the servers with a usable `path` whenever they change.
    /// Browsing stops when the consuming task is cancelled.
    public static func browse() -> AsyncStream<[DiscoveredServer]> {
        AsyncStream { continuation in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: NWParameters())
            browser.browseResultsChangedHandler = { results, _ in
                continuation.yield(results.compactMap(server(from:)).sorted { $0.instanceName < $1.instanceName })
            }
            browser.stateUpdateHandler = { state in Log.debug("Server browser: \(state)") }
            browser.start(queue: DispatchQueue(label: "sendspin.server-browser"))
            continuation.onTermination = { _ in browser.cancel() }
        }
    }

    private static func server(from result: NWBrowser.Result) -> DiscoveredServer? {
        guard case let .service(instance, _, _, _) = result.endpoint, case let .bonjour(txt) = result.metadata,
              let path = txt["path"], path.hasPrefix("/"), !path.contains("?"), !path.contains("#")
        else { return nil }
        return DiscoveredServer(instanceName: instance, name: txt["name"], path: path,
                                libraryPort: txt["api_port"].flatMap(Int.init), endpoint: result.endpoint)
    }

    /// The `ws://` URL of a discovered server. A WebSocket needs a URL to carry the path, so
    /// the service is resolved to an IPv4 address and port with a short-lived TCP connection.
    public static func resolve(_ server: DiscoveredServer, timeout: Duration = .seconds(5)) async throws -> URL {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: server.endpoint, using: parameters)
        let queue = DispatchQueue(label: "sendspin.server-resolve")
        defer { connection.cancel() }
        let (host, port): (String, Int) = try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        continuation.resume(returning: (hostString(host), Int(port.rawValue)))
                    } else {
                        continuation.resume(throwing: ResolveError.noAddress)
                    }
                case .failed(let error), .waiting(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds) * 1000)) {
                if once.claim() { continuation.resume(throwing: ResolveError.timedOut) }
            }
        }
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = server.path
        guard let url = components.url else { throw ResolveError.noAddress }
        return url
    }

    /// The address without its interface scope ("192.168.1.10%en0").
    private static func hostString(_ host: NWEndpoint.Host) -> String {
        let text: String
        switch host {
        case .ipv4(let address): text = "\(address)"
        case .ipv6(let address): text = "\(address)"
        case .name(let name, _): text = name
        @unknown default: text = "\(host)"
        }
        return String(text.prefix { $0 != "%" })
    }
}
