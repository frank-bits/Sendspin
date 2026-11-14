import CryptoKit
import Foundation
import Network

// Adapted from sendspin-mac's PlayerSession.swift (see UPSTREAM.md): split over several files.

// MARK: - Pairing, the server's side (pairing.md)

/// One pairing attempt: from the pairing server/activate until success or pair/abort.
struct PairingAttempt {
    let method: PairingMethod
    let index: Int
    /// client/pair-init arrived.
    var started = false
    /// Dynamic code: the client's commitment, and our nonce from the first round.
    var commitB: Data?
    var nonceA: Data?
    var round = 0
    /// This round's code, CPace run and session id, once the operator entered it.
    var code: Data?
    var cpace: CPace?
    var sid: Data?
    /// CPace derived the key from the client's share.
    var derived = false
    /// client/pair-confirm checked out: client/pair-finalize may follow.
    var confirmed = false
}

enum AfterRehandshake {
    /// To the pairing PSK, for the Pairing PSK flow.
    case pairing
    /// To the new long-term PSK, after a pairing.
    case paired
}

extension PlayerSession {
    /// The attempts, rounds and flows of pairing.md, Methods; the operator's codes come
    /// from `PairingRequest.code`.
    func startPairing(_ request: PairingRequest) -> SessionEnd? {
        status.pairing = .starting
        // Only a method the speaker offers (pairing.md, client/hello pair-method descriptor).
        let offered = switch request.method {
        case .token: status.pairMethods?.pairingPSK != nil
        case .staticCode: status.pairMethods?.staticCode != nil
        case .dynamicCode: status.pairMethods?.dynamicCode != nil
        case .dynamicQRCode: status.pairMethods?.dynamicQRCode != nil
        }
        guard offered else {
            status.pairing = .failed("The speaker doesn't offer this way of pairing.")
            return .stop(.pairingRequired)
        }
        if case .token(let token) = request.method {
            // The token must be this device's (pairing.md, Pairing PSK Flow).
            guard token.clientID == status.clientID else {
                Log.warning("\(status.name ?? "?"): the pairing token is another device's")
                status.pairing = .failed("That pairing token belongs to another device.")
                return .stop(.pairingRequired)
            }
            // The connection runs on the Sentinel or an old pairing: switch to its pairing PSK.
            // Nothing but server/activate may come first (messaging.md, Communication).
            sendMessage("server/activate", ServerActivate(activities: [], activeRoles: []))
            sentActivation = true
            beginRehandshake(to: token.pairingPSK, longTerm: false, then: .pairing)
            return nil
        }
        activatePairing()
        return nil
    }

    var methodName: (method: String, format: String?) {
        switch pairingRequest?.method {
        case .token: ("pairing_psk", nil)
        case .staticCode: ("static_pairing_code", nil)
        case .dynamicCode, nil: ("dynamic_pairing_code", "digits")
        case .dynamicQRCode: ("dynamic_pairing_code", "qr_code")
        }
    }

