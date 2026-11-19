#if os(macOS)
import Foundation
import MusicKit
import SendspinClientKit
import TandemServerKit

/// Apple Music for the server: MusicKit finds the songs and plays them on this Mac, and a
/// tap on Apple's player process hears them, muted here, for the server to send on.
///
/// It needs the signed-in user's Apple Music subscription and permission to record system
/// audio. There is one player, so one group at a time plays Apple Music: a song started for
/// another group ends the one that played.
@available(macOS 14.2, *)
final class AppleMusicProvider: StreamingProvider, @unchecked Sendable {
    let id = "applemusic"
    /// The process MusicKit's sound comes from.
    private static let playerBundleID = "com.apple.MediaPlayer.RemotePlayerService"

    private let lock = NSLock()
    private var songs: [String: Song] = [:]
    private var tracks: [String: LibraryTrack] = [:]
    private var current: AppleMusicStream?
    /// The steps asked of the player, one after another.
    private var chain = Task<Void, Never> {}

    // Only touched from the chain, on the main actor.
    @MainActor private var tap: ProcessTap?
    @MainActor private var loadedID: String?

    static var isAuthorized: Bool { MusicAuthorization.currentStatus == .authorized }

    // MARK: Finding music

    func search(_ query: String, limit: Int) async -> (tracks: [LibraryTrack], albums: [LibraryAlbum]) {
        guard Self.isAuthorized else { return ([], []) }
        let response = await Self.retrying {
            var request = MusicCatalogSearchRequest(term: query, types: [Song.self, Album.self])
            request.limit = max(1, min(25, limit))
            return try await request.response()
        }
        guard let response else { return ([], []) }
        let found = response.songs.map(remember)
        let albums = response.albums.map { album in
            LibraryAlbum.streamed(id: "\(id)-\(album.id.rawValue)", name: album.title, artist: album.artistName,
                                  year: album.releaseDate.map { Calendar.current.component(.year, from: $0) },
                                  artwork: album.artwork?.url(width: 600, height: 600)?.absoluteString)
        }
        return (found, albums)
    }

