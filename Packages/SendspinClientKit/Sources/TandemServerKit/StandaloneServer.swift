import Foundation
import SendspinClientKit

/// A Sendspin server of our own: players find it on the network and connect, it plays a
/// folder of music on them in sync, and apps browse that music over its HTTP API. No Home
/// Assistant or Music Assistant is involved.
public actor StandaloneServer {
    public struct Configuration: Sendable {
        /// The name players and apps show for the server.
        public var name: String
        /// Where the server keeps its identity, pairings and library index.
        public var dataDirectory: URL
        public var musicFolder: URL?
        /// The library API's port; another is used when it's taken.
        public var apiPort: UInt16
        /// Connect to players that announce a loopback address too: test players on this machine.
        public var dialsLoopback: Bool

        public init(name: String, dataDirectory: URL, musicFolder: URL? = nil, apiPort: UInt16 = 8929,
                    dialsLoopback: Bool = false) {
            self.name = name
            self.dataDirectory = dataDirectory
            self.musicFolder = musicFolder
            self.apiPort = apiPort
            self.dialsLoopback = dialsLoopback
        }
    }

    /// A player connected to the server, as an operator's screen lists it.
    public struct Player: Sendable, Identifiable, Equatable {
        public var id: String
        public var clientID: String?
        public var name: String
        public var connection: PlayerStatus.Connection
        public var paired: Bool
        public var pairing: PairingProgress?
        /// It can show a code to pair with.
        public var offersCode: Bool
        /// It announces itself on the network and the server connects to it, as hardware
        /// speakers do; otherwise it connected to the server by itself.
        public var found: Bool
    }

    public struct State: Sendable, Equatable {
        public var running = false
        public var players: [Player] = []
        public var library = Library.Status.noFolder
        public var apiPort: Int?
        /// The system refuses the server Local Network access, so it finds no players.
        public var localNetworkDenied = false
        /// Why the server couldn't start.
        public var error: String?

        public init() {}
    }

    /// The TXT key under which the server announces its library API's port.
    public static let apiPortKey = "api_port"

    public nonisolated let states: AsyncStream<State>
    private let stateContinuation: AsyncStream<State>.Continuation
    private var state = State() {
        didSet { if state != oldValue { stateContinuation.yield(state) } }
    }

    private let configuration: Configuration
    private var store: ServerStore?
    private var group: PlaybackGroup?
    private var library: MusicLibrary?
    private var api: ServerAPI?
    private var http: HTTPServer?
    private var listener: ServiceListener?
    private var accepting: Task<Void, Never>?
    private var discovering: Task<Void, Never>?
    private var identity: ServerIdentity?
    private var pairings: PlayerPairings?
    /// Players that announce themselves, which the server connects to, by player id: the name
    /// they announce under, which stays when their address changes.
    private var dialed: [String: DiscoveredPlayer] = [:]
    private var sessions: [String: PlayerSession] = [:]
    private var statuses: [String: PlayerStatus] = [:]
    /// Players whose pairing waits for the operator to enter the code they show.
    private var codeRequests: [String: CheckedContinuation<String?, Never>] = [:]

    public init(configuration: Configuration) {
        self.configuration = configuration
        (states, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public var currentState: State { state }

    // MARK: Running

    public func start() async {
        guard !state.running else { return }
        do {
            let store = try ServerStore(directory: configuration.dataDirectory)
            let identity = try store.identity(name: configuration.name)
            let pairings = store.pairings()
            let group = PlaybackGroup(name: configuration.name, leadMs: PlaybackEngine.minimumLeadMs)
            let engine = PlaybackEngine(group: group)
            let library = MusicLibrary(cacheURL: store.libraryCache)
            let api = ServerAPI(name: configuration.name, serverID: identity.id, library: library, engine: engine,
                                group: group, store: store)
            let http = HTTPServer { await api.respond(to: $0) }
            let port = try await http.start(port: configuration.apiPort)
            await engine.attach(artworkURL: { track in
                LocalAddress.primaryIPv4().map { "http://\($0):\(port)/imageproxy/\(track.albumID)?size=512" }
            }, onTrackStarted: { track in
                store.played(albumID: track.albumID)
            })
            let listener = ServiceListener(name: configuration.name, kind: .server, txt: [Self.apiPortKey: "\(port)"])
            listener.start()
            accepting = Task { [weak self] in
                for await connection in listener.connections {
                    await self?.accept(connection, identity: identity, pairings: pairings, store: store)
                }
            }
            await library.observe { [weak self] status in
                Task { await self?.libraryChanged(status) }
            }
            (self.store, self.group, self.library, self.api, self.http, self.listener) = (store, group, library, api, http, listener)
            (self.identity, self.pairings) = (identity, pairings)
            PlayerBrowser.allowsLoopback = configuration.dialsLoopback
            let denied: @Sendable (Bool) -> Void = { [weak self] denied in
                Task { await self?.localNetwork(denied: denied) }
            }
            discovering = Task { [weak self] in
                for await players in PlayerBrowser.browse(localNetworkDenied: denied) {
                    await self?.found(players)
                }
            }
            state.error = nil
            state.apiPort = Int(port)
            state.running = true
            Log.info("\(configuration.name): serving the library on port \(port)")
            Task { await library.load(folder: configuration.musicFolder) }
        } catch {
            Log.error("The server can't start: \(error)")
            state.error = "\(error)"
        }
    }

    public func stop() async {
        guard state.running else { return }
        accepting?.cancel()
        discovering?.cancel()
        listener?.stop()
        http?.stop()
        for request in codeRequests.values { request.resume(returning: nil) }
        codeRequests = [:]
        await api?.engine.stop()
        await group?.shutdown()
        await library?.load(folder: nil)
        (store, group, library, api, http, listener) = (nil, nil, nil, nil, nil, nil)
        (identity, pairings, dialed) = (nil, nil, [:])
        sessions = [:]
        statuses = [:]
        state = State()
    }

    /// Read another folder as the library, or the same one again.
    public func setMusicFolder(_ folder: URL?) async {
        await api?.artwork.clear()
        await library?.load(folder: folder)
    }

    private func libraryChanged(_ status: Library.Status) {
        state.library = status
    }

    // MARK: Players

    private func accept(_ connection: IncomingConnection, identity: ServerIdentity, pairings: PlayerPairings,
                        store: ServerStore) async {
        guard let group else { return }
        // A paired player plays; an unpaired one only once the operator allowed it.
        let session = PlayerSession(incoming: connection, identity: identity, pairings: pairings) { clientID, paired in
            paired || store.isAllowed(clientID)
        }
        let id = session.url.absoluteString
        sessions[id] = session
        follow(session, as: id)
        await group.add(session)
    }

    private func follow(_ session: PlayerSession, as id: String) {
        Task { [weak self] in
            for await status in session.updates { await self?.update(id, status, from: session) }
            await self?.ended(id, session)
        }
    }

    private func update(_ id: String, _ status: PlayerStatus, from session: PlayerSession) {
        guard sessions[id] === session else { return }
        statuses[id] = status
        publishPlayers()
    }

    /// A session ran out. A player that connected to us is gone until it connects again; one
    /// we connect to stays listed with how it ended, for the operator to pair or use it.
    private func ended(_ id: String, _ session: PlayerSession) {
        guard sessions[id] === session else { return }
        if dialed[id] == nil {
            remove(id)
        } else {
            codeRequests.removeValue(forKey: id)?.resume(returning: nil)
        }
    }

    // MARK: Players that announce themselves

    private func localNetwork(denied: Bool) {
        state.localNetworkDenied = denied
    }

    /// The players on the network changed: connect to the new ones, let go of those gone.
    private func found(_ players: [DiscoveredPlayer]) async {
        guard state.running else { return }
        let wanted = Dictionary(players.map { ($0.instanceName, $0) }) { first, _ in first }
        for id in dialed.keys where wanted[id] == nil {
            dialed[id] = nil
            if let session = sessions[id] { await group?.remove(url: session.url) }
            remove(id)
        }
        for (id, player) in wanted {
            if let known = dialed[id] {
                // A machine with two addresses is found at either. Only a player we can't
                // reach is tried at the other one: a connection that works is kept.
                guard known.url != player.url, statuses[id]?.connection == .unavailable else { continue }
                Log.info("\(player.displayName ?? id) moved to \(player.url.absoluteString)")
            } else {
                Log.info("Found \(player.displayName ?? id) at \(player.url.absoluteString)")
            }
            dialed[id] = player
            await dial(id)
        }
    }

    /// Connect to a found player, in place of any session with it that ran before. `chosen`
    /// claims it for playback, which only the operator asking for it does.
    private func dial(_ id: String, chosen: Bool = false, pairing: PairingRequest? = nil) async {
        guard let player = dialed[id], let group, let identity, let pairings, let store else { return }
        if let earlier = sessions[id] { await group.remove(url: earlier.url) }
        guard dialed[id] == player, self.group === group else { return }
        let session = PlayerSession(url: player.url, identity: identity, pairings: pairings, chosen: chosen,
                                    pairing: pairing) { clientID, paired in
            paired || store.isAllowed(clientID)
        }
        sessions[id] = session
        if statuses[id] == nil { statuses[id] = PlayerStatus() }
        publishPlayers()
        follow(session, as: id)
        await group.add(session)
    }

    /// Take a found player back for this server: one another server took, or that left.
    public func use(_ id: String) async {
        await dial(id, chosen: true)
    }

    private func remove(_ id: String) {
        sessions[id] = nil
        statuses[id] = nil
        codeRequests.removeValue(forKey: id)?.resume(returning: nil)
        publishPlayers()
    }

    private func publishPlayers() {
        state.players = statuses.compactMap { id, status in
            // Not listed before it said who it is, unless its announcement named it. Nor is a
            // device that turned out to be no speaker.
            let announced = dialed[id].map { $0.displayName ?? $0.instanceName }
            guard let name = status.name ?? announced, status.connection != .failed("not a speaker") else { return nil }
            return Player(id: id, clientID: status.clientID, name: name, connection: status.connection,
                          paired: status.paired, pairing: status.pairing,
                          offersCode: status.pairMethods?.dynamicCode != nil, found: dialed[id] != nil)
        }.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    /// Start pairing with the six digits the player shows; `enterCode(_:for:)` supplies them
    /// once `Player.pairing` asks.
    public func pair(_ id: String) async {
        let request = PairingRequest(method: .dynamicCode) { [weak self] _ in
            await self?.awaitCode(for: id)
        }
        // A found player's session ended when it asked for pairing: a new one pairs.
        if dialed[id] != nil {
            await dial(id, chosen: true, pairing: request)
        } else {
            await sessions[id]?.pair(request)
        }
    }

    private func awaitCode(for id: String) async -> String? {
        codeRequests.removeValue(forKey: id)?.resume(returning: nil)
        guard sessions[id] != nil else { return nil }
        return await withCheckedContinuation { codeRequests[id] = $0 }
    }

    /// The code the operator read off the player; nil cancels the pairing.
    public func enterCode(_ code: String?, for id: String) async {
        if let request = codeRequests.removeValue(forKey: id) {
            request.resume(returning: code)
        } else if code == nil {
            await sessions[id]?.cancelPairing()
        }
    }

    /// Let a player that admits it play without pairing.
    public func allow(_ id: String) async {
        guard let clientID = statuses[id]?.clientID else { return }
        store?.setAllowed(clientID, true)
        if dialed[id] != nil {
            await dial(id, chosen: true)
        } else {
            await sessions[id]?.reevaluateApproval()
        }
    }

    /// Forget a player's pairing, and its permission to play without one.
    public func forget(_ id: String) async {
        guard let clientID = statuses[id]?.clientID else { return }
        store?.setAllowed(clientID, false)
        await sessions[id]?.unpair()
    }
}

/// This machine's address on the local network, for links players fetch.
enum LocalAddress {
    /// An IPv4 address of an interface that's up, wired or Wi-Fi first; nil without one.
    static func primaryIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var fallback: String?
        var pointer = list
        while let current = pointer {
            pointer = current.pointee.ifa_next
            let flags = Int32(current.pointee.ifa_flags)
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            // Self-assigned addresses reach nobody.
            guard !text.hasPrefix("169.254.") else { continue }
            if String(cString: current.pointee.ifa_name).hasPrefix("en") { return text }
            fallback = fallback ?? text
        }
        return fallback
    }
}
