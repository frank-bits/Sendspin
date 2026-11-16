#if os(macOS)
import SendspinClientKit
import SwiftUI
import TandemServerKit

/// Running this Mac as the server: switching it on, choosing the music folder, and setting
/// up the players that connect.
struct HostView: View {
    @Bindable var host: HostModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Play music from this Mac", isOn: $host.isEnabled)
                } footer: {
                    Text("Tandem on other devices finds “\(host.serverName)” as a server, and plays a folder of "
                        + "this Mac's music in sync. It runs while Tandem is open, and needs no Music Assistant.")
                }
                if let error = host.state.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                if host.isEnabled, host.state.localNetworkDenied {
                    Section {
                        Label("Tandem isn't allowed on the local network, so it finds no speakers. Allow it in "
                            + "System Settings, under Privacy & Security, Local Network.",
                            systemImage: "exclamationmark.triangle")
                    }
                }
                if host.isEnabled {
                    music
                    players
                    speakers
                    GroupsSection(host: host)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Host")
        }
    }

    private var music: some View {
        Section("Music") {
            LabeledContent("Folder") {
                HStack {
                    Text(host.folder?.path(percentEncoded: false) ?? "None chosen")
                        .foregroundStyle(host.folder == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Choose…") { host.chooseFolder() }
                }
            }
            LabeledContent("Library") {
                HStack {
                    Text(libraryStatus).foregroundStyle(.secondary)
                    if case .scanning = host.state.library { ProgressView().controlSize(.small) }
                    Button("Rescan") { host.rescan() }
                        .disabled(host.folder == nil || host.state.library.isScanning)
                }
            }
        }
    }

    private var libraryStatus: String {
        switch host.state.library {
        case .noFolder: "Choose a folder of music files"
        case .scanning(let found): found == 0 ? "Reading…" : "Reading… \(found) tracks so far"
        case .ready(let tracks): tracks == 1 ? "1 track" : "\(tracks) tracks"
        case .failed(let reason): reason
        }
    }

    private var players: some View {
        Section {
            if host.state.players.isEmpty {
                Text("No players yet. Sendspin speakers on this network appear here by themselves. For an "
                    + "iPhone, iPad or Mac, open Tandem on it and choose “\(host.serverName)” as its server.")
                    .foregroundStyle(.secondary)
            }
            ForEach(host.state.players) { PlayerRow(player: $0, host: host) }
        } header: {
            Text("Players")
        } footer: {
            Text("A player is paired once, with a code it shows, and plays whenever it's connected after that.")
        }
    }
}

private extension HostView {
    var speakers: some View {
        Section {
            if host.state.speakers.isEmpty {
                Text("No AirPlay speakers found on this network.").foregroundStyle(.secondary)
            }
            ForEach(host.state.speakers) { SpeakerRow(speaker: $0, host: host) }
        } header: {
            Text("AirPlay Speakers")
        } footer: {
            Text("A speaker that's switched on plays with Everywhere and can be put in groups. It's taken over "
                + "when music starts on it, and let go soon after it stops. "
                + "With one switched on, music starts about two seconds after you ask: that's how far ahead "
                + "AirPlay speakers buffer. Apple TV, HomePod and Macs aren't listed; they need Apple's own AirPlay.")
        }
    }
}

/// One AirPlay speaker: whether it plays with the group, and how loud.
private struct SpeakerRow: View {
    let speaker: AirPlaySpeakers.Speaker
    let host: HostModel

    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { speaker.enabled }, set: { host.setSpeaker(speaker, enabled: $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(speaker.name)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if speaker.enabled {
                Stepper("\(speaker.volume)", value: Binding(get: { speaker.volume },
                                                           set: { host.setSpeaker(speaker, volume: $0) }),
                        in: 0...100, step: 5)
                    .monospacedDigit()
                    .fixedSize()
                    .help("Volume")
            }
        }
    }

    private var detail: String? {
        guard speaker.enabled else { return speaker.model }
        if !speaker.present { return "Not on the network" }
        switch speaker.status {
        case .idle: return speaker.model
        case .connecting: return "Connecting…"
        case .playing: return "Playing"
        case .failed(let reason): return "Couldn't play: \(reason)"
        }
    }
}

private extension Library.Status {
    var isScanning: Bool {
        if case .scanning = self { true } else { false }
    }
}

/// One connected player: what it's doing, and what it still needs.
private struct PlayerRow: View {
    let player: StandaloneServer.Player
    let host: HostModel
    @State private var code = ""

    private var digits: String { code.filter(\.isNumber) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(player.name, systemImage: player.connection == .connected ? "hifispeaker.fill" : "hifispeaker")
                Spacer()
                Text(status).foregroundStyle(.secondary)
                action
            }
            if case .enteringCode(let prompt) = player.pairing {
                HStack {
                    TextField(prompt.isRetry ? "That code didn't match. Try again" : "Code shown on the player", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .onSubmit(submit)
                    Button("Pair", action: submit)
                        .disabled(digits.count != prompt.length)
                    Button("Cancel") { host.enterCode(nil, for: player) }
                }
            }
        }
        .contextMenu {
            if player.paired { Button("Forget Pairing", role: .destructive) { host.forget(player) } }
        }
    }

    private func submit() {
        guard !digits.isEmpty else { return }
        host.enterCode(digits, for: player)
        code = ""
    }

    private var status: String {
        switch player.pairing {
        case .starting?: return "Starting to pair…"
        case .waiting(let message)?: return message ?? "Waiting for the player…"
        case .enteringCode?: return "Shows a code"
        case .checking?: return "Checking the code…"
        case .failed(let reason)?: return reason
        case .paired?, nil: break
        }
        switch player.connection {
        case .connected: return "Connected"
        case .pairingRequired: return "Needs pairing"
        case .notRecognized: return "Lost its pairing"
        case .awaitingApproval: return "Not allowed yet"
        case .left: return "Busy elsewhere"
        case .connecting: return "Connecting…"
        case .taken: return "In use by another server"
        case .unavailable: return "Can't be reached"
        case .notApproved: return "Not the device that was allowed"
        case .failed(let reason): return reason
        case .disconnected: return "Not connected"
        }
    }

    @ViewBuilder private var action: some View {
        if player.pairing == nil || player.pairing?.hasEnded == true {
            switch player.connection {
            case .pairingRequired, .notRecognized:
                if player.offersCode { Button("Pair…") { host.pair(player) } }
            case .awaitingApproval:
                if player.offersCode { Button("Pair…") { host.pair(player) } }
                Button("Allow") { host.allow(player) }
            case .taken, .left, .disconnected, .failed:
                // Only a speaker the server connects to can be fetched back.
                if player.found { Button("Use Here") { host.use(player) } }
            default:
                EmptyView()
            }
        }
    }
}

private extension PairingPrompt {
    var isRetry: Bool {
        switch self {
        case .staticCode(let again), .dynamicCode(let again), .dynamicQRCode(let again): again
        }
    }
}

private extension PairingProgress {
    /// Paired or failed: a new attempt may start.
    var hasEnded: Bool {
        switch self {
        case .paired, .failed: true
        default: false
        }
    }
}
#endif
