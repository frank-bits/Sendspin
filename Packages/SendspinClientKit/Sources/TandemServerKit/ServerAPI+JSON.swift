import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The library's items in the shapes Music Assistant gives them, as far as Tandem reads them.
enum JSON {
    static func track(_ track: LibraryTrack) -> [String: Any] {
        var item = base(id: track.id, name: track.title, type: "track", image: track.albumID)
        if let picture = remote(track.artwork) { item["image"] = picture }
        item["duration"] = track.duration
        item["artists"] = [reference(id: track.artistID, name: track.artist, type: "artist")]
        var album = reference(id: track.albumID, name: track.album, type: "album")
        album["image"] = image(of: track)
        item["album"] = album
        if let number = track.trackNumber { item["track_number"] = number }
        if let disc = track.discNumber { item["disc_number"] = disc }
        if let year = track.year { item["year"] = year }
        return item
    }

    static func album(_ album: LibraryAlbum) -> [String: Any] {
        var item = base(id: album.id, name: album.name, type: "album", image: album.id)
        if let picture = remote(album.artwork) { item["image"] = picture }
        item["artists"] = [reference(id: Library.identifier("artist", album.artist), name: album.artist, type: "artist")]
        if let year = album.year { item["year"] = year }
        return item
    }

    static func artist(_ artist: LibraryArtist) -> [String: Any] {
        base(id: artist.id, name: artist.name, type: "artist", image: nil)
    }

    /// A queue as `player_queues/get` reports it.
    static func queue(_ snapshot: PlaybackEngine.Snapshot, id: String) -> [String: Any] {
        var queue: [String: Any] = [
            "queue_id": id,
            "state": snapshot.state == .playing ? "playing" : snapshot.state == .paused ? "paused" : "idle",
            "shuffle_enabled": snapshot.shuffle,
            "repeat_mode": snapshot.repeatMode,
            "elapsed_time": snapshot.elapsed,
            "elapsed_time_last_updated": snapshot.elapsedAt.timeIntervalSince1970,
            "items": snapshot.queue.count,
        ]
        if let current = snapshot.current {
            queue["current_item"] = [
                "queue_item_id": current.id, "name": "\(current.artist) - \(current.title)",
                "duration": current.duration, "media_item": track(current), "image": image(of: current),
            ] as [String: Any]
        }
        return queue
    }

    private static func base(id: String, name: String, type: String, image imageID: String?) -> [String: Any] {
        var item = reference(id: id, name: name, type: type)
        item["version"] = ""
        if let imageID { item["image"] = image(imageID) }
        return item
    }

    private static func reference(id: String, name: String, type: String) -> [String: Any] {
        ["item_id": id, "provider": "library", "name": name, "media_type": type, "uri": "library://\(type)/\(id)"]
    }

    /// A streamed item's picture, which the app fetches from where it is.
    private static func remote(_ address: String?) -> [String: Any]? {
        address.map { ["type": "thumb", "path": $0, "provider": "library", "remotely_accessible": true] }
    }

    private static func image(of track: LibraryTrack) -> [String: Any] {
        remote(track.artwork) ?? image(track.albumID)
    }

    /// An image served from `/imageproxy/<id>`.
    private static func image(_ id: String) -> [String: Any] {
        ["type": "thumb", "path": id, "provider": "library", "proxy_id": id, "remotely_accessible": false]
    }
}

/// Album pictures, scaled to the size asked for and kept for the next request.
actor ArtworkCache {
    private var images: [String: Data] = [:]
    private var missing: Set<String> = []
    /// Keys in the order they were added, to drop the oldest.
    private var order: [String] = []

    private static let limit = 300

    func image(_ id: String, size: Int, from library: MusicLibrary) async -> Data? {
        let key = "\(id)/\(size)"
        if let image = images[key] { return image }
        if missing.contains(id) { return nil }
        guard let original = await library.artwork(id) else {
            missing.insert(id)
            return nil
        }
        let image = Self.scaled(original, to: size) ?? original
        images[key] = image
        order.append(key)
        if order.count > Self.limit { images[order.removeFirst()] = nil }
        return image
    }

    /// Forget everything: the library was read anew.
    func clear() {
        images = [:]
        missing = []
        order = []
    }

    /// A JPEG at most `size` pixels on its longer side; nil when the data isn't an image.
    private static func scaled(_ data: Data, to size: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        options[kCGImageSourceThumbnailMaxPixelSize] = size > 0 ? size : 1_024
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
