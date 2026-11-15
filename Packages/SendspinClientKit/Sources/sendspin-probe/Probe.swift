import Foundation
import SendspinClientKit

/// Connects to a Sendspin server as a client and logs the handshake, activation, clock sync and
/// any pairing: the interop check for SendspinClientKit. It never plays audio, so it reports
/// itself unavailable.
@main
struct Probe {
    static let usage = """
        usage: sendspin-probe [--url ws://host:port/path | --listen] [--name NAME] [--seconds N]
                              [--state FILE] [--show-token] [--verbose]

          --url         connect here instead of discovering a server over mDNS
          --listen      announce this client and wait for servers to connect, as hardware speakers do
          --name        friendly name shown on the server (default: this Mac's host name)
          --seconds     how long to stay connected (default 20; use more to pair)
          --state       credentials file (default: ~/Library/Application Support/sendspin-probe/credentials.json)
          --play        play the server's audio on this Mac's output (otherwise the probe reports itself unavailable)
          --show-token  print the pairing token: a credential that lets any server pair with this client
          --verbose     debug logging
        """

    static func main() async {
        // Unbuffered, so a pairing code shows at once even when the output is piped.
        setvbuf(stdout, nil, _IONBF, 0)
        var urlArgument: String?
        var name = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "") + " (probe)"
        var seconds = 20
        var statePath: String?
        var showToken = false
        var play = false
        var listen = false
        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--url": urlArgument = arguments.next()
            case "--name": name = arguments.next() ?? name
            case "--seconds": seconds = arguments.next().flatMap(Int.init) ?? seconds
            case "--state": statePath = arguments.next()
            case "--show-token": showToken = true
            case "--play": play = true
            case "--listen": listen = true
            case "--verbose": Log.minimumLevel = .debug
            default:
                print(usage)
                exit(argument == "--help" ? 0 : 2)
            }
        }

        let stateURL = statePath.map { URL(fileURLWithPath: $0) } ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sendspin-probe/credentials.json")
        let credentials: ClientCredentials
        do {
            credentials = try loadCredentials(at: stateURL)
        } catch {
            print("Cannot use the credentials file \(stateURL.path): \(error)")
            exit(1)
        }
        print("client_id: \(credentials.clientID ?? "?")  (paired servers: \(credentials.records.count))")
        if showToken { print("pairing token: \(credentials.pairingToken ?? "?")") }
        let store = CredentialStore(credentials: credentials) { changed in
            do { try saveCredentials(changed, at: stateURL) } catch { print("Saving credentials failed: \(error)") }
        }

        let configuration = ClientConfiguration(
            name: name, productName: "sendspin-probe", manufacturer: "SendspinClientKit", softwareVersion: "0.0.1",
            supportedRoles: ["player@v1", "controller@v1", "metadata@v1"], playerSupport: PlayerEngine.support())
        // Without --play the probe can't output audio, so it isn't available for playback.
        let status = ClientStatus(available: play, player: PlayerEngine.state(volume: 100, muted: false))

        if listen {
            let listener = ServiceListener(name: name, kind: .client)
            listener.start()
            print("announced as \(name); waiting for servers to connect")
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                exit(0)
            }
            // Several servers may connect, as Music Assistant does to anything announced.
            for await connection in listener.connections {
                print("a server connected from \(connection.remoteDescription)")
                let session = ClientSession(incoming: connection, store: store, configuration: configuration, status: status)
                Task { _ = await serve(session, play: play, seconds: nil) }
            }
            exit(0)
        }

        let url: URL
        if let urlArgument {
            guard let given = URL(string: urlArgument), given.scheme == "ws", given.host() != nil else {
                print("--url must be a ws:// URL")
                exit(2)
            }
            url = given
        } else {
            guard let found = await discover() else {
                print("No Sendspin server found over mDNS in 5 s; pass --url.")
                exit(1)
            }
            url = found
        }
        print("connecting to \(url.absoluteString)")
        let session = ClientSession(url: url, store: store, configuration: configuration, status: status)
        exit(await serve(session, play: play, seconds: seconds) ? 0 : 1)
    }

    /// Run one session to its end, logging what happens; whether the server activated it.
    static func serve(_ session: ClientSession, play: Bool, seconds: Int?) async -> Bool {
        let engine = play ? PlayerEngine(session: session) : nil

        Task { await session.run() }
        if let seconds {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                await session.close(goodbye: "shutdown")
            }
        }

        var activated = false
        var audioChunks = 0
        for await event in session.events {
            await engine?.handle(event)
            switch event {
            case let .handshakeCompleted(serverID, category):
                print("noise handshake complete: server_id \(serverID), psk category \(category)")
            case let .serverHello(serverName):
                print("server/hello: \(serverName)")
            case let .activated(activities, roles, paired):
                activated = true
                print("server/activate: activities \(activities), active_roles \(roles), paired \(paired)")
            case let .pairingCode(code):
                if let code {
                    print("\n  PAIRING CODE: \(code.prefix(3))-\(code.suffix(3))   (enter it on the server)\n")
                } else {
                    print("pairing code withdrawn")
                }
            case let .paired(serverName):
                print("PAIRED with \(serverName ?? "the server")")
            case let .clockSynchronized(error):
                print("clock synchronized (±\(Int(error)) µs)")
            case let .message(type, json):
                let text = String(decoding: json, as: UTF8.self)
                print("\(type): \(text.count > 400 ? String(text.prefix(400)) + "…" : text)")
            case let .binary(type, payload, _):
                // Audio arrives many times a second: count it rather than print each chunk.
                if type == 4 {
                    audioChunks += 1
                    if audioChunks == 1 || audioChunks.isMultiple(of: 250) { print("audio chunks received: \(audioChunks)") }
                } else {
                    print("binary message id \(type), \(payload.count) bytes")
                }
            case let .closed(reason):
                print("closed: \(reason ?? "clean")")
            }
        }
        return activated
    }

    /// The first server seen within 5 s, resolved to its URL.
    static func discover() async -> URL? {
        await withTaskGroup(of: URL?.self) { group in
            group.addTask {
                for await servers in ServerBrowser.browse() {
                    guard let server = servers.first else { continue }
                    print("found \(server.name ?? server.instanceName) at path \(server.path)")
                    return try? await ServerBrowser.resolve(server)
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Load the probe's credentials, creating them on first use. The file holds the private
    /// key, so it and its directory are readable by this user only.
    static func loadCredentials(at url: URL) throws -> ClientCredentials {
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(ClientCredentials.self, from: Data(contentsOf: url))
        }
        let credentials = ClientCredentials.generate()
        try saveCredentials(credentials, at: url)
        return credentials
    }

    static func saveCredentials(_ credentials: ClientCredentials, at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(credentials).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
