import Foundation
import SendspinClientKit
import TandemServerKit

// The standalone server without a window, for a machine that stays on: it plays a folder of
// music on the Sendspin players that connect to it. Commands are typed on standard input.

let usage = """
usage: tandem-server --music <folder> [--name <name>] [--data <folder>] [--api-port <port>] [--debug]

Then, on standard input:
  players            list the players that are connected
  pair <n>           pair with player n; it shows a code
  code <n> <digits>  enter the code player n shows
  allow <n>          let player n play without pairing, if it admits that
  forget <n>         forget player n's pairing
  rescan             read the music folder again
  quit
"""

var options: [String: String] = [:]
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    if flag == "--debug" {
        Log.minimumLevel = .debug
    } else if flag.hasPrefix("--"), !arguments.isEmpty {
        options[String(flag.dropFirst(2))] = arguments.removeFirst()
    } else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(2)
    }
}
guard let music = options["music"] else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let musicFolder = URL(fileURLWithPath: (music as NSString).expandingTildeInPath)
let server = StandaloneServer(configuration: .init(
    name: options["name"] ?? "Tandem on \(Host.current().localizedName ?? "this computer")",
    dataDirectory: options["data"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? support.appendingPathComponent("Tandem Server"),
    musicFolder: musicFolder,
    apiPort: options["api-port"].flatMap(UInt16.init) ?? 8929))

func describe(_ player: StandaloneServer.Player) -> String {
    var text = "\(player.name): "
    switch player.connection {
    case .connected: text += player.paired ? "playing in the group" : "playing in the group, not paired"
    case .pairingRequired: text += "needs pairing"
    case .notRecognized: text += "lost its pairing with this server; pair it again"
    case .awaitingApproval: text += "waits to be allowed"
    case .left: text += "left the group"
    case .connecting: text += "connecting"
    default: text += "\(player.connection)"
    }
    switch player.pairing {
    case .enteringCode?: text += " - enter the code it shows"
    case .checking?: text += " - checking the code"
    case .waiting(let message)?: text += " - waiting\(message.map { " (it says: \($0))" } ?? "")"
    case .failed(let reason)?: text += " - pairing failed: \(reason)"
    default: break
    }
    return text
}

await server.start()
let started = await server.currentState
if let error = started.error {
    FileHandle.standardError.write(Data("The server can't start: \(error)\n".utf8))
    exit(1)
}

Task {
    var last = StandaloneServer.State()
    for await state in server.states {
        if state.library != last.library {
            switch state.library {
            case .noFolder: print("No music folder.")
            case .scanning(let found): if found == 0 { print("Reading \(musicFolder.path)…") }
            case .ready(let tracks): print("Library ready: \(tracks) tracks.")
            case .failed(let reason): print("The library can't be read: \(reason)")
            }
        }
        if state.players != last.players {
            for (index, player) in state.players.enumerated() { print("  \(index + 1). \(describe(player))") }
            if state.players.isEmpty { print("  No players connected.") }
        }
        last = state
    }
}

for try await line in FileHandle.standardInput.bytes.lines {
    let words = line.split(separator: " ").map(String.init)
    let players = await server.currentState.players
    let chosen = words.count > 1 ? Int(words[1]).flatMap { players.indices.contains($0 - 1) ? players[$0 - 1] : nil } : nil
    switch (words.first, chosen) {
    case ("players", _):
        for (index, player) in players.enumerated() { print("  \(index + 1). \(describe(player))") }
        if players.isEmpty { print("  No players connected.") }
    case ("pair", let player?):
        await server.pair(player.id)
    case ("code", let player?) where words.count > 2:
        await server.enterCode(words[2...].joined(), for: player.id)
    case ("allow", let player?):
        await server.allow(player.id)
    case ("forget", let player?):
        await server.forget(player.id)
    case ("rescan", _):
        await server.setMusicFolder(musicFolder)
    case ("quit", _), ("exit", _):
        await server.stop()
        exit(0)
    case (nil, _):
        break
    default:
        print(usage)
    }
}
// Standard input closed, as under a service manager: keep serving.
while true { try await Task.sleep(for: .seconds(3600)) }
