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
    /// It speaks AirPlay 2 and lets a sender in without a code: the form to use with it. Some
    /// speakers that still list the first AirPlay play nothing over it.
    var usesAirPlay2 = false
    /// It takes its time from a clock on the network (PTP) rather than by asking us.
    var followsClock = false
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

    /// Whether the feature bits a speaker announces ("0xLOW,0xHIGH") say it takes AirPlay 2
    /// with the pairing that needs no code: bit 38 or 48 for AirPlay 2, bit 46 or 48 for that
    /// pairing, and no flag asking for a PIN (0x8) or the older pairing (0x200).
    static func usesAirPlay2(features text: String?, flags: String?) -> Bool {
        let bits = features(text)
        let status = number(Substring(flags ?? "0x0")) ?? 0
        func has(_ bit: UInt64) -> Bool { bits >> bit & 1 == 1 }
        return (has(38) || has(48)) && (has(46) || has(48)) && status & 0x208 == 0
    }

    private static func number(_ text: Substring) -> UInt64? {
        UInt64(text.trimmingCharacters(in: .whitespaces).dropFirst(text.lowercased().contains("0x") ? 2 : 0), radix: 16)
    }

    /// The feature bits of an announcement, low word first in the text; 0 without any.
    static func features(_ text: String?) -> UInt64 {
        let parts = (text ?? "").split(separator: ",")
        guard let low = parts.first.flatMap(number) else { return 0 }
        return (parts.count > 1 ? number(parts[1]) ?? 0 : 0) << 32 | low
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
                              usesAirPlay2: usesAirPlay2(features: txt["ft"], flags: txt["sf"]),
                              followsClock: features(txt["ft"]) >> 41 & 1 == 1, endpoint: endpoint)
    }
}
