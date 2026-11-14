import Foundation

/// A kind of media, by the name Music Assistant gives it. Open-ended: servers add kinds.
public struct MediaType: RawRepresentable, Hashable, Sendable, Decodable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }

    public static let artist = MediaType(rawValue: "artist")
    public static let album = MediaType(rawValue: "album")
    public static let track = MediaType(rawValue: "track")
    public static let playlist = MediaType(rawValue: "playlist")
    public static let radio = MediaType(rawValue: "radio")
    public static let podcast = MediaType(rawValue: "podcast")
    public static let podcastEpisode = MediaType(rawValue: "podcast_episode")
    public static let audiobook = MediaType(rawValue: "audiobook")
    public static let folder = MediaType(rawValue: "folder")

    /// The kinds the library lists, in the order to offer them.
    public static let libraryTypes: [MediaType] = [.artist, .album, .track, .playlist, .radio, .podcast, .audiobook]

    /// The middle of this kind's commands, e.g. `music/albums/library_items`.
    var apiBase: String { rawValue + "s" }

    /// The items of this kind open onto a list of others, rather than only play.
    public var hasChildren: Bool { [.artist, .album, .playlist, .podcast].contains(self) }
}

/// An image the server holds for an item.
public struct MediaImage: Decodable, Hashable, Sendable {
    public var path: String
    /// The server's short id for the image, to fetch it resized through `/imageproxy/`.
    public var proxyID: String?
    public var remotelyAccessible: Bool
    public var type: String?

    static let proxySizes = [80, 160, 256, 512, 1024]

    enum CodingKeys: String, CodingKey {
        case path, type
        case proxyID = "proxy_id"
        case remotelyAccessible = "remotely_accessible"
    }

    public init(path: String, proxyID: String? = nil, remotelyAccessible: Bool = false, type: String? = "thumb") {
        self.path = path
        self.proxyID = proxyID
        self.remotelyAccessible = remotelyAccessible
        self.type = type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        proxyID = try? container.decodeIfPresent(String.self, forKey: .proxyID)
        remotelyAccessible = (try? container.decodeIfPresent(Bool.self, forKey: .remotelyAccessible)) ?? false
        type = try? container.decodeIfPresent(String.self, forKey: .type)
    }

    /// Where to load the image from, at about `points` wide on a 2x screen. The server only
    /// resizes to a few sizes: the smallest that covers is chosen.
    public func url(server: URL, points: Int) -> URL? {
        if let proxyID, !proxyID.isEmpty {
            let size = Self.proxySizes.first { $0 >= points * 2 } ?? Self.proxySizes[Self.proxySizes.count - 1]
            var components = URLComponents(url: server.appendingPathComponent("imageproxy/\(proxyID)"),
                                           resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "size", value: String(size))]
            return components?.url
        }
        return remotelyAccessible ? URL(string: path) : nil
    }
}

/// Something in the library or on a music provider: a track, album, artist, playlist, radio
/// station and so on. Only what the app shows and needs to play it is kept.
public struct MediaItem: Decodable, Identifiable, Hashable, Sendable {
    public var itemID: String
    /// "library", or the provider instance the item comes from.
    public var provider: String
    public var name: String
    /// Sets apart releases of the same name, e.g. "Remastered".
    public var version: String
    /// What to hand the server to play the item.
    public var uri: String
    public var mediaType: MediaType
    public var image: MediaImage?
    public var artists: [String]
    public var album: String?
    /// Seconds.
    public var duration: Int?
    public var year: Int?
    public var owner: String?
    public var trackNumber: Int?

    public var id: String { uri }

    public var title: String { version.isEmpty ? name : "\(name) (\(version))" }

    /// A second line for lists: who it's by, or whose it is.
    public var subtitle: String? {
        let parts: [String?]
        switch mediaType {
        case .track: parts = [artists.joined(separator: ", "), album]
        case .album: parts = [artists.joined(separator: ", "), year.map(String.init)]
        case .playlist: parts = [owner]
        default: parts = [artists.joined(separator: ", ")]
        }
        let text = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
        return text.isEmpty ? nil : text
    }

    public init(itemID: String, provider: String = "library", name: String, version: String = "", uri: String,
                mediaType: MediaType, image: MediaImage? = nil, artists: [String] = [], album: String? = nil,
                duration: Int? = nil, year: Int? = nil, owner: String? = nil, trackNumber: Int? = nil) {
        self.itemID = itemID
        self.provider = provider
        self.name = name
        self.version = version
        self.uri = uri
        self.mediaType = mediaType
        self.image = image
        self.artists = artists
        self.album = album
        self.duration = duration
        self.year = year
        self.owner = owner
        self.trackNumber = trackNumber
    }

    enum CodingKeys: String, CodingKey {
        case provider, name, version, uri, image, metadata, artists, authors, album, duration, year, owner
        case itemID = "item_id"
        case mediaType = "media_type"
        case trackNumber = "track_number"
    }

    private struct Related: Decodable {
        var name: String
        var image: MediaImage?
    }

