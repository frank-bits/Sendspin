#if os(tvOS)
import SendspinClientKit
import SwiftUI

/// What a player or group is playing, for a television: the artwork large, the track beside
/// it, and controls the remote moves between. The volume is the TV's own.
struct NowPlayingView: View {
    let source: any NowPlayingSource
    /// The player or group shown, by the name the user knows it by.
    var groupName: String?

    var body: some View {
        HStack(alignment: .center, spacing: 80) {
            artwork
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(source.title ?? "Nothing playing")
                        .font(.title2.weight(.semibold))
                        .lineLimit(3)
                    Text(subtitle)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                ProgressRow(source: source)
                transport
                footer
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
        .padding(60)
        // The remote's own play and pause button, wherever the focus is.
        .onPlayPauseCommand { source.togglePlayPause() }
    }

    private var subtitle: String {
        [source.artist, source.album].compactMap { $0 }.joined(separator: " — ")
    }

    private var artwork: some View {
        AsyncImage(url: source.artworkURL) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.system(size: 140))
                        .foregroundStyle(.secondary)
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .frame(maxWidth: 640, maxHeight: 640)
        .accessibilityHidden(true)
    }

    private var transport: some View {
        HStack(spacing: 24) {
            control("Shuffle", "shuffle", enabled: source.supports("shuffle"), on: source.shuffle) {
                source.setShuffle(!source.shuffle)
            }
            control("Previous", "backward.fill", enabled: source.supports("previous"), action: source.previous)
            control(source.isPlaying ? "Pause" : "Play", source.isPlaying ? "pause.fill" : "play.fill",
                    enabled: source.supports(source.isPlaying ? "pause" : "play"), action: source.togglePlayPause)
            control("Next", "forward.fill", enabled: source.supports("next"), action: source.next)
            control("Repeat", source.repeatMode == "one" ? "repeat.1" : "repeat", enabled: source.supports("repeat_all"),
                    on: source.repeatMode != "off") {
                source.setRepeat(source.repeatMode == "off" ? "all" : "off")
            }
        }
    }

    /// A button of the transport row; `on` marks a setting that's switched on.
    private func control(_ title: String, _ systemImage: String, enabled: Bool, on: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(minWidth: 60, minHeight: 44)
        }
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var footer: some View {
        if let groupName {
            HStack(spacing: 24) {
                Label(groupName, systemImage: "hifispeaker.2")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if source.supports("switch") {
                    Button("Switch Group", action: source.switchGroup)
                }
            }
            .font(.callout)
        }
    }
}

/// The track position, updated twice a second.
private struct ProgressRow: View {
    let source: any NowPlayingSource

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let position = source.playbackPosition()
            let duration = Double(position?.durationMs ?? 0)
            let shown = Double(position?.positionMs ?? 0)
            VStack(spacing: 8) {
                ProgressView(value: duration > 0 ? min(shown, duration) / duration : 0)
                    .opacity(duration > 0 ? 1 : 0.3)
                    .accessibilityLabel("Track position")
                HStack {
                    Text(position == nil ? "--:--" : Self.time(shown))
                    Spacer()
                    Text(duration > 0 ? Self.time(duration) : "--:--")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    static func time(_ milliseconds: Double) -> String {
        let seconds = Int(milliseconds / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
#endif
