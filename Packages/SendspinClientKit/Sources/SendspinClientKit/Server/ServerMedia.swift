import Foundation

// What a server with a queue of music adds to sendspin-mac's live-sound server: track details
// for the metadata role, transport commands for the controller role, and stream/clear.

/// The `metadata` object of server/state (roles/metadata/v1.md).
public struct MetadataState: Encodable, Sendable, Equatable {
    public struct Progress: Encodable, Sendable, Equatable {
        /// Milliseconds into the track at `timestamp`.
        public var trackProgress: Int
        /// Milliseconds; 0 when unknown.
        public var trackDuration: Int
        /// Speed times 1000: 1000 while playing, 0 while paused.
        public var playbackSpeed: Int

        public init(trackProgress: Int, trackDuration: Int, playbackSpeed: Int) {
            self.trackProgress = trackProgress
            self.trackDuration = trackDuration
            self.playbackSpeed = playbackSpeed
        }

        enum CodingKeys: String, CodingKey {
            case trackProgress = "track_progress"
            case trackDuration = "track_duration"
            case playbackSpeed = "playback_speed"
        }
    }

    /// Server clock time, in microseconds, the state holds from.
    public var timestamp: Int64
    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var artworkURL: String?
    public var year: Int?
    public var track: Int?
    public var progress: Progress?

    /// Texts are cut to the lengths the role allows: 255 bytes, and 2048 for the URL.
    public init(timestamp: Int64, title: String? = nil, artist: String? = nil, albumArtist: String? = nil,
                album: String? = nil, artworkURL: String? = nil, year: Int? = nil, track: Int? = nil,
                progress: Progress? = nil) {
        self.timestamp = timestamp
        self.title = title?.truncated(toUTF8Bytes: 255)
        self.artist = artist?.truncated(toUTF8Bytes: 255)
        self.albumArtist = albumArtist?.truncated(toUTF8Bytes: 255)
        self.album = album?.truncated(toUTF8Bytes: 255)
        self.artworkURL = artworkURL.flatMap { $0.utf8.count <= 2048 ? $0 : nil }
        self.year = year
        self.track = track.flatMap { $0 >= 1 ? $0 : nil }
        self.progress = progress
    }

    enum CodingKeys: String, CodingKey {
        case timestamp, title, artist, album, year, track, progress
        case albumArtist = "album_artist"
        case artworkURL = "artwork_url"
    }
}

/// stream/clear (messaging.md): drop what's buffered and go on with what follows.
public struct StreamClear: Encodable, Sendable {
    public var serverTransmitted: Int64
    public var roles: [String]?

    enum CodingKeys: String, CodingKey {
        case roles
        case serverTransmitted = "server_transmitted"
    }
}

/// What the group's queue offers its controllers, beyond volume and mute.
public struct MediaControls: Sendable, Equatable {
    /// Of 'play', 'pause', 'stop', 'next', 'previous', 'repeat_off', 'repeat_one',
    /// 'repeat_all', 'shuffle', 'unshuffle', 'seek', 'seek_relative'.
    public var commands: [String]
    /// "off", "one" or "all".
    public var repeatMode: String
    public var shuffle: Bool
    /// The furthest a seek may go, in milliseconds; needed for 'seek'.
    public var seekMaxMs: Int?

    public init(commands: [String], repeatMode: String = "off", shuffle: Bool = false, seekMaxMs: Int? = nil) {
        self.commands = commands
        self.repeatMode = repeatMode
        self.shuffle = shuffle
        self.seekMaxMs = seekMaxMs
    }
}

/// A group's identifier: 32 random bytes, base64url without padding (messaging.md, group/update).
public enum GroupID {
    public static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Base64URL.encode(Data(bytes))
    }
}
