import SendspinClientKit
import SwiftUI

/// What a player or group is playing, with its transport and volume controls.
struct NowPlayingView: View {
    let source: any NowPlayingSource
    /// The player or group shown, by the name the user knows it by.
    var groupName: String?

    var body: some View {
        VStack(spacing: 20) {
            artwork
            VStack(spacing: 4) {
                Text(source.title ?? "Nothing playing")
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ProgressRow(source: source)
            transport
            VolumeRow(source: source)
            footer
        }
        .padding(24)
        .frame(maxWidth: 460)
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
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 320, maxHeight: 320)
        .accessibilityHidden(true)
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Toggle(isOn: Binding(get: { source.shuffle }, set: source.setShuffle)) {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(!source.supports("shuffle"))
            control("Previous", "backward.fill", enabled: source.supports("previous"), action: source.previous)
            control(source.isPlaying ? "Pause" : "Play", source.isPlaying ? "pause.fill" : "play.fill",
                    enabled: source.supports(source.isPlaying ? "pause" : "play"), large: true,
                    action: source.togglePlayPause)
            control("Next", "forward.fill", enabled: source.supports("next"), action: source.next)
            Toggle(isOn: Binding(get: { source.repeatMode != "off" },
                                 set: { source.setRepeat($0 ? "all" : "off") })) {
                Label("Repeat", systemImage: source.repeatMode == "one" ? "repeat.1" : "repeat")
            }
            .disabled(!source.supports("repeat_all"))
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private func control(_ title: String, _ systemImage: String, enabled: Bool, large: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: large ? 40 : 24))
                .frame(minWidth: 44, minHeight: 44)
        }
        .disabled(!enabled)
    }

    @ViewBuilder private var footer: some View {
        if let groupName {
            HStack {
                Label(groupName, systemImage: "hifispeaker.2")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if source.supports("switch") {
                    Button("Switch Group", action: source.switchGroup)
                }
            }
            .font(.callout)
        }
    }
}

