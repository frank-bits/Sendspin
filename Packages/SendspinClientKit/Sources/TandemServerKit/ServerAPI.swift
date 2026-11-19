import Foundation
import SendspinClientKit

/// The server's library and queue over HTTP, for apps to browse and choose music with.
///
/// It answers the part of Music Assistant's API that Tandem uses, in the same shapes
/// (`POST /api` with a command and its arguments, `GET /imageproxy/<id>`), so one set of
/// library screens serves both kinds of server. Every group and every speaker has a queue of
/// its own, named by its player id.
///
/// Nothing signs in: anyone on the network can browse and play. Requests from web pages are
/// refused, so a site open in a browser on the network can't drive it.
struct ServerAPI: Sendable {
    let name: String
    let serverID: String
    let library: MusicLibrary
    let zones: Zones
    let store: ServerStore
    let speakers: AirPlaySpeakers
    var providers: [StreamingProvider] = []
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
            // The folder's music first, then what each streaming service finds.
            var albums = await library.allAlbums(matching: query, limit: limit)
            var tracks = await library.allTracks(matching: query, limit: limit)
            if !query.isEmpty {
                for provider in providers {
                    let found = await provider.search(query, limit: limit)
                    albums += found.albums
                    tracks += found.tracks
                }
            }
            return [
                "artists": await library.allArtists(matching: query, limit: limit).map(JSON.artist),
                "albums": albums.map(JSON.album),
                "tracks": tracks.map(JSON.track),
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
            let id = arguments.string("item_id") ?? ""
            if let provider = providers.owner(of: id) { return await provider.albumTracks(id).map(JSON.track) }
            return (await library.album(id)?.tracks ?? []).map(JSON.track)
        case "music/artists/artist_albums":
            return await library.albums(byArtist: arguments.string("item_id") ?? "").map(JSON.album)

        // Players.
        case "players/all":
            return await players()
        case "players/get":
            let id = arguments.string("player_id") ?? Zones.everywhereID
            return await players().first { $0["player_id"] as? String == id } ?? NSNull()
        case "players/cmd/volume_set", "players/cmd/group_volume":
            guard let level = arguments.int("volume_level") else { return NSNull() }
            let id = arguments.string("player_id")
            if let speaker = speakerID(id) {
                await speakers.setVolume(speaker, level)
            } else if let id, let session = await zones.players[id] {
                await session.setVolume(level)
            } else {
                await zones.zone(id)?.group.setVolume(level)
            }
        case "players/cmd/volume_mute", "players/cmd/group_volume_mute":
            guard let muted = arguments.bool("muted") else { return NSNull() }
            let id = arguments.string("player_id")
            if let speaker = speakerID(id) {
                await speakers.setMuted(speaker, muted)
            } else if let id, let session = await zones.players[id] {
                await session.setMuted(muted)
            } else {
                await zones.zone(id)?.group.setMuted(muted)
            }

        // The queue of the group or speaker a command names; Everywhere's when it names none.
        case let queue where queue.hasPrefix("player_queues/"):
            guard let zone = await zones.zone(arguments.string("queue_id")) else { return NSNull() }
            return await run(String(queue.dropFirst("player_queues/".count)), arguments, on: zone)
        default:
            return nil
        }
        return NSNull()
    }

    private func run(_ command: String, _ arguments: Arguments, on zone: Zones.Zone) async -> Any? {
        let engine = zone.engine
        switch command {
        case "get":
            return JSON.queue(await engine.snapshot(), id: zone.id)
        case "play_media":
            await play(arguments, on: engine)
        case "play_pause": await engine.togglePlayPause()
        case "play", "resume":
            await engine.play()
            // Asked for while it plays already: speakers another group took come back.
            await zones.gather(zone.id)
        case "pause": await engine.pause()
        case "stop": await engine.stop()
        case "next": await engine.next()
        case "previous": await engine.previous()
        case "seek":
            if let position = arguments.double("position") { await engine.seek(to: position) }
        case "shuffle":
            if let on = arguments.bool("shuffle_enabled") { await engine.setShuffle(on) }
        case "repeat":
            if let mode = arguments.string("repeat_mode") { await engine.setRepeat(mode) }
        default:
            return nil
        }
        return NSNull()
    }

    private func play(_ arguments: Arguments, on engine: PlaybackEngine) async {
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
        if let provider = providers.owner(of: id) {
            switch parts[1] {
            case "track": return [await provider.track(id)].compactMap { $0 }
            case "album": return await provider.albumTracks(id)
            default: return []
            }
        }
        switch parts[1] {
        case "track": return [await library.track(id)].compactMap { $0 }
        case "album": return await library.album(id)?.tracks ?? []
        case "artist": return await library.albums(byArtist: id).flatMap(\.tracks)
        default: return []
        }
    }

    /// Everywhere, the user's groups, then each speaker: all of them can be played on. A
    /// speaker names the group it plays with now, unless it plays by itself.
    private func players() async -> [[String: Any]] {
        var playing: Set<String> = []
        var list: [[String: Any]] = []
        let groups = await zones.groups
        let order = [Zones.everywhereID: -1].merging(groups.enumerated().map { ($1.id, $0) }) { first, _ in first }
        for zone in await zones.all {
            if await zone.engine.snapshot().state == .playing { playing.insert(zone.id) }
            guard let place = order[zone.id] else { continue }
            let levels = await zone.group.levels()
            list.append([
                "player_id": zone.id, "name": zone.name, "display_name": zone.name, "type": "group",
                "available": true, "enabled": true, "playback_state": playing.contains(zone.id) ? "playing" : "idle",
                "volume_level": levels.volume, "group_volume": levels.volume,
                "volume_muted": levels.muted, "group_volume_muted": levels.muted,
                "group_members": await zones.members(of: zone.id), "order": place,
            ])
        }
        list.sort { ($0["order"] as? Int ?? 0) < ($1["order"] as? Int ?? 0) }
        for (clientID, session) in await zones.players.sorted(by: { $0.key < $1.key }) {
            let status = await session.currentStatus
            let zone = await zones.zoneID(of: clientID)
            var player: [String: Any] = [
                "player_id": clientID, "name": status.name ?? "Player", "display_name": status.name ?? "Player",
                "type": "player", "available": status.connection == .connected, "enabled": true,
                "playback_state": playing.contains(zone) ? "playing" : "idle", "volume_muted": status.muted ?? false,
            ]
            if let volume = status.volume { player["volume_level"] = volume }
            if zone != clientID { player["active_group"] = zone }
            list.append(player)
        }
        for speaker in await speakers.speakers where speaker.enabled {
            let id = AirPlaySpeakers.memberID(speaker.id)
            let zone = await zones.zoneID(of: id)
            var player: [String: Any] = [
                "player_id": id, "name": speaker.name, "display_name": speaker.name,
                "type": "player", "available": speaker.present, "enabled": true,
                "playback_state": speaker.status == .playing ? "playing" : "idle", "volume_level": speaker.volume,
                "volume_muted": speaker.muted,
            ]
            if zone != id { player["active_group"] = zone }
            list.append(player)
        }
        return list
    }

    /// The AirPlay speaker a player id names, if it names one.
    private func speakerID(_ id: String?) -> String? {
        guard let id, id.hasPrefix("airplay:") else { return nil }
        return String(id.dropFirst("airplay:".count))
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
