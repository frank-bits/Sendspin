import Foundation
import SendspinClientKit

/// What the server keeps between runs, as files in one folder: its identity, the players
/// paired with it, those allowed without pairing, and what was played lately. The identity
/// and the pairings are secrets, readable by this user only.
public final class ServerStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var allowed: Set<String>
    private var recent: [String]
    private var airPlay: [String: AirPlaySetting]

    private static let recentLimit = 24

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        allowed = Set(Self.read([String].self, directory.appendingPathComponent("allowed.json")) ?? [])
        recent = Self.read([String].self, directory.appendingPathComponent("recent.json")) ?? []
        airPlay = Self.read([String: AirPlaySetting].self, directory.appendingPathComponent("airplay.json")) ?? [:]
    }

    var libraryCache: URL { directory.appendingPathComponent("library.json") }

    /// The server's key, made on first use: with it gone, every player sees a different server.
    func identity(name: String) throws -> ServerIdentity {
        let file = directory.appendingPathComponent("identity.key")
        if let data = try? Data(contentsOf: file), let identity = try? ServerIdentity(privateKeyData: data, name: name) {
            return identity
        }
        let identity = ServerIdentity.generate(name: name)
        try write(identity.privateKeyData, to: file)
        return identity
    }

    /// The pairings, saved whenever one is added or removed.
    func pairings() -> PlayerPairings {
        let file = directory.appendingPathComponent("pairings.json")
        let stored = Self.read([String: Data].self, file) ?? [:]
        return PlayerPairings(records: stored) { [weak self] records in
            guard let data = try? JSONEncoder().encode(records) else { return }
            try? self?.write(data, to: file)
        }
    }

    // MARK: Players allowed without pairing

    func isAllowed(_ clientID: String) -> Bool {
        lock.withLock { allowed.contains(clientID) }
    }

    func setAllowed(_ clientID: String, _ isAllowed: Bool) {
        let ids = lock.withLock {
            if isAllowed { allowed.insert(clientID) } else { allowed.remove(clientID) }
            return allowed.sorted()
        }
        save(ids, "allowed.json")
    }

    // MARK: Recently played

    /// Album ids, the latest first.
    var recentAlbums: [String] {
        lock.withLock { recent }
    }

    func played(albumID: String) {
        let ids = lock.withLock {
            recent.removeAll { $0 == albumID }
            recent.insert(albumID, at: 0)
            recent = Array(recent.prefix(Self.recentLimit))
            return recent
        }
        save(ids, "recent.json")
    }

    // MARK: AirPlay speakers

    /// What's remembered of an AirPlay speaker, by its hardware address.
    public struct AirPlaySetting: Codable, Sendable, Equatable {
        /// A speaker starts quiet: its first sound shouldn't startle.
        static let startVolume = 25

        var enabled = false
        var volume = AirPlaySetting.startVolume
        var muted = false
        /// Its name when last seen, to list it while it's off the network.
        var name: String
    }

    var airPlaySettings: [String: AirPlaySetting] {
        get { lock.withLock { airPlay } }
        set {
            lock.withLock { airPlay = newValue }
            save(newValue, "airplay.json")
        }
    }

    // MARK: Files

    private func save(_ value: some Encodable, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? write(data, to: directory.appendingPathComponent(name))
    }

    private func write(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func read<Value: Decodable>(_ type: Value.Type, _ file: URL) -> Value? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
