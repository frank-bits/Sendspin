import AVFoundation
import Foundation

/// Reads what a music file says about itself. Where a file says nothing, its place in the
/// folder stands in: `Artist/Album/03 Title.ext`.
enum TagReader {
    /// The kinds of file the library takes, by extension.
    static let extensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "aif", "aiff", "caf", "alac"]

    private static let coverNames = ["cover", "folder", "front", "album", "artwork"]

    static func track(at url: URL, modified: Double, root: URL) async -> LibraryTrack {
        var tags = Tags()
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration), duration.isNumeric { tags.duration = duration.seconds }
        for item in await items(of: asset) {
            await tags.take(item)
        }
        let fallback = PathNames(url: url, root: root)
        let artist = tags.artist ?? tags.albumArtist ?? fallback.artist
        let albumArtist = tags.albumArtist ?? tags.artist ?? fallback.artist
        return LibraryTrack(id: Library.identifier("track", url.path), path: url.path,
                            title: tags.title ?? fallback.title, artist: artist, albumArtist: albumArtist,
                            album: tags.album ?? fallback.album, trackNumber: tags.track ?? fallback.track,
                            discNumber: tags.disc, year: tags.year, duration: max(0, tags.duration),
                            modified: modified)
    }

    /// The picture inside the file, or an image named like a cover in its folder.
    static func artwork(for url: URL) async -> Data? {
        for item in await items(of: AVURLAsset(url: url)) where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), !data.isEmpty { return data }
        }
        let folder = url.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let images = files.filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
        let cover = images.first { coverNames.contains($0.deletingPathExtension().lastPathComponent.lowercased()) }
        return (cover ?? images.first).flatMap { try? Data(contentsOf: $0) }
    }

    /// Every metadata item of the file, in whatever formats it carries.
    private static func items(of asset: AVURLAsset) async -> [AVMetadataItem] {
        var items = (try? await asset.load(.commonMetadata)) ?? []
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            items += (try? await asset.loadMetadata(for: format)) ?? []
        }
        return items
    }

    private struct Tags {
        var title: String?
        var artist: String?
        var albumArtist: String?
        var album: String?
        var track: Int?
        var disc: Int?
        var year: Int?
        var duration = 0.0

        mutating func take(_ item: AVMetadataItem) async {
            switch item.commonKey {
            case .commonKeyTitle?: if title == nil { title = (await text(item)) }
            case .commonKeyArtist?: if artist == nil { artist = (await text(item)) }
            case .commonKeyAlbumName?: if album == nil { album = (await text(item)) }
            case .commonKeyCreationDate?: if year == nil { year = (await text(item)).flatMap(Self.year) }
            default: break
            }
            // The rest by the format's own name for it: ID3 frames, iTunes atoms, Vorbis comments.
            let name = (item.identifier?.rawValue ?? (item.key as? String) ?? "").lowercased()
            if name.hasSuffix("/tpe2") || name.hasSuffix("/aart") || name.hasSuffix("albumartist")
                || name.hasSuffix("album artist") {
                if albumArtist == nil { albumArtist = (await text(item)) }
            } else if name.hasSuffix("/trck") || name.hasSuffix("/trkn") || name.hasSuffix("tracknumber") {
                if track == nil { track = (await number(item)) }
            } else if name.hasSuffix("/tpos") || name.hasSuffix("/disk") || name.hasSuffix("discnumber") {
                if disc == nil { disc = (await number(item)) }
            } else if name.hasSuffix("/tyer") || name.hasSuffix("/tdrc") || name.hasSuffix("/%a9day")
                || name.hasSuffix("/date") || name == "date" || name == "year" {
                if year == nil { year = (await text(item)).flatMap(Self.year) }
            }
        }

        private func text(_ item: AVMetadataItem) async -> String? {
            guard let value = try? await item.load(.stringValue) else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        /// A track or disc number: "3", "3/12", or the iTunes atom's bytes.
        private func number(_ item: AVMetadataItem) async -> Int? {
            if let text = await text(item), let value = Int(text.prefix { $0.isNumber }), value > 0 { return value }
            if let number = try? await item.load(.numberValue), number.intValue > 0 { return number.intValue }
            // `trkn` and `disk`: two reserved bytes, then the number as a big-endian 16-bit value.
            if let data = try? await item.load(.dataValue), data.count >= 4 {
                let value = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
                return value > 0 ? value : nil
            }
            return nil
        }

        /// The first four digits in a row: "2019", "2019-03-01".
        private static func year(_ text: String) -> Int? {
            let digits = text.prefix { $0.isNumber }
            return digits.count == 4 ? Int(digits) : nil
        }
    }

    /// What a file's place in the library folder says: `Artist/Album/03 Title.ext`.
    struct PathNames {
        var title: String
        var artist = "Unknown Artist"
        var album = "Unknown Album"
        var track: Int?

        init(url: URL, root: URL) {
            let name = url.deletingPathExtension().lastPathComponent
            // "03 Title", "03 - Title", "03. Title", "1-03 Title".
            let pattern = #/^(?:\d+-)?(\d{1,3})(?:\s*[-.]\s*|\s+)(.+)$/#
            if let match = name.firstMatch(of: pattern) {
                track = Int(match.1)
                title = String(match.2)
            } else {
                title = name
            }
            let folders = Array(url.deletingLastPathComponent().standardizedFileURL.pathComponents
                .dropFirst(root.standardizedFileURL.pathComponents.count))
            if let last = folders.last { album = last }
            if folders.count >= 2 { artist = folders[folders.count - 2] }
        }
    }
}
