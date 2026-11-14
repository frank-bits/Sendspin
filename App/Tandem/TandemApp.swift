import SendspinClientKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct TandemApp: App {
    @State private var model = AppModel()

    #if os(macOS)
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .defaultSize(width: 520, height: 720)

        MenuBarExtra("Tandem", systemImage: "hifispeaker.2.fill") {
            MenuBarView(model: model)
        }
    }
    #else
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
    #endif
}

/// What the app holds for its lifetime: the Sendspin client, or why it couldn't be set up.
@MainActor
@Observable
final class AppModel {
    nonisolated static let keychainService = "app.tandem.player"

    let client: SendspinClient?
    let library: LibraryModel?
    let startupError: String?
    let deviceName: String
    private var nowPlaying: NowPlayingBridge?
    #if os(macOS)
    /// This Mac as a server of its own, for other devices to play from.
    let host = HostModel()
    #endif

    init() {
        #if os(iOS)
        let device = UIDevice.current.name
        let product = UIDevice.current.model
        #else
        let device = Host.current().localizedName ?? "Mac"
        let product = "Mac"
        #endif
        // Told apart from the device's own AirPlay receiver, which servers list under the bare name.
        deviceName = "\(device) (Tandem)"
        // `TANDEM_LOG=debug` in the environment logs the stream's events to stderr.
        if ProcessInfo.processInfo.environment["TANDEM_LOG"] == "debug" { Log.minimumLevel = .debug }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        do {
            let store = try KeychainCredentials.store(service: Self.keychainService)
            let client = SendspinClient(name: deviceName, productName: product, softwareVersion: version, store: store)
            self.client = client
            library = LibraryModel(client: client, deviceName: deviceName)
            startupError = nil
            nowPlaying = NowPlayingBridge(client: client)
            client.start()
        } catch {
            client = nil
            library = nil
            startupError = "\(error)"
        }
    }
}

#if os(macOS)
/// Playback controls in the menu bar.
struct MenuBarView: View {
    let model: AppModel

    var body: some View {
        if let client = model.client {
            Text(client.metadata?.title ?? "Nothing playing")
            if let artist = client.metadata?.artist { Text(artist) }
            Divider()
            Button(client.isPlaying ? "Pause" : "Play") { client.togglePlayPause() }
                .disabled(!client.supports(client.isPlaying ? "pause" : "play"))
            Button("Next") { client.next() }.disabled(!client.supports("next"))
            Button("Previous") { client.previous() }.disabled(!client.supports("previous"))
            Divider()
        }
        Button("Quit Tandem") { NSApplication.shared.terminate(nil) }
    }
}
#endif
