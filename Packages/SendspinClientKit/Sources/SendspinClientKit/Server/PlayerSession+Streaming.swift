import CryptoKit
import Foundation
import Network

// Adapted from sendspin-mac's PlayerSession.swift (see UPSTREAM.md): split over several files.

extension PlayerSession {
    // MARK: Outbound

    func sendMessage<P: Encodable>(_ type: String, _ payload: P) {
        // After our Noise message 1, only the handshake until the new keys are in place.
        guard rehandshake == nil || type == "noise/handshake" else { return }
        if type == "server/activate" { activationOwed = false }
        do {
            send(SecureChannel.jsonType, try MessageCoding.encode(type: type, payload: payload))
        } catch {
            Log.error("encoding \(type): \(error)")
        }
    }

    /// Encrypt and send in one step: Noise nonces must follow the send order.
    func send(_ type: UInt8, _ payload: Data) {
        guard let socket, channel != nil else { return }
        do {
            for message in try channel!.seal(type: type, payload: payload) {
                socket.send(binary: message)
            }
        } catch {
            Log.error("\(status.name ?? "?"): encrypting: \(error)")
            socket.close()
        }
    }

    /// Send the player its group when it changed: ours while it plays with us, and a
    /// stopped group of its own while it's held or has left. Every connection gets one
    /// after its first server/activate (messaging.md, group/update).
    func sendGroupUpdate() {
        guard sentActivation else { return }
        let update: GroupUpdate
        if speaking && !left {
            guard let group else { return }
            update = GroupUpdate(playbackState: playing ? "playing" : "stopped", groupID: group.id, groupName: group.name)
        } else {
            if soloGroupID == nil { soloGroupID = GroupID.random() }
            update = GroupUpdate(playbackState: "stopped", groupID: soloGroupID!, groupName: status.name ?? "")
        }
        guard update != lastGroupUpdate else { return }
        lastGroupUpdate = update
        sendMessage("group/update", update)
    }

    // MARK: Group interface

    /// The group's track details changed: sent while the metadata role is active here.
    func updateMetadata(_ state: MetadataState) {
        trackDetails = state
        guard activated, activeRoles.contains("metadata@v1"), rehandshake == nil else { return }
        sendMessage("server/state", ServerState(metadata: state))
    }

    /// A role's first state carries a past or present timestamp (messaging.md, server/state).
    func currentMetadata(at now: Int64) -> MetadataState {
        guard var state = trackDetails else { return MetadataState(timestamp: now) }
        state.timestamp = min(state.timestamp, now)
        return state
    }

    /// A seek or a jump to another track: the player drops what it has buffered and goes on
    /// with what follows, without ending the stream (messaging.md, stream/clear).
    func clearStream() {
        let roles = (streaming ? ["player"] : []) + (visualizer != nil ? ["visualizer"] : [])
        guard !roles.isEmpty else { return }
        sendMessage("stream/clear", StreamClear(serverTransmitted: ServerClock.nowMicros(), roles: roles))
        // The next block starts a new timeline: nothing carries over from the old one.
        pipeline = nil
        buffer = PlayerBufferAccount()
        visualizer = nil
        visualizerBuffer = VisualizerBufferAccount()
    }

    func join(groupID: String, groupName: String, group playbackGroup: PlaybackGroup? = nil) {
        group = (groupID, groupName)
        self.playbackGroup = playbackGroup
        sendGroupUpdate()
    }

    // MARK: Controller role (roles/controller/v1.md)

    func controllerMember() -> ControllerMember {
        ControllerMember(inGroup: speaking && !left && ready, volume: status.volume, muted: status.muted,
                         canSetVolume: ready && status.canSetVolume, canMute: ready && status.canMute)
    }

    /// Send the controller its group's state, when it changed.
    func updateController(_ state: GroupControllerState) {
        guard activated, activeRoles.contains("controller@v1"), rehandshake == nil, state != controllerState else { return }
        controllerState = state
        sendMessage("server/state", ServerState(controller: state))
    }

