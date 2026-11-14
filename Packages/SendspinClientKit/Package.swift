// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SendspinClientKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SendspinClientKit", targets: ["SendspinClientKit"]),
        .library(name: "MusicAssistantKit", targets: ["MusicAssistantKit"]),
        .library(name: "TandemServerKit", targets: ["TandemServerKit"]),
        .executable(name: "sendspin-probe", targets: ["sendspin-probe"]),
        .executable(name: "tandem-server", targets: ["tandem-server"]),
    ],
    targets: [
        // Sendspin 1, both sides: the client (discovery, Noise handshake, pairing, clock sync,
        // playback) and, under `Server/`, the server's side of the same protocol.
        // `Upstream/` and `Server/` hold code from github.com/Sendspin/sendspin-mac (see UPSTREAM.md).
        .target(name: "SendspinClientKit"),
        // Connects to a server and logs the handshake: the Phase 0 interop check.
        .executableTarget(name: "sendspin-probe", dependencies: ["SendspinClientKit"]),
        .testTarget(name: "SendspinClientKitTests", dependencies: ["SendspinClientKit"]),
        // Music Assistant's own API, for what Sendspin leaves out: browsing, searching and
        // choosing the music to play.
        .target(name: "MusicAssistantKit"),
        .testTarget(name: "MusicAssistantKitTests", dependencies: ["MusicAssistantKit"]),
        // A server of our own: a folder of music as a library, a queue played on the players
        // that connect, and an HTTP API for apps to browse and choose with.
        .target(name: "TandemServerKit", dependencies: ["SendspinClientKit"]),
        // That server without a window, for a machine that stays on.
        .executableTarget(name: "tandem-server", dependencies: ["TandemServerKit", "SendspinClientKit"]),
        .testTarget(name: "TandemServerKitTests", dependencies: ["TandemServerKit", "SendspinClientKit", "MusicAssistantKit"]),
    ]
)
