import CryptoKit
import Foundation
import Network

// Adapted from sendspin-mac's PlayerSession.swift (see UPSTREAM.md): split over several files.

extension PlayerSession {
    // MARK: Inbound messages

    /// Handle one JSON message; returns how the session ends when the client leaves.
    func handle(_ data: Data, receivedAtUs: Int64) async throws -> SessionEnd? {
        let type = try MessageCoding.type(of: data)
        // Mid re-handshake, old-key messages may still come; nothing goes out but the handshake.
        if rehandshake != nil, type != "noise/handshake", type != "client/goodbye" { return nil }
        switch type {
        case "client/goodbye":
            return goodbye(try MessageCoding.payload(ClientGoodbye.self, from: data).reason)
        case "client/hello" where hello == nil:
            return try await handleHello(MessageCoding.payload(ClientHello.self, from: data))
        case _ where !sentActivation:
            // Before server/activate the client may send nothing but goodbye.
            Log.debug("\(status.name ?? "?"): ignoring \(type) before activation")
        case "client/time":
            let time = try MessageCoding.payload(ClientTime.self, from: data)
            sendMessage("server/time", ServerTime(clientTransmitted: time.clientTransmitted,
                                                  serverReceived: receivedAtUs,
                                                  serverTransmitted: ServerClock.nowMicros()))
        case "client/state":
            if let end = handleState(try MessageCoding.payload(ClientState.self, from: data)) { return end }
        case "client/command":
            handleCommand(try MessageCoding.payload(ClientCommand.self, from: data))
        case "client-stream/start":
            return try handleClientStreamStart(MessageCoding.payload(ClientStreamStart.self, from: data))
        case "client-stream/end":
            handleClientStreamEnd()
        case "client/leave":
            leaveGroup("left the group")
        case "noise/handshake":
            try await finishRehandshake(MessageCoding.payload(NoiseHandshakeMessage.self, from: data))
        case "client/pair-pending":
            try handlePairPending(MessageCoding.payload(ClientPairPendingMessage.self, from: data))
        case "client/pair-init":
            try handlePairInit(MessageCoding.payload(ClientPairInitMessage.self, from: data))
        case "client/pair-auth":
            try handlePairAuth(MessageCoding.payload(ClientPairAuthMessage.self, from: data))
        case "client/pair-retry":
            try handlePairRetry()
        case "client/pair-confirm":
            try handlePairConfirm(MessageCoding.payload(ClientPairConfirmMessage.self, from: data))
        case "client/pair-finalize":
            try await handlePairFinalize(MessageCoding.payload(ClientPairFinalizeMessage.self, from: data))
        case "pair/abort":
            handlePairAbort(try MessageCoding.payload(PairAbortMessage.self, from: data).reason)
        default:
            Log.debug("\(status.name ?? "?"): ignoring \(type)")
        }
        return nil
    }

    func goodbye(_ reason: String) -> SessionEnd {
        let name = status.name ?? url.absoluteString
        switch reason {
        case "restart", "shutdown":
            // Both SHOULD be reconnected; a player that's gone stops it, when its mDNS service
            // goes (messaging.md, client/goodbye).
            Log.info("\(name): goodbye (\(reason)), reconnecting")
            return .reconnect
        case "concurrent_attempt" where declaredActivities.contains("playback"):
            // Playback ranks highest, so only a pairing attempt keeps us out: it ends soon.
            Log.info("\(name): pairing with another server, trying again later")
            return .retryLater
        case "concurrent_attempt":
            Log.info("\(name): in use by another server")
            return .stop(.taken)
        case "another_server":
            Log.info("\(name): taken over by another server")
            return .stop(.taken)
        case "pairing_required":
            Log.info("\(name): requires pairing")
            return .stop(.pairingRequired)
        default:
            Log.info("\(name): left (\(reason))")
            return .stop(.disconnected(reason: reason))
        }
    }

