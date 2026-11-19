import Foundation
import Observation

/// A Sendspin player and controller for an app's interface: finds servers, keeps a connection
/// to one, plays its audio on this device, and publishes what's playing and what can be
/// controlled. Its properties are observable from SwiftUI.
@MainActor
@Observable
public final class SendspinClient {
    public enum Connection: Equatable {
        /// Not connected, and no server chosen yet.
        case searching
        case connecting(String)
        case connected(String)
        /// The last attempt failed; another follows.
        case retrying(String)
    }

    public private(set) var servers: [DiscoveredServer] = []
    public private(set) var connection: Connection = .searching
    /// The address of the server the client last connected to, e.g. "192.168.1.20".
    public private(set) var serverHost: String?
    /// Where that server serves a library API of its own, when it announces one; nil for a
    /// server whose library is found some other way, such as Music Assistant.
    public private(set) var libraryURL: URL?
    /// The server holds this device's pairing record: it may play here.
    public private(set) var isPaired = false
    /// A six-digit code to show while the server pairs with this device.
    public private(set) var pairingCode: String?
    public private(set) var activeRoles: [String] = []
    public private(set) var group: GroupInfo?
    public private(set) var controller: ControllerState?
    public private(set) var metadata: TrackMetadata?

    public var isPlaying: Bool { group?.isPlaying ?? false }

    private static let lastServerKey = "SendspinClient.lastServer"

    private let store: CredentialStore
    private let configuration: ClientConfiguration
    private var session: ClientSession?
    private var engine: PlayerEngine?
    private var browseTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var wantsConnection = true
    /// What to tell a server we leave: `user_request`, or `another_server` when switching.
    private var goodbye = "user_request"
    /// When the current metadata took effect on this device's clock, for the track position.
    private var metadataLocalUs: Int64?
    private var pendingMetadata: Task<Void, Never>?

    /// `name` is what the server shows for this device.
    public init(name: String, productName: String, manufacturer: String = "Apple", softwareVersion: String,
                store: CredentialStore) {
        self.store = store
        configuration = ClientConfiguration(
            name: name, productName: productName, manufacturer: manufacturer, softwareVersion: softwareVersion,
            supportedRoles: ["player@v1", "controller@v1", "metadata@v1"], playerSupport: PlayerEngine.support())
        OutputDevice.onChange { [weak self] in
            Task { @MainActor in await self?.engine?.outputChanged() }
        }
    }

    /// This device's Sendspin identity, as servers know it; nil when its stored key is corrupt.
    public func clientID() async -> String? {
        await store.credentials.clientID
    }

    // MARK: Connection

    /// Look for servers, and connect to the one used last, or to the only one there is.
    public func start() {
        guard browseTask == nil else { return }
        browseTask = Task { [weak self] in
            for await found in ServerBrowser.browse() {
                self?.serversChanged(found)
            }
        }
    }

    private func serversChanged(_ found: [DiscoveredServer]) {
        servers = found
        guard runTask == nil, wantsConnection else { return }
        let last = UserDefaults.standard.string(forKey: Self.lastServerKey)
        // The only server there is, is taken only while none was chosen before: servers show up
        // one by one, and the first seen would otherwise replace the one used last.
        let only = last == nil && found.count == 1 ? found.first : nil
        if let server = found.first(where: { $0.instanceName == last }) ?? only {
            connect(to: server)
        }
    }

    /// Connect to `server` and stay connected, reconnecting when the connection drops.
    public func connect(to server: DiscoveredServer) {
        wantsConnection = true
        UserDefaults.standard.set(server.instanceName, forKey: Self.lastServerKey)
        goodbye = "another_server"
        runTask?.cancel()
        runTask = Task { [weak self] in await self?.run(server) }
    }

    /// Leave the server and stay disconnected until `connect(to:)`.
    public func disconnect() {
        wantsConnection = false
        goodbye = "user_request"
        runTask?.cancel()
        runTask = nil
        connection = .searching
    }

    /// Forget every pairing: servers must pair with this device again.
    public func forgetPairings() async {
        await store.forgetPairings()
        // The open connection runs on a forgotten key: reconnect, and the server offers pairing.
        await session?.close(goodbye: "restart")
    }

