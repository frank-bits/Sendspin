import Foundation
import Testing
@testable import MusicAssistantKit

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@Suite struct MediaItemTests {
    /// A library track as `music/search` returns it, cut down to the fields that matter.
    static let track = """
    {"item_id": "63726", "provider": "library", "name": "All Around You", "version": "", "uri": "library://track/63726",
     "media_type": "track", "duration": 215, "track_number": 6,
     "metadata": {"images": [{"type": "fanart", "path": "https://example.com/f.jpg", "provider": "p",
                              "remotely_accessible": true, "proxy_id": "fan"},
                             {"type": "thumb", "path": "https://example.com/t.jpg", "provider": "p",
                              "remotely_accessible": true, "proxy_id": "thumb"}]},
     "artists": [{"item_id": "4375", "provider": "library", "name": "Sturgill Simpson", "uri": "library://artist/4375",
                  "media_type": "artist", "image": null}],
     "album": {"item_id": "7178", "provider": "library", "name": "A Sailor's Guide to Earth",
               "uri": "library://album/7178", "media_type": "album",
               "image": {"type": "thumb", "path": "https://example.com/a.jpg", "provider": "p",
                         "remotely_accessible": true, "proxy_id": "album"}}}
    """

    @Test func decodesATrack() throws {
        let item = try decode(MediaItem.self, Self.track)
        #expect(item.id == "library://track/63726")
        #expect(item.mediaType == .track)
        #expect(item.artists == ["Sturgill Simpson"])
        #expect(item.album == "A Sailor's Guide to Earth")
        #expect(item.duration == 215)
        #expect(item.trackNumber == 6)
        #expect(item.image?.proxyID == "thumb")
        #expect(item.subtitle == "Sturgill Simpson — A Sailor's Guide to Earth")
    }

    @Test func decodesAShortItemWithItsOwnImage() throws {
        let item = try decode(MediaItem.self, """
        {"item_id": "ra.u-1", "provider": "apple_music--x", "name": "A Station", "version": "Live",
         "uri": "apple_music--x://playlist/ra.u-1", "media_type": "playlist", "year": null,
         "image": {"type": "thumb", "path": "/collage/1.jpg", "provider": "builtin",
                   "remotely_accessible": false, "proxy_id": "abc"}}
        """)
        #expect(item.provider == "apple_music--x")
        #expect(item.title == "A Station (Live)")
        #expect(item.image?.proxyID == "abc")
        #expect(item.subtitle == nil)
    }

    @Test func fallsBackToTheAlbumImage() throws {
        let item = try decode(MediaItem.self, """
        {"item_id": "1", "provider": "library", "name": "T", "uri": "library://track/1", "media_type": "track",
         "album": {"name": "A", "image": {"path": "https://example.com/a.jpg", "proxy_id": "album"}}}
        """)
        #expect(item.image?.proxyID == "album")
    }

    @Test func audiobooksUseTheirAuthors() throws {
        let item = try decode(MediaItem.self, """
        {"item_id": "1", "provider": "library", "name": "B", "uri": "library://audiobook/1",
         "media_type": "audiobook", "authors": ["An Author"], "duration": 3600.5}
        """)
        #expect(item.artists == ["An Author"])
        #expect(item.duration == 3600)
    }

    @Test func unknownKindsStillDecode() throws {
        let item = try decode(MediaItem.self, """
        {"item_id": "1", "provider": "p", "name": "N", "uri": "p://hologram/1", "media_type": "hologram"}
        """)
        #expect(item.mediaType.rawValue == "hologram")
        #expect(!item.mediaType.hasChildren)
    }

    @Test func aListDropsWhatItCannotDecode() throws {
        let list = try decode(LossyList<MediaItem>.self, """
        [{"item_id": "1", "provider": "p", "name": "N", "uri": "p://track/1", "media_type": "track"},
         {"name": "no id"}, "text", 7, null,
         {"item_id": "2", "provider": "p", "name": "M", "uri": "p://track/2", "media_type": "track"}]
        """)
        #expect(list.elements.map(\.itemID) == ["1", "2"])
    }

    @Test func searchResultsKeepOnlyKindsThatFoundSomething() throws {
        let results = try decode(SearchResults.self, """
        {"artists": [], "albums": [{"item_id": "1", "provider": "p", "name": "N", "uri": "p://album/1",
                                    "media_type": "album"}], "genres": [], "tracks": null}
        """)
        #expect(results.sections.map(\.type) == [.album])
        #expect(try decode(SearchResults.self, "{}").isEmpty)
    }
}

@Suite struct MediaImageTests {
    let server = URL(string: "http://192.168.1.20:8095")!

    @Test func proxiedImagesAskForASizeTheServerAllows() {
        let image = MediaImage(path: "/collage/1.jpg", proxyID: "abc")
        #expect(image.url(server: server, points: 44)?.absoluteString == "http://192.168.1.20:8095/imageproxy/abc?size=160")
        #expect(image.url(server: server, points: 128)?.absoluteString == "http://192.168.1.20:8095/imageproxy/abc?size=256")
        #expect(image.url(server: server, points: 2000)?.absoluteString == "http://192.168.1.20:8095/imageproxy/abc?size=1024")
    }

    @Test func withoutAProxyOnlyRemoteImagesLoad() {
        #expect(MediaImage(path: "https://example.com/a.jpg", remotelyAccessible: true)
            .url(server: server, points: 44)?.absoluteString == "https://example.com/a.jpg")
        #expect(MediaImage(path: "/local/a.jpg").url(server: server, points: 44) == nil)
    }
}

