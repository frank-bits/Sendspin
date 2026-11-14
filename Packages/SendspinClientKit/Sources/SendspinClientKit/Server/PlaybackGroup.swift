import Foundation

/// Audio output in a group that isn't a Sendspin player, such as this Mac's own speakers. It
/// gets the group's audio with each block's play time on the server clock, and keeps it in
/// sync with the players itself.
public protocol GroupOutput: AnyObject, Sendable {
    func play(_ pcm: PCMBuffer, timestampUs: Int64)
    /// The group stopped (idle, or its lead changed): drop what's queued.
    func stop()
}

/// A member of the group that isn't a Sendspin player, such as this Mac's own speakers: a
/// controller counts its volume and mute in the group's, and its commands reach it too.
public struct LocalMember: Sendable {
    /// Its volume and mute now; nil while it doesn't play in the group.
    public var state: @Sendable () async -> ControllerMember?
    public var setVolume: @Sendable (Int) async -> Void
    public var setMuted: @Sendable (Bool) async -> Void

    public init(state: @escaping @Sendable () async -> ControllerMember?,
                setVolume: @escaping @Sendable (Int) async -> Void,
                setMuted: @escaping @Sendable (Bool) async -> Void) {
        self.state = state
        self.setVolume = setVolume
        self.setMuted = setMuted
    }
}

