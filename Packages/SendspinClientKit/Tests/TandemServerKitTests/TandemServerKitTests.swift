import AVFoundation
import Foundation
import MusicAssistantKit
import SendspinClientKit
import Testing
@testable import TandemServerKit

/// A folder of short silent WAV files laid out as `Artist/Album/NN Title.wav`, removed after.
final class MusicFolder {
    let url: URL

    init(_ paths: [String]) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-tests-\(UUID().uuidString)")
        for path in paths {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
            buffer.frameLength = 44_100
            try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
        }
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    static let standard = ["Zed/Late/02 Second.wav", "Zed/Late/01 First.wav", "Zed/Late/03 - Third.wav",
                           "Abe/Early/1-01 Opening.wav", "Abe/Early/loose.wav"]
}

@Suite struct LibraryTests {
    @Test func aFilesPlaceStandsInForMissingTags() {
        let root = URL(fileURLWithPath: "/Music")
        let numbered = TagReader.PathNames(url: root.appendingPathComponent("Abe/Early/03 - Third Song.flac"), root: root)
        #expect(numbered.title == "Third Song")
        #expect(numbered.track == 3)
        #expect(numbered.album == "Early")
        #expect(numbered.artist == "Abe")
        let disc = TagReader.PathNames(url: root.appendingPathComponent("Abe/Early/2-07 Late One.mp3"), root: root)
        #expect(disc.track == 7)
        #expect(disc.title == "Late One")
        let loose = TagReader.PathNames(url: root.appendingPathComponent("song.mp3"), root: root)
        #expect(loose.title == "song")
        #expect(loose.track == nil)
        #expect(loose.album == "Unknown Album")
        #expect(loose.artist == "Unknown Artist")
        // A year in the name isn't a track number.
        #expect(TagReader.PathNames(url: root.appendingPathComponent("1999.mp3"), root: root).title == "1999")
    }

    @Test func aScanSortsAlbumsArtistsAndTracks() async throws {
        let folder = try MusicFolder(MusicFolder.standard)
        let library = MusicLibrary()
        await library.load(folder: folder.url)
        #expect(await library.status == .ready(tracks: 5))
        #expect(await library.allArtists().map(\.name) == ["Abe", "Zed"])
        #expect(await library.allAlbums().map(\.name) == ["Early", "Late"])
        let late = try #require(await library.allAlbums(matching: "late").first)
        #expect(late.tracks.map(\.title) == ["First", "Second", "Third"])
        #expect(late.tracks.map(\.trackNumber) == [1, 2, 3])
        #expect(late.tracks.allSatisfy { abs($0.duration - 1) < 0.05 })
        #expect(await library.albums(byArtist: late.tracks[0].artistID).map(\.name) == ["Late"])
        #expect(await library.track(late.tracks[1].id)?.title == "Second")
    }

    @Test func searchMatchesEveryWordAndPages() async throws {
        let folder = try MusicFolder(MusicFolder.standard)
        let library = MusicLibrary()
        await library.load(folder: folder.url)
        #expect(await library.allTracks(matching: "zed thi").map(\.title) == ["Third"])
        #expect(await library.allTracks(matching: "nothing").isEmpty)
        let all = await library.allTracks(limit: 50).map(\.title)
        #expect(all.count == 5)
        #expect(await library.allTracks(limit: 2, offset: 2).map(\.title) == Array(all[2..<4]))
        #expect(await library.allTracks(limit: 2, offset: 9).isEmpty)
    }

    @Test func aRescanKeepsIdentifiersAndUsesTheCache() async throws {
        let folder = try MusicFolder(MusicFolder.standard)
        let cache = folder.url.appendingPathComponent("library.json")
        let first = MusicLibrary(cacheURL: cache)
        await first.load(folder: folder.url)
        let ids = await first.allTracks().map(\.id)
        #expect(FileManager.default.fileExists(atPath: cache.path))
        let second = MusicLibrary(cacheURL: cache)
        await second.load(folder: folder.url)
        #expect(await second.allTracks().map(\.id) == ids)
    }

    @Test func aMissingFolderIsReported() async {
        let library = MusicLibrary()
        await library.load(folder: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(await library.allTracks().isEmpty)
        await library.load(folder: nil)
        #expect(await library.status == .noFolder)
    }
}

@Suite struct HTTPParsingTests {
    private func parse(_ text: String) -> HTTPServer.Parsed { HTTPServer.parse(Data(text.utf8)) }

