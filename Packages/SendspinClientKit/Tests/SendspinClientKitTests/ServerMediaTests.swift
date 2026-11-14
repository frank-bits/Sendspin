import Foundation
import Testing
@testable import SendspinClientKit

/// What a server with a queue adds to the live-sound server: transport commands for
/// controllers, track details, and group identifiers.
@Suite struct ServerMediaTests {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test func aQueuesCommandsComeBeforeVolumeAndSwitch() throws {
        let member = ControllerMember(inGroup: true, volume: 40, muted: false, canSetVolume: true, canMute: true)
        let media = MediaControls(commands: ["play", "pause", "seek"], repeatMode: "all", shuffle: true, seekMaxMs: 215_000)
        let state = try json(GroupControllerState(group: [member], media: media))
        #expect(state["supported_commands"] as? [String] == ["play", "pause", "seek", "volume", "mute", "switch"])
        #expect(state["repeat"] as? String == "all")
        #expect(state["shuffle"] as? Bool == true)
        #expect(state["seek_max_ms"] as? Int == 215_000)
        #expect(state["volume"] as? Int == 40)
    }

    @Test func seekMaxIsOnlySentWithSeek() throws {
        let media = MediaControls(commands: ["play", "seek_relative"], seekMaxMs: 215_000)
        let state = try json(GroupControllerState(group: [], media: media))
        #expect(state["seek_max_ms"] == nil)
        // Without a queue, a group offers what it did before.
        let plain = try json(GroupControllerState(group: []))
        #expect(plain["supported_commands"] as? [String] == ["switch"])
        #expect(plain["repeat"] as? String == "off")
    }

    @Test func controllerCommandsCarryTheirSeekFields() throws {
        let data = Data(#"{"type":"client/command","payload":{"controller":{"command":"seek","position_ms":61500}}}"#.utf8)
        let command = try MessageCoding.payload(ClientCommand.self, from: data)
        #expect(command.controller?.command == "seek")
        #expect(command.controller?.positionMs == 61_500)
        let relative = Data(#"{"type":"client/command","payload":{"controller":{"command":"seek_relative","offset_ms":-10000}}}"#.utf8)
        #expect(try MessageCoding.payload(ClientCommand.self, from: relative).controller?.offsetMs == -10_000)
    }

    @Test func trackDetailsUseTheRolesFieldNamesAndLimits() throws {
        let long = String(repeating: "é", count: 200)  // 400 bytes
        let details = MetadataState(timestamp: 5, title: long, artist: "A", albumArtist: "B", album: "C",
                                    artworkURL: "http://192.168.1.2:8929/imageproxy/x", year: 2019, track: 0,
                                    progress: .init(trackProgress: 1_500, trackDuration: 215_000, playbackSpeed: 1_000))
        let state = try json(details)
        #expect((state["title"] as? String)?.utf8.count == 254)
        #expect(state["album_artist"] as? String == "B")
        #expect(state["artwork_url"] as? String == "http://192.168.1.2:8929/imageproxy/x")
        // A track number is at least 1, or absent.
        #expect(state["track"] == nil)
        let progress = try #require(state["progress"] as? [String: Any])
        #expect(progress["track_progress"] as? Int == 1_500)
        #expect(progress["track_duration"] as? Int == 215_000)
        #expect(progress["playback_speed"] as? Int == 1_000)
    }

    @Test func aStateWithNothingPlayingIsOnlyATimestamp() throws {
        let state = try json(ServerState(metadata: MetadataState(timestamp: 7)))
        #expect((state["metadata"] as? [String: Any])?.keys.sorted() == ["timestamp"])
    }

    @Test func groupIdentifiersAre32BytesInBase64URL() {
        let id = GroupID.random()
        #expect(id.count == 43)
        #expect(Base64URL.decode(id)?.count == 32)
        #expect(GroupID.random() != id)
    }

    @Test func aClearNamesItsRoles() throws {
        let clear = try json(StreamClear(serverTransmitted: 9, roles: ["player"]))
        #expect(clear["server_transmitted"] as? Int == 9)
        #expect(clear["roles"] as? [String] == ["player"])
    }
}
