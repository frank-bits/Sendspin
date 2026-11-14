import Foundation

// The player role's messages (roles/player/v1.md, messaging.md).

struct StreamStartReceived: Decodable {
    struct Player: Decodable {
        var codec: String
        var sampleRate: Int
        var channels: Int
        var bitDepth: Int
        /// Standard Base64, padding included; required for FLAC.
        var codecHeader: String?

        enum CodingKeys: String, CodingKey {
            case codec, channels
            case sampleRate = "sample_rate"
            case bitDepth = "bit_depth"
            case codecHeader = "codec_header"
        }
    }

    var player: Player?
}

struct StreamClearReceived: Decodable {
    var fromTimestamp: Int64?
    var roles: [String]?

    enum CodingKeys: String, CodingKey {
        case roles
        case fromTimestamp = "from_timestamp"
    }
}

struct StreamEndReceived: Decodable {
    var roles: [String]?
}

struct PlayerCommandReceived: Decodable {
    struct Player: Decodable {
        var command: String
        var volume: Int?
        var mute: Bool?
    }

    var player: Player?
}

/// A binary audio chunk without its message ID (roles/player/v1.md, Audio Chunks).
struct AudioChunk {
    static let messageType: UInt8 = 4

    /// Server clock time in µs when the first sample should be output.
    var timestampUs: Int64
    /// µs from the server's transmission to `timestampUs`; 0 and the maximum mean "not measured".
    var sendAheadUs: UInt32
    var audio: Data

