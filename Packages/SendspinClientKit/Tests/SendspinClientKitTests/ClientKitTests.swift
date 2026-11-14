import Foundation
import Testing
@testable import SendspinClientKit

struct ClientMessageTests {
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func helloCarriesPlayerSupportUnderItsVersionedKey() throws {
        let hello = ClientHelloMessage(
            name: "Kitchen", deviceInfo: DeviceInfoMessage(productName: "iPhone", manufacturer: "Apple", softwareVersion: "1.0"),
            supportedRoles: ["player@v1", "controller@v1"],
            playerSupport: PlayerSupport(
                supportedFormats: [AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48000, bitDepth: 16)],
                bufferCapacity: 1_000_000),
            unpairedAccess: .init(enabled: false))
        let message = try object(MessageCoding.encode(type: "client/hello", payload: hello))
        #expect(message["type"] as? String == "client/hello")
        let payload = try #require(message["payload"] as? [String: Any])
        let support = try #require(payload["player@v1_support"] as? [String: Any])
        let formats = try #require(support["supported_formats"] as? [[String: Any]])
        #expect(formats.first?["codec"] as? String == "flac")
        #expect(formats.first?["sample_rate"] as? Int == 48000)
        #expect(formats.first?["bit_depth"] as? Int == 16)
        #expect(support["buffer_capacity"] as? Int == 1_000_000)
        #expect((payload["unpaired_access"] as? [String: Any])?["enabled"] as? Bool == false)
        let methods = try #require(payload["supported_pair_methods"] as? [String: Any])
        #expect(methods["pairing_psk"] != nil)
        #expect((methods["dynamic_pairing_code"] as? [String: Any])?["formats"] as? [String] == ["digits"])
    }

    @Test func helloWithoutPlayerOmitsTheSupportObject() throws {
        let hello = ClientHelloMessage(
            name: "Remote", deviceInfo: DeviceInfoMessage(productName: "iPhone", manufacturer: "Apple", softwareVersion: "1.0"),
            supportedRoles: ["controller@v1"], playerSupport: nil, unpairedAccess: .init(enabled: true))
        let payload = try #require(try object(MessageCoding.encode(type: "client/hello", payload: hello))["payload"] as? [String: Any])
        #expect(payload["player@v1_support"] == nil)
    }

    @Test func stateOmitsAbsentPlayerAndFormat() throws {
        let bare = try #require(try object(MessageCoding.encode(
            type: "client/state", payload: ClientStateMessage(available: true)))["payload"] as? [String: Any])
        #expect(bare["available"] as? Bool == true)
        #expect(bare["player"] == nil)

        let state = ClientStateMessage(available: true, player: PlayerState(volume: 40, muted: false,
                                                                            supportedCommands: ["volume", "mute"]))
        let payload = try #require(try object(MessageCoding.encode(type: "client/state", payload: state))["payload"] as? [String: Any])
        let player = try #require(payload["player"] as? [String: Any])
        #expect(player["volume"] as? Int == 40)
        #expect(player["output_delay_ms"] as? Int == 0)
        #expect(player["required_lead_time_ms"] as? Int == 0)
        #expect(player["min_buffer_ms"] as? Int == 0)
        #expect(player["supported_commands"] as? [String] == ["volume", "mute"])
        #expect(player["format"] == nil)
    }
}

struct ClientCredentialsTests {
    private func psk(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }

    @Test func generatedCredentialsHaveAnIdentityAndToken() throws {
        let credentials = ClientCredentials.generate()
        #expect(credentials.clientID?.count == 43)
        #expect(try #require(credentials.pairingToken).hasPrefix("SP:0"))
        #expect(ClientCredentials.generate().privateKey != credentials.privateKey)
    }

    @Test func corruptPrivateKeyYieldsNoIdentity() {
        var credentials = ClientCredentials.generate()
        credentials.privateKey = Data([1, 2, 3])
        #expect(credentials.clientID == nil)
        #expect(credentials.pairingToken == nil)
    }

    @Test func recordIsFoundByItsPSKIdentifier() {
        var credentials = ClientCredentials.generate()
        credentials.store(serverID: "a", psk: psk(1), keeping: [])
        #expect(credentials.record(pskID: SendspinPSK.id(for: psk(1)))?.serverID == "a")
        #expect(credentials.record(pskID: SendspinPSK.id(for: psk(2))) == nil)
    }

    @Test func pairingAgainReplacesTheServersRecord() {
        var credentials = ClientCredentials.generate()
        credentials.store(serverID: "a", psk: psk(1), keeping: [])
        credentials.store(serverID: "a", psk: psk(2), keeping: [])
        #expect(credentials.records.count == 1)
        #expect(credentials.records.first?.psk == psk(2))
    }

    @Test func atCapacityTheLeastRecentlyUsedUnusedRecordIsEvicted() {
        var credentials = ClientCredentials.generate()
        for index in 0..<ClientCredentials.recordCapacity {
            credentials.store(serverID: "s\(index)", psk: psk(UInt8(index)), keeping: [])
            credentials.records[index].lastUsed = Date(timeIntervalSince1970: Double(index))
        }
        // s0 is the oldest but backs an open connection, so s1 goes.
        credentials.store(serverID: "new", psk: psk(99), keeping: ["s0"])
        let ids = Set(credentials.records.map(\.serverID))
        #expect(credentials.records.count == ClientCredentials.recordCapacity)
        #expect(ids.contains("s0") && ids.contains("new") && !ids.contains("s1"))
    }

    @Test func storePersistsEveryChange() async {
        let saved = Saved()
        let store = CredentialStore(credentials: .generate()) { saved.set($0) }
        await store.storePairing(serverID: "a", serverName: "Server A", psk: psk(1))
        #expect(saved.value?.records.first?.serverName == "Server A")
        await store.recordPlayback(serverID: "a")
        #expect(saved.value?.lastPlaybackServerID == "a")
        for _ in 0..<ClientCredentials.codeRoundLimit { await store.codeRoundBegan() }
        #expect(await store.codeRoundLimitReached)
        await store.allowPairingAgain()
        #expect(await !store.codeRoundLimitReached)
        await store.removePairing(serverID: "a")
        #expect(saved.value?.records.isEmpty == true)
    }
}

/// The last credentials handed to a store's `save`.
private final class Saved: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ClientCredentials?

    var value: ClientCredentials? { lock.withLock { stored } }
    func set(_ credentials: ClientCredentials) { lock.withLock { stored = credentials } }
}
