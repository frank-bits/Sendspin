import Foundation
import SendspinClientKit

/// Plays a queue of music files on a group of players.
///
/// Files are decoded a little ahead of the clock and pushed to the group, which stamps each
/// block with the time to play it: its place on a timeline, plus the group's lead. A track
/// follows the last without a gap, on the same timeline. A seek, a jump to another track or a
/// resume starts a new timeline, after telling the players to drop what they hold.
public actor PlaybackEngine {
    public enum State: String, Sendable {
        case stopped, playing, paused
    }

    /// What the queue is doing, for the server's API.
    public struct Snapshot: Sendable {
        public var state: State
        public var shuffle: Bool
        /// "off", "one" or "all".
        public var repeatMode: String
        public var current: LibraryTrack?
        /// Seconds into `current` at `elapsedAt`.
        public var elapsed: Double
        public var elapsedAt: Date
        public var queue: [LibraryTrack]
    }

    /// A track on the timeline: heard from `playUs` on the server clock, `offset` seconds in.
    struct Heard {
        var cursor: Int
        var track: LibraryTrack
        var playUs: Int64
        var offset: Double
    }

    /// The least lead: enough for a player on Wi-Fi to buffer, short enough that a tap is
    /// answered quickly.
    static let minimumLeadMs = 500
    /// How far ahead of the clock files are decoded and sent on.
    static let aheadUs: Int64 = 200_000

    let group: PlaybackGroup
    /// Where players can fetch a track's picture; set by the server once it knows its address.
    var artworkURL: (@Sendable (LibraryTrack) -> String?)?
    /// Called when a track starts to be heard.
    var onTrackStarted: (@Sendable (LibraryTrack) -> Void)?
    /// Called as playback starts, before any sound: the group gathers its speakers.
    var willStart: (@Sendable () async -> Void)?
    /// How long a group nobody hears keeps playing: a player that dropped off may be back.
    static let unheardLimitUs: Int64 = 30_000_000

    // The queue, in play order (PlaybackEngine+Queue.swift).
    var queue: [LibraryTrack] = []
    /// The order before shuffling, while shuffle is on.
    var unshuffled: [LibraryTrack]?
    /// The queue's track being decoded, or to start from.
    var cursor = 0
    var shuffle = false
    var repeatMode = "off"
    var state = State.stopped

    // Decoding.
    private var source: AudioFileSource?
    /// Seconds into the cursor's track decoding starts at.
    private var startOffset = 0.0
    /// The next block is the first of its track on this timeline.
    private var announce = false
    private var unreadable = 0

    // The timeline.
    /// Counts starts and stops, so a pump that was overtaken while it waited gives up.
    private var generation = 0
    private var pump: Task<Void, Never>?
    private var leadUs: Int64 = 0
    /// A run of blocks at one sample rate: where it starts and how many frames went out.
    private var segment: (startUs: Int64, sampleRate: Int, frames: Int64)?
    private var nextCaptureUs: Int64?
    /// What's heard now, and the tracks already sent that follow it.
    private var heard: Heard?
    private var upcoming: [Heard] = []

    public init(group: PlaybackGroup) {
        self.group = group
    }

    /// Take the group's transport commands, and say where artwork is served.
    public func attach(artworkURL: (@Sendable (LibraryTrack) -> String?)? = nil,
                       onTrackStarted: (@Sendable (LibraryTrack) -> Void)? = nil,
                       willStart: (@Sendable () async -> Void)? = nil) async {
        self.artworkURL = artworkURL
        self.onTrackStarted = onTrackStarted
        self.willStart = willStart
        await group.setMedia(controls()) { [weak self] command in await self?.handle(command) }
    }

    public func snapshot() -> Snapshot {
        Snapshot(state: state, shuffle: shuffle, repeatMode: repeatMode, current: currentTrack,
                 elapsed: position(), elapsedAt: Date(), queue: queue)
    }

    var currentTrack: LibraryTrack? {
        heard?.track ?? (queue.indices.contains(cursor) ? queue[cursor] : nil)
    }

    /// Seconds into the track that's heard.
    func position(at now: Int64 = ServerClock.nowMicros()) -> Double {
        guard let heard else { return 0 }
        guard state == .playing, heard.playUs <= now else { return heard.offset }
        let elapsed = heard.offset + Double(now - heard.playUs) / 1_000_000
        return heard.track.duration > 0 ? min(elapsed, heard.track.duration) : elapsed
    }

    // MARK: Transport

    public func play() async {
        switch state {
        case .playing: return
        case .paused: await start(at: heard?.offset ?? 0)
        case .stopped: await start(at: 0)
        }
    }

    public func pause() async {
        guard state == .playing else { return }
        await halt(.paused, at: position())
    }

    public func stop() async {
        guard state != .stopped else { return }
        await halt(.stopped, at: 0)
    }

    public func togglePlayPause() async {
        if state == .playing { await pause() } else { await play() }
    }

    public func next() async {
        guard !queue.isEmpty else { return }
        let following = (heard?.cursor ?? cursor) + 1
        if following < queue.count {
            cursor = following
        } else if repeatMode == "all" {
            cursor = 0
        } else {
            await stop()
            return
        }
        await start(at: 0)
    }

    /// Back to the start of the track, or to the track before when it has only just begun.
    public func previous() async {
        guard !queue.isEmpty else { return }
        let current = heard?.cursor ?? cursor
        cursor = position() > 3 ? current : max(0, current - 1)
        await start(at: 0)
    }

    /// Move to `seconds` into the track that's heard.
    public func seek(to seconds: Double) async {
        guard let heard else { return }
        let duration = heard.track.duration
        guard seconds >= 0, duration <= 0 || seconds <= duration else { return }
        cursor = min(heard.cursor, max(0, queue.count - 1))
        if state == .playing {
            await start(at: seconds)
        } else {
            self.heard?.offset = seconds
            await publish()
        }
    }

    public func seek(by seconds: Double) async {
        guard let heard else { return }
        let target = max(0, position() + seconds)
        await seek(to: heard.track.duration > 0 ? min(target, heard.track.duration) : target)
    }

    /// Start a new timeline with the cursor's track, `offset` seconds in. `gathering` calls in
    /// the group's speakers from wherever they play, as the user asking for music does.
    func start(at offset: Double, gathering: Bool = true) async {
        generation += 1
        let mine = generation
        pump?.cancel()
        guard queue.indices.contains(cursor) else {
            await halt(.stopped, at: 0)
            return
        }
        let wasPlaying = state == .playing
        state = .playing
        source = nil
        startOffset = offset
        unreadable = 0
        upcoming = []
        segment = nil
        nextCaptureUs = nil
        // Shown at once, though it's heard only once the lead has passed.
        heard = Heard(cursor: cursor, track: queue[cursor], playUs: .max, offset: offset)
        if gathering {
            await willStart?()
            guard mine == generation else { return }
        }
        if wasPlaying { await group.clear() }
        guard mine == generation else { return }
        await publish()
        guard mine == generation else { return }
        pump = Task { await self.run(mine) }
    }

    /// Stop sending: paused where it is, or stopped at the start of the track.
    private func halt(_ newState: State, at offset: Double) async {
        generation += 1
        pump?.cancel()
        if let heard, queue.indices.contains(heard.cursor) { cursor = heard.cursor }
        if var heard {
            heard.offset = offset
            heard.playUs = .max
            self.heard = queue.isEmpty ? nil : heard
        }
        state = newState
        source = nil
        startOffset = offset
        upcoming = []
        await group.setPlaying(false)
        await publish()
    }

    // MARK: The pump

    private func run(_ mine: Int) async {
        var lead = max(Self.minimumLeadMs, await group.requiredLeadMs())
        guard mine == generation else { return }
        await group.setLead(ms: lead)
        guard mine == generation else { return }
        leadUs = Int64(lead) * 1_000
        var checked = ServerClock.nowMicros()
        var heardAt = checked
        while mine == generation, !Task.isCancelled {
            let now = ServerClock.nowMicros()
            while mine == generation, (nextCaptureUs ?? 0) < now + Self.aheadUs {
                guard let (block, captureUs) = nextBlock(now: now) else {
                    await finish(mine)
                    return
                }
                await group.push(block, captureTimeUs: captureUs)
            }
            guard mine == generation else { return }
            await applyDue()
            // A player that joined may need more lead than the group has: start over with it.
            if now - checked > 2_000_000 {
                checked = now
                let needed = await group.requiredLeadMs()
                guard mine == generation else { return }
                if needed > lead {
                    lead = needed
                    Log.info("A player needs \(needed) ms of lead; restarting the stream with it")
                    if let heard, queue.indices.contains(heard.cursor) { cursor = heard.cursor }
                    await start(at: position(), gathering: false)
                    return
                }
                if await group.hasListeners() { heardAt = now }
                guard mine == generation else { return }
                if now - heardAt > Self.unheardLimitUs {
                    Log.info("\(group.name): nobody is listening; paused")
                    await pause()
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    /// The next block of the queue and its place on the timeline; nil when the queue is over.
    private func nextBlock(now: Int64) -> (PCMBuffer, Int64)? {
        while true {
            if source == nil {
                guard queue.indices.contains(cursor) else { return nil }
                do {
                    let opened = try AudioFileSource(url: queue[cursor].url)
                    opened.seek(to: startOffset)
                    source = opened
                    announce = true
                } catch {
                    Log.warning("Can't play \(queue[cursor].path): \(error)")
                    unreadable += 1
                    // A queue of nothing but unreadable files, on repeat, would never end.
                    guard unreadable < queue.count, step() else { return nil }
                    continue
                }
            }
            guard let block = source?.next() else {
                source = nil
                guard step() else { return nil }
                continue
            }
            unreadable = 0
            if segment == nil || segment?.sampleRate != block.sampleRate {
                segment = (nextCaptureUs ?? now + 60_000, block.sampleRate, 0)
            }
            guard var run = segment else { return nil }
            let captureUs = run.startUs + run.frames * 1_000_000 / Int64(run.sampleRate)
            run.frames += Int64(block.frameCount)
            segment = run
            nextCaptureUs = run.startUs + run.frames * 1_000_000 / Int64(run.sampleRate)
            if announce {
                announce = false
                upcoming.append(Heard(cursor: cursor, track: queue[cursor], playUs: captureUs + leadUs, offset: startOffset))
            }
            return (block, captureUs)
        }
    }

    /// Move the cursor on as a track ends; false at the end of a queue that doesn't repeat.
    private func step() -> Bool {
        startOffset = 0
        if repeatMode == "one" { return queue.indices.contains(cursor) }
        if cursor + 1 < queue.count {
            cursor += 1
            return true
        }
        guard repeatMode == "all", !queue.isEmpty else { return false }
        cursor = 0
        return true
    }

    /// Tracks whose first sample is due become the one that's heard.
    private func applyDue() async {
        let now = ServerClock.nowMicros()
        while let next = upcoming.first, next.playUs <= now {
            upcoming.removeFirst()
            heard = next
            onTrackStarted?(next.track)
            await publish()
        }
    }

    /// Everything is sent: wait for it to play out, then stop at the start of the queue.
    private func finish(_ mine: Int) async {
        let endUs = (nextCaptureUs ?? ServerClock.nowMicros()) + leadUs
        while mine == generation, ServerClock.nowMicros() < endUs {
            await applyDue()
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard mine == generation else { return }
        cursor = 0
        heard = queue.first.map { Heard(cursor: 0, track: $0, playUs: .max, offset: 0) }
        await halt(.stopped, at: 0)
    }

    // MARK: Telling the players

    /// Send the track details and what the controllers may do.
    func publish() async {
        let now = ServerClock.nowMicros()
        var details = MetadataState(timestamp: now)
        if let heard {
            let track = heard.track
            let running = state == .playing && heard.playUs <= now
            details = MetadataState(
                timestamp: now, title: track.title, artist: track.artist, albumArtist: track.albumArtist,
                album: track.album, artworkURL: artworkURL?(track), year: track.year, track: track.trackNumber,
                progress: .init(trackProgress: Int(position(at: now) * 1_000),
                                trackDuration: Int(track.duration * 1_000), playbackSpeed: running ? 1_000 : 0))
        }
        await group.setMetadata(details)
        await group.setMedia(controls())
    }

    func controls() -> MediaControls {
        guard !queue.isEmpty else { return MediaControls(commands: []) }
        let duration = currentTrack?.duration ?? 0
        var commands = ["play", "pause", "stop", "next", "previous", "repeat_off", "repeat_one", "repeat_all",
                        "shuffle", "unshuffle", "seek_relative"]
        if duration > 0 { commands.append("seek") }
        return MediaControls(commands: commands, repeatMode: repeatMode, shuffle: shuffle,
                             seekMaxMs: duration > 0 ? Int(duration * 1_000) : nil)
    }
}
