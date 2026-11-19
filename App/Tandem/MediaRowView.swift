import MusicAssistantKit
import SendspinClientKit
import SwiftUI

/// Where the library's screens lead.
enum LibraryRoute: Hashable {
    case list(MediaType)
    case item(MediaItem)
    case web(URL)
}

extension MediaType {
    /// The plural name of the kind, for headings.
    var heading: String {
        switch self {
        case .artist: "Artists"
        case .album: "Albums"
        case .track: "Tracks"
        case .playlist: "Playlists"
        case .radio: "Radio"
        case .podcast: "Podcasts"
        case .audiobook: "Audiobooks"
        default: rawValue.capitalized
        }
    }

    var systemImage: String {
        switch self {
        case .artist: "music.mic"
        case .album: "square.stack"
        case .track: "music.note"
        case .playlist: "music.note.list"
        case .radio: "dot.radiowaves.left.and.right"
        case .podcast, .podcastEpisode: "mic"
        case .audiobook: "book"
        default: "music.note"
        }
    }
}

/// An item's picture, or its kind's symbol while there's none.
struct ArtworkView: View {
    let item: MediaItem
    let library: LibraryModel
    let points: Int

    var body: some View {
        AsyncImage(url: library.artworkURL(item, points: points)) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: item.mediaType.systemImage)
                        .font(.system(size: CGFloat(points) * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: CGFloat(points), height: CGFloat(points))
        .clipShape(item.mediaType == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6)))
        .accessibilityHidden(true)
    }
}

/// One item in a list. Choosing it opens it when it holds other items, and plays it otherwise.
struct MediaRow: View {
    let item: MediaItem
    let library: LibraryModel
    /// The album or playlist the row is listed under, if any.
    var container: MediaItem?

    var body: some View {
        Group {
            if item.mediaType.hasChildren {
                NavigationLink(value: LibraryRoute.item(item)) { label }
            } else {
                Button {
                    library.play(item, in: container)
                } label: {
                    label.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu { PlayMenu(item: item, library: library) }
    }

    private var label: some View {
        HStack(spacing: 12) {
            ArtworkView(item: item, library: library, points: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if library.startingItemID == item.id {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Starting")
            } else if let duration = item.duration, duration > 0, !item.mediaType.hasChildren {
                Text(Duration.seconds(duration).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The ways to play an item: now, next, or after everything queued.
struct PlayMenu: View {
    let item: MediaItem
    let library: LibraryModel

    var body: some View {
        Button("Play Now", systemImage: "play") { library.play(item, option: .replace) }
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            library.play(item, option: .next)
        }
        Button("Add to Queue", systemImage: "text.append") { library.play(item, option: .add) }
    }
}

/// A square item for a row that scrolls sideways.
struct MediaTile: View {
    let item: MediaItem
    let library: LibraryModel

    /// Room for the artwork and two lines of text.
    static let height: CGFloat = 176

    var body: some View {
        Group {
            if item.mediaType.hasChildren {
                NavigationLink(value: LibraryRoute.item(item)) { label }
            } else {
                Button { library.play(item) } label: { label }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { PlayMenu(item: item, library: library) }
    }

    private var label: some View {
        VStack(alignment: item.mediaType == .artist ? .center : .leading, spacing: 6) {
            ArtworkView(item: item, library: library, points: 120)
            Text(item.title)
                .font(.subheadline)
                .lineLimit(1)
            Text(item.subtitle ?? item.mediaType.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 120)
        .contentShape(Rectangle())
    }
}

/// What's playing, along the bottom of the library: a way to pause, and back to the player.
struct MiniPlayerBar: View {
    private static var bar: Material { BarBackground.material }
    let source: any NowPlayingSource
    let showPlayer: () -> Void

    var body: some View {
        if let title = source.title {
            HStack(spacing: 12) {
                Button(action: showPlayer) {
                    HStack(spacing: 12) {
                        AsyncImage(url: source.artworkURL) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Rectangle().fill(.quaternary)
                            }
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).lineLimit(1)
                            if let artist = source.artist {
                                Text(artist)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the player")
                Button(source.isPlaying ? "Pause" : "Play", systemImage: source.isPlaying ? "pause.fill" : "play.fill") {
                    source.togglePlayPause()
                }
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.plain)
                .disabled(!source.supports(source.isPlaying ? "pause" : "play"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Self.bar)
        }
    }
}

/// Where picked music plays, with the way to send it to another player or group.
struct PlayerPickerBar: View {
    let library: LibraryModel
    private static var bar: Material { BarBackground.material }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Play on", selection: Binding(get: { library.target?.playerID },
                                                     set: { id in choose(id) })) {
                    ForEach(library.players) { player in
                        Label(title(player), systemImage: player.isGroup ? "hifispeaker.2" : "hifispeaker")
                            .tag(Optional(player.playerID))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Playing on \(library.target.map(title) ?? "this device")",
                      systemImage: library.target?.isGroup == true ? "hifispeaker.2" : "hifispeaker")
                    .lineLimit(1)
            }
            .fixedSize()
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Self.bar)
        .task { await library.loadPlayers() }
    }

    private func title(_ player: ServerPlayer) -> String {
        player.playerID == library.ownPlayer?.playerID ? "This device" : player.name
    }

    private func choose(_ id: String?) {
        library.choosePlayer(library.players.first { $0.playerID == id })
        // The list may be stale by the next time the menu opens.
        Task { await library.loadPlayers() }
    }
}

/// What a bar along an edge is drawn on. Apple TV has no bar material of its own.
enum BarBackground {
    static var material: Material {
        #if os(tvOS)
        .regularMaterial
        #else
        .bar
        #endif
    }
}