    func handleHello(_ hello: ClientHello) async -> SessionEnd? {
        self.hello = hello
        status.name = hello.name
        status.supportedFormats = (hello.playerSupport?.supportedFormats ?? [])
            .filter { $0.codec == AudioCodec.pcm.rawValue || $0.codec == AudioCodec.flac.rawValue }
        Log.info("\(hello.name): hello (\(hello.deviceInfo?.productName ?? "unknown device"), "
            + "software \(hello.deviceInfo?.softwareVersion ?? "?"))")

        status.pairMethods = hello.supportedPairMethods
        status.supportedRoles = hello.supportedRoles.filter {
            ($0 != "player@v1" || hello.playerSupport != nil) && ($0 != "source@v1" || hello.sourceSupport != nil)
        }
        if probing {
            probedHello = hello
            return .stop(.disconnected(reason: nil))
        }
        // A role we don't know may be a newer version than ours (overview.md, Detecting
        // Outdated Servers).
        let unknown = hello.supportedRoles.filter { !$0.hasPrefix("_") && !Self.implementedRoles.contains($0) }
        if !unknown.isEmpty {
            Log.info("\(hello.name): offers roles this server doesn't implement: \(unknown.joined(separator: ", "))")
        }
        // Like roles: identifiers from a newer revision of the spec (pairing.md, pair-method descriptor).
        if let ignored = hello.supportedPairMethods?.ignored, !ignored.isEmpty {
            Log.info("\(hello.name): offers pairing identifiers this server doesn't know: \(ignored.joined(separator: ", "))")
        }

        guard (uses.contains(.speaker) && status.isSpeaker) || (uses.contains(.input) && status.isInput) else {
            sendMessage("server/activate", ServerActivate(activities: [], activeRoles: []))
            return .stop(.failed(uses.contains(.speaker) ? "not a speaker" : "not an input"))
        }
        if let pairingRequest, !pairingFinished {
            return startPairing(pairingRequest)
        }
        // While our record exists, a player on the Sentinel MUST NOT play: pairing again fixes it.
        if notRecognized {
            Log.info("\(hello.name): doesn't recognize this Mac any more; it needs pairing again")
            // A player that connected to us is paired on this connection: hold it.
            if isIncoming { return holdIncoming(as: .notRecognized) }
            return .stop(.notRecognized)
        }
        if status.paired {
            await askApprovals()
            guard speakerApproved || inputApproved else {
                if isIncoming || awaitsInputApproval { return holdIncoming() }
                return .stop(.disconnected(reason: nil))
            }
            activatePlayback()
            return nil
        }
        // There's no pairing record, so this is an unpaired session on the Sentinel PSK:
        // the player must admit unpaired access and the user must have approved it.
        guard hello.unpairedAccess?.enabled == true else {
            Log.info("\(hello.name): doesn't admit unpaired access; it needs pairing")
            if isIncoming { return holdIncoming(as: .pairingRequired) }
            return .stop(.pairingRequired)
        }
        await askApprovals()
        guard speakerApproved || inputApproved else {
            if isIncoming || awaitsInputApproval { return holdIncoming() }
            // A found player isn't held on an idle connection: allowing it dials it again.
            Log.info("\(hello.name): hasn't been allowed to play without pairing")
            return .stop(.awaitingApproval)
        }
        activatePlayback()
        return nil
    }

    /// Ask whether it may play as a speaker, and as an input, for the uses it's wanted for.
    func askApprovals() async {
        guard let clientID = status.clientID else { return }
        let paired = status.paired
        speakerApproved = uses.contains(.speaker) && status.isSpeaker ? await approve(clientID, paired) : false
        inputApproved = uses.contains(.input) && status.isInput ? await approveInput?(clientID, paired) ?? false : false
    }

    /// Wanted only as an input, which the user hasn't allowed yet: it waits on an idle connection.
    var awaitsInputApproval: Bool {
        uses.contains(.input) && status.isInput && !(uses.contains(.speaker) && status.isSpeaker)
    }

    /// Hold a device with no activities, as the spec allows, until the user allows it: a player
    /// that connected to us, or an input not allowed yet.
    func holdIncoming(as connection: PlayerStatus.Connection = .awaitingApproval) -> SessionEnd? {
        sendMessage("server/activate", ServerActivate(activities: [], activeRoles: []))
        sentActivation = true
        sendGroupUpdate()
        status.connection = connection
        return nil
    }

    static let implementedRoles = ["player@v1", "controller@v1", "metadata@v1", "artwork@v1", "visualizer@v1", "color@v1", "source@v1"]

