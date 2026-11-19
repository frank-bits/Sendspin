import Foundation
import MusicAssistantKit
import SendspinClientKit
import Testing
@testable import TandemServerKit

/// A stream of silence that arrives at the speed it plays, a tenth of a second at a time.
final class FakeStream: LiveStream, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var sent = 0
    private let started = Date()
    private(set) var closed = false

    init(blocks: Int) { remaining = blocks }

    func read() -> LiveRead {
        lock.withLock {
            guard remaining > 0 else { return .ended }
            guard Date().timeIntervalSince(started) >= Double(sent) * 0.1 else { return .wait }
            remaining -= 1
            sent += 1
            return .block(PCMBuffer(samples: [Float](repeating: 0, count: 9_600), sampleRate: 48_000, channels: 2))
        }
    }

    func close() { lock.withLock { closed = true } }
    var isClosed: Bool { lock.withLock { closed } }
}

/// A streaming service with one song and one album.
final class FakeProvider: StreamingProvider, @unchecked Sendable {
    let id = "fake"
    private let lock = NSLock()
    private var opened: [(offset: Double, stream: FakeStream)] = []
    let blocks: Int

    init(blocks: Int = 5) { self.blocks = blocks }

    static let song = LibraryTrack.streamed(provider: "fake", id: "fake-1", title: "Streamed", artist: "Someone",
                                            album: "Online", albumID: "fake-9", duration: 0.5,
                                            artwork: "https://example.com/art.jpg")

    func search(_ query: String, limit: Int) async -> (tracks: [LibraryTrack], albums: [LibraryAlbum]) {
        ([Self.song], [.streamed(id: "fake-9", name: "Online", artist: "Someone", artwork: "https://example.com/art.jpg")])
    }
    func track(_ id: String) async -> LibraryTrack? { id == "fake-1" ? Self.song : nil }
    func albumTracks(_ albumID: String) async -> [LibraryTrack] { albumID == "fake-9" ? [Self.song] : [] }
    func open(_ track: LibraryTrack, at offset: Double) -> LiveStream {
        let stream = FakeStream(blocks: blocks)
        lock.withLock { opened.append((offset, stream)) }
        return stream
    }

    var offsets: [Double] { lock.withLock { opened.map(\.offset) } }
    var streams: [FakeStream] { lock.withLock { opened.map(\.stream) } }
}

@Suite struct StreamingTests {
    private func wait(seconds: Double = 5, until done: () async -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if await done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func aStreamedTrackPlaysThenTheFileAfterIt() async throws {
        let folder = try MusicFolder(MusicFolder.standard)
        let library = MusicLibrary()
        await library.load(folder: folder.url)
        let file = try #require(await library.allAlbums(matching: "late").first?.tracks.first)
        let provider = FakeProvider()
        let engine = PlaybackEngine(group: PlaybackGroup(name: "Test", leadMs: 500))
        await engine.attach(providers: [provider])
        await engine.enqueue([FakeProvider.song, file], .replace)
        #expect(await engine.snapshot().current?.title == "Streamed")
        #expect(await wait { provider.offsets == [0] })
        // The stream ends after half a second; the file follows by itself.
        #expect(await wait { await engine.snapshot().current?.title == "First" })
        #expect(provider.streams.first?.isClosed == true)
        await engine.stop()
    }

    @Test func pausingClosesTheStreamAndPlayingOpensItWhereItWas() async throws {
        let provider = FakeProvider(blocks: 100)
        let engine = PlaybackEngine(group: PlaybackGroup(name: "Test", leadMs: 500))
        await engine.attach(providers: [provider])
        var song = FakeProvider.song
        song.duration = 10
        await engine.enqueue([song], .replace)
        #expect(await wait { await engine.snapshot().elapsed > 0.2 })
        await engine.pause()
        #expect(provider.streams.first?.isClosed == true)
        let place = await engine.snapshot().elapsed
        await engine.play()
        #expect(await wait { provider.offsets.count == 2 })
        #expect(provider.offsets.last == place)
        await engine.stop()
        #expect(provider.streams.last?.isClosed == true)
    }

    @Test func aTrackWithNoProviderHereIsSkipped() async throws {
        let engine = PlaybackEngine(group: PlaybackGroup(name: "Test", leadMs: 500))
        await engine.enqueue([FakeProvider.song], .replace)
        #expect(await wait { await engine.snapshot().state == .stopped })
    }

    @Test func searchAndPlayReachTheProvider() async throws {
        let folder = try MusicFolder(MusicFolder.standard)
        let library = MusicLibrary()
        await library.load(folder: folder.url)
        let group = PlaybackGroup(name: "Test", leadMs: 500)
        let store = try ServerStore(directory: folder.url.appendingPathComponent(".server"))
        let speakers = AirPlaySpeakers(group: group, store: store) { _ in }
        let zones = Zones(home: group, store: store, speakers: speakers) { _ in }
        let provider = FakeProvider(blocks: 100)
        await zones.start(providers: [provider]) { _ in nil }
        let api = ServerAPI(name: "Test", serverID: "id", library: library, zones: zones, store: store,
                            speakers: speakers, providers: [provider])
        func call(_ command: String, _ arguments: [String: Any]) async throws -> Data {
            let body = try JSONSerialization.data(withJSONObject: ["command": command, "args": arguments])
            let response = await api.respond(to: HTTPRequest(method: "POST", path: "/api", query: [:], body: body))
            #expect(response.status == 200)
            return response.body
        }
        let found = try JSONDecoder().decode(SearchResults.self, from: try await call("music/search", ["search_query": "first"]))
        let streamed = try #require(found.tracks.first { $0.name == "Streamed" })
        #expect(found.tracks.contains { $0.name == "First" })
        #expect(streamed.image?.url(server: URL(string: "http://host:1")!, points: 40)?.absoluteString == "https://example.com/art.jpg")
        #expect(found.albums.contains { $0.name == "Online" })
        let tracks = try JSONDecoder().decode([MediaItem].self, from: try await call("music/albums/album_tracks", ["item_id": "fake-9"]))
        #expect(tracks.map(\.name) == ["Streamed"])
        _ = try await call("player_queues/play_media", ["media": [streamed.uri]])
        let engine = try #require(await zones.zone(nil)).engine
        #expect(await engine.snapshot().current?.id == "fake-1")
        await engine.stop()
    }
}