    @Test func aRequestWithABodyIsReadWhole() throws {
        let text = "POST /api HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nOrigin: http://a\r\n\r\nabcdGET"
        guard case let .request(request, rest) = parse(text) else {
            Issue.record("not parsed")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/api")
        #expect(request.body == Data("abcd".utf8))
        #expect(request.headers["origin"] == "http://a")
        #expect(rest == Data("GET".utf8))
    }

    @Test func theQueryIsSplitFromThePath() {
        guard case let .request(request, _) = parse("GET /imageproxy/ab%20c?size=160&x= HTTP/1.1\r\n\r\n") else {
            Issue.record("not parsed")
            return
        }
        #expect(request.path == "/imageproxy/ab c")
        #expect(request.query == ["size": "160", "x": ""])
    }

    @Test func aRequestStillArrivingWaits() {
        if case .incomplete = parse("POST /api HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc") {} else { Issue.record("should wait") }
        if case .incomplete = parse("POST /api HTTP/1.1\r\nContent-Le") {} else { Issue.record("should wait") }
    }

    @Test func nonsenseIsRefused() {
        if case .malformed = parse("hello\r\n\r\n") {} else { Issue.record("should be malformed") }
        if case .malformed = parse("POST /api HTTP/1.1\r\nContent-Length: -4\r\n\r\n") {} else { Issue.record("should be malformed") }
    }
}

@Suite struct ServerAPITests {
    /// A server's API over a library of the standard folder; nothing listens on the network.
    private func makeAPI(_ folder: MusicFolder) async throws -> ServerAPI {
        let library = MusicLibrary()
        await library.load(folder: folder.url)
        let group = PlaybackGroup(name: "Test", leadMs: 500)
        let store = try ServerStore(directory: folder.url.appendingPathComponent(".server"))
        return ServerAPI(name: "Test", serverID: "id", library: library, engine: PlaybackEngine(group: group),
                         group: group, store: store)
    }

    private func call(_ api: ServerAPI, _ command: String, _ arguments: [String: Any] = [:]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["command": command, "args": arguments])
        let response = await api.respond(to: HTTPRequest(method: "POST", path: "/api", query: [:], body: body))
        #expect(response.status == 200)
        return response.body
    }

    @Test func itemsDecodeAsTheAppsMediaItems() async throws {
        let folder = try MusicFolder(MusicFolder.standard)
        let api = try await makeAPI(folder)
        let albums = try JSONDecoder().decode([MediaItem].self, from: try await call(api, "music/albums/library_items"))
        #expect(albums.map(\.name) == ["Early", "Late"])
        #expect(albums[1].mediaType == .album)
        #expect(albums[1].artists == ["Zed"])
        #expect(albums[1].image?.proxyID == albums[1].itemID)
        let tracks = try JSONDecoder().decode([MediaItem].self, from: try await call(
            api, "music/albums/album_tracks", ["item_id": albums[1].itemID, "provider_instance_id_or_domain": "library"]))
        #expect(tracks.map(\.name) == ["First", "Second", "Third"])
        #expect(tracks[0].album == "Late")
        #expect(tracks[0].duration == 1)
        #expect(tracks[2].trackNumber == 3)
        #expect(tracks[0].uri == "library://track/\(tracks[0].itemID)")
        let found = try JSONDecoder().decode(SearchResults.self, from: try await call(
            api, "music/search", ["search_query": "late", "limit": 8]))
        #expect(found.albums.map(\.name) == ["Late"])
        #expect(found.tracks.count == 3)
        #expect(found.playlists.isEmpty)
    }

    @Test func theGroupIsTheOnePlayerOffered() async throws {
        let folder = try MusicFolder(MusicFolder.standard)
        let api = try await makeAPI(folder)
        let players = try JSONDecoder().decode([ServerPlayer].self, from: try await call(api, "players/all"))
        #expect(players.map(\.playerID) == ["group"])
        #expect(players[0].isGroup)
        #expect(players[0].isSelectable)
    }

    @Test func playingAnAlbumFromATrackQueuesTheWholeAlbum() async throws {
        let folder = try MusicFolder(MusicFolder.standard)
        let api = try await makeAPI(folder)
        let late = try #require(await api.library.allAlbums(matching: "late").first)
        _ = try await call(api, "player_queues/play_media", [
            "queue_id": "group", "media": ["library://album/\(late.id)"], "option": "replace",
            "start_item": "library://track/\(late.tracks[1].id)",
        ])
        var snapshot = await api.engine.snapshot()
        #expect(snapshot.state == .playing)
        #expect(snapshot.queue.map(\.title) == ["First", "Second", "Third"])
        #expect(snapshot.current?.title == "Second")
        let queue = try JSONDecoder().decode(QueueState.self, from: try await call(api, "player_queues/get"))
        #expect(queue.isPlaying)
        #expect(queue.current?.media?.name == "Second")
        _ = try await call(api, "player_queues/next")
        #expect(await api.engine.snapshot().current?.title == "Third")
        // Past the end of a queue that doesn't repeat, playback stops.
        _ = try await call(api, "player_queues/next")
        snapshot = await api.engine.snapshot()
        #expect(snapshot.state == .stopped)
        await api.engine.stop()
    }