@Suite struct MusicAssistantAPITests {
    let api = MusicAssistantAPI(baseURL: URL(string: "http://192.168.1.20:8095")!, token: " secret\n")

    @Test func requestsCarryTheCommandItsArgumentsAndTheToken() throws {
        let request = try api.request("music/albums/library_items", ["search": nil, "limit": 50, "offset": 0])
        #expect(request.url?.absoluteString == "http://192.168.1.20:8095/api")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["command"] as? String == "music/albums/library_items")
        let arguments = body?["args"] as? [String: Any]
        #expect(arguments?.keys.sorted() == ["limit", "offset"])
        #expect(arguments?["limit"] as? Int == 50)
    }

    @Test func thePlayerForThisDeviceIsTheOneWrappingItsSendspinClient() throws {
        let players = try decode(LossyList<ServerPlayer>.self, """
        [{"player_id": "RINCON_1", "output_protocols": []},
         {"player_id": "up4e763bc6", "output_protocols": [{"output_protocol_id": "client-key", "name": "Sendspin"}]},
         {"player_id": "bare-client"}]
        """).elements
        #expect(MusicAssistantAPI.player(forSendspinClient: "client-key", in: players)?.playerID == "up4e763bc6")
        #expect(MusicAssistantAPI.player(forSendspinClient: "bare-client", in: players)?.playerID == "bare-client")
        #expect(MusicAssistantAPI.player(forSendspinClient: "absent", in: players) == nil)
    }

    @Test func onlyPlayersThatCanTakeMusicAreSelectable() throws {
        let players = try decode(LossyList<ServerPlayer>.self, """
        [{"player_id": "g", "display_name": "Indoor", "name": "x", "type": "group", "available": true,
          "enabled": true, "hide_in_ui": false, "synced_to": null, "playback_state": "playing"},
         {"player_id": "off", "name": "Off", "type": "player", "available": false, "enabled": true},
         {"player_id": "hidden", "name": "Light", "type": "light", "available": true, "hide_in_ui": true},
         {"player_id": "follower", "name": "Kitchen", "type": "player", "available": true, "synced_to": "g",
          "active_group": "g"},
         {"player_id": "bare"}]
        """).elements
        #expect(players.map(\.isSelectable) == [true, false, false, false, true])
        #expect(players[0].name == "Indoor")
        #expect(players[0].isGroup && players[0].isPlaying)
        #expect(players[4].name == "bare")
        #expect(players[3].activeGroup == "g")
        #expect(players[0].activeGroup == nil)
    }

    @Test func libraryCommandsFollowTheKind() {
        #expect(MediaType.radio.apiBase == "radios")
        #expect(MediaType.audiobook.apiBase == "audiobooks")
        #expect(MediaType.libraryTypes.allSatisfy { !$0.apiBase.isEmpty })
    }
}

@Suite struct QueueStateTests {
    static let playing = """
    {"queue_id": "g", "state": "playing", "shuffle_enabled": true, "repeat_mode": "all",
     "elapsed_time": 89.4, "elapsed_time_last_updated": 1000.0,
     "current_item": {"name": "Black Flag - Rise Above", "duration": 146,
                      "media_item": {"item_id": "1", "provider": "library", "name": "Rise Above",
                                     "uri": "library://track/1", "media_type": "track",
                                     "artists": [{"name": "Black Flag"}], "album": {"name": "Damaged"},
                                     "metadata": {"images": [{"type": "thumb", "path": "p", "proxy_id": "img"}]}}}}
    """

    @Test func decodesWhatIsPlaying() throws {
        let queue = try decode(QueueState.self, Self.playing)
        #expect(queue.isPlaying && queue.shuffle)
        #expect(queue.repeatMode == "all")
        #expect(queue.current?.media?.artists == ["Black Flag"])
        #expect(queue.current?.image?.proxyID == "img")
        #expect(queue.current?.duration == 146)
    }

    @Test func thePositionMovesOnOnlyWhilePlayingAndStopsAtTheEnd() throws {
        let queue = try decode(QueueState.self, Self.playing)
        #expect(abs(queue.position(at: Date(timeIntervalSince1970: 1010)) - 99.4) < 0.001)
        #expect(queue.position(at: Date(timeIntervalSince1970: 5000)) == 146)
        // A clock behind the server's must not run the position backwards.
        #expect(abs(queue.position(at: Date(timeIntervalSince1970: 900)) - 89.4) < 0.001)
        let idle = try decode(QueueState.self, #"{"state": "idle", "elapsed_time": 12, "elapsed_time_last_updated": 1000}"#)
        #expect(idle.position(at: Date(timeIntervalSince1970: 2000)) == 12)
        #expect(idle.current == nil && !idle.isPlaying)
    }

    @Test func aGroupsLevelStandsInWhereAPlayerHasNone() throws {
        let group = try decode(PlayerLevels.self, #"{"volume_level": null, "group_volume": 56, "volume_muted": null, "group_volume_muted": true}"#)
        #expect(group.volume == 56 && group.muted)
        let player = try decode(PlayerLevels.self, #"{"volume_level": 30, "group_volume": 56, "volume_muted": false}"#)
        #expect(player.volume == 30 && !player.muted)
    }
}
