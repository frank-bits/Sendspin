import Foundation
import SendspinClientKit

/// What a live stream has for the engine now.
public enum LiveRead: Sendable {
    case block(PCMBuffer)
    /// Nothing yet: the track is starting, or the next sound hasn't been captured.
    case wait
    /// The track played to its end, or can't be played.
    case ended
}

/// One streamed track, heard as it plays: unlike a file it can't be read ahead of the clock.
public protocol LiveStream: AnyObject, Sendable {
    func read() -> LiveRead
    /// Stop playing it. Called once, when the engine is done with the track.
    func close()
}

/// A streaming service the server can search and play from, beside its folder of files.
///
/// Its tracks and albums carry ids that start with the provider's id and a hyphen
/// (`applemusic-307029144`), which is how the server tells whose they are.
public protocol StreamingProvider: Sendable {
    /// Short and fixed, for ids: "applemusic".
    var id: String { get }
    func search(_ query: String, limit: Int) async -> (tracks: [LibraryTrack], albums: [LibraryAlbum])
    func track(_ id: String) async -> LibraryTrack?
    func albumTracks(_ albumID: String) async -> [LibraryTrack]
    /// Start `track`, `offset` seconds in. A provider with one player gives it to the newest
    /// stream: an older one ends.
    func open(_ track: LibraryTrack, at offset: Double) -> LiveStream
}

extension LibraryTrack {
    /// The provider a streamed track plays from; nil for a file.
    public var providerID: String? {
        guard !path.hasPrefix("/"), let colon = path.firstIndex(of: ":") else { return nil }
        return String(path[..<colon])
    }

    /// A track a provider streams. `id` and `albumID` start with the provider's id and a hyphen.
    public static func streamed(provider: String, id: String, title: String, artist: String, albumArtist: String? = nil,
                                album: String, albumID: String?, trackNumber: Int? = nil, discNumber: Int? = nil,
                                year: Int? = nil, duration: Double, artwork: String? = nil) -> LibraryTrack {
        var track = LibraryTrack(id: id, path: "\(provider):\(id)", title: title, artist: artist,
                                 albumArtist: albumArtist ?? artist, album: album, trackNumber: trackNumber,
                                 discNumber: discNumber, year: year, duration: duration, modified: 0)
        track.artwork = artwork
        track.streamAlbumID = albumID
        return track
    }
}

extension LibraryAlbum {
    /// An album a provider streams; its tracks are asked for when it's opened.
    public static func streamed(id: String, name: String, artist: String, year: Int? = nil, artwork: String? = nil) -> LibraryAlbum {
        var album = LibraryAlbum(id: id, name: name, artist: artist, year: year, tracks: [])
        album.artwork = artwork
        return album
    }
}

extension [StreamingProvider] {
    /// The provider an item id belongs to.
    func owner(of id: String) -> StreamingProvider? {
        first { id.hasPrefix($0.id + "-") }
    }
}
