import Foundation
import SendspinClientKit

/// The server's library and queue over HTTP, for apps to browse and choose music with.
///
/// It answers the part of Music Assistant's API that Tandem uses, in the same shapes
/// (`POST /api` with a command and its arguments, `GET /imageproxy/<id>`), so one set of
/// library screens serves both kinds of server. There is one queue, played by one group:
/// whichever player or queue a command names, it means that one.
///
/// Nothing signs in: anyone on the network can browse and play. Requests from web pages are
/// refused, so a site open in a browser on the network can't drive it.
struct ServerAPI: Sendable {
    static let groupID = "group"

    let name: String
    let serverID: String
    let library: MusicLibrary
    let engine: PlaybackEngine
    let group: PlaybackGroup
    let store: ServerStore
    let artwork = ArtworkCache()

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        // Browsers name the page a request comes from; apps don't.
        guard request.headers["origin"] == nil else { return .error(403, "Requests from web pages aren't accepted") }
        switch (request.method, request.path) {
        case ("GET", "/info"):
            return .json(["server_id": serverID, "server_version": "0.1.0", "name": name, "tandem": true])
        case ("POST", "/api"):
            guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let command = body["command"] as? String
            else { return .error(400, "Invalid request") }
            let arguments = Arguments(values: body["args"] as? [String: Any] ?? [:])
            guard let result = await run(command, arguments) else { return .error(400, "Invalid Command") }
            return .json(result)
        case ("GET", let path) where path.hasPrefix("/imageproxy/"):
            let id = String(path.dropFirst("/imageproxy/".count))
            let size = request.query["size"].flatMap(Int.init) ?? 0
            guard let image = await artwork.image(id, size: size, from: library) else { return .error(404, "No image") }
            return HTTPResponse(status: 200, contentType: "image/jpeg", body: image)
        default:
            return .error(404, "Not found")
        }
    }

    /// A command's result as JSON, or nil for a command this server doesn't have.
    private func run(_ command: String, _ arguments: Arguments) async -> Any? {
        switch command {
        case "auth/me":
            return ["username": "local", "display_name": name]

        // Finding music.
        case "music/search":
            let query = arguments.string("search_query") ?? ""
            let limit = arguments.int("limit") ?? 8
            return [
                "artists": await library.allArtists(matching: query, limit: limit).map(JSON.artist),
                "albums": await library.allAlbums(matching: query, limit: limit).map(JSON.album),
                "tracks": await library.allTracks(matching: query, limit: limit).map(JSON.track),
                "playlists": [Any](), "radio": [Any](), "podcasts": [Any](), "audiobooks": [Any](),
            ] as [String: Any]
        case "music/recently_played_items":
            var albums: [Any] = []
            for id in store.recentAlbums.prefix(arguments.int("limit") ?? 12) {
                if let album = await library.album(id) { albums.append(JSON.album(album)) }
            }
            return albums
        case "music/artists/library_items":
            return await library.allArtists(matching: arguments.string("search"), limit: arguments.int("limit") ?? 50,
                                            offset: arguments.int("offset") ?? 0).map(JSON.artist)
        case "music/albums/library_items":
            return await library.allAlbums(matching: arguments.string("search"), limit: arguments.int("limit") ?? 50,
                                           offset: arguments.int("offset") ?? 0).map(JSON.album)
        case "music/tracks/library_items":
            return await library.allTracks(matching: arguments.string("search"), limit: arguments.int("limit") ?? 50,
                                           offset: arguments.int("offset") ?? 0).map(JSON.track)
        case "music/playlists/library_items", "music/radios/library_items", "music/podcasts/library_items",
             "music/audiobooks/library_items", "music/playlists/playlist_tracks", "music/podcasts/podcast_episodes":
            // Kinds a folder of music files doesn't hold.
            return [Any]()
        case "music/albums/album_tracks":
            return (await library.album(arguments.string("item_id") ?? "")?.tracks ?? []).map(JSON.track)
        case "music/artists/artist_albums":
            return await library.albums(byArtist: arguments.string("item_id") ?? "").map(JSON.album)

        // Players.
        case "players/all":
            return await players()
        case "players/get":
            let id = arguments.string("player_id") ?? Self.groupID
            return await players().first { $0["player_id"] as? String == id } ?? NSNull()
        case "players/cmd/volume_set", "players/cmd/group_volume":
            guard let level = arguments.int("volume_level") else { return NSNull() }
            if let session = await session(arguments.string("player_id")) {
                await session.setVolume(level)
            } else {
                await group.setVolume(level)
            }
        case "players/cmd/volume_mute", "players/cmd/group_volume_mute":
            guard let muted = arguments.bool("muted") else { return NSNull() }
            if let session = await session(arguments.string("player_id")) {
                await session.setMuted(muted)
            } else {
                await group.setMuted(muted)
            }

        // The queue.
        case "player_queues/get":
            return JSON.queue(await engine.snapshot())
        case "player_queues/play_media":
            await play(arguments)
        case "player_queues/play_pause": await engine.togglePlayPause()
        case "player_queues/play", "player_queues/resume": await engine.play()
        case "player_queues/pause": await engine.pause()
        case "player_queues/stop": await engine.stop()
        case "player_queues/next": await engine.next()
        case "player_queues/previous": await engine.previous()
        case "player_queues/seek":
            if let position = arguments.double("position") { await engine.seek(to: position) }
        case "player_queues/shuffle":
            if let on = arguments.bool("shuffle_enabled") { await engine.setShuffle(on) }
        case "player_queues/repeat":
            if let mode = arguments.string("repeat_mode") { await engine.setRepeat(mode) }
        default:
            return nil
        }
        return NSNull()
    }

    private func play(_ arguments: Arguments) async {
        var tracks: [LibraryTrack] = []
        for uri in arguments.strings("media") { tracks += await resolve(uri) }
        var start = 0
        if let startItem = arguments.string("start_item"), let first = await resolve(startItem).first {
            start = tracks.firstIndex(of: first) ?? 0
        }
        let insertion = arguments.string("option").flatMap(QueueInsertion.init(rawValue:)) ?? .replace
        await engine.enqueue(tracks, insertion, startAt: start, shuffle: arguments.bool("shuffle"))
    }

    /// The tracks a URI such as `library://album/<id>` stands for, in play order.
    private func resolve(_ uri: String) async -> [LibraryTrack] {
        let parts = uri.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "library:" else { return [] }
        let id = parts[2]
        switch parts[1] {
        case "track": return [await library.track(id)].compactMap { $0 }
        case "album": return await library.album(id)?.tracks ?? []
        case "artist": return await library.albums(byArtist: id).flatMap(\.tracks)
        default: return []
        }
    }

    /// The group, then each connected player. Only the group is offered to play on: the
    /// players are listed so that an app finds itself, and for their own volume.
    private func players() async -> [[String: Any]] {
        let snapshot = await engine.snapshot()
        let levels = await group.levels()
        let members = Set(await group.members().map(ObjectIdentifier.init))
        let playing = snapshot.state == .playing
        var list: [[String: Any]] = [[
            "player_id": Self.groupID, "name": name, "display_name": name, "type": "group",
            "available": true, "enabled": true, "playback_state": playing ? "playing" : "idle",
            "volume_level": levels.volume, "group_volume": levels.volume,
            "volume_muted": levels.muted, "group_volume_muted": levels.muted,
        ]]
        for session in await group.players {
            let status = await session.currentStatus
            guard let clientID = status.clientID else { continue }
            let inGroup = members.contains(ObjectIdentifier(session))
            var player: [String: Any] = [
                "player_id": clientID, "name": status.name ?? "Player", "display_name": status.name ?? "Player",
                "type": "player", "available": status.connection == .connected, "enabled": true, "hide_in_ui": true,
                "playback_state": inGroup && playing ? "playing" : "idle", "volume_muted": status.muted ?? false,
            ]
            if let volume = status.volume { player["volume_level"] = volume }
            if inGroup { player["active_group"] = Self.groupID }
            list.append(player)
        }
        return list
    }

    /// The connected player with this client id; nil for the group or an unknown id.
    private func session(_ id: String?) async -> PlayerSession? {
        guard let id, id != Self.groupID else { return nil }
        for session in await group.players where await session.currentStatus.clientID == id { return session }
        return nil
    }
}

/// A command's arguments, read leniently: clients differ in how they write numbers and lists.
struct Arguments: @unchecked Sendable {
    let values: [String: Any]

    func string(_ key: String) -> String? {
        (values[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    func int(_ key: String) -> Int? {
        (values[key] as? NSNumber)?.intValue ?? (values[key] as? String).flatMap(Int.init)
    }

    func double(_ key: String) -> Double? {
        (values[key] as? NSNumber)?.doubleValue ?? (values[key] as? String).flatMap(Double.init)
    }

    func bool(_ key: String) -> Bool? {
        (values[key] as? NSNumber)?.boolValue
    }

    /// A list of strings, or a single one.
    func strings(_ key: String) -> [String] {
        (values[key] as? [String]) ?? string(key).map { [$0] } ?? []
    }
}
