import Foundation
import MusicAssistantKit
import SendspinClientKit

/// What the player screen shows and controls: this device's own Sendspin group, or another
/// player reached through Music Assistant.
@MainActor
protocol NowPlayingSource: AnyObject {
    var title: String? { get }
    var artist: String? { get }
    var album: String? { get }
    var artworkURL: URL? { get }
    var isPlaying: Bool { get }
    var shuffle: Bool { get }
    /// "off", "one" or "all".
    var repeatMode: String { get }
    /// 0-100; nil when unknown.
    var volume: Int? { get }
    var muted: Bool { get }

    /// Whether `command` is accepted now, by its Sendspin name: "play", "pause", "next",
    /// "previous", "shuffle", "repeat_all", "seek", "volume", "mute", "switch".
    func supports(_ command: String) -> Bool
    /// The track position now and the track's length, in ms; a length of 0 means unknown.
    func playbackPosition() -> (positionMs: Int, durationMs: Int)?
    func togglePlayPause()
    func next()
    func previous()
    func setShuffle(_ on: Bool)
    func setRepeat(_ mode: String)
    func setVolume(_ volume: Int)
    func setMuted(_ muted: Bool)
    func seek(toMs position: Int)
    func switchGroup()
}

extension SendspinClient: NowPlayingSource {
    var title: String? { metadata?.title }
    var artist: String? { metadata?.artist }
    var album: String? { metadata?.album }
    var artworkURL: URL? { metadata?.artworkURL.flatMap(URL.init(string:)) }
    var shuffle: Bool { controller?.shuffle ?? false }
    var repeatMode: String { controller?.repeatMode ?? "off" }
    var volume: Int? { controller?.volume }
    var muted: Bool { controller?.muted ?? false }
}

/// Another player or group, watched and controlled through Music Assistant's API. It asks the
/// server for the state every couple of seconds while `run()` runs.
@MainActor
@Observable
final class RemotePlayer: NowPlayingSource {
    let player: ServerPlayer
    private let api: MusicAssistantAPI
    private let report: @MainActor (Error) -> Void
    private var queue: QueueState?
    private var levels: PlayerLevels?
    /// The level last asked for, shown until a reply that follows the command, so a reply
    /// sent before it can't put the old value back on screen.
    private var pendingVolume: Int?
    /// Sends volume changes one at a time, each the latest wanted.
    private var volumeTask: Task<Void, Never>?

    private static let interval = Duration.seconds(2)

    init(player: ServerPlayer, api: MusicAssistantAPI, report: @escaping @MainActor (Error) -> Void) {
        self.player = player
        self.api = api
        self.report = report
    }

    /// Keep the state current until cancelled.
    func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// Ask the server for the state now, rather than at the next poll.
    func refresh() async {
        // A missed poll is no news: the next one follows shortly.
        async let queue = try? api.queueState(player.playerID)
        async let levels = try? api.levels(of: player)
        let (newQueue, newLevels) = await (queue, levels)
        guard !Task.isCancelled else { return }
        if let newQueue { self.queue = newQueue }
        if let newLevels {
            self.levels = newLevels
            if volumeTask == nil { pendingVolume = nil }
        }
    }

    private func send(_ command: @escaping @Sendable (MusicAssistantAPI, ServerPlayer) async throws -> Void) {
        Task {
            do {
                try await command(api, player)
                await refresh()
            } catch {
                report(error)
            }
        }
    }

    // MARK: NowPlayingSource

    private var media: MediaItem? { queue?.current?.media }

    var title: String? {
        guard let current = queue?.current else { return nil }
        return media?.title ?? (current.name.isEmpty ? nil : current.name)
    }

    var artist: String? {
        media.map { $0.artists.joined(separator: ", ") }.flatMap { $0.isEmpty ? nil : $0 }
    }

    var album: String? { media?.album }
    var artworkURL: URL? { queue?.current?.image?.url(server: api.baseURL, points: 320) }
    var isPlaying: Bool { queue?.isPlaying ?? false }
    var shuffle: Bool { queue?.shuffle ?? false }
    var repeatMode: String { queue?.repeatMode ?? "off" }
    var volume: Int? { pendingVolume ?? levels?.volume }
    var muted: Bool { levels?.muted ?? false }

    func supports(_ command: String) -> Bool {
        switch command {
        case "switch": false
        case "volume", "mute": levels?.volume != nil
        case "seek": (queue?.current?.duration ?? 0) > 0
        default: queue?.current != nil
        }
    }

    func playbackPosition() -> (positionMs: Int, durationMs: Int)? {
        guard let queue, let current = queue.current else { return nil }
        return (Int(queue.position() * 1000), (current.duration ?? 0) * 1000)
    }

    func togglePlayPause() { send { try await $0.queueCommand("play_pause", queueID: $1.playerID) } }
    func next() { send { try await $0.queueCommand("next", queueID: $1.playerID) } }
    func previous() { send { try await $0.queueCommand("previous", queueID: $1.playerID) } }
    func setShuffle(_ on: Bool) { send { try await $0.setShuffle(on, queueID: $1.playerID) } }
    func setRepeat(_ mode: String) { send { try await $0.setRepeat(mode, queueID: $1.playerID) } }
    func setMuted(_ muted: Bool) { send { try await $0.setMuted(muted, of: $1) } }
    func seek(toMs position: Int) { send { try await $0.seek(queueID: $1.playerID, position: position / 1000) } }
    func switchGroup() {}

    func setVolume(_ volume: Int) {
        pendingVolume = volume
        // One request at a time: sent side by side they could arrive out of order, and leave
        // an earlier level in place.
        guard volumeTask == nil else { return }
        volumeTask = Task {
            var sent: Int?
            do {
                while let wanted = pendingVolume, wanted != sent {
                    try await api.setVolume(wanted, of: player)
                    sent = wanted
                }
            } catch {
                report(error)
            }
            volumeTask = nil
            await refresh()
        }
    }
}