    /// A pairing activation admits one attempt; it doesn't touch roles or streams.
    func activatePairing() {
        guard let pairingRequest else { return }
        pairingIndex += 1
        attempt = PairingAttempt(method: pairingRequest.method, index: pairingIndex)
        let (method, format) = methodName
        sendMessage("server/activate", ServerActivate(activities: ["pairing"], activeRoles: [],
                                                      pairing: .init(method: method, format: format)))
        sentActivation = true
        sendGroupUpdate()
        // Our own timeout while waiting for client/pair-init (pairing.md, Entering and leaving
        // pairing), long enough for a button press or a pairing window to be opened.
        let index = pairingIndex
        pairingInitTimeout?.cancel()
        pairingInitTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            await self?.pairingInitTimedOut(index)
        }
    }

    /// Cancelled by the activation alone: `user_cancelled` is for an operator's own cancel
    /// (pairing.md, Entering and leaving pairing).
    func pairingInitTimedOut(_ index: Int) {
        guard let attempt, attempt.index == index, !attempt.started else { return }
        failPairing("The speaker didn't start pairing.", abort: nil)
    }

    /// A lower index is a leftover from a superseded pairing, discarded; a higher one is an error.
    func isCurrent(_ index: Int) throws -> Bool {
        guard index <= pairingIndex else { throw SessionError.pairing("pairing_index \(index) ahead of \(pairingIndex)") }
        return index == pairingIndex && attempt != nil
    }

    func handlePairPending(_ message: ClientPairPendingMessage) throws {
        guard try isCurrent(message.pairingIndex), let attempt else { return }
        // It only comes before an attempt starts, and never in the Pairing PSK Flow: otherwise
        // it's out of sequence, a protocol error (pairing.md, Messages).
        if attempt.started { throw SessionError.pairing("client/pair-pending after client/pair-init") }
        if case .token = attempt.method { throw SessionError.pairing("client/pair-pending in the Pairing PSK Flow") }
        // From an unauthenticated peer: plain text, at most 200 bytes.
        status.pairing = .waiting(message: message.message?.truncated(toUTF8Bytes: 200))
    }

    func handlePairInit(_ message: ClientPairInitMessage) throws {
        guard try isCurrent(message.pairingIndex), var attempt, !attempt.started else { return }
        attempt.started = true
        pairingInitTimeout?.cancel()
        switch attempt.method {
        case .token:
            status.pairing = .checking  // client/pair-finalize follows at once
        case .staticCode:
            attempt.round = 1
            self.attempt = attempt
            askForCode(.staticCode(again: staticCodeWasWrong))
            return
        case .dynamicCode, .dynamicQRCode:
            guard let commit = message.commitB.flatMap(Base64URL.decode), commit.count == 32 else {
                throw SessionError.pairing("client/pair-init without commit_B")
            }
            let nonceA = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            attempt.commitB = commit
            attempt.nonceA = nonceA
            attempt.round = 1
            self.attempt = attempt
            sendMessage("server/pair-init", ServerPairInitReceived(nonceA: Base64URL.encode(nonceA)))
            askForCode(dynamicPrompt(attempt.method, again: false))
            return
        }
        self.attempt = attempt
    }

    func dynamicPrompt(_ method: PairingMethod, again: Bool) -> PairingPrompt {
        method == .dynamicQRCode ? .dynamicQRCode(again: again) : .dynamicCode(again: again)
    }

    /// The operator enters the code; the session goes on meanwhile.
    func askForCode(_ prompt: PairingPrompt) {
        guard let pairingRequest, let attempt else { return }
        status.pairing = .enteringCode(prompt)
        let index = attempt.index, round = attempt.round
        Task { [weak self] in
            let code = await pairingRequest.code(prompt)
            await self?.codeEntered(code, prompt: prompt, index: index, round: round)
        }
    }

    func codeEntered(_ code: String?, prompt: PairingPrompt, index: Int, round: Int) {
        guard var attempt, attempt.index == index, attempt.round == round, attempt.code == nil,
              let channel else { return }
        guard let code else {
            failPairing(nil, abort: "user_cancelled")
            return
        }
        let prs: Data
        if case .dynamicQRCode = prompt {
            // A version-1 pairing token, its first 24 payload bytes the code (pairing.md,
            // QR-code emission). Anything else is asked for again.
            guard let bytes = PairingToken.decodeDynamicCode(code) else {
                askForCode(prompt)
                return
            }
            prs = bytes
        } else {
            // Separators never count (pairing.md, Pairing Code Presentation).
            let digits = code.filter(\.isASCII).filter(\.isNumber)
            guard digits.count == prompt.length else {
                askForCode(prompt)
                return
            }
            prs = Data(digits.utf8)
        }
        let sid = DynamicPairingCode.sessionID(handshakeHash: channel.handshakeHash, pairingIndex: index, round: round)
        do {
            let cpace = try CPace(role: .initiator, prs: prs, sid: sid, ad: Data("server".utf8))
            attempt.code = prs
            attempt.sid = sid
            attempt.cpace = cpace
            self.attempt = attempt
            status.pairing = .checking
            sendMessage("server/pair-auth", ServerPairAuthReceived(pakeMsg1: Base64URL.encode(cpace.publicShare)))
        } catch {
            failPairing("Pairing failed: \(error)", abort: nil)
        }
    }

    func handlePairAuth(_ message: ClientPairAuthMessage) throws {
        guard var attempt, var cpace = attempt.cpace, !attempt.derived else {
            throw SessionError.pairing("client/pair-auth out of sequence")
        }
        guard let share = Base64URL.decode(message.pakeMsg2) else { throw SessionError.pairing("malformed pake_msg_2") }
        try cpace.derive(peerShare: share, peerAD: Data("client".utf8))
        guard let tag = cpace.tag() else { throw SessionError.pairing("no confirmation tag") }
        attempt.cpace = cpace
        attempt.derived = true
        self.attempt = attempt
        sendMessage("server/pair-confirm", ServerPairConfirmReceived(serverKC: Base64URL.encode(tag)))
    }

    /// The client's check of our tag failed: the code was wrong. Another round, same code.
    func handlePairRetry() throws {
        guard var attempt, [.dynamicCode, .dynamicQRCode].contains(attempt.method), attempt.derived else {
            throw SessionError.pairing("client/pair-retry out of sequence")
        }
        guard attempt.round < 20 else {
            failPairing("Too many wrong codes.", abort: "pairing_code_mismatch")
            return
        }
        attempt.round += 1
        attempt.code = nil
        attempt.cpace = nil
        attempt.sid = nil
        attempt.derived = false
        self.attempt = attempt
        sendMessage("server/pair-init", ServerPairInitReceived(nonceA: nil))
        askForCode(dynamicPrompt(attempt.method, again: true))
    }

    func handlePairConfirm(_ message: ClientPairConfirmMessage) throws {
        guard var attempt, let cpace = attempt.cpace, attempt.derived, !attempt.confirmed,
              let sid = attempt.sid, let isk = cpace.isk else {
            throw SessionError.pairing("client/pair-confirm out of sequence")
        }
        guard let tag = Base64URL.decode(message.clientKC), cpace.verify(peerTag: tag) else {
            failPairing("That code didn't match.", abort: "pairing_code_mismatch")
            return
        }
        // The dynamic code is bound to this handshake: the client's committed nonce must
        // open, and give the code the operator entered (pairing.md, Server verification).
        if [.dynamicCode, .dynamicQRCode].contains(attempt.method) {
            guard let sealed = message.wrappedNonceB.flatMap(Base64URL.decode),
                  let nonceB = try? DynamicPairingCode.unwrap(sealed, .nonce, sid: sid, isk: isk, suite: suite),
                  DynamicPairingCode.commitment(to: nonceB) == attempt.commitB,
                  let channel, let nonceA = attempt.nonceA,
                  expectedCode(attempt.method, handshakeHash: channel.handshakeHash, nonceA: nonceA, nonceB: nonceB) == attempt.code
            else { throw SessionError.pairing("the pairing code isn't bound to this handshake") }
        }
        attempt.confirmed = true
        self.attempt = attempt
    }

    /// The code the client derived, as fed into CPace: six ASCII digits, or 24 raw bytes.
    func expectedCode(_ method: PairingMethod, handshakeHash h: Data, nonceA: Data, nonceB: Data) -> Data {
        method == .dynamicQRCode ? DynamicPairingCode.qrCode(handshakeHash: h, nonceA: nonceA, nonceB: nonceB)
            : Data(DynamicPairingCode.digits(handshakeHash: h, nonceA: nonceA, nonceB: nonceB).utf8)
    }

    func handlePairFinalize(_ message: ClientPairFinalizeMessage) async throws {
        guard let attempt, attempt.started, let clientID = status.clientID else {
            throw SessionError.pairing("client/pair-finalize out of sequence")
        }
        let psk: Data
        switch attempt.method {
        case .token:
            guard let value = message.longTermPSK.flatMap(Base64URL.decode) else {
                throw SessionError.pairing("client/pair-finalize without long_term_psk")
            }
            psk = value
        case .staticCode, .dynamicCode, .dynamicQRCode:
            guard attempt.confirmed, let sid = attempt.sid, let isk = attempt.cpace?.isk,
                  let sealed = message.wrappedPSK.flatMap(Base64URL.decode),
                  let value = try? DynamicPairingCode.unwrap(sealed, .psk, sid: sid, isk: isk, suite: suite) else {
                throw SessionError.pairing("wrapped_psk doesn't open")
            }
            psk = value
        }
        guard psk.count == 32, psk != SendspinPSK.sentinel, psk != connectionPSK else {
            throw SessionError.pairing("unusable long-term PSK")
        }
        // Persisted before we say so; the client persists its record on server/pair-finalize.
        pairings.store(psk, for: clientID)
        sendMessage("server/pair-finalize", EmptyPayload())
        self.attempt = nil
        pairingFinished = true
        notRecognized = false
        status.pairing = .paired
        Log.info("\(status.name ?? clientID): paired")
        beginRehandshake(to: psk, longTerm: true, then: .paired)
    }

    func handlePairAbort(_ reason: String) {
        guard let attempt else { return }
        if reason == "pairing_code_mismatch", case .staticCode = attempt.method {
            // The client found our tag wrong: the static code was. A new attempt, in the
            // pairing window the device keeps open.
            staticCodeWasWrong = true
            activatePairing()
            return
        }
        let text = switch reason {
        case "attempt_timeout": "The speaker stopped waiting for the code."
        case "method_not_supported": "The speaker doesn't offer this way of pairing."
        case "user_cancelled": "Pairing was cancelled on the speaker."
        case "pairing_code_mismatch": "Too many wrong codes. Check the speaker, then try again."
        case "concurrent_attempt": "The speaker is pairing with another server."
        default: "The speaker ended pairing (\(reason))."
        }
        failPairing(text, abort: nil)
    }

    /// Leave pairing, and end the connection: the operator starts a new attempt. A cancel
    /// says why first (pairing.md, Entering and leaving pairing).
    func failPairing(_ text: String?, abort reason: String?) {
        if let reason { sendMessage("pair/abort", PairAbortMessage(reason: reason)) }
        sendMessage("server/activate", ServerActivate(activities: [], activeRoles: []))
        attempt = nil
        pairingInitTimeout?.cancel()
        status.pairing = text.map { .failed($0) } ?? .failed("Pairing was cancelled.")
        endOfConnection = .stop(.pairingRequired)
        socket?.close()
    }

    /// Pair on this connection: for a player that connected to us and is held, since a server
    /// never opens another connection to pair (connection.md, Multiple servers).
    public func pair(_ request: PairingRequest) {
        guard hello != nil, sentActivation, rehandshake == nil, attempt == nil else { return }
        pairingRequest = request
        pairingFinished = false
        // A method the player doesn't offer fails in `status.pairing`; the connection stays.
        _ = startPairing(request)
    }

    /// Forget the pairing. A connected speaker is told to forget it too (server/unpair), and
    /// says goodbye with `unpaired`; one that isn't keeps its record until it's paired again,
    /// which replaces it.
    public func unpair() {
        guard let clientID = status.clientID else { return }
        if status.paired, channel != nil, hello != nil {
            // Nothing but server/activate may go first (messaging.md, Communication), also under
            // new keys: while the hello, or a re-handshake, still waits on approval, an idle one.
            if !sentActivation || activationOwed {
                sendMessage("server/activate", ServerActivate(activities: [], activeRoles: []))
                sentActivation = true
            }
            sendMessage("server/unpair", EmptyPayload())
        }
        pairings.remove(clientID)
        Log.info("\(status.name ?? clientID): pairing forgotten")
    }

    /// Cancel the pairing in progress, from this Mac.
    public func cancelPairing() {
        guard attempt != nil || status.pairing == .starting else { return }
        failPairing(nil, abort: "user_cancelled")
    }

    // MARK: Re-handshake (connection.md, Re-handshake)

    /// New session keys on the same connection: the prologue is the old handshake hash, and
    /// nothing else goes out until the new keys are in place.
    func beginRehandshake(to psk: Data, longTerm: Bool, then next: AfterRehandshake) {
        guard let channel, let clientKey else { return }
        var handshake = NoiseInitiatorHandshake(suite: suite, prologue: channel.handshakeHash,
                                                localStatic: identity.privateKey, remoteStatic: clientKey, psk: psk)
        do {
            let payload = try JSONEncoder().encode(
                NoiseMessage1Payload(pskID: SendspinPSK.id(for: psk), pskCategory: longTerm ? "lt" : "pr"))
            let message1 = try handshake.writeMessage1(payload: payload)
            sendMessage("noise/handshake", NoiseHandshakeMessage(data: Base64URL.encode(message1)))
            rehandshake = (handshake, psk, longTerm, next)
            rehandshakeTimeout?.cancel()
            rehandshakeTimeout = socket.flatMap(Self.closeAfterTimeout)
        } catch {
            failPairing("Pairing failed: \(error)", abort: nil)
        }
    }

    func finishRehandshake(_ message: NoiseHandshakeMessage) async throws {
        guard var state = rehandshake, let message2 = Base64URL.decode(message.data) else {
            throw SessionError.handshake("noise/handshake out of sequence")
        }
        // A miss fails: no Sentinel fallback in a re-handshake.
        let (payload, transport) = try state.handshake.readMessage2(message2)
        guard payload == Self.message2Payload else { throw SessionError.handshake("Noise message 2 payload isn't {}") }
        rehandshakeTimeout?.cancel()
        rehandshakeTimeout = nil
        channel = SecureChannel(transport: transport)
        rehandshake = nil
        connectionPSK = state.psk
        pairingIndex = 0
        status.paired = state.longTerm
        activationOwed = true
        Log.debug("\(status.name ?? "?"): re-handshake done (\(state.longTerm ? "lt" : "pr"))")
        // The first message under the new keys is server/activate.
        switch state.then {
        case .pairing:
            activatePairing()
        case .paired:
            // As after a hello on a paired connection: the roles follow from what's approved.
            await askApprovals()
            guard speakerApproved || inputApproved else {
                sendMessage("server/activate", ServerActivate(activities: [], activeRoles: []))
                return
            }
            activatePlayback()
        }
    }
}
