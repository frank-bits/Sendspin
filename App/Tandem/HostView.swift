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
                if host.isEnabled {
                    music
                    players
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
                Text("No players yet. Open Tandem on an iPhone, iPad or Mac on this network and choose "
                    + "“\(host.serverName)” as its server.")
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
        case .connected: return "Playing here"
        case .pairingRequired: return "Needs pairing"
        case .notRecognized: return "Lost its pairing"
        case .awaitingApproval: return "Not allowed yet"
        case .left: return "Busy elsewhere"
        case .connecting: return "Connecting…"
        default: return "Not connected"
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
