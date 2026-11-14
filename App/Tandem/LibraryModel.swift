import Foundation
import MusicAssistantKit
import Security
import SendspinClientKit

/// The library behind the Sendspin server, Music Assistant's or a Tandem server's own:
/// signing in to it where that's needed, and playing what the user picks.
@MainActor
@Observable
final class LibraryModel {
    /// The library's web address, once known.
    private(set) var server: URL?
    /// The server takes no sign-in: a Tandem server, open to its network.
    private(set) var isOpen = false
    /// Set while signed in.
    private(set) var api: MusicAssistantAPI?
    private(set) var userName: String?
    private(set) var isSigningIn = false
    /// The item a play request is out for: the server can take seconds to line up a stream,
    /// and the lists mark the item meanwhile.
    private(set) var startingItemID: String?
    /// A failure to show the user; cleared when dismissed.
    var errorMessage: String?

    private let client: SendspinClient
    private let deviceName: String
    /// The players music can be sent to, groups first; loaded by `loadPlayers()`.
    private(set) var players: [ServerPlayer] = []
    /// This device as the server lists it; nil until found there.
    private(set) var ownPlayer: ServerPlayer?
    /// The name of the server's group this device is playing as part of, if any: the one
    /// the user knows it by, where Sendspin names the group after the speaker leading it.
    private(set) var ownGroupName: String?
    /// The chosen player, watched and controlled through the server, while this device isn't
    /// playing as part of it; nil while the device's own Sendspin connection covers it.
    private(set) var remote: RemotePlayer?
    private var remoteTask: Task<Void, Never>?
    /// The player the user chose to play on; nil for this device.
    private(set) var chosenPlayerID: String?

    private static let chosenPlayerKey = "LibraryModel.chosenPlayer"

    /// Where picked music plays: the chosen player while the server still offers it,
    /// otherwise this device.
    var target: ServerPlayer? {
        players.first { $0.playerID == chosenPlayerID } ?? ownPlayer
    }

    init(client: SendspinClient, deviceName: String) {
        self.client = client
        self.deviceName = deviceName
        chosenPlayerID = UserDefaults.standard.string(forKey: Self.chosenPlayerKey)
    }

    /// Music Assistant serves its API and web interface from the Sendspin server's host, on
    /// this port unless configured otherwise.
    static let defaultWebPort = 8095

    /// Where Music Assistant is expected on the Sendspin server at `host`.
    static func defaultURL(host: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = defaultWebPort
        return components.url
    }

    /// What to call the server in messages.
    private var serverLabel: String { isOpen ? "The server" : "Music Assistant" }

    /// Follow the server to `url`, signing in with the token kept for it, if any. An `open`
    /// server needs none.
    func setServer(_ url: URL?, open: Bool = false) {
        guard url != server || open != isOpen else { return }
        server = url
        isOpen = open && url != nil
        api = nil
        userName = nil
        players = []
        ownPlayer = nil
        updateRemote()
        if let url, open {
            api = MusicAssistantAPI(baseURL: url, token: "")
            Task { await loadPlayers() }
            return
        }
        guard let url, let token = TokenKeychain.load(account: Self.account(url)) else { return }
        api = MusicAssistantAPI(baseURL: url, token: token)
        Task { await refreshUser() }
    }

    // MARK: Signing in

    func signIn(username: String, password: String) async {
        guard let server else { return }
        await signIn {
            try await MusicAssistantAPI.login(baseURL: server, username: username, password: password,
                                              deviceName: self.deviceName)
        }
    }

    /// Sign in with an access token made in Music Assistant, for accounts without a password
    /// of their own, such as those that come from Home Assistant.
    func signIn(token: String) async {
        await signIn { token }
    }

