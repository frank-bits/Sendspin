import Foundation

/// What a player's queue is doing: the item it's on, how far in, and its play settings.
public struct QueueState: Decodable, Sendable, Equatable {
    public struct Item: Decodable, Sendable, Equatable {
        /// The item as the queue names it, e.g. "Artist - Title": used when there's no `media`.
        public var name: String
        /// Seconds; nil or 0 when unknown, as for live radio.
        public var duration: Int?
        public var media: MediaItem?
        public var image: MediaImage?

        enum CodingKeys: String, CodingKey {
            case name, duration, image
            case media = "media_item"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
            duration = (try? container.decodeIfPresent(Double.self, forKey: .duration)).map { Int($0) }
            media = try? container.decodeIfPresent(MediaItem.self, forKey: .media)
            image = (try? container.decodeIfPresent(MediaImage.self, forKey: .image)) ?? media?.image
        }
    }

    public var isPlaying: Bool
    public var shuffle: Bool
    /// "off", "one" or "all".
    public var repeatMode: String
    /// Seconds into the current item when the server last noted it, at `elapsedUpdated`.
    public var elapsed: Double
    public var elapsedUpdated: Date?
    public var current: Item?

    enum CodingKeys: String, CodingKey {
        case state
        case shuffle = "shuffle_enabled"
        case repeatMode = "repeat_mode"
        case elapsed = "elapsed_time"
        case elapsedUpdated = "elapsed_time_last_updated"
        case current = "current_item"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isPlaying = (try? container.decodeIfPresent(String.self, forKey: .state)) == "playing"
        shuffle = (try? container.decodeIfPresent(Bool.self, forKey: .shuffle)) ?? false
        repeatMode = (try? container.decodeIfPresent(String.self, forKey: .repeatMode)) ?? "off"
        elapsed = (try? container.decodeIfPresent(Double.self, forKey: .elapsed)) ?? 0
        elapsedUpdated = (try? container.decodeIfPresent(Double.self, forKey: .elapsedUpdated))
            .map(Date.init(timeIntervalSince1970:))
        current = try? container.decodeIfPresent(Item.self, forKey: .current)
    }

    /// The position in the current item at `now`, in seconds: the server's last figure, moved
    /// on by the time since while playing, and kept within the item.
    public func position(at now: Date = Date()) -> Double {
        var position = elapsed
        if isPlaying, let elapsedUpdated { position += max(0, now.timeIntervalSince(elapsedUpdated)) }
        if let duration = current?.duration, duration > 0 { position = min(position, Double(duration)) }
        return max(0, position)
    }
}

/// A player's or group's volume, 0-100, and whether it's muted.
public struct PlayerLevels: Decodable, Sendable, Equatable {
    public var volume: Int?
    public var muted: Bool

    enum CodingKeys: String, CodingKey {
        case volume = "volume_level"
        case muted = "volume_muted"
        case groupVolume = "group_volume"
        case groupMuted = "group_volume_muted"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A group has no level of its own: the one for the group as a whole stands in.
        let own = try? container.decodeIfPresent(Int.self, forKey: .volume)
        volume = own ?? (try? container.decodeIfPresent(Int.self, forKey: .groupVolume))
        muted = (try? container.decodeIfPresent(Bool.self, forKey: .muted))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .groupMuted)) ?? false
    }
}

extension MusicAssistantAPI {
    public func queueState(_ queueID: String) async throws -> QueueState {
        try await result(request("player_queues/get", ["queue_id": queueID]))
    }

    public func levels(of player: ServerPlayer) async throws -> PlayerLevels {
        try await result(request("players/get", ["player_id": player.playerID]))
    }

    /// A queue command that takes nothing but the queue: "play_pause", "next", "previous".
    public func queueCommand(_ name: String, queueID: String) async throws {
        _ = try await data(request("player_queues/\(name)", ["queue_id": queueID]))
    }

    /// Move to `position` seconds into the current item.
    public func seek(queueID: String, position: Int) async throws {
        _ = try await data(request("player_queues/seek", ["queue_id": queueID, "position": position]))
    }

    public func setShuffle(_ on: Bool, queueID: String) async throws {
        _ = try await data(request("player_queues/shuffle", ["queue_id": queueID, "shuffle_enabled": on]))
    }

    /// `mode` is "off", "one" or "all".
    public func setRepeat(_ mode: String, queueID: String) async throws {
        _ = try await data(request("player_queues/repeat", ["queue_id": queueID, "repeat_mode": mode]))
    }

    /// Set a player's volume, or a group's as a whole, 0-100.
    public func setVolume(_ level: Int, of player: ServerPlayer) async throws {
        let command = player.isGroup ? "players/cmd/group_volume" : "players/cmd/volume_set"
        _ = try await data(request(command, ["player_id": player.playerID, "volume_level": min(100, max(0, level))]))
    }

    public func setMuted(_ muted: Bool, of player: ServerPlayer) async throws {
        let command = player.isGroup ? "players/cmd/group_volume_mute" : "players/cmd/volume_mute"
        _ = try await data(request(command, ["player_id": player.playerID, "muted": muted]))
    }
}