    /// Something the group's controller state depends on changed.
    func controllerChanged() {
        let group = playbackGroup
        Task { await group?.membersChanged() }
    }

    func handleCommand(_ command: ClientCommand) {
        // Only for an active role, and only what we offer (Controller messages).
        guard let controller = command.controller, activated, activeRoles.contains("controller@v1"),
              controllerState?.supportedCommands.contains(controller.command) == true
        else { return }
        Log.info("\(status.name ?? "?"): controller \(controller.command)"
            + (controller.volume.map { " \($0)" } ?? "") + (controller.mute.map { " \($0)" } ?? ""))
        if controller.command == "switch" {
            // The cycle is our group while it plays, then one of its own. From its own it goes
            // back: first of all to the group it left by becoming unavailable or client/leave,
            // and to one it switched away from only while that plays (Switch command cycle).
            if !left {
                leaveGroup("switched to a group of its own", bySwitch: true)
            } else if !leftBySwitch || playing {
                rejoin()
            } else {
                Log.info("\(status.name ?? "?"): no group plays to switch to; it stays on its own")
            }
            return
        }
        let group = playbackGroup
        Task { await group?.command(controller, from: self) }
    }

    func setPlaying(_ playing: Bool) {
        guard playing != self.playing else { return }
        self.playing = playing
        if playing { declareActivities() }
        sendGroupUpdate()
        if playing {
            claiming = false
        } else {
            endStreams()
            // Not at once: a lead change stops and restarts the group in one go.
            Task {
                try? await Task.sleep(for: .seconds(1))
                if !self.playing { self.declareActivities() }
            }
        }
    }

    func endClaim() {
        guard claiming else { return }
        claiming = false
        declareActivities()
    }

    /// stream/end for every stream that's active.
    func endStreams() {
        let roles = (streaming ? ["player"] : []) + (artworkStream != nil ? ["artwork"] : [])
            + (visualizer != nil ? ["visualizer"] : [])
        if !roles.isEmpty { sendMessage("stream/end", StreamEnd(roles: roles)) }
        stopStreaming()
    }

    func stopStreaming() {
        streaming = false
        pipeline = nil
        status.streamFormat = nil
        // stream/end empties the player's and the visualizer's buffer accounting.
        buffer = PlayerBufferAccount()
        visualizer = nil
        visualizerBuffer = VisualizerBufferAccount()
        artworkStream = nil
    }

    /// Send one block of group audio, and its visualization; `timestampUs` is its play time
    /// on the server clock.
    func deliver(_ pcm: PCMBuffer, timestampUs: Int64, preferredBitDepth: Int, leadUs: Int64) {
        guard speaking, !left, available, rehandshake == nil else { return }
        deliverAudio(pcm, timestampUs: timestampUs, preferredBitDepth: preferredBitDepth, leadUs: leadUs)
        visualize(pcm, timestampUs: timestampUs)
        if artworkStream == nil, let request = artworkRequest { startArtwork(request.streamed) }
    }

    /// The player gets the format closest to the source (see `FormatChoice`).
    func deliverAudio(_ pcm: PCMBuffer, timestampUs: Int64, preferredBitDepth: Int, leadUs: Int64) {
        guard let socket, ready else { return }
        // A lead too short for this player's buffer: wait for the group's lead to be raised,
        // which restarts the stream, rather than start it short (player/v1.md, Server Audio
        // Send Constraints).
        guard streaming || leadUs >= Int64(status.requiredBufferMs + PlaybackGroup.sendMarginMs) * 1_000 else { return }
        if pipeline == nil || !pipeline!.accepts(pcm) || pipelineBitDepthPreference != preferredBitDepth {
            guard startPipeline(for: pcm, timestampUs: timestampUs, preferredBitDepth: preferredBitDepth) else { return }
        }

        // A stalled player must not buffer unbounded audio in the network stack.
        if socket.backlog > 100 {
            droppedChunks += 1
            if droppedChunks.isMultiple(of: 50) {
                Log.warning("\(status.name ?? "?"): send backlog, dropped \(droppedChunks) chunks")
            }
            return
        }
        guard let chunks = pipeline?.process(pcm, timestampUs: timestampUs), let format = pipeline?.format else { return }
        sendChunks(chunks, sampleRate: format.sampleRate)
    }

