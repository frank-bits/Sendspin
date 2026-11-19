import CryptoKit
import Foundation

/// One music file in the library.
public struct LibraryTrack: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var path: String
    public var title: String
    public var artist: String
    public var albumArtist: String
    public var album: String
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    /// Seconds; 0 when unknown.
    public var duration: Double
    /// The file's modification time when it was read, to notice a changed file.
    public var modified: Double
    /// A streamed track's picture, as an address anyone can fetch (Streaming.swift).
    public var artwork: String?
    /// A streamed track's album, as its provider names it.
    public var streamAlbumID: String?

    public var url: URL { URL(fileURLWithPath: path) }
    public var albumID: String { streamAlbumID ?? Library.identifier("album", albumArtist, album) }
    public var artistID: String { Library.identifier("artist", albumArtist) }
}

public struct LibraryAlbum: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var artist: String
    public var year: Int?
    public var tracks: [LibraryTrack]
    /// A streamed album's picture, as an address anyone can fetch.
    public var artwork: String?
}

public struct LibraryArtist: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
}

public enum Library {
    /// A short stable identifier for the texts that name an item: the same after a rescan.
    static func identifier(_ parts: String...) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").lowercased().utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// How far a scan has come.
    public enum Status: Sendable, Equatable {
        case noFolder
        case scanning(found: Int)
        case ready(tracks: Int)
        case failed(String)
    }
}

/// The music in a folder: its files read once for their tags, then listed and searched from
/// memory. A cache file keeps what was read, so a later scan only reads new or changed files.
public actor MusicLibrary {
    public private(set) var status = Library.Status.noFolder
    public private(set) var folder: URL?

    private let cacheURL: URL?
    private var tracks: [String: LibraryTrack] = [:]
    private var albums: [String: LibraryAlbum] = [:]
    private var artists: [String: LibraryArtist] = [:]
    private var sortedTracks: [LibraryTrack] = []
    private var sortedAlbums: [LibraryAlbum] = []
    private var sortedArtists: [LibraryArtist] = []
    private var scan: Task<Void, Never>?
    private var onChange: (@Sendable (Library.Status) -> Void)?

    public init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL
    }

    /// Called with each new status.
    public func observe(_ onChange: @escaping @Sendable (Library.Status) -> Void) {
        self.onChange = onChange
    }

    /// Read `folder`, replacing what the library held. Returns when the scan is done.
    public func load(folder: URL?) async {
        scan?.cancel()
        self.folder = folder
        guard let folder else {
            replace(with: [])
            set(.noFolder)
            return
        }
        let task = Task { await self.scan(folder) }
        scan = task
        await task.value
    }

    private func scan(_ folder: URL) async {
        set(.scanning(found: 0))
        var known: [String: LibraryTrack] = [:]
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([LibraryTrack].self, from: data) {
            for track in cached { known[track.path] = track }
        }
        guard let files = Self.audioFiles(in: folder) else {
            replace(with: [])
            set(.failed("The folder can't be read."))
            return
        }
        var found: [LibraryTrack] = []
        for (url, modified) in files {
            if Task.isCancelled { return }
            if let cached = known[url.path], cached.modified == modified {
                found.append(cached)
            } else {
                found.append(await TagReader.track(at: url, modified: modified, root: folder))
            }
            if found.count.isMultiple(of: 50) { set(.scanning(found: found.count)) }
        }
        if Task.isCancelled { return }
        replace(with: found)
        if let cacheURL, let data = try? JSONEncoder().encode(found) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        set(.ready(tracks: found.count))
    }

    private func set(_ status: Library.Status) {
        self.status = status
        onChange?(status)
    }

    /// Every audio file under `folder` with its modification time; nil when it can't be listed.
    private static func audioFiles(in folder: URL) -> [(URL, Double)]? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return nil }
        var files: [(URL, Double)] = []
        for case let url as URL in walker where TagReader.extensions.contains(url.pathExtension.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return files.sorted { $0.0.path < $1.0.path }
    }

    private func replace(with found: [LibraryTrack]) {
        tracks = Dictionary(found.map { ($0.id, $0) }) { first, _ in first }
        albums = [:]
        artists = [:]
        for track in found {
            albums[track.albumID, default: LibraryAlbum(id: track.albumID, name: track.album, artist: track.albumArtist,
                                                        year: track.year, tracks: [])].tracks.append(track)
            artists[track.artistID] = LibraryArtist(id: track.artistID, name: track.albumArtist)
        }
        for (id, unsorted) in albums {
            var album = unsorted
            album.tracks.sort {
                ($0.discNumber ?? 1, $0.trackNumber ?? .max, $0.path) < ($1.discNumber ?? 1, $1.trackNumber ?? .max, $1.path)
            }
            album.year = album.year ?? album.tracks.compactMap(\.year).first
            albums[id] = album
        }
        sortedTracks = found.sorted { Self.ordered($0.title, $1.title) }
        sortedAlbums = albums.values.sorted { Self.ordered($0.name, $1.name) }
        sortedArtists = artists.values.sorted { Self.ordered($0.name, $1.name) }
    }

    private static func ordered(_ first: String, _ second: String) -> Bool {
        first.localizedStandardCompare(second) == .orderedAscending
    }

    // MARK: Looking things up

    public func track(_ id: String) -> LibraryTrack? { tracks[id] }
    public func album(_ id: String) -> LibraryAlbum? { albums[id] }
    public func artist(_ id: String) -> LibraryArtist? { artists[id] }

    public func allTracks(matching search: String? = nil, limit: Int = 50, offset: Int = 0) -> [LibraryTrack] {
        Self.page(sortedTracks, search, limit, offset) { [$0.title, $0.artist, $0.album] }
    }

    public func allAlbums(matching search: String? = nil, limit: Int = 50, offset: Int = 0) -> [LibraryAlbum] {
        Self.page(sortedAlbums, search, limit, offset) { [$0.name, $0.artist] }
    }

    public func allArtists(matching search: String? = nil, limit: Int = 50, offset: Int = 0) -> [LibraryArtist] {
        Self.page(sortedArtists, search, limit, offset) { [$0.name] }
    }

    /// An artist's albums, newest first.
    public func albums(byArtist id: String) -> [LibraryAlbum] {
        sortedAlbums.filter { Library.identifier("artist", $0.artist) == id }
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    /// The image for an album or a track: embedded in a file, or beside it in the folder.
    public func artwork(_ id: String) async -> Data? {
        guard let track = albums[id]?.tracks.first ?? tracks[id] else { return nil }
        return await TagReader.artwork(for: track.url)
    }

    private static func page<Item>(_ items: [Item], _ search: String?, _ limit: Int, _ offset: Int,
                                   texts: (Item) -> [String]) -> [Item] {
        var matching = items
        if let words = search?.lowercased().split(separator: " "), !words.isEmpty {
            matching = items.filter { item in
                let text = texts(item).joined(separator: " ").lowercased()
                return words.allSatisfy { text.contains($0) }
            }
        }
        return Array(matching.dropFirst(max(0, offset)).prefix(max(0, limit)))
    }
}