    private func run(_ server: DiscoveredServer) async {
        let name = server.name ?? "server"
        var delay = 1
        while !Task.isCancelled {
            connection = delay == 1 ? .connecting(name) : .retrying(name)
            do {
                let url = try await ServerBrowser.resolve(server)
                serverHost = url.host(percentEncoded: false)
                libraryURL = server.libraryPort.flatMap { port in
                    var address = URLComponents()
                    address.scheme = "http"
                    address.host = url.host(percentEncoded: false)
                    address.port = port
                    return address.url
                }
                let status = ClientStatus(available: true, player: PlayerEngine.state(volume: 100, muted: false))
                let session = ClientSession(url: url, store: store, configuration: configuration, status: status)
                let engine = PlayerEngine(session: session)
                self.session = session
                self.engine = engine
                Task { await session.run() }
                for await event in session.events {
                    // Audio first: its timing matters more than the interface's.
                    await engine.handle(event)
                    await apply(event)
                    if case .activated = event { delay = 1 }
                }
                // Cancelled while connected: the events stopped, but the session still runs.
                if Task.isCancelled { await session.close(goodbye: goodbye) }
                await engine.handle(.closed(reason: nil))
            } catch {
                Log.info("Connecting to \(name) failed: \(error)")
            }
            sessionEnded()
            guard !Task.isCancelled else { return }
            connection = .retrying(name)
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 30)
        }
    }

    private func sessionEnded() {
        session = nil
        engine = nil
        isPaired = false
        pairingCode = nil
        activeRoles = []
        group = nil
        controller = nil
        setMetadata(nil, localUs: nil)
    }

    // MARK: Events

    private func apply(_ event: SessionEvent) async {
        switch event {
        case let .handshakeCompleted(_, category):
            isPaired = category == "lt"
        case let .serverHello(name):
            connection = .connected(name)
        case let .activated(_, roles, paired):
            activeRoles = roles
            isPaired = paired
            // A removed role's state is discarded at once (messaging.md, server/activate).
            if !roles.contains("controller@v1") { controller = nil }
            if !roles.contains("metadata@v1") { setMetadata(nil, localUs: nil) }
        case let .pairingCode(code):
            pairingCode = code
        case let .message(type, json) where type == "group/update":
            if let update = try? MessageCoding.payload(GroupInfo.self, from: json) { group = update }
        case let .message(type, json) where type == "server/state":
            guard let state = try? MessageCoding.payload(ServerStateReceived.self, from: json) else { return }
            if let controller = state.controller, activeRoles.contains("controller@v1") { self.controller = controller }
            if let metadata = state.metadata, activeRoles.contains("metadata@v1") { await receive(metadata) }
        default:
            break
        }
    }

    /// Metadata takes effect at its timestamp: at once when that's past, otherwise it waits as
    /// the one pending update, replacing any held before (roles/metadata/v1.md).
    private func receive(_ metadata: TrackMetadata) async {
        guard let session else { return }
        let localUs = await session.localTime(fromServer: metadata.timestamp)
        let waitUs = localUs - ServerClock.nowMicros()
        guard waitUs > 0 else {
            setMetadata(metadata, localUs: localUs)
            return
        }
        pendingMetadata?.cancel()
        pendingMetadata = Task { [weak self] in
            try? await Task.sleep(for: .microseconds(waitUs))
            guard !Task.isCancelled else { return }
            self?.setMetadata(metadata, localUs: localUs)
        }
    }

    private func setMetadata(_ metadata: TrackMetadata?, localUs: Int64?) {
        pendingMetadata?.cancel()
        pendingMetadata = nil
        self.metadata = metadata
        metadataLocalUs = localUs
    }

    /// The track position now and the track's length, in ms; nil when the server reports none.
    /// A length of 0 means unknown, as for live radio.
    public func playbackPosition() -> (positionMs: Int, durationMs: Int)? {
        guard let progress = metadata?.progress, let metadataLocalUs else { return nil }
        let position = progress.positionMs(elapsedUs: ServerClock.nowMicros() - metadataLocalUs)
        return (position, progress.trackDuration)
    }

    // MARK: Commands

    /// Whether the group currently accepts `command`, e.g. "play", "next", "volume", "seek".
    public func supports(_ command: String) -> Bool {
        controller?.supportedCommands.contains(command) ?? false
    }

    public func play() { command("play") }
    public func pause() { command("pause") }
    public func togglePlayPause() { isPlaying ? pause() : play() }
    public func next() { command("next") }
    public func previous() { command("previous") }
    public func setShuffle(_ on: Bool) { command(on ? "shuffle" : "unshuffle") }
    /// "off", "one" or "all".
    public func setRepeat(_ mode: String) { command("repeat_\(mode)") }
    /// Move this device to the next group in the server's cycle.
    public func switchGroup() { command("switch") }

    /// Volume of the whole group, 0-100.
    public func setVolume(_ volume: Int) {
        command("volume") { $0.volume = min(100, max(0, volume)) }
    }

    public func setMuted(_ muted: Bool) {
        command("mute") { $0.mute = muted }
    }

    public func seek(toMs position: Int) {
        guard let limit = controller?.seekMaxMs else { return }
        command("seek") { $0.positionMs = min(limit, max(0, position)) }
    }

    /// The server ignores commands it doesn't list, so they aren't sent.
    private func command(_ name: String, configure: (inout ClientCommandMessage.Controller) -> Void = { _ in }) {
        guard supports(name), let session else { return }
        var controller = ClientCommandMessage.Controller(command: name)
        configure(&controller)
        let message = ClientCommandMessage(controller: controller)
        Task { await session.send(type: "client/command", payload: message) }
    }
}
