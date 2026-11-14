import CryptoKit
import Foundation
import Network

// Adapted from sendspin-mac's PlayerSession.swift (see UPSTREAM.md): split over several files.

extension PlayerSession {
    // MARK: Input (roles/source/v1.md)

    static let sourceAudioType: UInt8 = 12

    /// Play the device's input on the group, or stop it.
    public func playInput(_ play: Bool) {
        guard play != inputWanted else { return }
        inputWanted = play
        inputUndecodable = false
        // Playback is declared before the start, so the connection ranks as it streams.
        declareActivities()
        sendInputCommand()
    }

    /// Start the input when it's wanted and may start, stop it when it's not wanted any more
    /// (Source command semantics).
    func sendInputCommand() {
        guard activated, activeRoles.contains("source@v1"), rehandshake == nil else { return }
        if inputWanted {
            guard sourceReady, available, !startPending, inputStream == nil, !inputUndecodable else { return }
            startPending = true
            startsUnanswered += 1
            Log.info("\(status.name ?? "?"): starting its input")
            sendMessage("server/command", ServerCommand(source: SourceCommand(command: "start")))
        } else if startPending || inputStream?.decoder != nil {
            startPending = false
            // Until its client-stream/end, what it still sends is discarded.
            inputStream?.decoder = nil
            status.inputStreaming = false
            Log.info("\(status.name ?? "?"): stopping its input")
            sendMessage("server/command", ServerCommand(source: SourceCommand(command: "stop")))
        }
    }

    func handleClientStreamStart(_ start: ClientStreamStart) throws -> SessionEnd? {
        let name = status.name ?? "?"
        if inputStream == nil {
            // Opening one is only an answer to our start (Default streaming behavior).
            guard startsUnanswered > 0 else {
                Log.warning("\(name): opened an input stream without our start")
                return .stop(.failed("protocol error"))
            }
            startsUnanswered -= 1
            startPending = false
        }
        guard ServerHello.SourceSupport().supportedCodecs.contains(start.source.codec) else {
            Log.warning("\(name): sends its input as \(start.source.codec), which we didn't offer")
            return .stop(.failed("protocol error"))
        }
        let format = SourceFormat(codec: start.source.codec, channels: start.source.channels,
                                  sampleRate: start.source.sampleRate, bitDepth: start.source.bitDepth,
                                  codecHeader: start.source.codecHeader.flatMap { Data(base64Encoded: $0) })
        let wanted = inputWanted && activeRoles.contains("source@v1")
        let decoder = wanted ? SourceDecoder(format: format) : nil
        if decoder != nil {
            Log.info("\(name): input streaming \(format.codec) \(format.sampleRate) Hz \(format.bitDepth)-bit \(format.channels) ch")
        }
        // A new format replaces the stream's in place, on a new timeline.
        inputStream = (decoder, InputTimeline(sampleRate: format.sampleRate, channels: format.channels))
        status.inputStreaming = decoder != nil
        if wanted && decoder == nil {
            // It won't play: stop it rather than take audio we discard, and don't start it again by itself.
            Log.error("\(name): can't decode its input (\(format.codec) \(format.sampleRate) Hz \(format.bitDepth)-bit "
                + "\(format.channels) ch); stopping it")
            inputUndecodable = true
            startPending = false
            sendMessage("server/command", ServerCommand(source: SourceCommand(command: "stop")))
        }
        return nil
    }

    func handleClientStreamEnd() {
        guard let stream = inputStream else { return }
        Log.info("\(status.name ?? "?"): input stream ended (for its clock \(stream.timeline.doubled) frames doubled, "
            + "\(stream.timeline.dropped) dropped; \(stream.timeline.resyncs) restarts after a gap)")
        inputStream = nil
        startPending = false
        status.inputStreaming = false
    }

    /// One chunk of the input: its first sample's capture time, then whole codec units.
    func handleSourceAudio(_ payload: Data) throws {
        // Each of these closes the connection (Source Audio Chunks).
        guard payload.count >= 8 else { throw SessionError.protocolViolation("source audio shorter than 9 bytes") }
        guard let stream = inputStream else { throw SessionError.protocolViolation("source audio without an input stream") }
        guard available else { throw SessionError.protocolViolation("source audio while unavailable") }
        guard let decoder = stream.decoder else { return }
        let timestampUs = payload.prefix(8).reduce(Int64(0)) { $0 << 8 | Int64($1) }
        guard let samples = decoder.decode(payload.dropFirst(8)) else {
            undecodableChunks += 1
            if undecodableChunks == 1 || undecodableChunks.isMultiple(of: 100) {
                Log.warning("\(status.name ?? "?"): \(undecodableChunks) input chunks didn't decode")
            }
            return
        }
        var timeline = stream.timeline
        let placed = timeline.place(samples, timestampUs: timestampUs)
        inputStream?.timeline = timeline
        inputContinuation.yield(InputBlock(
            pcm: PCMBuffer(samples: placed.samples, sampleRate: decoder.format.sampleRate, channels: decoder.format.channels),
            captureTimeUs: placed.captureTimeUs))
    }

    // MARK: Player control

    /// Only sent when the player offers the command, and after its first client/state.
    /// What the player told about itself in client/state, until it says it again: after a
    /// reconnect, or once the player role is active anew.
    func forgetPlayerState() {
        ready = false
        status.volume = nil
        status.muted = nil
        status.canSetVolume = false
        status.canMute = false
        status.requiredBufferMs = 0
        status.reportedPlayerState = false
        outputDelayUs = 0
    }

    public func setVolume(_ volume: Int) {
        guard ready, status.canSetVolume else { return }
        sendMessage("server/command", ServerCommand(player: .volume(max(0, min(100, volume)))))
    }

    public func setMuted(_ muted: Bool) {
        guard ready, status.canMute else { return }
        sendMessage("server/command", ServerCommand(player: .mute(muted)))
    }

    /// End the stream and close the connection.
    func shutdown() {
        shuttingDown = true
        setPlaying(false)
        socket?.close()
    }
}

/// The audio a player may still hold (player/v1.md, Player Buffer Accounting): each chunk
/// counts from when it's sent until its completion time, its end minus the player's output
/// delay. Chunks stay listed until they've ended outright, so a lower output delay counts
/// them again.
struct PlayerBufferAccount {
    /// Wire size, and when playback ends on the server clock, in send order.
    var chunks: [(endUs: Int64, bytes: Int)] = []

    /// Count a chunk in if it fits within `capacity` next to the counted ones.
    mutating func admit(bytes: Int, endUs: Int64, nowUs: Int64, outputDelayUs: Int64, capacity: Int) -> Bool {
        // A chunk that has ended can't count again: the output delay is never negative.
        while let first = chunks.first, first.endUs <= nowUs { chunks.removeFirst() }
        let counted = chunks.reduce(0) { $1.endUs - outputDelayUs > nowUs ? $0 + $1.bytes : $0 }
        guard counted + bytes <= capacity else { return false }
        chunks.append((endUs, bytes))
        return true
    }
}
