import Foundation

extension MusicAssistantAPI {
    /// The signed-in user's name: also the check that a token works.
    public func userName() async throws -> String {
        struct User: Decodable {
            var username: String
            var displayName: String?

            enum CodingKeys: String, CodingKey {
                case username
                case displayName = "display_name"
            }
        }
        let user: User = try await result(request("auth/me"))
        return user.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? user.username
    }

    // MARK: Finding music

    /// Search the library and every music provider; up to `limit` items of each kind.
    public func search(_ query: String, limit: Int = 8) async throws -> SearchResults {
        try await result(request("music/search", ["search_query": query, "limit": limit]))
    }

    public func recentlyPlayed(limit: Int = 12) async throws -> [MediaItem] {
        try await items(request("music/recently_played_items", ["limit": limit]))
    }

    /// One page of the library's items of a kind, optionally only those matching `search`.
    public func libraryItems(_ type: MediaType, search: String? = nil, limit: Int = 50,
                             offset: Int = 0) async throws -> [MediaItem] {
        let search = search.flatMap { $0.isEmpty ? nil : $0 }
        return try await items(request("music/\(type.apiBase)/library_items",
                                       ["search": search, "limit": limit, "offset": offset]))
    }

    /// What `item` holds: an album's or playlist's tracks, an artist's albums, a podcast's
    /// episodes. Empty for kinds that hold nothing.
    public func children(of item: MediaItem) async throws -> [MediaItem] {
        let command: String
        switch item.mediaType {
        case .album: command = "music/albums/album_tracks"
        case .playlist: command = "music/playlists/playlist_tracks"
        case .artist: command = "music/artists/artist_albums"
        case .podcast: command = "music/podcasts/podcast_episodes"
        default: return []
        }
        return try await items(request(command, ["item_id": item.itemID,
                                                 "provider_instance_id_or_domain": item.provider]))
    }

    private func items(_ request: URLRequest) async throws -> [MediaItem] {
        try await result(request, as: LossyList<MediaItem>.self).elements
    }

    // MARK: Playing it

    /// Every player and group the server knows, including those that can't be played to now.
    public func players() async throws -> [ServerPlayer] {
        try await result(request("players/all"), as: LossyList<ServerPlayer>.self).elements
    }

    /// The player standing for the Sendspin client `clientID`, or nil when the server has
    /// none. Music Assistant wraps a Sendspin client in a player of its own, with the client
    /// as its output; music is queued under that player's id.
    public static func player(forSendspinClient clientID: String, in players: [ServerPlayer]) -> ServerPlayer? {
        players.first { $0.outputProtocols.contains { $0.outputProtocolID == clientID } }
            ?? players.first { $0.playerID == clientID }
    }

    /// Play `uris` on a queue. With no `option` the server applies its own default for the
    /// kind of item. `startItem` is the URI of the track to start an album or playlist from.
    public func play(_ uris: [String], queueID: String, option: QueueOption? = nil, startItem: String? = nil,
                     shuffle: Bool? = nil) async throws {
        _ = try await data(request("player_queues/play_media", [
            "queue_id": queueID, "media": uris, "option": option?.rawValue, "start_item": startItem,
            "shuffle": shuffle,
        ]))
    }
}