    func sendChunks(_ chunks: [PlayerAudioPipeline.Chunk], sampleRate: Int) {
        for chunk in chunks {
            guard fitsBuffer(AudioFrame.headerSize + chunk.payload.count, playAtUs: chunk.timestampUs,
                             durationUs: Int64(chunk.frames) * 1_000_000 / Int64(sampleRate))
            else { continue }
            // send_ahead is taken as late as possible: right before encrypting.
            let frame = AudioFrame.pack(timestampUs: chunk.timestampUs,
                                        sendAheadUs: chunk.timestampUs - ServerClock.nowMicros(), payload: chunk.payload)
            send(frame[frame.startIndex], Data(frame.dropFirst()))
        }
    }

    /// The player's buffer_capacity is a hard limit: a chunk is only sent if it fits next
    /// to the chunks whose playback hasn't ended yet. Format choice keeps this rare.
    func fitsBuffer(_ bytes: Int, playAtUs: Int64, durationUs: Int64) -> Bool {
        let capacity = hello?.playerSupport?.bufferCapacity ?? .max
        guard buffer.admit(bytes: bytes, endUs: playAtUs + durationUs, nowUs: ServerClock.nowMicros(),
                           outputDelayUs: outputDelayUs, capacity: capacity)
        else {
            capacityDrops += 1
            if capacityDrops == 1 || capacityDrops.isMultiple(of: 50) {
                Log.warning("\(status.name ?? "?"): buffer_capacity \(capacity) bytes full, dropped \(capacityDrops) chunks")
            }
            return false
        }
        return true
    }

    /// Choose the stream format for this source and (re)start the stream in it.
    func startPipeline(for pcm: PCMBuffer, timestampUs: Int64, preferredBitDepth: Int) -> Bool {
        // How far ahead audio goes, so the format fits the player's buffer_capacity.
        let bufferMs = Int(max(0, timestampUs - ServerClock.nowMicros() - outputDelayUs) / 1_000)
        guard let format = FormatChoice.best(from: status.supportedFormats, sourceRate: pcm.sampleRate,
                                             sourceChannels: pcm.channels, preferredBitDepth: preferredBitDepth,
                                             bufferCapacity: hello?.playerSupport?.bufferCapacity, bufferMs: bufferMs)
        else {
            if !unsupportedSourceWarned {
                unsupportedSourceWarned = true
                Log.error("\(status.name ?? "?"): no usable PCM or FLAC format for \(pcm.sampleRate) Hz audio")
            }
            return false
        }
        // The stream goes on: what the old pipeline still holds goes out first, in its own format,
        // and the new one starts where it ended (player/v1.md, stream/start).
        var continuingAt: Int64?
        if streaming, var old = self.pipeline {
            sendChunks(old.flush(), sampleRate: old.format.sampleRate)
            continuingAt = old.endUs
        }
        guard let pipeline = PlayerAudioPipeline(format: format, sourceRate: pcm.sampleRate,
                                                 sourceChannels: pcm.channels, continuingAt: continuingAt)
        else {
            if !unsupportedSourceWarned {
                unsupportedSourceWarned = true
                Log.error("\(status.name ?? "?"): no usable PCM or FLAC format for \(pcm.sampleRate) Hz audio")
            }
            return false
        }
        unsupportedSourceWarned = false
        // Against the stream's format, not the pipeline's: a clear drops the pipeline alone.
        let changed = format != status.streamFormat
        self.pipeline = pipeline
        pipelineBitDepthPreference = preferredBitDepth
        if !streaming || changed {
            // stream/start again on a format change: the player reconfigures its decoder.
            sendMessage("stream/start", StreamStart(
                serverTransmitted: ServerClock.nowMicros(),
                player: StreamStartPlayer(codec: format.codec, sampleRate: format.sampleRate,
                                          channels: format.channels, bitDepth: format.bitDepth,
                                          // Standard base64 with padding (player/v1.md).
                                          codecHeader: pipeline.codecHeader?.base64EncodedString())))
            streaming = true
            status.streamFormat = format
            let conversion = format.sampleRate == pcm.sampleRate ? "" : " (resampled from \(pcm.sampleRate) Hz)"
            Log.info("\(status.name ?? "?"): streaming \(format.codec) \(format.sampleRate) Hz "
                + "\(format.bitDepth)-bit \(format.channels) ch\(conversion)")
        }
        return true
    }

