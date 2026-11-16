import Foundation
import Network
import SendspinClientKit

/// A speaker on the network that takes AirPlay audio.
public struct AirPlaySpeaker: Sendable, Hashable, Identifiable {
    /// Its hardware address, as it announces it: the same across restarts and renames.
    public var id: String
    public var name: String
    /// What it calls its model, e.g. "Era 100".
    public var model: String?
    /// Whether it wants the extra setup step some makers' speakers ask for (MFi).
    var wantsAuthSetup: Bool
    var endpoint: NWEndpoint
}

enum AirPlayBrowser {
    static let serviceType = "_raop._tcp"

    /// The speakers that take plain AirPlay audio, whenever they change. Apple's own devices
    /// (Apple TV, HomePod, Macs) aren't among them: they insist on Apple's protected form.
    static func browse() -> AsyncStream<[AirPlaySpeaker]> {
        AsyncStream { continuation in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: NWParameters())
            browser.browseResultsChangedHandler = { results, _ in
                let speakers = Dictionary(results.compactMap(speaker).map { ($0.id, $0) }) { first, _ in first }
                continuation.yield(speakers.values.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) })
            }
            browser.start(queue: DispatchQueue(label: "tandem.airplay.browser"))
            continuation.onTermination = { _ in browser.cancel() }
        }
    }

    private static func speaker(_ result: NWBrowser.Result) -> AirPlaySpeaker? {
        guard case let .service(instance, _, _, _) = result.endpoint, case let .bonjour(txt) = result.metadata else { return nil }
        return speaker(instance: instance, txt: txt.dictionary, endpoint: result.endpoint)
    }

    /// What an announcement says, if the speaker is one we can play on. The instance name is
    /// the hardware address, an "@", and the name people see.
    static func speaker(instance: String, txt: [String: String], endpoint: NWEndpoint) -> AirPlaySpeaker? {
        let parts = instance.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        func numbers(_ key: String) -> Set<Int> { Set((txt[key] ?? "").split(separator: ",").compactMap { Int($0) }) }
        let encryption = numbers("et")
        // Without encryption (0), as ALAC (1), no password, and not one of Apple's (3 and 5
        // are its protected forms, which only its own devices list).
        guard encryption.contains(0), encryption.isDisjoint(with: [3, 5]), numbers("cn").contains(1),
              txt["pw"]?.lowercased() != "true" else { return nil }
        return AirPlaySpeaker(id: parts[0], name: parts[1], model: txt["am"], wantsAuthSetup: encryption.contains(4),
                              endpoint: endpoint)
    }
}