    @Test func webPagesAndUnknownCommandsAreRefused() async throws {
        let folder = try MusicFolder(["A/B/01 C.wav"])
        let api = try await makeAPI(folder)
        let body = try JSONSerialization.data(withJSONObject: ["command": "players/all"])
        let fromPage = await api.respond(to: HTTPRequest(method: "POST", path: "/api", query: [:],
                                                         headers: ["origin": "http://example.com"], body: body))
        #expect(fromPage.status == 403)
        let unknown = try JSONSerialization.data(withJSONObject: ["command": "config/players/remove"])
        #expect(await api.respond(to: HTTPRequest(method: "POST", path: "/api", query: [:], body: unknown)).status == 400)
        #expect(await api.respond(to: HTTPRequest(method: "GET", path: "/elsewhere", query: [:], body: Data())).status == 404)
        #expect(await api.respond(to: HTTPRequest(method: "GET", path: "/imageproxy/none", query: [:], body: Data())).status == 404)
    }
}

@Suite struct QueueTests {
    private func makeEngine(_ folder: MusicFolder) async -> (PlaybackEngine, [LibraryTrack]) {
        let library = MusicLibrary()
        await library.load(folder: folder.url)
        let tracks = await library.allAlbums(matching: "late").first?.tracks ?? []
        return (PlaybackEngine(group: PlaybackGroup(name: "Test", leadMs: 500)), tracks)
    }

    @Test func insertionsGoWhereTheyAreAskedTo() async throws {
        let folder = try MusicFolder(MusicFolder.standard)
        let (engine, tracks) = await makeEngine(folder)
        // Into an empty queue, anything starts playing.
        await engine.enqueue([tracks[0]], .add)
        #expect(await engine.snapshot().state == .playing)
        await engine.enqueue([tracks[2]], .add)
        await engine.enqueue([tracks[1]], .next)
        var snapshot = await engine.snapshot()
        #expect(snapshot.queue.map(\.title) == ["First", "Second", "Third"])
        #expect(snapshot.current?.title == "First")
        await engine.enqueue([tracks[2]], .play)
        snapshot = await engine.snapshot()
        #expect(snapshot.queue.map(\.title) == ["First", "Third", "Second", "Third"])
        #expect(snapshot.current?.title == "Third")
        await engine.stop()
    }

    @Test func shuffleKeepsTheCurrentTrackAndUnshuffleRestoresTheOrder() async throws {
        let folder = try MusicFolder(MusicFolder.standard)
        let (engine, tracks) = await makeEngine(folder)
        await engine.enqueue(tracks, .replace, startAt: 1)
        await engine.setShuffle(true)
        var snapshot = await engine.snapshot()
        #expect(snapshot.shuffle)
        #expect(snapshot.queue.first?.title == "Second")
        #expect(Set(snapshot.queue) == Set(tracks))
        #expect(snapshot.current?.title == "Second")
        await engine.setShuffle(false)
        snapshot = await engine.snapshot()
        #expect(snapshot.queue == tracks)
        #expect(snapshot.current?.title == "Second")
        await engine.stop()
    }

    @Test func pauseKeepsThePlaceAndSeekMovesIt() async throws {
        let folder = try MusicFolder(MusicFolder.standard)
        let (engine, tracks) = await makeEngine(folder)
        await engine.enqueue(tracks, .replace)
        await engine.pause()
        var snapshot = await engine.snapshot()
        #expect(snapshot.state == .paused)
        #expect(snapshot.current?.title == "First")
        await engine.seek(to: 0.5)
        snapshot = await engine.snapshot()
        #expect(snapshot.elapsed == 0.5)
        // Past the end of the track, a seek is ignored.
        await engine.seek(to: 30)
        #expect(await engine.snapshot().elapsed == 0.5)
        await engine.previous()
        snapshot = await engine.snapshot()
        #expect(snapshot.state == .playing)
        #expect(snapshot.current?.title == "First")
        await engine.stop()
        #expect(await engine.snapshot().state == .stopped)
    }

    @Test func repeatAllWrapsAround() async throws {
        let folder = try MusicFolder(MusicFolder.standard)
        let (engine, tracks) = await makeEngine(folder)
        await engine.enqueue(tracks, .replace, startAt: 2)
        await engine.setRepeat("all")
        await engine.setRepeat("sideways")
        #expect(await engine.snapshot().repeatMode == "all")
        await engine.next()
        #expect(await engine.snapshot().current?.title == "First")
        await engine.stop()
    }

    @Test func aQueueOffersTransportCommandsAndSeekWithinTheTrack() async throws {
        let folder = try MusicFolder(MusicFolder.standard)
        let (engine, tracks) = await makeEngine(folder)
        #expect(await engine.controls().commands.isEmpty)
        await engine.enqueue(tracks, .replace)
        let controls = await engine.controls()
        #expect(controls.commands.contains("next"))
        #expect(controls.commands.contains("seek"))
        #expect(controls.seekMaxMs == 1_000)
        await engine.stop()
    }
}
