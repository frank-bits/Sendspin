import CryptoKit
import Foundation

/// What a device keeps as a Sendspin client (pairing.md): its identity, its pairing PSK, the
/// pairing records of servers it paired with, and the last server it played for. Hosts persist
/// it whole (an app in the Keychain): losing it means pairing again.
/// Adapted from sendspin-mac's Client/SourceCredentials.swift (see UPSTREAM.md).
public struct ClientCredentials: Codable, Sendable, Equatable {
    public struct PairingRecord: Codable, Sendable, Equatable {
        public var serverID: String
        /// The long-term PSK.
        public var psk: Data
        public var lastUsed: Date
        /// From the server's last server/hello, for showing.
        public var serverName: String?
    }

    /// At least 5, as the spec requires; more would only keep stale servers.
    static let recordCapacity = 5
    /// Dynamic pairing code rounds allowed since the last verified one (pairing.md, Rounds).
    static let codeRoundLimit = 20

    /// The identity's raw Curve25519 private key; its public key is the `client_id`.
    public var privateKey: Data
    /// Long-lived and reusable: pairing doesn't consume it. Shown only as the pairing token.
    public var pairingPSK: Data
    public var records: [PairingRecord] = []
    /// The server that most recently held a playback connection (connection.md, Multiple servers).
    public var lastPlaybackServerID: String?
    /// Code rounds that failed since the last success, kept so a relaunch doesn't lift the limit.
    public var failedCodeRounds: Int?

    /// New credentials, every secret from a CSPRNG.
    public static func generate() -> ClientCredentials {
        ClientCredentials(privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
                          pairingPSK: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    var identity: Curve25519.KeyAgreement.PrivateKey {
        get throws { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey) }
    }

    /// The base64url public key, or nil when the stored private key is corrupt.
    public var clientID: String? {
        (try? identity).map { Base64URL.encode($0.publicKey.rawRepresentation) }
    }

    /// What the operator enters into the server to pair: a credential, so show it deliberately.
    public var pairingToken: String? {
        (try? identity).map { PairingToken.encode(clientKey: $0.publicKey.rawRepresentation, pairingPSK: pairingPSK) }
    }

    func record(pskID: String) -> PairingRecord? {
        records.first { SendspinPSK.id(for: $0.psk) == pskID }
    }

    /// Store a new pairing, replacing the server's old one. At capacity the least recently
    /// used record goes, but never one in `use` (backing an open connection).
    mutating func store(serverID: String, psk: Data, keeping use: Set<String>) {
        records.removeAll { $0.serverID == serverID }
        while records.count >= Self.recordCapacity,
              let oldest = records.filter({ !use.contains($0.serverID) }).min(by: { $0.lastUsed < $1.lastUsed }) {
            records.removeAll { $0.serverID == oldest.serverID }
        }
        records.append(PairingRecord(serverID: serverID, psk: psk, lastUsed: Date()))
    }
}

/// The credentials in use, shared by sessions; every change is handed to `save` whole.
public actor CredentialStore {
    public private(set) var credentials: ClientCredentials
    private let save: @Sendable (ClientCredentials) -> Void

    public init(credentials: ClientCredentials, save: @escaping @Sendable (ClientCredentials) -> Void) {
        self.credentials = credentials
        self.save = save
    }

    var codeRoundLimitReached: Bool {
        (credentials.failedCodeRounds ?? 0) >= ClientCredentials.codeRoundLimit
    }

    /// Count a round as it begins: every round since the last verified `server_kc` counts.
    func codeRoundBegan() {
        credentials.failedCodeRounds = (credentials.failedCodeRounds ?? 0) + 1
        save(credentials)
    }

    func codeRoundVerified() {
        guard credentials.failedCodeRounds != nil else { return }
        credentials.failedCodeRounds = nil
        save(credentials)
    }

    /// The deliberate operator action that lifts the round limit (pairing.md, Rounds).
    public func allowPairingAgain() {
        codeRoundVerified()
    }

    func storePairing(serverID: String, serverName: String?, psk: Data) {
        // The record of the connection that pairs is replaced, so nothing else needs keeping:
        // a client-initiated client holds one connection at a time.
        credentials.store(serverID: serverID, psk: psk, keeping: [])
        if let index = credentials.records.firstIndex(where: { $0.serverID == serverID }) {
            credentials.records[index].serverName = serverName
        }
        save(credentials)
    }

    /// Mark the record used, and keep the server's name current, for least-recently-used eviction.
    func touchPairing(serverID: String, serverName: String?) {
        guard let index = credentials.records.firstIndex(where: { $0.serverID == serverID }) else { return }
        credentials.records[index].lastUsed = Date()
        if let serverName { credentials.records[index].serverName = serverName }
        save(credentials)
    }

    func removePairing(serverID: String) {
        credentials.records.removeAll { $0.serverID == serverID }
        save(credentials)
    }

    /// Forget every pairing: servers must pair again.
    public func forgetPairings() {
        credentials.records = []
        credentials.lastPlaybackServerID = nil
        save(credentials)
    }

    func recordPlayback(serverID: String) {
        guard credentials.lastPlaybackServerID != serverID else { return }
        credentials.lastPlaybackServerID = serverID
        save(credentials)
    }
}
