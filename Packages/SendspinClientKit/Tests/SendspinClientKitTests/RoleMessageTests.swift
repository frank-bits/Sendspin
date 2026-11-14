import Foundation
import Testing
@testable import SendspinClientKit

struct RoleMessageTests {
    @Test func decodesControllerAndMetadataAsMusicAssistantSendsThem() throws {
        let json = Data(#"""
        {"type":"server/state","payload":{
          "controller":{"supported_commands":["play","pause","volume","seek"],"volume":80,"muted":false,
                        "repeat":"all","shuffle":true,"seek_max_ms":188000},
          "metadata":{"timestamp":337318659306,"title":"First Day of My Life","artist":"Bright Eyes",
                      "album":"I'm Wide Awake, It's Morning","artwork_url":"http://192.0.2.1/art.jpg","track":6,
                      "progress":{"track_progress":1500,"track_duration":188000,"playback_speed":1000}}}}
        """#.utf8)
        let state = try MessageCoding.payload(ServerStateReceived.self, from: json)
        let controller = try #require(state.controller)
        #expect(controller.supportedCommands == ["play", "pause", "volume", "seek"])
        #expect(controller.volume == 80 && controller.repeatMode == "all" && controller.shuffle)
        #expect(controller.seekMaxMs == 188_000)
        let metadata = try #require(state.metadata)
        #expect(metadata.title == "First Day of My Life" && metadata.artist == "Bright Eyes")
        #expect(metadata.artworkURL == "http://192.0.2.1/art.jpg" && metadata.track == 6)
        #expect(metadata.progress?.trackDuration == 188_000)
    }

    @Test func decodesMetadataWithNothingPlaying() throws {
        let json = Data(#"{"type":"server/state","payload":{"metadata":{"timestamp":336852887938}}}"#.utf8)
        let metadata = try #require(try MessageCoding.payload(ServerStateReceived.self, from: json).metadata)
        #expect(metadata.title == nil && metadata.progress == nil)
    }

    @Test func decodesGroupUpdate() throws {
        let json = Data(#"{"type":"group/update","payload":{"playback_state":"playing","group_id":"g","group_name":"Kitchen"}}"#.utf8)
        let group = try MessageCoding.payload(GroupInfo.self, from: json)
        #expect(group.isPlaying && group.groupName == "Kitchen")
    }

    @Test func positionAdvancesWithSpeedAndStaysWithinTheTrack() {
        let playing = TrackMetadata.Progress(trackProgress: 1_000, trackDuration: 10_000, playbackSpeed: 1_000)
        #expect(playing.positionMs(elapsedUs: 0) == 1_000)
        #expect(playing.positionMs(elapsedUs: 2_500_000) == 3_500)
        #expect(playing.positionMs(elapsedUs: 60_000_000) == 10_000)
        #expect(playing.positionMs(elapsedUs: -5_000_000) == 0)
        let paused = TrackMetadata.Progress(trackProgress: 4_000, trackDuration: 10_000, playbackSpeed: 0)
        #expect(paused.positionMs(elapsedUs: 9_000_000) == 4_000)
        let fast = TrackMetadata.Progress(trackProgress: 0, trackDuration: 0, playbackSpeed: 1_500)
        #expect(fast.positionMs(elapsedUs: 2_000_000) == 3_000)  // unknown length: no upper bound
    }

    @Test func commandCarriesOnlyItsOwnField() throws {
        var controller = ClientCommandMessage.Controller(command: "seek")
        controller.positionMs = 42_000
        let data = try MessageCoding.encode(type: "client/command", payload: ClientCommandMessage(controller: controller))
        let message = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require((message["payload"] as? [String: Any])?["controller"] as? [String: Any])
        #expect(payload["command"] as? String == "seek")
        #expect(payload["position_ms"] as? Int == 42_000)
        #expect(payload.count == 2)
    }
}
