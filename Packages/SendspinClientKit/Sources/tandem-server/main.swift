import Foundation
import SendspinClientKit
import TandemServerKit

// The standalone server without a window, for a machine that stays on: it plays a folder of
// music on the Sendspin players that connect to it. Commands are typed on standard input.

let usage = """
usage: tandem-server --music <folder> [--name <name>] [--data <folder>] [--api-port <port>] [--loopback] [--debug]

Then, on standard input:
  players            list the players that are connected
  pair <n>           pair with player n; it shows a code
  code <n> <digits>  enter the code player n shows; the code alone will do when only
                     one player waits for it
  allow <n>          let player n play without pairing, if it admits that
  forget <n>         forget player n's pairing
  use <n>            take player n back, after another server had it
  speakers           list the AirPlay speakers
  speaker <n> on|off have AirPlay speaker n play with the group, or not
  speaker <n> <0-100> set AirPlay speaker n's volume
  rescan             read the music folder again
  quit
"""

// Unbuffered, so what it prints reaches a log file as it happens.
setvbuf(stdout, nil, _IONBF, 0)

var options: [String: String] = [:]
var loopback = false
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    if flag == "--debug" {
        Log.minimumLevel = .debug
    } else if flag == "--loopback" {
        // Test players on this machine announce a loopback address.
        loopback = true
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
    apiPort: options["api-port"].flatMap(UInt16.init) ?? 8929, dialsLoopback: loopback))

func describe(_ player: StandaloneServer.Player) -> String {
    var text = "\(player.name): "
    // While it pairs, that is all there is to say.
    let pairing = player.pairing.map { progress in
        if case .paired = progress { false } else if case .failed = progress { false } else { true }
    } ?? false
    switch pairing ? nil : player.connection {
    case nil: text += "pairing"
    case .connected?: text += player.paired ? "playing in the group" : "playing in the group, not paired"
    case .pairingRequired?: text += "needs pairing"
    case .notRecognized?: text += "lost its pairing with this server; pair it again"
    case .awaitingApproval?: text += "waits to be allowed"
    case .left?: text += "left the group"
    case .connecting?: text += "connecting"
    case .taken?: text += "in use by another server; 'use' takes it back"
    case .unavailable?: text += "can't be reached"
    case .notApproved?: text += "isn't the device that was allowed"
    case .disconnected?: text += "not connected"
    case .failed(let reason)?: text += "failed (\(reason))"
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

/// Enter a code as it was typed: its digits, whatever separates them.
func enter(_ code: String, for player: StandaloneServer.Player) async {
    guard case .enteringCode = player.pairing else {
        print("\(player.name) isn't waiting for a code. Start with: pair <n>")
        return
    }
    await server.enterCode(code.filter(\.isNumber), for: player.id)
}

func describe(_ speaker: AirPlaySpeakers.Speaker) -> String {
    var text = "\(speaker.name)\(speaker.model.map { " (\($0))" } ?? ""): \(speaker.enabled ? "on" : "off")"
    guard speaker.enabled else { return text }
    text += ", volume \(speaker.volume)"
    if !speaker.present { return text + ", not on the network" }
    switch speaker.status {
    case .idle: break
    case .connecting: text += ", connecting"
    case .playing: text += ", playing"
    case .failed(let reason): text += ", failed: \(reason)"
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
        if state.speakers.filter(\.enabled) != last.speakers.filter(\.enabled) {
            for speaker in state.speakers where speaker.enabled { print("  AirPlay: \(describe(speaker))") }
        }
        last = state
    }
}

// Asked to end, as a service manager or Ctrl-C does: let the speakers go first, or they
// keep waiting for audio.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signals = [SIGTERM, SIGINT].map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        Task {
            await server.stop()
            exit(0)
        }
    }
    source.resume()
    return source
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
        await enter(words[2...].joined(), for: player)
    case ("allow", let player?):
        await server.allow(player.id)
    case ("forget", let player?):
        await server.forget(player.id)
    case ("use", let player?):
        await server.use(player.id)
    case ("speakers", _):
        let speakers = await server.currentState.speakers
        for (index, speaker) in speakers.enumerated() { print("  \(index + 1). \(describe(speaker))") }
        if speakers.isEmpty { print("  No AirPlay speakers found.") }
    case ("speaker", _) where words.count == 3:
        let speakers = await server.currentState.speakers
        guard let number = Int(words[1]), speakers.indices.contains(number - 1) else {
            print("No such speaker; 'speakers' lists them.")
            break
        }
        let speaker = speakers[number - 1]
        if let volume = Int(words[2]) {
            await server.setSpeaker(speaker.id, volume: volume)
        } else if ["on", "off"].contains(words[2]) {
            await server.setSpeaker(speaker.id, enabled: words[2] == "on")
        } else {
            print("Say on, off or a volume from 0 to 100.")
        }
    case ("rescan", _):
        await server.setMusicFolder(musicFolder)
    case ("quit", _), ("exit", _):
        await server.stop()
        exit(0)
    case (nil, _):
        break
    case (let word?, _) where ["pair", "code", "allow", "forget", "use"].contains(word):
        print(players.isEmpty ? "No players connected." : "Say which player by its number, as in: \(word) 1")
    case _ where line.contains(where: \.isNumber) && line.allSatisfy({ $0.isNumber || $0 == "-" || $0 == " " }):
        // A code typed alone, as the player shows it: "482-044".
        let waiting = players.filter { if case .enteringCode = $0.pairing { true } else { false } }
        if waiting.count == 1 {
            await enter(line, for: waiting[0])
        } else if waiting.isEmpty {
            print("No player waits for a code. Start with: pair <n>")
        } else {
            print("More than one player waits for a code. Say which: code <n> <digits>")
        }
    default:
        print(usage)
    }
}
// Standard input closed, as under a service manager: keep serving.
while true { try await Task.sleep(for: .seconds(3600)) }