/// A set of players that play the same live audio in sync.
///
/// Every chunk is scheduled at its capture time plus a fixed lead. Capture time comes
/// from the audio device's host-time stamps, so the timeline follows the capture clock
/// exactly: there is no drift to correct and no rebasing. Players that join late
/// simply start with the next chunk.
public actor PlaybackGroup {
    /// How long after its capture time a chunk can reach a player: the capture block, the
    /// FLAC encoder's block and the network. The lead must exceed what a player needs queued
    /// by this much, as its queue starts at the lead minus this (player/v1.md, Server Audio
    /// Send Constraints).
    public static let sendMarginMs = 50

    public nonisolated let id = GroupID.random()
    public let name: String
    /// How far ahead of capture time players are told to play (their buffer).
    public private(set) var leadUs: Int64
    /// Bit depth to stream when players support it (16 or 24).
    public private(set) var preferredBitDepth = 16
    /// A bit depth that takes over with the first block at this rate.
    private var bitDepthForRate: (sampleRate: Int, bitDepth: Int)?

    private var sessions: [URL: (session: PlayerSession, task: Task<Void, Never>)] = [:]
    private var outputs: [ObjectIdentifier: any GroupOutput] = [:]
    private var localMember: LocalMember?
    private var playing = false
    private var lateChunks = 0
    /// Counts recomputations of the controller state, so an older one doesn't send late.
    private var controllerGeneration = 0
    /// What the queue offers controllers, and who carries its commands out.
    private var media: MediaControls?
    private var mediaHandler: (@Sendable (ControllerCommand) async -> Void)?
    /// The track details every metadata client has, or gets when it joins.
    private var trackDetails: MetadataState?

    public init(name: String, leadMs: Int) {
        self.name = name
        leadUs = Int64(leadMs) * 1_000
    }

    public var players: [PlayerSession] { sessions.values.map(\.session) }

    public var isPlaying: Bool { playing }

    /// Players switch format at the next chunk: each session restarts its stream. With
    /// `sampleRate`, the bit depth waits for the first block at that rate, so that a new rate
    /// and bit depth restart it once, together, however soon the blocks come.
    public func setPreferredBitDepth(_ bitDepth: Int, fromSampleRate sampleRate: Int? = nil) {
        if let sampleRate {
            bitDepthForRate = (sampleRate, bitDepth)
        } else {
            bitDepthForRate = nil
            preferredBitDepth = bitDepth
        }
    }

    /// Change the lead. Players restart their stream, since shifting timestamps
    /// mid-stream would make them skip or repeat audio.
    public func setLead(ms: Int) async {
        let newLead = Int64(ms) * 1_000
        guard newLead != leadUs else { return }
        let wasPlaying = playing
        await setPlaying(false)
        leadUs = newLead
        if wasPlaying { await setPlaying(true) }
    }

    /// Add a player; the group keeps it connected until it is removed.
    public func add(_ session: PlayerSession) async {
        guard sessions[session.url] == nil else { return }
        await session.join(groupID: id, groupName: name, group: self)
        await session.setPlaying(playing)
        if let trackDetails { await session.updateMetadata(trackDetails) }
        sessions[session.url] = (session, Task { [weak self] in
            await session.run()
            // A player that connected to us is served once: it comes back as a new session.
            if session.isIncoming { await self?.ended(session) }
        })
    }

    private func ended(_ session: PlayerSession) async {
        guard sessions[session.url]?.session === session else { return }
        sessions[session.url] = nil
        await membersChanged()
    }

    // MARK: A queue of music

    /// What the group's queue offers controllers; `handler` carries their commands out.
    public func setMedia(_ controls: MediaControls?, handler: (@Sendable (ControllerCommand) async -> Void)? = nil) async {
        if let handler { mediaHandler = handler }
        guard controls != media else { return }
        media = controls
        await membersChanged()
    }

    /// The details of what plays, for the metadata role: sent now, and to players that join.
    /// Its timestamp must not lie ahead, so that it also serves as a joining player's first state.
    public func setMetadata(_ state: MetadataState) async {
        trackDetails = state
        for (session, _) in sessions.values { await session.updateMetadata(state) }
    }

    /// A seek or a jump to another track: players drop what they have buffered, and the
    /// stream goes on with the next block pushed (messaging.md, stream/clear).
    public func clear() async {
        for (session, _) in sessions.values { await session.clearStream() }
        for output in outputs.values { output.stop() }
    }

    /// The lead the players need now: the longest buffer one asks for, plus the send margin.
    public func requiredLeadMs() async -> Int {
        var longest = 0
        for (session, _) in sessions.values { longest = max(longest, await session.currentStatus.requiredBufferMs) }
        return longest + Self.sendMarginMs
    }

    public func remove(url: URL) async {
        guard let entry = sessions.removeValue(forKey: url) else { return }
        entry.task.cancel()
        await entry.session.shutdown()
        await membersChanged()
    }

    // MARK: Controller role (roles/controller/v1.md)

    public func setLocalMember(_ member: LocalMember) async {
        localMember = member
        await membersChanged()
    }

    /// A member's volume, mute or place in the group changed: send every controller its
    /// group's state, if that changed.
    public func membersChanged() async {
        controllerGeneration += 1
        let generation = controllerGeneration
        var members: [(session: PlayerSession, member: ControllerMember)] = []
        for (session, _) in sessions.values { members.append((session, await session.controllerMember())) }
        let local = await localMember?.state()
        let group = GroupControllerState(group: members.map(\.member).filter(\.inGroup) + (local.map { [$0] } ?? []),
                                         media: media)
        for (session, member) in members {
            guard generation == controllerGeneration else { return }
            // A player out of the group is a group of its own.
            await session.updateController(member.inGroup ? group : GroupControllerState(group: [member]))
        }
    }

    /// A controller's command for its group: ours, or the stopped group of its own it's in.
    func command(_ command: ControllerCommand, from controller: PlayerSession) async {
        var members: [(session: PlayerSession, member: ControllerMember)] = []
        for (session, _) in sessions.values { members.append((session, await session.controllerMember())) }
        guard let own = members.first(where: { $0.session === controller }) else { return }
        let targets = own.member.inGroup ? members.filter(\.member.inGroup) : [own]
        let local = own.member.inGroup ? await localMember?.state() : nil
        switch command.command {
        case "volume":
            guard let volume = command.volume else { return }
            await apply(volume: volume, to: targets, local: local)
        case "mute":
            guard let mute = command.mute else { return }
            await apply(mute: mute, to: targets, local: local)
        default:
            // The queue's commands, for controllers that play in the group.
            if own.member.inGroup { await mediaHandler?(command) }
        }
    }

    private typealias Member = (session: PlayerSession, member: ControllerMember)

    /// One command per member, after redistributing what one can't take (Setting group volume).
    private func apply(volume: Int, to targets: [Member], local: ControllerMember?) async {
        enum Key: Hashable { case player(ObjectIdentifier), local }
        let players = targets.filter { $0.member.canSetVolume && $0.member.volume != nil }
        var current = Dictionary(uniqueKeysWithValues: players.map { (Key.player(ObjectIdentifier($0.session)), $0.member.volume!) })
        if let local, local.canSetVolume, let level = local.volume { current[.local] = level }
        let levels = GroupVolume.redistribute(current, to: volume)
        for player in players where levels[.player(ObjectIdentifier(player.session))] != player.member.volume {
            await player.session.setVolume(levels[.player(ObjectIdentifier(player.session))]!)
        }
        if let level = levels[.local], level != local?.volume { await localMember?.setVolume(level) }
    }

    private func apply(mute: Bool, to targets: [Member], local: ControllerMember?) async {
        for player in targets where player.member.canMute && player.member.muted != mute {
            await player.session.setMuted(mute)
        }
        if let local, local.canMute, local.muted != mute { await localMember?.setMuted(mute) }
    }

    private func groupMembers() async -> [Member] {
        var members: [Member] = []
        for (session, _) in sessions.values {
            let member = await session.controllerMember()
            if member.inGroup { members.append((session, member)) }
        }
        return members
    }

    /// The group's volume and mute, as its controllers see them.
    public func levels() async -> (volume: Int, muted: Bool) {
        let local = await localMember?.state()
        let state = GroupControllerState(group: await groupMembers().map(\.member) + (local.map { [$0] } ?? []))
        return (state.volume, state.muted)
    }

    /// Set the volume of the group as a whole, keeping the players' differences.
    public func setVolume(_ volume: Int) async {
        await apply(volume: volume, to: await groupMembers(), local: await localMember?.state())
    }

    public func setMuted(_ muted: Bool) async {
        await apply(mute: muted, to: await groupMembers(), local: await localMember?.state())
    }

    /// The players that take part in the group now.
    public func members() async -> [PlayerSession] {
        await groupMembers().map(\.session)
    }

    public func add(output: any GroupOutput) {
        outputs[ObjectIdentifier(output)] = output
    }

    public func remove(output: any GroupOutput) {
        outputs[ObjectIdentifier(output)]?.stop()
        outputs[ObjectIdentifier(output)] = nil
    }

    /// Fan one captured block out to all players.
    /// - Parameter captureTimeUs: server-clock time of the block's first sample.
    public func push(_ pcm: PCMBuffer, captureTimeUs: Int64) async {
        if let waiting = bitDepthForRate, pcm.sampleRate == waiting.sampleRate {
            preferredBitDepth = waiting.bitDepth
            bitDepthForRate = nil
        }
        if !playing { await setPlaying(true) }
        let timestampUs = captureTimeUs + leadUs
        // Chunks that would arrive after their play time are useless to every player.
        if timestampUs < ServerClock.nowMicros() + 20_000 {
            lateChunks += 1
            if lateChunks.isMultiple(of: 50) { Log.warning("dropped \(lateChunks) late chunks") }
            return
        }
        for output in outputs.values {
            output.play(pcm, timestampUs: timestampUs)
        }
        for (session, _) in sessions.values {
            await session.deliver(pcm, timestampUs: timestampUs, preferredBitDepth: preferredBitDepth, leadUs: leadUs)
        }
    }

    /// Mark the group idle: players get `stream/end` and `group/update` stopped.
    public func setPlaying(_ playing: Bool) async {
        guard playing != self.playing else { return }
        self.playing = playing
        for (session, _) in sessions.values {
            await session.setPlaying(playing)
        }
        if !playing {
            for output in outputs.values { output.stop() }
        }
    }

    public func shutdown() async {
        for url in Array(sessions.keys) {
            await remove(url: url)
        }
        for output in Array(outputs.values) {
            remove(output: output)
        }
    }
}
