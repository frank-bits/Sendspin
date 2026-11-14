import CryptoKit
import Foundation
import Network

// Adapted from sendspin-mac's PlayerSession.swift (see UPSTREAM.md): split over several files.

extension PlayerSession {
    // MARK: Connection lifecycle

    /// Connect and keep the player connected until cancelled or the player leaves for good.
    public func run() async {
        defer {
            socket?.close()
            updatesContinuation.finish()
            inputContinuation.finish()
        }
        if isIncoming {
            // A player that connected to us comes back by itself; we can't dial it.
            status.connection = .connecting
            do {
                if case .stop(let connection) = try await connectAndServe() {
                    status.connection = connection
                } else {
                    status.connection = .disconnected(reason: nil)
                }
            } catch where Self.isUnreachable(error) {
                Log.info("\(status.name ?? url.absoluteString): unavailable (\(error))")
                status.connection = .unavailable
            } catch {
                Log.warning("\(url): \(error)")
                status.connection = .failed(String(describing: error))
            }
            resetConnectionState()
            return
        }
        var backoff: Duration = .seconds(1)
        var busyBackoff: Duration = .seconds(5)
        while !Task.isCancelled {
            // An unavailable player stays so while we try again: no "Connecting…" each time.
            if status.connection != .unavailable { status.connection = .connecting }
            var outcome: SessionEnd
            var unreachable = false
            let started = ContinuousClock.now
            reached = false
            do {
                outcome = try await connectAndServe()
                // Only a connection that lasted resets the backoff: one that closes right after
                // its handshake is retried ever later too (messaging.md, client/goodbye).
                if ContinuousClock.now - started > .seconds(10) { backoff = .seconds(1) }
            } catch is CancellationError {
                break
            } catch where Self.isUnreachable(error) {
                if status.connection != .unavailable {
                    Log.info("\(status.name ?? url.absoluteString): unavailable (\(error)), retrying")
                }
                status.connection = .unavailable
                // Only a player we didn't reach: a network error once connected is a failed
                // handshake, backed off as one (messaging.md, client/goodbye).
                unreachable = !reached
                outcome = .reconnect
            } catch {
                Log.warning("\(url): \(error)")
                status.connection = .failed(String(describing: error))
                outcome = .reconnect
            }
            resetConnectionState()
            if Task.isCancelled { break }
            // An attempt ends with its connection: the operator starts another one. Until one
            // started, the session keeps trying to reach the speaker.
            if pairingRequest != nil, !pairingFinished, status.pairing != nil {
                if case .failed = status.pairing {} else {
                    status.pairing = .failed("The connection to the speaker ended.")
                }
                status.connection = .pairingRequired
                return
            }

            switch outcome {
            case .reconnect:
                busyBackoff = .seconds(5)
            case .retryLater:
                // A server MAY retry later (messaging.md, client/goodbye): not every second.
                try? await Task.sleep(for: busyBackoff)
                busyBackoff = min(busyBackoff * 2, .seconds(60))
                continue
            case .stop(let connection):
                status.connection = connection
                return
            }
            // Also the backoff for repeated handshake failures, which the spec asks for. A
            // player that's off the network is tried more often, so it plays again soon after
            // it's back: a connection attempt costs nothing on the network it isn't on.
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, unreachable ? .seconds(5) : .seconds(30))
        }
    }

    /// The network failed, not the player: unreachable, refused, timed out, or gone silent.
    static func isUnreachable(_ error: any Error) -> Bool {
        error is NWError || error is WebSocketConnection.Failure
    }

    enum SessionEnd {
        case reconnect
        /// Turned away while another server pairs with it (`concurrent_attempt`).
        case retryLater
        case stop(PlayerStatus.Connection)
    }

    func connectAndServe() async throws -> SessionEnd {
        let socket = incoming ?? WebSocketConnection(url: url)
        self.socket = socket
        defer { socket.close() }
        try await socket.open()
        reached = true
        Log.debug("\(url): connected")

        var frames = socket.frames.makeAsyncIterator()
        var timeout = Self.closeAfterTimeout(socket)
        defer { timeout?.cancel() }

        // client/init, then server/init and Noise message 1 back to back.
        guard case let .text(clientInitData, _)? = try await frames.next() else {
            reject(socket, reason: "malformed")
            throw SessionError.handshake("expected client/init")
        }
        let (clientInit, suite, clientKey) = try parseClientInit(clientInitData, socket: socket)
        let serverInitData = try MessageCoding.encode(type: "server/init", payload: ServerInit(serverID: identity.id))
        // A paired player gets our pairing's long-term PSK, any other the Sentinel.
        let longTerm = pairings.psk(for: clientInit.clientID)
        var attempt = NoiseInitiatorHandshake(
            suite: suite, prologue: clientInitData + serverInitData, localStatic: identity.privateKey,
            remoteStatic: clientKey, psk: longTerm ?? SendspinPSK.sentinel)
        let message1Payload = try JSONEncoder().encode(
            NoiseMessage1Payload(pskID: SendspinPSK.id(for: longTerm ?? SendspinPSK.sentinel),
                                 pskCategory: longTerm == nil ? "sn" : "lt"))
        let message1 = try attempt.writeMessage1(payload: message1Payload)
        var sentMessage1 = attempt
        socket.send(text: serverInitData)
        socket.send(text: try MessageCoding.encode(type: "noise/handshake",
                                                   payload: NoiseHandshakeMessage(data: Base64URL.encode(message1))))
        timeout?.cancel()
        timeout = Self.closeAfterTimeout(socket)

        // Noise message 2 completes the handshake. Failures from here on are silent: close.
        guard case let .text(message2Data, _)? = try await frames.next(),
              try MessageCoding.type(of: message2Data) == "noise/handshake",
              let message2 = Base64URL.decode(try MessageCoding.payload(NoiseHandshakeMessage.self,
                                                                         from: message2Data).data)
        else { throw SessionError.handshake("expected Noise message 2") }
        let payload: Data, transport: NoiseTransport
        if let result = try? attempt.readMessage2(message2) {
            (payload, transport) = result
            status.paired = longTerm != nil
        } else if longTerm != nil, let result = try? sentMessage1.readMessage2(message2, psk: SendspinPSK.sentinel) {
            // It answered on the Sentinel: it lost our pairing. Authenticated, but it
            // removes nothing by itself (connection.md, Sentinel Fallback).
            (payload, transport) = result
            notRecognized = true
        } else {
            throw SessionError.handshake("Noise message 2 doesn't verify")
        }
        guard payload == Self.message2Payload else { throw SessionError.handshake("Noise message 2 payload isn't {}") }
        channel = SecureChannel(transport: transport)
        status.clientID = clientInit.clientID
        self.suite = suite
        self.clientKey = clientKey
        connectionPSK = status.paired ? (longTerm ?? SendspinPSK.sentinel) : SendspinPSK.sentinel
        Log.debug("\(url): Noise handshake done (\(suite.rawValue))")

        // The name our mDNS TXT record carries, which SHOULD match (connection.md): a DNS label's 63 bytes.
        sendMessage("server/hello", ServerHello(name: identity.name.truncated(toUTF8Bytes: ServiceListener.maxNameBytes)))
        timeout?.cancel()
        timeout = Self.closeAfterTimeout(socket)

        while let frame = try await frames.next() {
            // After the handshake, a cleartext message is a silent failure.
            guard case let .binary(ciphertext, receivedAtUs) = frame,
                  let message = try channel?.open(ciphertext)
            else {
                if case .text = frame { throw SessionError.handshake("cleartext message after the handshake") }
                continue
            }
            guard message.type == SecureChannel.jsonType else {
                if message.type == Self.sourceAudioType { try handleSourceAudio(message.payload) }
                continue
            }
            if let end = try await handle(message.payload, receivedAtUs: receivedAtUs) {
                return end
            }
            if hello != nil {
                timeout?.cancel()
                timeout = nil
            }
        }
        if let endOfConnection { return endOfConnection }
        // A drop without client/goodbye: assume `restart` (messaging.md, client/goodbye).
        if hello != nil, !shuttingDown {
            Log.info("\(status.name ?? url.absoluteString): closed without a goodbye, reconnecting")
        }
        if status.connection == .connected { status.connection = .disconnected(reason: nil) }
        return .reconnect
    }

    /// Validate client/init; on an init failure, answer with server/error first.
    func parseClientInit(_ data: Data, socket: WebSocketConnection)
        throws -> (ClientInit, NoiseSuite, Curve25519.KeyAgreement.PublicKey) {
        let clientInit: ClientInit, suite: NoiseSuite
        do {
            (clientInit, suite) = try ClientInit.parse(data)
        } catch {
            reject(socket, reason: error.rawValue)
            throw SessionError.handshake("client/init: \(error.rawValue)")
        }
        guard let keyData = Base64URL.decode(clientInit.clientID), keyData.count == 32,
              let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
        else {
            reject(socket, reason: "malformed")
            throw SessionError.handshake("client_id isn't a Curve25519 key")
        }
        return (clientInit, suite, key)
    }

    func reject(_ socket: WebSocketConnection, reason: String) {
        if let message = try? MessageCoding.encode(type: "server/error", payload: ServerError(reason: reason)) {
            socket.send(text: message)
        }
    }

    /// Each handshake step must arrive within 30 s (connection.md, Failure Handling).
    /// Message 2's payload: the empty object, as the literal two bytes `{}`; anything else is a
    /// malformed payload, a silent failure (messaging.md, noise/handshake).
    static let message2Payload = Data("{}".utf8)

    static func closeAfterTimeout(_ socket: WebSocketConnection) -> Task<Void, Never>? {
        Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { socket.close() }
        }
    }

    func resetConnectionState() {
        rehandshakeTimeout?.cancel()
        rehandshakeTimeout = nil
        socket = nil
        channel = nil
        hello = nil
        activated = false
        notRecognized = false
        attempt = nil
        pairingIndex = 0
        pairingInitTimeout?.cancel()
        rehandshake = nil
        activationOwed = false
        endOfConnection = nil
        status.paired = false
        declaredActivities = []
        // The others' group lost a member.
        controllerChanged()
        activeRoles = []
        visualizerRequest = nil
        controllerState = nil
        artworkRequest = nil
        speakerApproved = false
        inputApproved = false
        // A start doesn't survive the connection (Default streaming behavior).
        sourceReady = false
        startPending = false
        startsUnanswered = 0
        inputStream = nil
        inputUndecodable = false
        status.inputStreaming = false
        status.inputSignal = nil
        sentActivation = false
        available = false
        // Its volume and mute may have changed meanwhile: they come with its first client/state
        // (player/v1.md, Volume and mute).
        forgetPlayerState()
        // A player that left stays out across reconnects: the server MUST NOT auto-rejoin it
        // (messaging.md, External Source Handling).
        lastGroupUpdate = nil
        stopStreaming()
    }
}
