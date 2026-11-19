import SendspinClientKit
import SwiftUI

/// The window's content: whatever the connection needs next, then what's playing.
struct ContentView: View {
    let model: AppModel
    @State private var tab = Tab.player

    private enum Tab {
        case player, library, host
    }

    var body: some View {
        TabView(selection: $tab) {
            player
                .tabItem { Label("Player", systemImage: "play.circle") }
                .tag(Tab.player)
            if let client = model.client, let library = model.library {
                LibraryView(library: library, client: client) { tab = .player }
                    .tabItem { Label("Library", systemImage: "music.note.list") }
                    .tag(Tab.library)
            }
            #if os(macOS)
            HostView(host: model.host)
                .tabItem { Label("Host", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(Tab.host)
            #endif
        }
        // Sign in to the library as soon as the server is known, not only once its tab is
        // opened: the player uses it too.
        .task(id: model.client?.libraryURL?.absoluteString ?? model.client?.serverHost) {
            if let own = model.client?.libraryURL {
                model.library?.setServer(own, open: true)
            } else if let host = model.client?.serverHost, model.library?.server == nil || model.library?.isOpen == true {
                model.library?.setServer(LibraryModel.defaultURL(host: host))
            }
        }
    }

    private var player: some View {
        NavigationStack {
            Group {
                if let client = model.client {
                    ConnectionView(client: client, library: model.library, deviceName: model.deviceName)
                } else {
                    ContentUnavailableView("Tandem can't start", systemImage: "exclamationmark.triangle",
                                           description: Text(model.startupError ?? "Unknown error"))
                }
            }
            .navigationTitle("Tandem")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

}

private struct ConnectionView: View {
    let client: SendspinClient
    let library: LibraryModel?
    let deviceName: String
    @State private var confirmingForget = false
    @AppStorage(VolumeStyle.key) private var volumeStyle = VolumeStyle.standard
    @AppStorage(OutputDevice.userDelayKey) private var soundDelay = 0

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: client.group?.groupID) {
                // This device joined or left a group: the library's view of the players is
                // stale. Again shortly after, as the server reports it a moment later.
                await library?.loadPlayers()
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { await library?.loadPlayers() }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { serverMenu }
            }
            .confirmationDialog("Forget pairing?", isPresented: $confirmingForget) {
                Button("Forget Pairing", role: .destructive) {
                    Task { await client.forgetPairings() }
                }
            } message: {
                Text("Servers will have to pair with this device again before they can play on it.")
            }
    }

    @ViewBuilder private var content: some View {
        if let code = client.pairingCode {
            PairingCodeView(code: code)
        } else {
            switch client.connection {
            case .searching:
                ServerListView(client: client)
            case .connecting(let name):
                StatusView(title: "Connecting to \(name)…", busy: true)
            case .retrying(let name):
                StatusView(title: "Can't reach \(name)", detail: "Trying again…", busy: true)
            case .connected(let name):
                if client.isPaired {
                    nowPlaying
                } else {
                    StatusView(title: "Waiting to be set up",
                               detail: "In \(name), open the player settings and set up “\(deviceName)”. "
                                   + "A pairing code will appear here.",
                               systemImage: "link.badge.plus")
                }
            }
        }
    }

    /// The chosen player when it's another one, otherwise this device's own group.
    private var nowPlaying: some View {
        let source: any NowPlayingSource = library?.nowPlaying ?? client
        let name = library?.remote?.player.name ?? library?.ownGroupName ?? client.group?.groupName
        return NowPlayingView(source: source, groupName: name)
            .id(ObjectIdentifier(source))
    }

    private var serverMenu: some View {
        Menu {
            if case .connected(let name) = client.connection {
                Section(name) {
                    Button("Disconnect") { client.disconnect() }
                }
            }
            if client.servers.count > 1 {
                Section("Servers") {
                    ForEach(client.servers) { server in
                        Button(server.name ?? server.instanceName) { client.connect(to: server) }
                    }
                }
            }
            #if os(tvOS)
            // A television plays sound a little after it gets it; this much earlier we send it.
            Picker("TV Sound Delay", selection: $soundDelay) {
                ForEach(Array(stride(from: 0, through: 300, by: 25)), id: \.self) { delay in
                    Text(delay == 0 ? "None" : "\(delay) ms").tag(delay)
                }
            }
            .pickerStyle(.menu)
            #endif
            // A TV's volume is its remote's.
            #if !os(tvOS)
            Picker("Volume Control", selection: $volumeStyle) {
                ForEach(VolumeStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            #endif
            Button("Forget Pairing…", role: .destructive) { confirmingForget = true }
        } label: {
            Label("Options", systemImage: "ellipsis.circle")
        }
    }
}

/// The servers found on the network, to choose one.
private struct ServerListView: View {
    let client: SendspinClient

    var body: some View {
        if client.servers.isEmpty {
            StatusView(title: "Looking for Sendspin servers…",
                       detail: "Music Assistant and Tandem servers on this network appear here.", busy: true)
        } else {
            List(client.servers) { server in
                Button {
                    client.connect(to: server)
                } label: {
                    Label(server.name ?? server.instanceName, systemImage: "server.rack")
                }
            }
        }
    }
}

/// The code the operator types into the server, grouped 3-3 as the spec presents it.
private struct PairingCodeView: View {
    let code: String

    var body: some View {
        VStack(spacing: 16) {
            Text("Pairing code")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("\(String(code.prefix(3)))-\(String(code.suffix(3)))")
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .monospacedDigit()
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
            Text("Enter this code on the server.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct StatusView: View {
    let title: String
    var detail: String?
    var systemImage: String?
    var busy = false

    var body: some View {
        VStack(spacing: 12) {
            if busy {
                ProgressView()
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
            }
            Text(title).font(.headline)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }
}