    func track(_ trackID: String) async -> LibraryTrack? {
        if let known = lock.withLock({ tracks[trackID] }) { return known }
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(catalogID(trackID)))
        return await Self.retrying({ try await request.response() })?.items.first.map(remember)
    }

    func albumTracks(_ albumID: String) async -> [LibraryTrack] {
        let request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(catalogID(albumID)))
        guard let album = await Self.retrying({ try await request.response() })?.items.first,
              let full = await Self.retrying({ try await album.with([.tracks]) })
        else { return [] }
        return (full.tracks ?? []).compactMap { track in
            guard case .song(let song) = track else { return nil }
            return remember(song, albumID: albumID, albumArtist: album.artistName)
        }
    }

    private func catalogID(_ itemID: String) -> String { String(itemID.dropFirst(id.count + 1)) }

    private func remember(_ song: Song) -> LibraryTrack { remember(song, albumID: nil, albumArtist: nil) }

    private func remember(_ song: Song, albumID: String?, albumArtist: String?) -> LibraryTrack {
        // A song's address ends in its album's id: .../album/<name>/<album id>?i=<song id>.
        let fromAddress = song.url.map(\.lastPathComponent).flatMap { $0.allSatisfy(\.isNumber) ? "\(id)-\($0)" : nil }
        let track = LibraryTrack.streamed(
            provider: id, id: "\(id)-\(song.id.rawValue)", title: song.title, artist: song.artistName,
            albumArtist: albumArtist, album: song.albumTitle ?? "", albumID: albumID ?? fromAddress,
            trackNumber: song.trackNumber, discNumber: song.discNumber,
            year: song.releaseDate.map { Calendar.current.component(.year, from: $0) },
            duration: song.duration ?? 0, artwork: song.artwork?.url(width: 600, height: 600)?.absoluteString)
        lock.withLock {
            songs[track.id] = song
            tracks[track.id] = track
        }
        return track
    }

    /// Apple's servers refuse a request now and then, more so for a newly registered app.
    private static func retrying<T>(_ work: () async throws -> T) async -> T? {
        for attempt in 1...5 {
            do {
                return try await work()
            } catch {
                if attempt == 5 { Log.warning("Apple Music: \(error)") }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        return nil
    }

    // MARK: Playing

    func open(_ track: LibraryTrack, at offset: Double) -> LiveStream {
        let stream = AppleMusicStream(trackID: track.id) { [weak self] in self?.closed($0) }
        let earlier = lock.withLock {
            let earlier = current
            current = stream
            return earlier
        }
        earlier?.finish()
        enqueue { await self.play(track, at: offset, into: stream) }
        return stream
    }

    private func closed(_ stream: AppleMusicStream) {
        enqueue {
            // Another song took the player meanwhile: it's left playing.
            guard self.lock.withLock({ self.current === stream }) else { return }
            self.lock.withLock { self.current = nil }
            await self.pause()
        }
    }

    private func enqueue(_ step: @escaping @Sendable () async -> Void) {
        lock.withLock {
            let before = chain
            chain = Task {
                await before.value
                await step()
            }
        }
    }

    @MainActor private func pause() {
        tap?.send(to: nil)
        ApplicationMusicPlayer.shared.pause()
    }

    @MainActor private func play(_ track: LibraryTrack, at offset: Double, into stream: AppleMusicStream) async {
        guard lock.withLock({ current === stream }) else { return }
        guard let song = lock.withLock({ songs[track.id] }) else {
            // Queued in an earlier run of the app: looked up again.
            if await self.track(track.id) != nil, lock.withLock({ songs[track.id] }) != nil {
                await play(track, at: offset, into: stream)
            } else {
                stream.finish()
            }
            return
        }
        let player = ApplicationMusicPlayer.shared
        do {
            // The same song, held where it was: it only has to move and go on.
            let held = loadedID == track.id && player.state.playbackStatus != .stopped
            if !held {
                player.queue = [song]
                loadedID = track.id
                try await player.prepareToPlay()
            }
            let ready = attachTap(to: stream)
            if offset > 0 || held { player.playbackTime = offset }
            try await player.play()
            if !ready {
                // The player's process appears with its first sound: tap it, then start over
                // so nothing of the song is missed.
                var found = false
                for _ in 0..<100 where !found {
                    try await Task.sleep(for: .milliseconds(100))
                    found = attachTap(to: stream)
                }
                guard found else {
                    Log.warning("Apple Music: can't hear the player; is Tandem allowed to record system audio?")
                    player.pause()
                    stream.finish()
                    return
                }
                player.playbackTime = offset
            }
            stream.accept()
        } catch {
            Log.warning("Apple Music: can't play \(track.title): \(error)")
            loadedID = nil
            stream.finish()
            return
        }
        Task { @MainActor in await self.watch(stream, track: track, from: offset) }
    }

    /// Point the tap at `stream`, making it when the player's process is there. False without one.
    @MainActor private func attachTap(to stream: AppleMusicStream) -> Bool {
        let process = ProcessTap.process(bundleID: Self.playerBundleID)
        if tap == nil || tap?.process != process {
            tap = process.flatMap { ProcessTap(process: $0) }
        }
        guard let tap else { return false }
        let (rate, channels) = (tap.sampleRate, tap.channels)
        tap.send { [weak stream] in stream?.append($0, sampleRate: rate, channels: channels) }
        return true
    }

    /// End the stream when its song does.
    @MainActor private func watch(_ stream: AppleMusicStream, track: LibraryTrack, from offset: Double) async {
        let player = ApplicationMusicPlayer.shared
        let started = Date()
        var idleSince: Date?
        while !stream.hasEnded, lock.withLock({ current === stream }) {
            try? await Task.sleep(for: .milliseconds(100))
            let elapsed = Date().timeIntervalSince(started)
            if player.state.playbackStatus == .playing {
                idleSince = nil
            } else if elapsed > 1 {
                idleSince = idleSince ?? Date()
            }
            let idle = idleSince.map { Date().timeIntervalSince($0) > 0.5 } ?? false
            // A song that neither stops nor ends is cut off a little after its length.
            let overdue = track.duration > 0 && elapsed > track.duration - offset + 5
            if idle || overdue {
                stream.finish()
                return
            }
        }
    }
}
#endif
