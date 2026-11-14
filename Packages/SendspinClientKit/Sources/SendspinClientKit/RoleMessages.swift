import Foundation

// The controller and metadata roles' messages and group/update
// (roles/controller/v1.md, roles/metadata/v1.md, messaging.md).

/// group/update: the group this client is part of.
public struct GroupInfo: Decodable, Sendable, Equatable {
    /// "playing" or "stopped"; a paused group reports "stopped".
    public var playbackState: String
    public var groupID: String
    public var groupName: String

    public var isPlaying: Bool { playbackState == "playing" }

    enum CodingKeys: String, CodingKey {
        case playbackState = "playback_state"
        case groupID = "group_id"
        case groupName = "group_name"
    }
}

/// The controller object of server/state: what the group can be told, and its current settings.
public struct ControllerState: Decodable, Sendable, Equatable {
    public var supportedCommands: [String]
    /// Volume of the whole group, 0-100.
    public var volume: Int
    public var muted: Bool
    /// "off", "one" or "all".
    public var repeatMode: String
    public var shuffle: Bool
    /// The furthest position a seek may target; present when "seek" is supported.
    public var seekMaxMs: Int?

    enum CodingKeys: String, CodingKey {
        case volume, muted, shuffle
        case supportedCommands = "supported_commands"
        case repeatMode = "repeat"
        case seekMaxMs = "seek_max_ms"
    }
}

/// The metadata object of server/state.
public struct TrackMetadata: Decodable, Sendable, Equatable {
    public struct Progress: Decodable, Sendable, Equatable {
        /// Position in ms since the start of the track, measured at the metadata's timestamp.
        public var trackProgress: Int
        /// Track length in ms; 0 when unknown or unlimited.
        public var trackDuration: Int
        /// Speed × 1000: 1000 is normal, 0 paused.
        public var playbackSpeed: Int

        enum CodingKeys: String, CodingKey {
            case trackProgress = "track_progress"
            case trackDuration = "track_duration"
            case playbackSpeed = "playback_speed"
        }

        /// The position `elapsedUs` after the metadata took effect, clamped to the track
        /// (roles/metadata/v1.md, Calculating current track position).
        public func positionMs(elapsedUs: Int64) -> Int {
            let calculated = Int64(trackProgress) + elapsedUs * Int64(playbackSpeed) / 1_000_000
            let upper = trackDuration != 0 ? Int64(trackDuration) : Int64.max
            return Int(max(0, min(calculated, upper)))
        }
    }

    /// Server clock time in µs at which this metadata takes effect.
    public var timestamp: Int64
    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var artworkURL: String?
    public var year: Int?
    public var track: Int?
    public var progress: Progress?

    enum CodingKeys: String, CodingKey {
        case timestamp, title, artist, album, year, track, progress
        case albumArtist = "album_artist"
        case artworkURL = "artwork_url"
    }
}

struct ServerStateReceived: Decodable {
    var metadata: TrackMetadata?
    var controller: ControllerState?
}

/// client/command with a controller object. Only the field its command needs is set.
struct ClientCommandMessage: Encodable, Sendable {
    struct Controller: Encodable, Sendable {
        var command: String
        var volume: Int?
        var mute: Bool?
        var positionMs: Int?
        var offsetMs: Int?

        enum CodingKeys: String, CodingKey {
            case command, volume, mute
            case positionMs = "position_ms"
            case offsetMs = "offset_ms"
        }
    }

    var controller: Controller
}
