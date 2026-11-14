import MediaPlayer
import Observation
import SendspinClientKit

/// Shows what's playing in the system's Now Playing (lock screen, Control Center, the Mac's
/// menu bar) and routes its controls and the media keys to the group.
@MainActor
final class NowPlayingBridge {
    private let client: SendspinClient

    init(client: SendspinClient) {
        self.client = client
        let commands = MPRemoteCommandCenter.shared()
        register(commands.playCommand) { $0.play() }
        register(commands.pauseCommand) { $0.pause() }
        register(commands.togglePlayPauseCommand) { $0.togglePlayPause() }
        register(commands.nextTrackCommand) { $0.next() }
        register(commands.previousTrackCommand) { $0.previous() }
        observe()
    }

    private func register(_ command: MPRemoteCommand, _ action: @escaping @MainActor (SendspinClient) -> Void) {
        command.addTarget { [weak self] _ in
            Task { @MainActor in
                if let self { action(self.client) }
            }
            return .success
        }
    }

    /// Publish the current state, and again whenever something it read changes.
    private func observe() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let metadata = client.metadata, metadata.title != nil else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [MPMediaItemPropertyTitle: metadata.title ?? ""]
        info[MPMediaItemPropertyArtist] = metadata.artist
        info[MPMediaItemPropertyAlbumTitle] = metadata.album
        if let position = client.playbackPosition() {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(position.positionMs) / 1000
            if position.durationMs > 0 { info[MPMediaItemPropertyPlaybackDuration] = Double(position.durationMs) / 1000 }
        }
        let speed = Double(metadata.progress?.playbackSpeed ?? 1000) / 1000
        info[MPNowPlayingInfoPropertyPlaybackRate] = client.isPlaying ? speed : 0
        center.nowPlayingInfo = info
        #if os(macOS)
        // macOS shows the item only once the app declares its playback state.
        center.playbackState = client.isPlaying ? .playing : .paused
        #endif
    }
}