    private struct Metadata: Decodable {
        var images: LossyList<MediaImage>?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try container.decode(String.self, forKey: .itemID)
        provider = try container.decode(String.self, forKey: .provider)
        name = try container.decode(String.self, forKey: .name)
        uri = try container.decode(String.self, forKey: .uri)
        mediaType = try container.decode(MediaType.self, forKey: .mediaType)
        version = (try? container.decodeIfPresent(String.self, forKey: .version)) ?? ""
        year = try? container.decodeIfPresent(Int.self, forKey: .year)
        owner = try? container.decodeIfPresent(String.self, forKey: .owner)
        trackNumber = try? container.decodeIfPresent(Int.self, forKey: .trackNumber)
        duration = (try? container.decodeIfPresent(Double.self, forKey: .duration)).map { Int($0) }

        let related = (try? container.decodeIfPresent(LossyList<Related>.self, forKey: .artists))?.elements ?? []
        // Audiobooks name their authors, as plain strings.
        let authors = (try? container.decodeIfPresent([String].self, forKey: .authors)) ?? []
        artists = related.isEmpty ? authors : related.map(\.name)

        let album = try? container.decodeIfPresent(Related.self, forKey: .album)
        self.album = album?.name

        // Short forms of an item carry one `image`; full ones a list, in which thumbs come first.
        let images = (try? container.decodeIfPresent(Metadata.self, forKey: .metadata))?.images?.elements ?? []
        image = (try? container.decodeIfPresent(MediaImage.self, forKey: .image))
            ?? images.first { $0.type == "thumb" } ?? images.first ?? album?.image
    }
}

/// What a search found, by kind.
public struct SearchResults: Decodable, Sendable {
    public var artists: [MediaItem] = []
    public var albums: [MediaItem] = []
    public var tracks: [MediaItem] = []
    public var playlists: [MediaItem] = []
    public var radio: [MediaItem] = []
    public var podcasts: [MediaItem] = []
    public var audiobooks: [MediaItem] = []

    enum CodingKeys: String, CodingKey {
        case artists, albums, tracks, playlists, radio, podcasts, audiobooks
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func items(_ key: CodingKeys) -> [MediaItem] {
            (try? container.decodeIfPresent(LossyList<MediaItem>.self, forKey: key))?.elements ?? []
        }
        artists = items(.artists)
        albums = items(.albums)
        tracks = items(.tracks)
        playlists = items(.playlists)
        radio = items(.radio)
        podcasts = items(.podcasts)
        audiobooks = items(.audiobooks)
    }

    /// The kinds that found something, in the order to show them.
    public var sections: [(type: MediaType, items: [MediaItem])] {
        [(.artist, artists), (.album, albums), (.track, tracks), (.playlist, playlists), (.radio, radio),
         (.podcast, podcasts), (.audiobook, audiobooks)].filter { !$0.1.isEmpty }
    }

    public var isEmpty: Bool { sections.isEmpty }
}

/// How newly chosen music joins what a player already has queued.
public enum QueueOption: String, Sendable {
    /// Play now, keeping the rest of the queue after it.
    case play
    /// Play now, in place of the queue.
    case replace
    /// Play after the current item.
    case next
    /// Play after everything queued.
    case add
}

/// A player or group of players as Music Assistant lists it.
public struct ServerPlayer: Decodable, Identifiable, Hashable, Sendable {
    struct OutputProtocol: Decodable, Hashable, Sendable {
        var outputProtocolID: String

        enum CodingKeys: String, CodingKey {
            case outputProtocolID = "output_protocol_id"
        }
    }

    public var playerID: String
    public var name: String
    public var isGroup: Bool
    public var isPlaying: Bool
    /// Reachable, enabled, shown by the server, and not following another player: music
    /// can be sent to it.
    public var isSelectable: Bool
    /// The id of the server's group this player is currently playing as part of, if any.
    public var activeGroup: String?
    /// The id of the player this one follows in synced playback, if any.
    public var syncedTo: String?
    var outputProtocols: [OutputProtocol]

    public var id: String { playerID }

    enum CodingKeys: String, CodingKey {
        case name, type, available, enabled
        case playerID = "player_id"
        case displayName = "display_name"
        case playbackState = "playback_state"
        case hideInUI = "hide_in_ui"
        case syncedTo = "synced_to"
        case activeGroup = "active_group"
        case outputProtocols = "output_protocols"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playerID = try container.decode(String.self, forKey: .playerID)
        func text(_ key: CodingKeys) -> String? {
            (try? container.decodeIfPresent(String.self, forKey: key)).flatMap { $0.isEmpty ? nil : $0 }
        }
        func flag(_ key: CodingKeys) -> Bool? { try? container.decodeIfPresent(Bool.self, forKey: key) }
        name = text(.displayName) ?? text(.name) ?? playerID
        isGroup = text(.type) == "group"
        isPlaying = text(.playbackState) == "playing"
        isSelectable = flag(.available) ?? true && flag(.enabled) ?? true && !(flag(.hideInUI) ?? false)
            && text(.syncedTo) == nil
        activeGroup = text(.activeGroup)
        syncedTo = text(.syncedTo)
        outputProtocols = (try? container.decodeIfPresent(LossyList<OutputProtocol>.self, forKey: .outputProtocols))?
            .elements ?? []
    }
}
