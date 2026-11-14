import CryptoKit
import Foundation

// Pairing as a client (pairing.md): the Pairing PSK flow and the Dynamic Pairing Code flow.
// Adapted from sendspin-mac's Client/SourceSession.swift (see UPSTREAM.md).

extension ClientSession {
    /// One Dynamic Pairing Code attempt: its code stays the same across rounds, each round a
    /// fresh CPace run.
    struct CodeAttempt {
        let nonceB = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let pairingIndex: Int
        var round = 0
        /// Waiting for server/pair-init: after client/pair-init, and after client/pair-retry.
        var awaitingRound = true
        /// From the first round's nonce_A on.
        var code: String?
        var cpace: CPace?
        var sid = Data()
    }

    /// Pairing PSK flow: pair-init and pair-finalize back to back, with a new long-term PSK.
    func startPairingPSK() {
        let psk = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        pendingPSK = psk
        sendMessage("client/pair-init", ClientPairInitMessage(pairingIndex: pairingIndex))
        sendMessage("client/pair-finalize", ClientPairFinalizeMessage(longTermPSK: Base64URL.encode(psk)))
        startPairingTimeout()
        Log.info("Pairing with \(serverName ?? "server") (token)")
    }

    /// Dynamic Pairing Code flow: commit to nonce_B; the code follows from the server's nonce_A
    /// in its first server/pair-init. Past the round limit, attempts wait until the operator
    /// allows pairing again (pairing.md, Rounds).
    func startPairingCode() async {
        if await store.codeRoundLimitReached {
            heldAtLimit = true
            sendMessage("client/pair-pending", ClientPairPendingMessage(
                pairingIndex: pairingIndex,
                message: "Too many wrong codes. To try again, allow pairing in the app's settings on the device."))
            return
        }
        heldAtLimit = false
        let attempt = CodeAttempt(pairingIndex: pairingIndex)
        codeAttempt = attempt
        sendMessage("client/pair-init", ClientPairInitMessage(
            pairingIndex: pairingIndex, commitB: Base64URL.encode(DynamicPairingCode.commitment(to: attempt.nonceB))))
        startPairingTimeout()
        Log.info("Pairing with \(serverName ?? "server") (code)")
    }

    /// Pairing was allowed again (`CredentialStore.allowPairingAgain()`): an attempt held back
    /// at the round limit starts, in the same pairing activation.
    public func releaseHeldPairing() async {
        guard heldAtLimit, activities.contains("pairing"), codeAttempt == nil, !rehandshaking else { return }
        await startPairingCode()
    }

    /// server/pair-init: a round begins. The first carries nonce_A, which fixes the code; each
    /// shows the code and starts a fresh CPace run on it.
    func beginCodeRound(_ message: ServerPairInitReceived) async throws {
        guard var attempt = codeAttempt else { return }  // left over from an ended attempt
        guard attempt.awaitingRound, let h = channel?.handshakeHash else {
            throw SessionError.pairing("server/pair-init out of turn")
        }
        attempt.round += 1
        if attempt.round == 1 {
            guard let nonceA = message.nonceA.flatMap(Base64URL.decode), nonceA.count == DynamicPairingCode.nonceSize
            else { throw SessionError.pairing("bad nonce_A") }
            attempt.code = DynamicPairingCode.digits(handshakeHash: h, nonceA: nonceA, nonceB: attempt.nonceB)
        } else if message.nonceA != nil {
            throw SessionError.pairing("nonce_A after the first round")
        }
        guard let code = attempt.code else { throw SessionError.pairing("no pairing code") }
        await store.codeRoundBegan()
        attempt.sid = DynamicPairingCode.sessionID(handshakeHash: h, pairingIndex: attempt.pairingIndex,
                                                   round: attempt.round)
        attempt.cpace = try CPace(role: .responder, prs: Data(code.utf8), sid: attempt.sid, ad: Data("client".utf8))
        attempt.awaitingRound = false
        codeAttempt = attempt
        emit.yield(.pairingCode(code))
        Log.info("Showing the pairing code (round \(attempt.round))")
    }