    private func signIn(token: @MainActor () async throws -> String) async {
        guard let server, !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let candidate = MusicAssistantAPI(baseURL: server, token: try await token())
            userName = try await candidate.userName()
            TokenKeychain.save(candidate.token, account: Self.account(server))
            api = candidate
        } catch {
            report(error)
        }
    }

    func signOut() {
        if let server { TokenKeychain.delete(account: Self.account(server)) }
        api = nil
        userName = nil
        players = []
        ownPlayer = nil
        updateRemote()
    }

    private func refreshUser() async {
        guard let api else { return }
        do {
            userName = try await api.userName()
        } catch {
            // Only a refused token signs out; an unreachable server may be back shortly.
            if case MusicAssistantAPI.APIError.unauthorized = error { report(error) }
        }
    }

    private static func account(_ server: URL) -> String {
        "music-assistant:\(server.host(percentEncoded: false) ?? server.absoluteString)"
    }

    // MARK: Playing

    /// Fetch the players music can be sent to, and which of them is this device.
    func loadPlayers() async {
        guard let api else { return }
        do {
            let all = try await api.players()
            if let clientID = await client.clientID() {
                ownPlayer = MusicAssistantAPI.player(forSendspinClient: clientID, in: all)
            }
            ownGroupName = ownPlayer?.activeGroup.flatMap { id in all.first { $0.playerID == id }?.name }
            // This device first and always, then groups, then the other players.
            let own = ownPlayer?.playerID
            func rank(_ player: ServerPlayer) -> Int { player.playerID == own ? 0 : player.isGroup ? 1 : 2 }
            players = all.filter { $0.isSelectable || $0.playerID == own }.sorted {
                (rank($0), $0.name.lowercased()) < (rank($1), $1.name.lowercased())
            }
            updateRemote()
        } catch {
            report(error)
        }
    }

    /// Play on `player` from now on; nil for this device.
    func choosePlayer(_ player: ServerPlayer?) {
        chosenPlayerID = player?.playerID == ownPlayer?.playerID ? nil : player?.playerID
        UserDefaults.standard.set(chosenPlayerID, forKey: Self.chosenPlayerKey)
        updateRemote()
    }

    /// What the player screen should show: the chosen player, or this device's own group.
    var nowPlaying: any NowPlayingSource { remote ?? client }

    /// Watch the chosen player through the server unless this device is playing as part of
    /// it, in which case its Sendspin connection already shows and controls the same music.
    private func updateRemote() {
        var wanted: ServerPlayer?
        if let target, let api, target.playerID != ownPlayer?.playerID,
           ownPlayer?.activeGroup != target.playerID, ownPlayer?.syncedTo != target.playerID {
            wanted = target
            guard remote?.player.playerID != target.playerID else { return }
            let player = RemotePlayer(player: target, api: api) { [weak self] in self?.report($0) }
            remoteTask?.cancel()
            remote = player
            remoteTask = Task { await player.run() }
        }
        if wanted == nil {
            remoteTask?.cancel()
            remoteTask = nil
            remote = nil
        }
    }

    /// Play `item` on the chosen player. A track picked from inside an album or playlist
    /// plays that `container` from the track on, so the rest follows it.
    func play(_ item: MediaItem, option: QueueOption? = nil, in container: MediaItem? = nil,
              shuffle: Bool? = nil) {
        guard let api else { return }
        startingItemID = item.id
        Task {
            defer { if startingItemID == item.id { startingItemID = nil } }
            do {
                if target == nil { await loadPlayers() }
                guard let queueID = target?.playerID else {
                    errorMessage = "\(serverLabel) doesn't list this device as a player yet. "
                        + "Check the Player tab: it may still need to be paired."
                    return
                }
                if let container, option == nil {
                    try await api.play([container.uri], queueID: queueID, option: .replace, startItem: item.uri)
                } else {
                    try await api.play([item.uri], queueID: queueID, option: option, shuffle: shuffle)
                }
                if startingItemID == item.id { startingItemID = nil }
                await remote?.refresh()
                // Starting a group can pull this device into it: look again once it has.
                try? await Task.sleep(for: .seconds(2))
                await loadPlayers()
            } catch MusicAssistantAPI.APIError.server(_, let message) {
                errorMessage = "\(serverLabel) couldn't play “\(item.title)”"
                    + (message.isEmpty ? "." : ": \(message)")
            } catch {
                report(error)
            }
        }
    }

    /// Show `error`, unless it's only a cancelled request. A refused token signs out, so the
    /// sign-in screen returns.
    func report(_ error: Error) {
        if error is CancellationError { return }
        if case MusicAssistantAPI.APIError.unauthorized = error, api != nil, !isOpen {
            signOut()
            errorMessage = "Music Assistant no longer accepts this sign-in. Please sign in again."
            return
        }
        errorMessage = "\(error)"
    }

    func artworkURL(_ item: MediaItem, points: Int) -> URL? {
        guard let server else { return nil }
        return item.image?.url(server: server, points: points)
    }
}

/// The Music Assistant access token in the Keychain, one per server. It stays on this device.
private enum TokenKeychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: AppModel.keychainService,
         kSecAttrAccount as String: account]
    }

    static func load(account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, account: String) {
        let query = query(account)
        let data = Data(token.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status != errSecSuccess { NSLog("Saving the Music Assistant token failed: %d", status) }
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
