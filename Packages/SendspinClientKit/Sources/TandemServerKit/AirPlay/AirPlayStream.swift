import CryptoKit
import Foundation
import Network
import SendspinClientKit

/// The group's audio on one AirPlay speaker. Blocks arrive with the time to play them on the
/// server's clock; the speaker takes its time from us, so it plays them then, in step with
/// the Sendspin players.
actor AirPlayStream {
    enum Status: Sendable, Equatable {
        case idle
        case connecting
        case playing
        case failed(String)
    }

    enum Event: Sendable {
        case audio(PCMBuffer, playUs: Int64)
        /// The group stopped, or jumps elsewhere: drop what the speaker holds.
        case stop
        /// What plays changed.
        case details(title: String?, artist: String?, album: String?)
    }

    /// What plays, as the speaker was last to be told.
    private var details: (title: String?, artist: String?, album: String?) = (nil, nil, nil)
    /// The list last sent over this connection, not to send it twice.
    private var sentDetails: Data?

    /// How long a speaker is left alone after it failed, before the next try.
    private static let retryUs: Int64 = 10_000_000
    /// How long after the music stopped the speaker is let go, for others to use.
    private static let idleRelease: Duration = .seconds(8)
    /// A block this far off its place on the timeline moves the timeline.
    private static let toleranceUs: Int64 = 30_000

    struct Link {
        var rtsp: RTSPClient
        var uri: String
        var audio: UDPSocket
        var control: UDPSocket
        var timing: UDPSocket
        var audioAddress: sockaddr_in
        var controlAddress: sockaddr_in
        /// The share of the latency the speaker takes, in frames.
        var receiverLatency: Int
        /// AirPlay 2 only: the key each audio packet is sealed with, the number the stream goes
        /// by, and the connection the speaker reports on, held open for as long as we play.
        var audioKey: SymmetricKey?
        var streamID: UInt32 = 0
        var events: NWConnection?
        /// The network clock the speaker follows, and the speaker's address on it.
        var clock: PTPClock?
        var remote = ""
    }

    let speaker: AirPlaySpeaker
    private let onStatus: @Sendable (Status) -> Void
    let queue = DispatchQueue(label: "tandem.airplay.stream")
    let history = PacketHistory()
    let source = UInt32.random(in: .min ... .max)
    private var volume: Int
    private var muted: Bool
    private var status = Status.idle
    var link: Link?
    private var retryAfter: Int64 = 0

    private var resampler: (converter: Resampler, rate: Int, channels: Int)?
    /// Stereo samples that don't fill a packet yet.
    private var pending: [Int16] = []
    var sequence = UInt16.random(in: .min ... .max)
    /// The frame the next packet starts with. Its low 32 bits are the RTP timestamp.
    var nextFrame = Int64(UInt32.random(in: .min ... .max))
    /// A frame and the time it plays: the timeline since the stream started or was flushed.
    var anchor: (frame: Int64, playUs: Int64)?
    var firstPacket = true
    private var syncing: Task<Void, Never>?
    /// Compresses AirPlay 2's packets; the first AirPlay's go out uncompressed.
    private let encoder = ALACEncoder()
    /// AirPlay 2 packets made but not due to go out yet, the earliest first.
    private var outbox: [(sendUs: Int64, packet: Data)] = []
    private var pacing: Task<Void, Never>?
    /// How long before it plays an AirPlay 2 packet is sent. A speaker has room for two
    /// seconds and drops what comes earlier, so it gets each packet a little inside that.
    private static let sendAheadUs: Int64 = 1_750_000
    private var releasing: Task<Void, Never>?

    init(speaker: AirPlaySpeaker, volume: Int, muted: Bool, onStatus: @escaping @Sendable (Status) -> Void) {
        self.speaker = speaker
        self.volume = volume
        self.muted = muted
        self.onStatus = onStatus
    }

    func handle(_ event: Event) async {
        switch event {
        case .audio(let pcm, let playUs): await play(pcm, at: playUs)
        case .stop: await flush()
        case .details(let title, let artist, let album):
            details = (title, artist, album)
            if let link { try? await sendDetails(over: link) }
        }
    }

    func setVolume(_ volume: Int, muted: Bool) async {
        self.volume = volume
        self.muted = muted
        guard let link else { return }
        try? await sendVolume(over: link)
    }

    /// Let the speaker go.
    func close() async {
        releasing?.cancel()
        await disconnect()
        set(.idle)
    }

    // MARK: Audio

    private func play(_ pcm: PCMBuffer, at playUs: Int64) async {
        releasing?.cancel()
        releasing = nil
        if link == nil {
            guard ServerClock.nowMicros() >= retryAfter else { return }
            set(.connecting)
            do {
                try await connect()
            } catch {
                fail(error)
                return
            }
        }
        guard let link else { return }
        let samples = convert(pcm)
        guard !samples.isEmpty else { return }

        // Where this block belongs on the timeline, against where the last one ended.
        let head = nextFrame + Int64(pending.count / 2)
        if let anchor {
            let expectedUs = anchor.playUs + (head - anchor.frame) * 1_000_000 / Int64(RAOP.sampleRate)
            let late = playUs - expectedUs
            if late > Self.toleranceUs {
                // A gap in the audio: the timestamps skip it, and the speaker plays silence.
                send(pending: true, over: link)
                nextFrame += late * Int64(RAOP.sampleRate) / 1_000_000
            } else if late < -Self.toleranceUs {
                // The timeline went back without a stop: start it anew.
                await flush()
                releasing?.cancel()
                releasing = nil
                guard self.link != nil else { return }
                self.anchor = (nextFrame, playUs)
            }
        } else {
            anchor = (head, playUs)
        }
        if syncing == nil { startSync(over: link) }
        pending += samples
        send(pending: false, over: link)
        set(.playing)
    }

    /// The block as 44.1 kHz 16-bit stereo, which is all this form of AirPlay carries.
    private func convert(_ pcm: PCMBuffer) -> [Int16] {
        var samples = pcm.samples
        if pcm.sampleRate != RAOP.sampleRate {
            if resampler?.rate != pcm.sampleRate || resampler?.channels != pcm.channels {
                resampler = Resampler(from: pcm.sampleRate, to: RAOP.sampleRate, channels: pcm.channels)
                    .map { ($0, pcm.sampleRate, pcm.channels) }
            }
            guard let resampler else { return [] }
            samples = resampler.converter.process(samples)
        } else {
            resampler = nil
        }
        return RAOP.stereo16(samples, channels: pcm.channels)
    }

    /// Send every full packet that's pending; with `pad`, the rest too, filled up with silence.
    private func send(pending pad: Bool, over link: Link) {
        let size = RAOP.framesPerPacket * 2
        if pad, !pending.count.isMultiple(of: size) {
            pending += [Int16](repeating: 0, count: size - pending.count % size)
        }
        var offset = 0
        while pending.count - offset >= size {
            let block = pending[offset..<offset + size]
            let payload = (link.audioKey != nil ? encoder?.encode(block) : nil) ?? RAOP.alacFrame(block)
            let timestamp = UInt32(truncatingIfNeeded: nextFrame)
            let packet: Data
            if let key = link.audioKey {
                guard let sealed = try? RAOP.sealedAudioPacket(sequence: sequence, timestamp: timestamp, source: link.streamID,
                                                                first: firstPacket, payload: payload, key: key) else { break }
                packet = sealed
            } else {
                packet = RAOP.audioPacket(sequence: sequence, timestamp: timestamp, source: source,
                                          first: firstPacket, payload: payload)
            }
            if link.audioKey != nil, let anchor {
                let playUs = anchor.playUs + (nextFrame - anchor.frame) * 1_000_000 / Int64(RAOP.sampleRate)
                outbox.append((playUs - Self.sendAheadUs, packet))
            } else {
                link.audio.send(packet, to: link.audioAddress)
            }
            history.store(packet, sequence: sequence)
            sequence &+= 1
            nextFrame += Int64(RAOP.framesPerPacket)
            firstPacket = false
            offset += size
        }
        pending.removeFirst(offset)
        release(over: link)
    }

    /// Send the packets that are due, and come back for the rest.
    private func release(over link: Link) {
        let now = ServerClock.nowMicros()
        var sent = 0
        while sent < outbox.count, outbox[sent].sendUs <= now {
            link.audio.send(outbox[sent].packet, to: link.audioAddress)
            sent += 1
        }
        outbox.removeFirst(sent)
        guard !outbox.isEmpty, pacing == nil else { return }
        pacing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(15))
            await self?.paced()
        }
    }

    private func paced() {
        pacing = nil
        if let link { release(over: link) } else { outbox = [] }
    }

    /// Tell the speaker, now and every second, which frame goes with which time.
    private func startSync(over link: Link) {
        syncing = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                await self?.sendSync(first: count == 0, over: link)
                count += 1
                // A speaker that something else took over closes the control connection
                // without a word; asking it now and then is how we find out.
                if count.isMultiple(of: 10) { await self?.checkAlive(link) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func sendSync(first: Bool, over link: Link) {
        guard let anchor else { return }
        let now = ServerClock.nowMicros()
        // The frame that plays one latency from now is the one a sender would hand over now.
        let aheadUs = Int64(RAOP.latencyFrames) * 1_000_000 / Int64(RAOP.sampleRate)
        let frame = anchor.frame + (now + aheadUs - anchor.playUs) * Int64(RAOP.sampleRate) / 1_000_000
        var packet = RAOP.syncPacket(first: first, timestamp: UInt32(truncatingIfNeeded: frame),
                                     receiverLatency: link.receiverLatency, nowMicros: RAOP.clockMicros(now))
        if link.clock != nil {
            let heard = anchor.frame + (now - anchor.playUs) * Int64(RAOP.sampleRate) / 1_000_000
            packet = RAOP.clockSyncPacket(first: first, heard: UInt32(truncatingIfNeeded: heard),
                                          clockNanos: PTPClock.nowNanos(now), clock: PTPClock.identity)
        }
        link.control.send(packet, to: link.controlAddress)
    }

    private func checkAlive(_ link: Link) async {
        do {
            // AirPlay 2 has a request of its own for this.
            if link.audioKey != nil {
                _ = try await link.rtsp.send("POST", "/feedback", lenient: true)
            } else {
                _ = try await link.rtsp.send("OPTIONS", "*", lenient: true)
            }
        } catch {
            if self.link?.uri == link.uri { fail(error) }
        }
    }

    /// Drop what the speaker has buffered; the stream goes on with the next block.
    private func flush() async {
        syncing?.cancel()
        syncing = nil
        pending = []
        outbox = []
        resampler?.converter.reset()
        history.clear()
        guard let link, anchor != nil else { return }
        anchor = nil
        firstPacket = true
        // Past anything sent before, so the speaker can't take old packets for new ones.
        nextFrame += Int64(RAOP.sampleRate)
        do {
            _ = try await link.rtsp.send("FLUSH", link.uri, headers: [
                ("RTP-Info", "seq=\(sequence);rtptime=\(UInt32(truncatingIfNeeded: nextFrame))"),
            ])
        } catch {
            fail(error)
            return
        }
        set(.idle)
        releasing = Task { [weak self] in
            try? await Task.sleep(for: Self.idleRelease)
            guard !Task.isCancelled else { return }
            await self?.close()
        }
    }

    // MARK: The connection

    private func connect() async throws {
        if speaker.usesAirPlay2 {
            do {
                try await connectAirPlay2()
                return
            } catch let error as PTPClock.Failure {
                // Another program has the clock's ports. The first AirPlay needs no clock,
                // and many speakers still play over it.
                Log.warning("\(speaker.name): AirPlay 2 \(error); trying the first AirPlay")
            }
        }
        let instance = (0..<8).map { _ in String(format: "%02X", UInt8.random(in: .min ... .max)) }.joined()
        let rtsp = RTSPClient(endpoint: speaker.endpoint, headers: [
            ("User-Agent", "iTunes/7.6.2 (Windows; N;)"), ("Client-Instance", instance), ("DACP-ID", instance),
            ("Active-Remote", "\(UInt32.random(in: .min ... .max))"),
        ])
        let history = history
        var sockets: [UDPSocket] = []
        do {
            let (local, remote) = try await rtsp.open()
            let uri = "rtsp://\(local)/\(UInt32.random(in: .min ... .max))"
            _ = try await rtsp.send("OPTIONS", "*", lenient: true)
            if speaker.wantsAuthSetup {
                // A step these speakers expect before audio: a key exchange we don't go on to use.
                let key = Data([0x01] + (0..<32).map { _ in UInt8.random(in: .min ... .max) })
                _ = try await rtsp.send("POST", "/auth-setup", body: key, contentType: "application/octet-stream", lenient: true)
            }
            let description = [
                "v=0", "o=iTunes \(UInt32.random(in: .min ... .max)) 0 IN IP4 \(local)", "s=iTunes", "c=IN IP4 \(remote)",
                "t=0 0", "m=audio 0 RTP/AVP 96", "a=rtpmap:96 AppleLossless",
                "a=fmtp:96 \(RAOP.framesPerPacket) 0 16 40 10 14 2 255 0 0 \(RAOP.sampleRate)",
            ].joined(separator: "\r\n") + "\r\n"
            _ = try await rtsp.send("ANNOUNCE", uri, body: Data(description.utf8), contentType: "application/sdp")

            // The speaker asks this port for the time, which is ours to give.
            let clock = try TimingResponder(queue: queue, localAddress: local)
            sockets.append(clock.socket)
            let control = try ResendResponder(queue: queue, localAddress: local, history: history)
            sockets.append(control.socket)
            let audio = try UDPSocket(queue: queue, localAddress: local) { _, _ in }
            sockets.append(audio)

            let setup = try await rtsp.send("SETUP", uri, headers: [
                ("Transport", "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=\(control.socket.port);"
                    + "timing_port=\(clock.socket.port)"),
            ])
            let transport = Self.parameters(setup.headers["transport"] ?? "")
            Log.debug("\(speaker.name): AirPlay transport \(setup.headers["transport"] ?? "none"); ours control "
                + "\(control.socket.port), timing \(clock.socket.port)")
            guard let audioPort = transport["server_port"].flatMap(UInt16.init),
                  let audioAddress = UDPSocket.address(remote, port: audioPort),
                  let controlAddress = UDPSocket.address(remote, port: transport["control_port"].flatMap(UInt16.init) ?? audioPort + 1)
            else { throw RTSPClient.Failure.malformed }
            await rtsp.setSession(setup.headers["session"]?.split(separator: ";").first.map(String.init))

            let record = try await rtsp.send("RECORD", uri, headers: [
                ("Range", "npt=0-"), ("RTP-Info", "seq=\(sequence);rtptime=\(UInt32(truncatingIfNeeded: nextFrame))"),
            ])
            let latency = record.headers["audio-latency"].flatMap(Int.init) ?? RAOP.receiverLatencyFrames
            let link = Link(rtsp: rtsp, uri: uri, audio: audio, control: control.socket, timing: clock.socket,
                            audioAddress: audioAddress, controlAddress: controlAddress,
                            receiverLatency: min(max(0, latency), RAOP.latencyFrames))
            try await begin(link)
            Log.info("\(speaker.name): AirPlay connected from \(local) (its latency \(latency) frames)")
        } catch {
            sockets.forEach { $0.close() }
            rtsp.close()
            throw error
        }
    }

    /// "a=1;b=2" as a dictionary.
    static func parameters(_ header: String) -> [String: String] {
        var values: [String: String] = [:]
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { values[pair[0].lowercased()] = pair[1] }
        }
        return values
    }

    /// The last steps of connecting, the same for both forms of AirPlay.
    func begin(_ link: Link) async throws {
        try await sendVolume(over: link)
        sentDetails = nil
        try await sendDetails(over: link)
        self.link = link
        anchor = nil
        firstPacket = true
    }

    private func sendVolume(over link: Link) async throws {
        let text = String(format: "volume: %.6f\r\n", RAOP.decibels(volume: volume, muted: muted))
        _ = try await link.rtsp.send("SET_PARAMETER", link.uri, body: Data(text.utf8), contentType: "text/parameters")
    }

    /// Tell the speaker what plays. Without a title yet it gets the app's name: a Sonos
    /// speaker takes the audio and stays silent until it has been told something.
    private func sendDetails(over link: Link) async throws {
        let title = details.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Tandem"
        let list = RAOP.trackDetails(title: title, artist: details.artist, album: details.album)
        guard list != sentDetails else { return }
        sentDetails = list
        _ = try await link.rtsp.send("SET_PARAMETER", link.uri,
                                     headers: [("RTP-Info", "rtptime=\(UInt32(truncatingIfNeeded: nextFrame))")],
                                     body: list, contentType: "application/x-dmap-tagged", lenient: true)
    }

    private func disconnect() async {
        syncing?.cancel()
        syncing = nil
        guard let link else { return }
        self.link = nil
        anchor = nil
        pending = []
        outbox = []
        _ = try? await link.rtsp.send("TEARDOWN", link.uri, lenient: true)
        link.rtsp.close()
        link.events?.cancel()
        link.clock?.remove(peer: link.remote)
        [link.audio, link.control, link.timing].forEach { $0.close() }
    }

    private func fail(_ error: any Error) {
        Log.warning("\(speaker.name): AirPlay \(error)")
        retryAfter = ServerClock.nowMicros() + Self.retryUs
        if let link {
            self.link = nil
            link.rtsp.close()
            link.events?.cancel()
            link.clock?.remove(peer: link.remote)
            [link.audio, link.control, link.timing].forEach { $0.close() }
        }
        syncing?.cancel()
        syncing = nil
        anchor = nil
        pending = []
        set(.failed("\(error)"))
    }

    private func set(_ status: Status) {
        guard status != self.status else { return }
        self.status = status
        onStatus(status)
    }
}