    /// Nil for a chunk shorter than its header: a protocol error.
    init?(_ body: Data) {
        guard body.count >= 12 else { return nil }
        let bytes = [UInt8](body.prefix(12))
        timestampUs = Int64(bitPattern: bytes[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        sendAheadUs = bytes[8..<12].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        audio = body.dropFirst(12)
    }
}

/// The player role: decodes the server's audio stream and plays it in sync on this device's
/// output, and applies the server's volume and mute commands. Feed it every event of its
/// session, in order.
public actor PlayerEngine {
    private let session: ClientSession
    private var output: AudioOutput?
    private var decoder: SourceDecoder?
    private var playerActive = false
    private var playbackAllowed = false
    private var volume: Int
    private var muted: Bool
    private var chunks = 0
    private var undecodable = 0
    /// Chunks not yet due, in arrival order, each with the decoder of the format it came in.
    /// Servers send buffered audio many seconds ahead; the playout buffer holds only a few.
    private var pending: [(chunk: AudioChunk, decoder: SourceDecoder)] = []
    private var feeder: Task<Void, Never>?
    private var feeding = false
    /// Counts clears and stream ends, so a feed in progress can tell its audio was dropped.
    private var clearGeneration = 0
    /// For the log: the next chunk is the first since the stream started or was cleared.
    private var awaitingFirstChunk = false

    /// How far ahead of its due time audio is decoded into the playout buffer.
    static let feedAheadUs: Int64 = 1_500_000

    /// The formats to offer in client/hello: FLAC then PCM, at the output's own rate first so
    /// the server resamples rather than this device, then the other common rate.
    public static func support(outputRate: Int = OutputDevice.sampleRate()) -> PlayerSupport {
        let rates = [48_000, 44_100].sorted { first, _ in first == outputRate }
        let formats = rates.flatMap { rate in
            [AudioFormatSpec(codec: .flac, channels: 2, sampleRate: rate, bitDepth: 16),
             AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: rate, bitDepth: 16)]
        }
        // About 10 s of 16-bit stereo PCM at 48 kHz.
        return PlayerSupport(supportedFormats: formats, bufferCapacity: 2_000_000)
    }

    /// The player object of client/state for these settings. The lead time covers starting the
    /// output and decoder; the buffer absorbs Wi-Fi jitter.
    public static func state(volume: Int, muted: Bool) -> PlayerState {
        PlayerState(volume: volume, muted: muted, outputDelayMs: 0, requiredLeadTimeMs: 500, minBufferMs: 250,
                    supportedCommands: ["volume", "mute"])
    }

    public init(session: ClientSession, volume: Int = 100, muted: Bool = false) {
        self.session = session
        self.volume = volume
        self.muted = muted
    }

    public func handle(_ event: SessionEvent) async {
        switch event {
        case let .activated(activities, activeRoles, _):
            playerActive = activeRoles.contains("player@v1")
            playbackAllowed = activities.contains("playback")
            // A removed role stops its output and clears its buffers (messaging.md, server/activate).
            if !playerActive { endStream() }
        case let .message(type, json):
            await handle(type: type, json: json)
        case let .binary(type, payload, _) where type == AudioChunk.messageType:
            await play(payload)
        case .closed:
            endStream()
        default:
            break
        }
    }

    private func handle(type: String, json: Data) async {
        guard playerActive else { return }
        switch type {
        case "stream/start":
            guard playbackAllowed, let player = (try? MessageCoding.payload(StreamStartReceived.self, from: json))?.player
            else { return }
            startStream(player)
        case "stream/clear":
            guard let clear = try? MessageCoding.payload(StreamClearReceived.self, from: json),
                  clear.roles?.contains("player") ?? true else { return }
            clearGeneration += 1
            Log.debug("stream/clear from \(clear.fromTimestamp.map(String.init) ?? "now"), \(pending.count) chunks waiting")
            awaitingFirstChunk = true
            if let from = clear.fromTimestamp {
                pending.removeAll { $0.chunk.timestampUs >= from }
                output?.truncate(fromUs: await session.localTime(fromServer: from))
            } else {
                pending.removeAll()
                output?.clear()
            }
        case "stream/end":
            guard let end = try? MessageCoding.payload(StreamEndReceived.self, from: json),
                  end.roles?.contains("player") ?? true else { return }
            Log.debug("stream/end, \(pending.count) chunks waiting")
            endStream()
        case "server/command":
            guard let command = (try? MessageCoding.payload(PlayerCommandReceived.self, from: json))?.player else { return }
            await apply(command)
        default:
            break
        }
    }

    /// stream/start: a new stream, or a new format for the running one. Audio already queued
    /// stays; an output at another rate replaces the old one.
    private func startStream(_ player: StreamStartReceived.Player) {
        let header = player.codecHeader.flatMap { Data(base64Encoded: $0) }
        let format = SourceFormat(codec: player.codec, channels: player.channels, sampleRate: player.sampleRate,
                                  bitDepth: player.bitDepth, codecHeader: header)
        guard let decoder = SourceDecoder(format: format) else {
            Log.error("Can't decode \(player.codec) \(player.sampleRate) Hz \(player.bitDepth)-bit, \(player.channels) ch")
            self.decoder = nil
            return
        }
        self.decoder = decoder
        awaitingFirstChunk = true
        if output?.sampleRate != player.sampleRate {
            // Audio still waiting at the old rate can't play on the new output.
            pending.removeAll()
            output?.stop()
            let output = AudioOutput(sampleRate: player.sampleRate)
            output.setVolume(volume, muted: muted)
            self.output = output
        }
        if feeder == nil {
            feeder = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    await self?.feed()
                }
            }
        }
        Log.info("Stream: \(player.codec) \(player.sampleRate) Hz \(player.bitDepth)-bit, \(player.channels) ch")
    }

    /// The system's output changed (another device, or an interruption ended): play on the new
    /// one. What was already decoded for the old output is lost, about a second of audio.
    public func outputChanged() {
        guard let old = output else { return }
        old.stop()
        let new = AudioOutput(sampleRate: old.sampleRate)
        new.setVolume(volume, muted: muted)
        output = new
    }

    private func endStream() {
        feeder?.cancel()
        feeder = nil
        clearGeneration += 1
        pending.removeAll()
        output?.stop()
        decoder = nil
    }

    /// Decode into the playout buffer the chunks due within `feedAheadUs`, in order.
    private func feed() async {
        // One feed at a time: the session calls below suspend, and chunks must stay in order.
        guard let output, !pending.isEmpty, !feeding else { return }
        feeding = true
        defer { feeding = false }
        let horizonUs = await session.serverTime(fromLocal: ServerClock.nowMicros()) + Self.feedAheadUs
        let due = pending.prefix { $0.chunk.timestampUs <= horizonUs }
        pending.removeFirst(due.count)
        let generation = clearGeneration
        for (chunk, decoder) in due {
            guard let samples = decoder.decode(chunk.audio) else {
                undecodable += 1
                if undecodable == 1 || undecodable.isMultiple(of: 100) { Log.warning("\(undecodable) audio chunks didn't decode") }
                continue
            }
            let localUs = await session.localTime(fromServer: chunk.timestampUs)
            // A clear or the stream's end came in meanwhile: this audio is no longer wanted.
            guard generation == clearGeneration else { return }
            output.write(Self.stereo(samples, channels: decoder.format.channels), timestampUs: localUs)
            chunks += 1
            if chunks.isMultiple(of: 500) {
                let (errorUs, counters) = output.statistics
                Log.debug(String(format: "%+.0f µs off", errorUs) + ", \(counters.droppedFrames) frames dropped and "
                    + "\(counters.repeatedFrames) repeated, \(counters.snaps) resyncs, \(counters.underruns) underruns, "
                    + "\(counters.overflows) overflows, \(pending.count) chunks waiting")
            }
        }
    }

    private func play(_ body: Data) async {
        guard playerActive, playbackAllowed else { return }
        guard let chunk = AudioChunk(body) else {
            // Shorter than its header: the client MUST close (roles/player/v1.md).
            Log.error("Audio chunk shorter than its header; closing")
            await session.close(goodbye: "restart")
            return
        }
        // Each chunk decodes in the format in effect when it was received (roles/player/v1.md).
        guard let decoder else { return }
        if awaitingFirstChunk {
            awaitingFirstChunk = false
            let leadUs = chunk.timestampUs - (await session.serverTime(fromLocal: ServerClock.nowMicros()))
            Log.debug("First chunk after a start or clear: due in \(leadUs / 1000) ms")
        }
        pending.append((chunk, decoder))
        await feed()
    }

    /// server/command: only the commands the player state offers, with values in range.
    private func apply(_ command: PlayerCommandReceived.Player) async {
        switch (command.command, command.volume, command.mute) {
        case let ("volume", value?, _) where (0...100).contains(value): volume = value
        case let ("mute", _, value?): muted = value
        default: return
        }
        output?.setVolume(volume, muted: muted)
        // Every change to the player state is reported (roles/player/v1.md).
        await session.setStatus(ClientStatus(available: true, player: Self.state(volume: volume, muted: muted)))
    }

    static func stereo(_ samples: [Float], channels: Int) -> [Float] {
        switch channels {
        case 2: return samples
        case 1: return samples.flatMap { [$0, $0] }
        default:
            let frames = samples.count / channels
            return (0..<frames).flatMap { [samples[$0 * channels], samples[$0 * channels + 1]] }
        }
    }
}