    /// The roles we activate: every one the client lists that we implement, each with the
    /// support object it requires (messaging.md, client/hello), for what the user allowed it as.
    /// All are v1, so there's no version to choose (overview.md, Priority and Activation).
    func wantedRoles() -> [String] {
        guard let hello else { return [] }
        var roles: [String] = []
        if speakerApproved {
            roles.append("player@v1")
            for role in ["controller@v1", "metadata@v1", "artwork@v1", "color@v1"] where hello.supportedRoles.contains(role) {
                roles.append(role)
            }
            if hello.supportedRoles.contains("visualizer@v1"), hello.visualizerSupport != nil { roles.append("visualizer@v1") }
        }
        if inputApproved { roles.append("source@v1") }
        return roles
    }

    /// The player role is active: the device is a speaker in our group, or has left it.
    var speaking: Bool { activated && activeRoles.contains("player@v1") }

    func activatePlayback() {
        activated = true
        activeRoles = wantedRoles()
        // A held player may have sent client/state already, but not for the roles it gets now.
        ready = false
        visualizerRequest = nil
        controllerState = nil
        artworkRequest = nil
        sourceReady = false
        declareActivities(force: true)
        if claiming {
            // Sound normally follows within a moment; without it, the claim lapses.
            Task {
                try? await Task.sleep(for: .seconds(5))
                endClaim()
            }
        }
        sentActivation = true
        sendGroupUpdate()
        status.connection = left ? .left : .connected
        // Each role with a server/state object gets its state at once (messaging.md, server/state):
        // metadata and color here, the controller from the group.
        let now = ServerClock.nowMicros()
        let metadata = activeRoles.contains("metadata@v1") ? currentMetadata(at: now) : nil
        let color = activeRoles.contains("color@v1") ? TimestampOnlyState(timestamp: now) : nil
        if metadata != nil || color != nil { sendMessage("server/state", ServerState(metadata: metadata, color: color)) }
        controllerChanged()
    }

    /// The uses or approvals changed on an activated connection: activate the roles they call
    /// for now, without reconnecting (messaging.md, server/activate).
    func updateRoles() {
        let wanted = wantedRoles()
        guard wanted != activeRoles else { return }
        let added = wanted.filter { !activeRoles.contains($0) }
        // A removed stream role's stream ends first; the speaker's roles go together, and its
        // player state with them (messaging.md, server/activate).
        if activeRoles.contains("player@v1") && !wanted.contains("player@v1") {
            endStreams()
            forgetPlayerState()
        }
        if added.contains("player@v1") {
            ready = false
            visualizerRequest = nil
            controllerState = nil
            artworkRequest = nil
        }
        if added.contains("source@v1") { sourceReady = false }
        if !wanted.contains("source@v1") {
            // The client ends its stream itself; what's still in flight is discarded.
            startPending = false
            inputStream?.decoder = nil
        }
        Log.info("\(status.name ?? "?"): roles \(wanted.isEmpty ? "none" : wanted.joined(separator: ", "))")
        activeRoles = wanted
        declareActivities(force: true)
        sendGroupUpdate()
        let now = ServerClock.nowMicros()
        let metadata = added.contains("metadata@v1") ? currentMetadata(at: now) : nil
        let color = added.contains("color@v1") ? TimestampOnlyState(timestamp: now) : nil
        if metadata != nil || color != nil { sendMessage("server/state", ServerState(metadata: metadata, color: color)) }
        controllerChanged()
    }

    /// What the user has the device for changed: its roles follow, on the same connection.
    public func use(_ uses: Uses) async {
        guard uses != self.uses else { return }
        self.uses = uses
        await reevaluate()
    }

    /// Ask the approvals again, and activate what they allow now.
    func reevaluate() async {
        guard hello != nil, sentActivation, rehandshake == nil, !notRecognized, attempt == nil else { return }
        await askApprovals()
        if activated {
            updateRoles()
            sendInputCommand()
        } else if speakerApproved || inputApproved {
            Log.info("\(status.name ?? "?"): allowed")
            activatePlayback()
        }
    }

