import MusicAssistantKit
import SwiftUI

/// The library's front page: search across everything, what was played lately, and the way
/// into each kind of music.
struct LibraryHomeView: View {
    let library: LibraryModel
    let api: MusicAssistantAPI
    @State private var query = ""
    @State private var results: SearchResults?
    @State private var recent: [MediaItem] = []

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        List {
            if trimmedQuery.isEmpty {
                home
            } else if let results {
                if results.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                } else {
                    ForEach(results.sections, id: \.type) { section in
                        Section(section.type.heading) {
                            ForEach(section.items) { MediaRow(item: $0, library: library) }
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .searchable(text: $query, prompt: "Artists, albums, tracks, playlists")
        .task(id: trimmedQuery) { await search(trimmedQuery) }
        .task { await loadRecent() }
        .refreshable { await loadRecent() }
    }

    @ViewBuilder private var home: some View {
        if !recent.isEmpty {
            Section("Recently Played") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(recent) { MediaTile(item: $0, library: library) }
                    }
                    .padding(.vertical, 4)
                }
                // A fixed height: the list can't measure a sideways-scrolling row by itself.
                .frame(height: MediaTile.height)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 0))
            }
        }
        Section("Library") {
            ForEach(MediaType.libraryTypes, id: \.self) { type in
                NavigationLink(value: LibraryRoute.list(type)) {
                    Label(type.heading, systemImage: type.systemImage)
                }
            }
        }
    }

    private func search(_ text: String) async {
        results = nil
        guard !text.isEmpty else { return }
        // Wait out the typing: each change cancels this task and starts another.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        do {
            results = try await api.search(text)
        } catch {
            guard !Task.isCancelled else { return }
            results = SearchResults()
            library.report(error)
        }
    }

    private func loadRecent() async {
        do {
            recent = try await api.recentlyPlayed().filter { $0.mediaType != .folder }
        } catch {
            library.report(error)
        }
    }
}

/// Everything of one kind in the library, loaded a page at a time as the list is scrolled.
struct MediaListView: View {
    let type: MediaType
    let library: LibraryModel
    let api: MusicAssistantAPI
    @State private var items: [MediaItem] = []
    @State private var filter = ""
    @State private var reachedEnd = false
    @State private var isLoading = false

    private static let pageSize = 60

    var body: some View {
        List {
            ForEach(items) { item in
                MediaRow(item: item, library: library)
                    .onAppear {
                        if item.id == items.last?.id { Task { await loadMore() } }
                    }
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .overlay {
            if items.isEmpty, reachedEnd {
                if filter.isEmpty {
                    ContentUnavailableView("No \(type.heading)", systemImage: type.systemImage,
                                           description: Text("The library has none yet."))
                } else {
                    ContentUnavailableView.search(text: filter)
                }
            }
        }
        .navigationTitle(type.heading)
        .searchable(text: $filter, prompt: "Filter \(type.heading.lowercased())")
        .task(id: filter) { await reload() }
    }

    private func reload() async {
        if !items.isEmpty || !filter.isEmpty {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
        }
        items = []
        reachedEnd = false
        isLoading = false
        await loadMore()
    }

    private func loadMore() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        let wanted = filter
        do {
            let page = try await api.libraryItems(type, search: wanted, limit: Self.pageSize, offset: items.count)
            // A reply to a filter that has since changed belongs to no list any more.
            guard wanted == filter, !Task.isCancelled else { return }
            let known = Set(items.map(\.id))
            items += page.filter { !known.contains($0.id) }
            reachedEnd = page.count < Self.pageSize
        } catch {
            guard !Task.isCancelled else { return }
            reachedEnd = true
            library.report(error)
        }
    }
}

/// An album, playlist, artist or podcast: play it whole, or pick from what it holds.
struct MediaDetailView: View {
    let item: MediaItem
    let library: LibraryModel
    let api: MusicAssistantAPI
    @State private var children: [MediaItem]?

    /// Tracks picked here play the rest of the album or playlist after them.
    private var container: MediaItem? {
        item.mediaType == .album || item.mediaType == .playlist ? item : nil
    }

    var body: some View {
        List {
            Section {
                header
                    .frame(maxWidth: .infinity)
                    #if !os(tvOS)
                    .listRowSeparator(.hidden)
                    #endif
            }
            if let children {
                Section {
                    ForEach(children) { MediaRow(item: $0, library: library, container: container) }
                } footer: {
                    if children.isEmpty { Text("Nothing here yet.") }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(item.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    PlayMenu(item: item, library: library)
                } label: {
                    Label("Play Options", systemImage: "ellipsis.circle")
                }
            }
        }
        .task(id: item.id) {
            do {
                children = try await api.children(of: item)
            } catch {
                guard !Task.isCancelled else { return }
                children = []
                library.report(error)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(item: item, library: library, points: 200)
            VStack(spacing: 4) {
                Text(item.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let subtitle = item.subtitle {
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Button {
                    library.play(item, option: .replace, shuffle: false)
                } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(library.startingItemID == item.id)
                Button {
                    library.play(item, option: .replace, shuffle: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(library.startingItemID == item.id)
            }
            .controlSize(.large)
            .frame(maxWidth: 360)
        }
        .padding(.vertical, 8)
    }
}

/// Signing in to Music Assistant, which keeps its library behind an account.
struct LibrarySignInView: View {
    let library: LibraryModel
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""

    var body: some View {
        Form {
            Section {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .onSubmit(signIn)
                Button("Sign In", action: signIn)
                    .disabled(username.isEmpty || password.isEmpty || library.isSigningIn)
            } header: {
                Text("Music Assistant account")
            } footer: {
                Text("Sign in to browse and choose music. The app keeps an access token, not your password.")
            }
            Section {
                SecureField("Access token", text: $token)
                    .autocorrectionDisabled()
                Button("Use Token") {
                    Task { await library.signIn(token: token) }
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.isSigningIn)
            } header: {
                Text("Or use an access token")
            } footer: {
                Text("If you sign in to Music Assistant through Home Assistant, create a long-lived access "
                    + "token in Music Assistant's profile settings and paste it here.")
            }
            if library.isSigningIn {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Library")
    }

    private func signIn() {
        guard !username.isEmpty, !password.isEmpty else { return }
        Task { await library.signIn(username: username, password: password) }
    }
}