    /// server/pair-auth: the server has the code the operator entered; answer with our share.
    func answerCodeAuth(_ message: ServerPairAuthReceived) throws {
        guard var attempt = codeAttempt else { return }
        guard var cpace = attempt.cpace, cpace.isk == nil else { throw SessionError.pairing("server/pair-auth out of turn") }
        guard let ya = Base64URL.decode(message.pakeMsg1) else { throw SessionError.pairing("bad pake_msg_1") }
        do {
            try cpace.derive(peerShare: ya, peerAD: Data("server".utf8))
        } catch {
            throw SessionError.pairing("\(error)")
        }
        attempt.cpace = cpace
        codeAttempt = attempt
        sendMessage("client/pair-auth", ClientPairAuthMessage(pakeMsg2: Base64URL.encode(cpace.publicShare)))
    }

    /// server/pair-confirm: a tag that verifies means the operator entered our code. Then our
    /// tag, the opening of the commitment and the new long-term PSK, the last two wrapped under
    /// the CPace output; otherwise another round, up to the limit.
    func confirmCode(_ message: ServerPairConfirmReceived) async throws {
        guard var attempt = codeAttempt else { return }
        guard let cpace = attempt.cpace, let isk = cpace.isk else { throw SessionError.pairing("server/pair-confirm out of turn") }
        guard let ta = Base64URL.decode(message.serverKC), ta.count == 64 else { throw SessionError.pairing("bad server_kc") }
        attempt.cpace = nil
        guard cpace.verify(peerTag: ta), let tb = cpace.tag() else {
            if await store.codeRoundLimitReached {
                Log.info("Wrong pairing code, and the round limit is reached")
                sendMessage("pair/abort", PairAbortMessage(reason: "pairing_code_mismatch"))
                endPairingAttempt()
            } else {
                Log.info("Wrong pairing code; asking for another round")
                attempt.awaitingRound = true
                codeAttempt = attempt
                sendMessage("client/pair-retry", EmptyPayload())
            }
            return
        }
        await store.codeRoundVerified()
        codeAttempt = attempt
        let psk = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let wrappedNonce = try DynamicPairingCode.wrap(attempt.nonceB, .nonce, sid: attempt.sid, isk: isk, suite: .chaChaPoly)
        let wrappedPSK = try DynamicPairingCode.wrap(psk, .psk, sid: attempt.sid, isk: isk, suite: .chaChaPoly)
        pendingPSK = psk
        sendMessage("client/pair-confirm", ClientPairConfirmMessage(clientKC: Base64URL.encode(tb),
                                                                    wrappedNonceB: Base64URL.encode(wrappedNonce)))
        sendMessage("client/pair-finalize", ClientPairFinalizeMessage(wrappedPSK: Base64URL.encode(wrappedPSK)))
        Log.info("\(serverName ?? "The server") entered the right code")
    }

    /// The operator cancelled on this device.
    public func cancelPairing() {
        guard pendingPSK != nil || codeAttempt != nil else { return }
        sendMessage("pair/abort", PairAbortMessage(reason: "user_cancelled"))
        endPairingAttempt()
    }

    /// Each attempt ends within 2 minutes of its first message (pairing.md).
    private func startPairingTimeout() {
        pairingTimeout?.cancel()
        pairingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            await self?.pairingTimedOut()
        }
    }

    private func pairingTimedOut() {
        guard pendingPSK != nil || codeAttempt != nil else { return }
        sendMessage("pair/abort", PairAbortMessage(reason: "attempt_timeout"))
        endPairingAttempt()
    }

    func endPairingAttempt() {
        let showedCode = codeAttempt?.code != nil
        pendingPSK = nil
        codeAttempt = nil
        heldAtLimit = false
        pairingTimeout?.cancel()
        pairingTimeout = nil
        if showedCode { emit.yield(.pairingCode(nil)) }
    }
}