/// The track position, updated twice a second, and a slider to seek where the server allows it.
private struct ProgressRow: View {
    let source: any NowPlayingSource
    @State private var seekTarget: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let position = source.playbackPosition()
            let duration = Double(position?.durationMs ?? 0)
            let shown = seekTarget ?? Double(position?.positionMs ?? 0)
            VStack(spacing: 2) {
                if duration > 0 {
                    Slider(value: Binding(get: { min(shown, duration) }, set: { seekTarget = $0 }), in: 0...duration) { editing in
                        if !editing, let seekTarget {
                            source.seek(toMs: Int(seekTarget))
                            self.seekTarget = nil
                        }
                    }
                    .disabled(!source.supports("seek"))
                    .accessibilityLabel("Track position")
                } else {
                    ProgressView(value: 0).opacity(position == nil ? 0.3 : 1)
                }
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

/// How the volume is set: the user's choice, kept between launches.
enum VolumeStyle: String, CaseIterable, Identifiable {
    case buttons, knob, slider

    static let key = "volumeStyle"
    static let standard = VolumeStyle.buttons

    var id: Self { self }

    var title: String {
        switch self {
        case .buttons: "Buttons"
        case .knob: "Knob"
        case .slider: "Slider"
        }
    }
}

/// The volume of the player or group shown, set with whichever control the user chose.
///
/// The control shows what the user set, not what the server reports, until the server has had
/// time to catch up: its reports trail the commands, and a group's level moves in steps as each
/// speaker follows.
private struct VolumeRow: View {
    let source: any NowPlayingSource
    @AppStorage(VolumeStyle.key) private var style = VolumeStyle.standard
    @State private var volume = 0.0
    /// A drag is under way.
    @State private var adjusting = false
    @State private var lastChange = Date.distantPast
    @State private var lastSent = Date.distantPast

    /// How long after the user's last change the server's reports are left unshown.
    private static let settle = 1.5
    /// What one press of a button changes the volume by.
    private static let step = 2.0

    var body: some View {
        Group {
            switch style {
            case .buttons: buttons
            case .knob: knob
            case .slider: slider
            }
        }
        .onChange(of: source.volume, initial: true) { _, new in adopt(new) }
        .task(id: lastChange) {
            // Once the server has caught up, show what it settled on.
            try? await Task.sleep(for: .seconds(Self.settle))
            if !Task.isCancelled { adopt(source.volume) }
        }
    }

    private var canSet: Bool { source.supports("volume") }

    private var mute: some View {
        Button {
            source.setMuted(!source.muted)
        } label: {
            Label("Mute", systemImage: source.muted ? "speaker.slash.fill" : "speaker.fill")
                .labelStyle(.iconOnly)
                .frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.borderless)
        .disabled(!source.supports("mute"))
    }

    private var slider: some View {
        HStack(spacing: 12) {
            mute
            Slider(value: Binding(get: { volume }, set: { change(to: $0, final: false) }), in: 0...100, step: 1) { editing in
                adjusting = editing
                if !editing { change(to: volume, final: true) }
            }
            .accessibilityLabel("Volume")
            .disabled(!canSet)
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var buttons: some View {
        HStack(spacing: 14) {
            mute
            Spacer()
            stepButton("Volume Down", "minus", by: -Self.step)
                .disabled(!canSet || volume <= 0)
            Text("\(Int(volume))")
                .font(.title3.monospacedDigit().weight(.medium))
                .frame(minWidth: 44)
                .opacity(canSet ? 1 : 0.4)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int(volume)) percent")
            stepButton("Volume Up", "plus", by: Self.step)
                .disabled(!canSet || volume >= 100)
            Spacer()
            // As wide as the mute button, to keep the rest centred.
            Color.clear.frame(width: 28, height: 28)
        }
    }

    /// A button that steps the volume, and keeps stepping while held.
    private func stepButton(_ title: String, _ systemImage: String, by amount: Double) -> some View {
        Button {
            change(to: volume + amount, final: true)
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 30)
        }
        .buttonStyle(.bordered)
        .buttonRepeatBehavior(.enabled)
    }

    private var knob: some View {
        HStack(spacing: 14) {
            mute
            Spacer()
            VolumeKnob(value: volume) { new in
                adjusting = true
                change(to: new, final: false)
            } onEnded: {
                adjusting = false
                change(to: volume, final: true)
            }
            .disabled(!canSet)
            Spacer()
            Color.clear.frame(width: 28, height: 28)
        }
    }

    /// Show `new` and send it. Mid-drag values go out at most ten times a second; a `final`
    /// one always goes.
    private func change(to new: Double, final: Bool) {
        volume = min(100, max(0, new.rounded()))
        lastChange = Date()
        guard final || Date().timeIntervalSince(lastSent) > 0.1 else { return }
        lastSent = Date()
        source.setVolume(Int(volume))
    }

    /// Show the server's level, unless the user is setting one or has just done so.
    private func adopt(_ reported: Int?) {
        guard let reported, !adjusting, Date().timeIntervalSince(lastChange) >= Self.settle else { return }
        volume = Double(reported)
    }
}

/// A round volume control, turned by dragging around it: clockwise is louder.
private struct VolumeKnob: View {
    /// 0-100.
    let value: Double
    let onChange: (Double) -> Void
    let onEnded: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var lastAngle: Double?
    /// The level being dragged to, before rounding, so that slow turns add up.
    @State private var turning: Double?

    private static let size: CGFloat = 104
    /// Degrees from silent to full: three quarters of a turn, with the gap at the bottom.
    private static let sweep = 270.0
    private static let line = StrokeStyle(lineWidth: 6, lineCap: .round)

    var body: some View {
        let fraction = value / 100
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(.quaternary, style: Self.line)
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * fraction)
                .stroke(.tint, style: Self.line)
                .rotationEffect(.degrees(135))
            Circle().fill(.background.secondary)
                .padding(13)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            Circle().fill(.tint)
                .frame(width: 7, height: 7)
                .offset(y: -(Self.size / 2 - 23))
                .rotationEffect(.degrees(-Self.sweep / 2 + Self.sweep * fraction))
            Text("\(Int(value))")
                .font(.title3.monospacedDigit().weight(.medium))
        }
        .frame(width: Self.size, height: Self.size)
        .contentShape(Circle())
        .opacity(isEnabled ? 1 : 0.4)
        .allowsHitTesting(isEnabled)
        .gesture(turn)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(value)) percent")
        .accessibilityAdjustableAction { direction in
            onChange(value + (direction == .increment ? 5 : -5))
            onEnded()
        }
    }

    /// Follows the finger round the centre and adds up how far it has turned, so the level
    /// never jumps to wherever the drag began or across the gap.
    private var turn: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let x = drag.location.x - Self.size / 2
                let y = drag.location.y - Self.size / 2
                // Too near the centre, the angle swings wildly.
                guard hypot(x, y) > 10 else {
                    lastAngle = nil
                    return
                }
                let angle = atan2(y, x) * 180 / .pi
                defer { lastAngle = angle }
                guard let lastAngle else { return }
                var delta = angle - lastAngle
                if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                let turned = min(100, max(0, (turning ?? value) + delta / Self.sweep * 100))
                turning = turned
                onChange(turned)
            }
            .onEnded { _ in
                lastAngle = nil
                turning = nil
                onEnded()
            }
    }
}
