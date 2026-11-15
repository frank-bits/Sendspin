#if os(macOS)
import AppKit
import Foundation
import SendspinClientKit
import TandemServerKit

/// This Mac as a Sendspin server of its own: it plays a folder of music on the Tandem apps
/// and other players that connect to it, without Home Assistant or Music Assistant.
@MainActor
@Observable
final class HostModel {
    /// The server's players and library, as it last reported them.
    private(set) var state = StandaloneServer.State()
    /// The folder of music files the server plays from.
    private(set) var folder: URL?
    /// Whether the server runs; it starts with the app while this is on.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
        }
    }

    let serverName: String
    private var server: StandaloneServer?
    private var watching: Task<Void, Never>?

    private static let enabledKey = "host.enabled"
    private static let folderKey = "host.musicFolder"

    init() {
        serverName = "Tandem on \(Host.current().localizedName ?? "this Mac")"
        folder = UserDefaults.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0) }
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if isEnabled { start() }
    }

    private func start() {
        guard server == nil else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let server = StandaloneServer(configuration: .init(
            name: serverName, dataDirectory: support.appendingPathComponent("Tandem/Server"), musicFolder: folder))
        self.server = server
        watching = Task { [weak self] in
            await server.start()
            self?.state = await server.currentState
            for await state in server.states {
                self?.state = state
            }
        }
    }

    private func stop() {
        watching?.cancel()
        watching = nil
        let stopping = server
        server = nil
        state = StandaloneServer.State()
        Task { await stopping?.stop() }
    }

    /// Ask for the folder of music to play from.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds your music files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        rescan()
    }

    /// Read the music folder again, for files added or changed since.
    func rescan() {
        let folder = folder
        Task { await server?.setMusicFolder(folder) }
    }

    // MARK: Players

    func pair(_ player: StandaloneServer.Player) {
        Task { await server?.pair(player.id) }
    }

    /// The code read off the player; nil cancels the pairing.
    func enterCode(_ code: String?, for player: StandaloneServer.Player) {
        Task { await server?.enterCode(code, for: player.id) }
    }

    func allow(_ player: StandaloneServer.Player) {
        Task { await server?.allow(player.id) }
    }

    /// Take back a speaker another server had.
    func use(_ player: StandaloneServer.Player) {
        Task { await server?.use(player.id) }
    }

    func forget(_ player: StandaloneServer.Player) {
        Task { await server?.forget(player.id) }
    }
}
#endif
