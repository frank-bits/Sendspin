import CryptoKit
import Foundation

/// What this client tells a server about itself in client/hello.
public struct ClientConfiguration: Sendable {
    /// Friendly name; truncated to the 64 bytes the spec allows.
    public var name: String
    public var productName: String
    public var manufacturer: String
    public var softwareVersion: String
    /// Versioned roles, e.g. `player@v1`, `controller@v1`, `metadata@v1`.
    public var supportedRoles: [String]
    /// Required when `player@v1` is among the roles.
    public var playerSupport: PlayerSupport?
    /// Whether a server that hasn't paired may use this client (pairing.md, Unpaired Access).
    public var unpairedAccess: Bool

    public init(name: String, productName: String, manufacturer: String, softwareVersion: String,
                supportedRoles: [String], playerSupport: PlayerSupport? = nil, unpairedAccess: Bool = false) {
        self.name = name
        self.productName = productName
        self.manufacturer = manufacturer
        self.softwareVersion = softwareVersion
        self.supportedRoles = supportedRoles
        self.playerSupport = playerSupport
        self.unpairedAccess = unpairedAccess
    }
}

/// What the client reports in client/state.
public struct ClientStatus: Sendable, Equatable {
    public var available: Bool
    /// Needed while the player role is active.
    public var player: PlayerState?

    public init(available: Bool, player: PlayerState? = nil) {
        self.available = available
        self.player = player
    }
}

public enum SessionEvent: Sendable {
    /// The Noise handshake (or a re-handshake) finished; `pskCategory` is "lt", "pr" or "sn".
    case handshakeCompleted(serverID: String, pskCategory: String)
    case serverHello(name: String)
    case activated(activities: [String], activeRoles: [String], paired: Bool)
    /// The six-digit code to show while a server pairs with this client; nil when it ends.
    case pairingCode(String?)
    case paired(serverName: String?)
    case clockSynchronized(errorMicros: Double)
    /// A JSON message the session doesn't handle itself (group/update, server/state, stream/*, ...).
    case message(type: String, json: Data)
    /// A role's binary message: its ID, body, and local receive time.
    case binary(type: UInt8, payload: Data, receivedAtUs: Int64)
    /// The connection ended; `reason` is nil for a clean close.
    case closed(reason: String?)
}