    /// Declare playback only while there's something to play, as the spec asks: a server that
    /// keeps an unused activity wins players it doesn't need (messaging.md, server/activate).
    /// The player role stays active, so the stream starts at once when sound comes.
    func declareActivities(force: Bool = false) {
        guard activated else { return }
        let speakerPlays = speaking && (playing || claiming) && !left
        let inputPlays = activeRoles.contains("source@v1") && inputWanted
        let activities = speakerPlays || inputPlays ? ["playback"] : []
        guard force || activities != declaredActivities else { return }
        declaredActivities = activities
        sendMessage("server/activate", ServerActivate(activities: activities, activeRoles: activeRoles))
    }

    /// The user allowed a held player (ticked it): activate playback on the same connection.
    public func reevaluateApproval() async {
        await reevaluate()
    }

    /// The user selected a player that left: back into the group, if it's available again.
    /// Its stream restarts with the next chunk.
    public func rejoin() {
        guard left else { return }
        guard available else {
            Log.info("\(status.name ?? "?"): still in use elsewhere")
            return
        }
        Log.info("\(status.name ?? "?"): back in the group")
        left = false
        leftBySwitch = false
        soloGroupID = nil
        declareActivities()
        sendGroupUpdate()
        status.connection = .connected
        controllerChanged()
    }

    /// The player stops taking part, being in use by something else or having sent
    /// `client/leave`: move it to a stopped group of its own and end its stream. It stays
    /// there, even once available again, until the user selects it (messaging.md,
    /// External Source Handling).
    func leaveGroup(_ reason: String, bySwitch: Bool = false) {
        guard speaking, !left else { return }
        Log.info("\(status.name ?? "?"): \(reason); out of the group until it's selected again")
        left = true
        leftBySwitch = bySwitch
        soloGroupID = GroupID.random()
        sendGroupUpdate()
        endStreams()
        declareActivities()
        status.connection = .left
        controllerChanged()
    }

    func handleState(_ state: ClientState) -> SessionEnd? {
        // Objects for roles that aren't active are ignored (messaging.md, server/activate).
        if let request = state.visualizer, activated, activeRoles.contains("visualizer@v1") {
            guard !request.isMalformed else {
                Log.warning("\(status.name ?? "?"): asks for a spectrum without its configuration")
                return .stop(.failed("protocol error"))
            }
            visualizerRequest = request
            // A change to an active stream restarts it in place; without one it waits for the next.
            // Never to a client that says it's unavailable (messaging.md, stream/start).
            if let current = visualizer, state.available, request.negotiated() != current.config {
                startVisualizer(request.negotiated(), sampleRate: current.sampleRate, channels: current.channels,
                                after: current.lastUs)
            }
        }
        if let request = state.artwork, activated, activeRoles.contains("artwork@v1") {
            guard !request.isMalformed else {
                Log.warning("\(status.name ?? "?"): asks for more than four artwork channels, or one without its format")
                return .stop(.failed("protocol error"))
            }
            artworkRequest = request
            if let current = artworkStream, state.available, request.streamed != current { startArtwork(request.streamed) }
        }
        let wasAvailable = available
        available = state.available
        // Only for an active player role: an inactive role's object is ignored.
        if let player = state.player, activeRoles.contains("player@v1") {
            if let volume = player.volume { status.volume = volume }
            if let muted = player.muted { status.muted = muted }
            let commands = player.supportedCommands ?? []
            status.canSetVolume = commands.contains("volume")
            status.canMute = commands.contains("mute")
            status.requiredBufferMs = (player.minBufferMs ?? 0) + (player.outputDelayMs ?? 0)
            status.reportedPlayerState = true
            outputDelayUs = Int64(player.outputDelayMs ?? 0) * 1_000
            if speaking { ready = true }
            controllerChanged()
        }
        // Only a change counts: a player says `available: false` until its clock is in sync
        // (messaging.md, Clock Synchronization), so its first state often does.
        if wasAvailable && !available {
            leaveGroup("in use elsewhere")
        }
        if let source = state.source, activated, activeRoles.contains("source@v1") {
            sourceReady = true
            status.inputSignal = source.signal
        }
        // Unavailable is an implicit stop: the client drops our start (Default streaming behavior).
        // It does so before saying it, and its messages come in send order, so no answer to an
        // earlier start can follow any more.
        if !available {
            startPending = false
            startsUnanswered = 0
        }
        sendInputCommand()
        return nil
    }
}