    /// The block's visualizer frames, in a stream started once the client said what it wants.
    func visualize(_ pcm: PCMBuffer, timestampUs: Int64) {
        guard let request = visualizerRequest, let socket else { return }
        if visualizer == nil {
            startVisualizer(request.negotiated(), sampleRate: pcm.sampleRate, channels: pcm.channels, after: nil)
        } else if let current = visualizer, current.sampleRate != pcm.sampleRate || current.channels != pcm.channels {
            // The source changed: the same stream, analysed afresh.
            visualizer = VisualizerAnalyzer(config: current.config, sampleRate: pcm.sampleRate,
                                            channels: pcm.channels, after: current.lastUs)
        }
        guard socket.backlog <= 100, let frames = visualizer?.process(pcm, timestampUs: timestampUs) else { return }
        let capacity = hello?.visualizerSupport?.bufferCapacity ?? .max
        for frame in frames {
            guard visualizerBuffer.admit(bytes: frame.message.count, timestampUs: frame.timestampUs,
                                         nowUs: ServerClock.nowMicros(), capacity: capacity)
            else {
                visualizerDrops += 1
                if visualizerDrops == 1 || visualizerDrops.isMultiple(of: 100) {
                    Log.warning("\(status.name ?? "?"): visualizer buffer_capacity \(capacity) bytes full, "
                        + "dropped \(visualizerDrops) frames")
                }
                continue
            }
            send(frame.message[frame.message.startIndex], Data(frame.message.dropFirst()))
        }
    }

    /// stream/start for the visualizer, new or with a new configuration.
    func startVisualizer(_ config: VisualizerConfig, sampleRate: Int, channels: Int, after lastUs: Int64?) {
        sendMessage("stream/start", StreamStart(serverTransmitted: ServerClock.nowMicros(), visualizer: config))
        visualizer = VisualizerAnalyzer(config: config, sampleRate: sampleRate, channels: channels, after: lastUs)
        Log.info("\(status.name ?? "?"): visualizing \(config.types.isEmpty ? "nothing" : config.types.joined(separator: ", ")) "
            + "at \(config.rateMax) fps")
    }

    /// stream/start for artwork, new or with new channels. There are no images, so a channel's
    /// current image is an empty one: a channel turned off is cleared before the stream/start,
    /// as the spec asks, and a new or changed channel right after it, as its current image
    /// (Late join), so nothing shows there that an earlier stream left.
    func startArtwork(_ config: ArtworkConfig) {
        let old = artworkStream?.channels ?? []
        for (index, channel) in old.enumerated() where channel.source != "none"
            && (index >= config.channels.count || config.channels[index].source == "none") {
            sendEmptyImage(channel: index)
        }
        sendMessage("stream/start", StreamStart(serverTransmitted: ServerClock.nowMicros(), artwork: config))
        artworkStream = config
        for (index, channel) in config.channels.enumerated() where channel.source != "none"
            && (index >= old.count || old[index] != channel) {
            sendEmptyImage(channel: index)
        }
    }

    /// An announce of total_size 0 with a present timestamp: the channel shows nothing.
    func sendEmptyImage(channel: Int) {
        var image = Data([0x02])
        withUnsafeBytes(of: ServerClock.nowMicros().bigEndian) { image.append(contentsOf: $0) }
        image.append(contentsOf: [0, 0, 0, 0])
        send(UInt8(8 + channel), image)
    }
}