/// One client-initiated connection to a Sendspin server. It runs the Noise handshake as
/// responder, pairs with the pairing token or a code shown on this device, keeps the clock in
/// sync, and hands role messages to its consumer as events.
/// Adapted from sendspin-mac's Client/SourceSession.swift (see UPSTREAM.md).
public actor ClientSession {
    /// Which PSK keyed the session (connection.md, Pre-Shared Key).
    enum PSKCategory: String {
        case longTerm = "lt", pairing = "pr", sentinel = "sn"
    }

    enum PairingMethod { case token, code }

    public nonisolated let events: AsyncStream<SessionEvent>
    let emit: AsyncStream<SessionEvent>.Continuation
    let store: CredentialStore
    let configuration: ClientConfiguration
    let socket: WebSocketConnection

    var identity: Curve25519.KeyAgreement.PrivateKey?
    var channel: SecureChannel?
    var serverKey: Curve25519.KeyAgreement.PublicKey?
    var serverID: String?
    var serverName: String?
    var matched: PSKCategory = .sentinel

    // Activation.
    var activated = false
    var activities: [String] = []
    var activeRoles: [String] = []
    /// Between Noise message 1 of a re-handshake and the server/activate under the new keys,
    /// nothing but the handshake may be sent (connection.md, Re-handshake).
    var rehandshaking = false
    /// We're closing the connection, so its end isn't the server's doing.
    var closing = false

    // Pairing (ClientSession+Pairing.swift).
    var pairingIndex = 0
    /// The long-term PSK sent in client/pair-finalize, stored once the server confirms.
    var pendingPSK: Data?
    var pairingTimeout: Task<Void, Never>?
    var codeAttempt: CodeAttempt?
    var heldAtLimit = false

    // Clock (ClientSession+Clock.swift).
    var filter = TimeFilter()
    var timeSync: Task<Void, Never>?
    var timeReply: CheckedContinuation<(ServerTimeReceived, Int64)?, Never>?
    var timeExchange = 0
    var converged: Bool { filter.count >= 3 }

    var status: ClientStatus
    var lastSentState: ClientStateMessage?

    public init(url: URL, store: CredentialStore, configuration: ClientConfiguration,
                status: ClientStatus = ClientStatus(available: true)) {
        socket = WebSocketConnection(url: url)
        self.store = store
        self.configuration = configuration
        self.status = status
        (events, emit) = AsyncStream.makeStream()
    }

    /// A session with a server that connected to us (connection.md, Server Initiated
    /// Connections): the same exchange, on its connection.
    public init(incoming connection: IncomingConnection, store: CredentialStore, configuration: ClientConfiguration,
                status: ClientStatus = ClientStatus(available: true)) {
        socket = connection.socket
        self.store = store
        self.configuration = configuration
        self.status = status
        (events, emit) = AsyncStream.makeStream()
    }

    // MARK: Connection

    /// Connect and serve until the connection ends; `events` finishes with `.closed`.
    public func run() async {
        var reason: String?
        do {
            try await serve()
        } catch {
            reason = "\(error)"
            Log.info("Session with \(serverName ?? socket.remoteDescription) ended: \(error)")
        }
        timeSync?.cancel()
        pairingTimeout?.cancel()
        timeReply?.resume(returning: nil)
        timeReply = nil
        socket.close()
        emit.yield(.closed(reason: reason))
        emit.finish()
    }

    private func serve() async throws {
        let identity = try await store.credentials.identity
        self.identity = identity
        try await socket.open()
        var frames = socket.frames.makeAsyncIterator()
        var timeout = closeAfterTimeout()
        defer { timeout?.cancel() }

        // client/init, then the server's server/init (or server/error) and Noise message 1.
        let suite = NoiseSuite.chaChaPoly
        let clientInit = try MessageCoding.encode(type: "client/init", payload: ClientInitMessage(
            clientID: Base64URL.encode(identity.publicKey.rawRepresentation), suite: suite.rawValue))
        socket.send(text: clientInit)

        guard case let .text(serverInitData, _)? = try await frames.next() else {
            throw SessionError.handshake("expected server/init")
        }
        let type = try MessageCoding.type(of: serverInitData)
        if type == "server/error" {
            let reason = (try? MessageCoding.payload(PairAbortMessage.self, from: serverInitData).reason) ?? "?"
            throw SessionError.handshake("server/error: \(reason)")
        }
        guard type == "server/init", let serverInit = try? MessageCoding.payload(ServerInitMessage.self, from: serverInitData),
              serverInit.version == 1, let keyData = Base64URL.decode(serverInit.serverID), keyData.count == 32,
              let serverKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
        else { throw SessionError.handshake("bad server/init") }
        self.serverKey = serverKey
        serverID = serverInit.serverID

        guard case let .text(message1Data, _)? = try await frames.next(),
              try MessageCoding.type(of: message1Data) == "noise/handshake",
              let message1 = Base64URL.decode(try MessageCoding.payload(NoiseHandshakeMessage.self, from: message1Data).data)
        else { throw SessionError.handshake("expected Noise message 1") }

        var handshake = NoiseResponderHandshake(suite: suite, prologue: clientInit + serverInitData,
                                                localStatic: identity, remoteStatic: serverKey)
        let (psk, category) = try await choosePSK(try handshake.readMessage1(message1), rehandshake: false)
        let (message2, transport) = try handshake.writeMessage2(payload: Data("{}".utf8), psk: psk)
        socket.send(text: try MessageCoding.encode(type: "noise/handshake",
                                                   payload: NoiseHandshakeMessage(data: Base64URL.encode(message2))))
        channel = SecureChannel(transport: transport)
        await handshakeCompleted(category)
        timeout?.cancel()
        // A server that never declares its purpose isn't worth holding a connection for.
        timeout = closeAfterTimeout()

        while let frame = try await frames.next() {
            guard case let .binary(ciphertext, receivedAtUs) = frame else {
                throw SessionError.handshake("cleartext message after the handshake")
            }
            guard let message = try channel?.open(ciphertext) else { continue }
            guard message.type == SecureChannel.jsonType else {
                // Binary role data counts only once the server has activated the connection.
                if activated { emit.yield(.binary(type: message.type, payload: message.payload, receivedAtUs: receivedAtUs)) }
                continue
            }
            if try await handle(message.payload, receivedAtUs: receivedAtUs) { return }
            if activated {
                timeout?.cancel()
                timeout = nil
            }
        }
        // The server closed the WebSocket without our goodbye.
        if !closing { throw WebSocketConnection.Failure.closed }
    }

    /// The PSK named in Noise message 1. A miss in the first handshake falls back to the
    /// Sentinel PSK, and the server learns we lost the credential; in a re-handshake it fails.
    private func choosePSK(_ payload: Data, rehandshake: Bool) async throws -> (Data, PSKCategory) {
        // A psk_id that isn't 43 base64url characters (32 bytes) breaks the payload's shape: a
        // silent failure, not a lookup miss (messaging.md, noise/handshake).
        guard let named = try? JSONDecoder().decode(NoiseMessage1Received.self, from: payload),
              let category = PSKCategory(rawValue: named.pskCategory),
              named.pskID.utf8.count == 43, Base64URL.decode(named.pskID)?.count == 32
        else { throw SessionError.handshake("malformed Noise message 1 payload") }
        let credentials = await store.credentials
        switch category {
        case .longTerm:
            if let record = credentials.record(pskID: named.pskID) {
                // The record must be this server's: anything else is a misbinding.
                guard record.serverID == serverID else { throw SessionError.handshake("PSK of another server") }
                return (record.psk, .longTerm)
            }
        case .pairing:
            if named.pskID == SendspinPSK.id(for: credentials.pairingPSK) { return (credentials.pairingPSK, .pairing) }
        case .sentinel:
            if named.pskID == SendspinPSK.id(for: SendspinPSK.sentinel) { return (SendspinPSK.sentinel, .sentinel) }
        }
        guard !rehandshake else { throw SessionError.handshake("unknown PSK in a re-handshake") }
        Log.info("The server's credential is unknown here; continuing unpaired")
        return (SendspinPSK.sentinel, .sentinel)
    }

    private func handshakeCompleted(_ category: PSKCategory) async {
        matched = category
        pairingIndex = 0
        guard let serverID else { return }
        if category == .longTerm { await store.touchPairing(serverID: serverID, serverName: serverName) }
        emit.yield(.handshakeCompleted(serverID: serverID, pskCategory: category.rawValue))
    }

    private func closeAfterTimeout() -> Task<Void, Never>? {
        let socket = socket
        return Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { socket.close() }
        }
    }

    // MARK: Inbound

    /// Handle one JSON message; true when the session is over.
    private func handle(_ data: Data, receivedAtUs: Int64) async throws -> Bool {
        let type = try MessageCoding.type(of: data)
        switch type {
        case "server/hello":
            let hello = try MessageCoding.payload(ServerHelloReceived.self, from: data)
            serverName = hello.name
            emit.yield(.serverHello(name: hello.name))
            sendMessage("client/hello", ClientHelloMessage(
                name: configuration.name.truncated(toUTF8Bytes: 64),
                deviceInfo: DeviceInfoMessage(productName: configuration.productName.truncated(toUTF8Bytes: 64),
                                              manufacturer: configuration.manufacturer.truncated(toUTF8Bytes: 64),
                                              softwareVersion: configuration.softwareVersion.truncated(toUTF8Bytes: 64)),
                supportedRoles: configuration.supportedRoles,
                playerSupport: configuration.supportedRoles.contains("player@v1") ? configuration.playerSupport : nil,
                unpairedAccess: .init(enabled: configuration.unpairedAccess)))
        case "server/activate":
            return try await handleActivate(MessageCoding.payload(ServerActivateReceived.self, from: data))
        case "noise/handshake":
            try await rehandshake(MessageCoding.payload(NoiseHandshakeMessage.self, from: data))
        case _ where !activated:
            Log.debug("Ignoring \(type) before activation")
        case "server/time":
            timeReply?.resume(returning: (try MessageCoding.payload(ServerTimeReceived.self, from: data), receivedAtUs))
            timeReply = nil
        case "server/pair-init":
            try await beginCodeRound(MessageCoding.payload(ServerPairInitReceived.self, from: data))
        case "server/pair-auth":
            try answerCodeAuth(MessageCoding.payload(ServerPairAuthReceived.self, from: data))
        case "server/pair-confirm":
            try await confirmCode(MessageCoding.payload(ServerPairConfirmReceived.self, from: data))
        case "server/pair-finalize":
            if let psk = pendingPSK, let serverID {
                // The server persisted its record: now ours. It re-handshakes to the new key next.
                endPairingAttempt()
                await store.storePairing(serverID: serverID, serverName: serverName, psk: psk)
                emit.yield(.paired(serverName: serverName))
                Log.info("Paired with \(serverName ?? serverID)")
            }
        case "pair/abort":
            let reason = (try? MessageCoding.payload(PairAbortMessage.self, from: data).reason) ?? "?"
            Log.info("Pairing aborted by the server (\(reason))")
            endPairingAttempt()
        case "server/unpair":
            guard matched == .longTerm, let serverID else { break }
            await store.removePairing(serverID: serverID)
            Log.info("\(serverName ?? serverID) unpaired")
            sendMessage("client/goodbye", ClientGoodbyeMessage(reason: "unpaired"))
            closing = true
            return true
        default:
            emit.yield(.message(type: type, json: data))
        }
        return false
    }

    /// Validate and apply server/activate (messaging.md, server/activate).
    private func handleActivate(_ activate: ServerActivateReceived) async throws -> Bool {
        // Any server/activate ends a re-handshake's hold on our messages (connection.md, Re-handshake).
        rehandshaking = false
        let declared = Set(activate.activities)
        let unpaired = matched != .longTerm

        func allowed(_ activities: Set<String>, unpairedAccess: Bool) -> Bool {
            switch matched {
            case .longTerm: return activities.isSubset(of: ["playback"])
            case .pairing, .sentinel:
                return activities.isSubset(of: ["pairing"]) || (unpairedAccess && activities.isSubset(of: ["playback", "pairing"]))
            }
        }
        // Roles carry over when omitted, but not onto a connection that can no longer play:
        // then they count as empty, and the activation isn't refused for them.
        let unpairedAccess = configuration.unpairedAccess
        let capable = allowed(declared.union(["playback"]), unpairedAccess: unpairedAccess)
        let roles = activate.activeRoles ?? (activated && capable ? activeRoles : [])
        func admissible(unpairedAccess: Bool) -> Bool {
            guard allowed(declared, unpairedAccess: unpairedAccess) else { return false }
            return allowed(declared.union(["playback"]), unpairedAccess: unpairedAccess) || roles.isEmpty
        }
        if unpaired && !unpairedAccess && !admissible(unpairedAccess: false) && admissible(unpairedAccess: true) {
            Log.info("\(serverName ?? "The server") wants unpaired playback; pairing is required")
            sendMessage("client/goodbye", ClientGoodbyeMessage(reason: "pairing_required"))
            closing = true
            return true
        }
        guard admissible(unpairedAccess: unpairedAccess) else {
            sendMessage("client/goodbye", ClientGoodbyeMessage(reason: "unauthorized"))
            closing = true
            return true
        }
        // A pairing method we don't offer under this PSK is answered, and the connection stays open.
        let method: PairingMethod?
        switch (activate.pairing?.method, matched) {
        case ("pairing_psk", .pairing): method = .token
        case ("dynamic_pairing_code", .sentinel) where activate.pairing?.format == "digits": method = .code
        default: method = nil
        }
        if declared.contains("pairing"), method == nil {
            sendMessage("pair/abort", PairAbortMessage(reason: "method_not_supported"))
            return false
        }

        activated = true
        activities = activate.activities
        let rolesChanged = roles != activeRoles
        activeRoles = roles
        if rolesChanged { lastSentState = nil }
        emit.yield(.activated(activities: activities, activeRoles: roles, paired: matched == .longTerm))
        if declared.contains("playback"), let serverID { await store.recordPlayback(serverID: serverID) }
        if timeSync == nil { startTimeSync() }
        sendState(force: rolesChanged)

        // Pairing: the token on a pairing-PSK connection, a code on an unpaired one.
        if declared.contains("pairing") {
            pairingIndex += 1
            endPairingAttempt()  // each pairing activation admits one attempt of its own
            switch method {
            case .token: startPairingPSK()
            case .code: await startPairingCode()
            case nil: break  // answered above
            }
        } else if pendingPSK != nil || codeAttempt != nil {
            // Left pairing without server/pair-finalize: persist nothing.
            endPairingAttempt()
        }
        return false
    }

    /// The server swaps session keys in-band, e.g. to the new long-term PSK after pairing.
    /// Our message 2 still goes under the old keys; everything after under the new.
    private func rehandshake(_ message: NoiseHandshakeMessage) async throws {
        guard let identity, let serverKey, let previous = channel, let message1 = Base64URL.decode(message.data) else {
            throw SessionError.handshake("bad re-handshake")
        }
        rehandshaking = true
        // It cuts the clock's burst short: no reply comes for an exchange in flight.
        timeReply?.resume(returning: nil)
        timeReply = nil
        // A re-handshake keeps the suite of the session; ours is always ChaChaPoly.
        var handshake = NoiseResponderHandshake(suite: .chaChaPoly, prologue: previous.handshakeHash,
                                                localStatic: identity, remoteStatic: serverKey)
        let (psk, category) = try await choosePSK(try handshake.readMessage1(message1), rehandshake: true)
        let (message2, transport) = try handshake.writeMessage2(payload: Data("{}".utf8), psk: psk)
        sendMessage("noise/handshake", NoiseHandshakeMessage(data: Base64URL.encode(message2)), duringRehandshake: true)
        channel = SecureChannel(transport: transport)
        await handshakeCompleted(category)
    }

    // MARK: State

    /// Change what client/state reports; sent when it differs from the last one sent.
    public func setStatus(_ status: ClientStatus) {
        self.status = status
        sendState()
    }

    /// client/state goes out once roles are active, and for a player only once the clock is in sync.
    func sendState(force: Bool = false) {
        guard activated, !activeRoles.isEmpty, !rehandshaking else { return }
        let playerActive = activeRoles.contains("player@v1")
        if playerActive {
            guard converged else { return }
            guard status.player != nil else {
                Log.warning("The player role is active but no player state is set; client/state held back")
                return
            }
        }
        let message = ClientStateMessage(available: status.available, player: playerActive ? status.player : nil)
        guard force || message != lastSentState else { return }
        lastSentState = message
        sendMessage("client/state", message)
    }

    // MARK: Outbound

    /// Send a role's JSON message, e.g. client/command. Dropped during a re-handshake.
    public func send<P: Encodable & Sendable>(type: String, payload: P) {
        guard activated else { return }
        sendMessage(type, payload)
    }

    /// Say goodbye and close: `shutdown`, `restart`, `user_request` or `another_server`.
    public func close(goodbye reason: String) {
        closing = true
        if activities.contains("pairing"), pendingPSK != nil || codeAttempt != nil {
            sendMessage("pair/abort", PairAbortMessage(reason: "user_cancelled"))
        }
        sendMessage("client/goodbye", ClientGoodbyeMessage(reason: reason))
        socket.close()
    }

    func sendMessage<P: Encodable>(_ type: String, _ payload: P, duringRehandshake: Bool = false) {
        guard duringRehandshake || !rehandshaking || type == "client/goodbye" else { return }
        do {
            send(SecureChannel.jsonType, try MessageCoding.encode(type: type, payload: payload))
        } catch {
            Log.error("encoding \(type): \(error)")
        }
    }

    private func send(_ type: UInt8, _ payload: Data) {
        guard channel != nil else { return }
        do {
            for message in try channel!.seal(type: type, payload: payload) {
                socket.send(binary: message)
            }
        } catch {
            Log.error("encrypting: \(error)")
            socket.close()
        }
    }
}
