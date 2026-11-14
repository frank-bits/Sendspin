import MusicAssistantKit
import SendspinClientKit
import SwiftUI

/// Browsing and choosing music. Sendspin itself only plays and controls, so this talks to
/// the library behind the server through its own API: Music Assistant's, or a Tandem server's.
struct LibraryView: View {
    let library: LibraryModel
    let client: SendspinClient
    /// Switch to the player, from the bar showing what's playing.
    let showPlayer: () -> Void
    @State private var servers: [MusicAssistantServer] = []

    private var serverName: String? {
        if case .connected(let name) = client.connection { return name }
        return nil
    }

    private var url: URL? {
        // A Tandem server says where its library is; never another server's stands in for it.
        if let own = client.libraryURL { return own }
        if let server = servers.first(where: { $0.name == serverName }) ?? servers.first { return server.url }
        // Not found over mDNS: assume the usual port on the Sendspin server's host.
        return client.serverHost.flatMap(LibraryModel.defaultURL(host:))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(for: LibraryRoute.self, destination: destination)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if library.api != nil { PlayerPickerBar(library: library) }
                MiniPlayerBar(source: library.nowPlaying, showPlayer: showPlayer)
            }
        }
        .alert("Library", isPresented: Binding(get: { library.errorMessage != nil },
                                                set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? "")
        }
        .task {
            for await found in MusicAssistantBrowser.browse() {
                servers = found
            }
        }
        .task(id: url) { library.setServer(url, open: client.libraryURL != nil) }
    }

    @ViewBuilder private var content: some View {
        if library.server == nil {
            ContentUnavailableView {
                Label("Looking for the library…", systemImage: "music.note.list")
            } description: {
                Text("Its library appears here once it's found on this network.")
            }
        } else if let api = library.api {
            LibraryHomeView(library: library, api: api)
                .navigationTitle("Library")
                .toolbar {
                    // A Tandem server has no account to sign out of, and no web page.
                    if !library.isOpen {
                        ToolbarItem(placement: .primaryAction) { accountMenu }
                    }
                }
        } else {
            LibrarySignInView(library: library)
        }
    }

    private var accountMenu: some View {
        Menu {
            if let name = library.userName {
                Section("Signed in as \(name)") {
                    Button("Sign Out", role: .destructive) { library.signOut() }
                }
            } else {
                Button("Sign Out", role: .destructive) { library.signOut() }
            }
            if let server = library.server {
                NavigationLink(value: LibraryRoute.web(server)) {
                    Label("Open Music Assistant", systemImage: "globe")
                }
            }
        } label: {
            Label("Account", systemImage: "person.crop.circle")
        }
    }

    @ViewBuilder private func destination(_ route: LibraryRoute) -> some View {
        switch route {
        case .web(let url):
            MusicAssistantWebView(url: url)
        case .list(let type):
            if let api = library.api { MediaListView(type: type, library: library, api: api) }
        case .item(let item):
            if let api = library.api { MediaDetailView(item: item, library: library, api: api) }
        }
    }
}
