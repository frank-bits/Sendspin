import Foundation

// The messages of a Sendspin client's core protocol and pairing (messaging.md, pairing.md).
// Adapted from sendspin-mac's Client/ClientMessages.swift (see UPSTREAM.md): the source role
// is replaced by the player role. Decoders ignore unknown fields.

// MARK: - Handshake (cleartext)

struct ClientInitMessage: Encodable {
    var clientID: String
    var version = 1
    var suite: String

    enum CodingKeys: String, CodingKey {
        case version, suite
        case clientID = "client_id"
    }
}

struct ServerInitMessage: Decodable {
    var serverID: String
    var version: Int

    enum CodingKeys: String, CodingKey {
        case version
        case serverID = "server_id"
    }
}

/// The payload of Noise message 1: which PSK the server mixes in.
struct NoiseMessage1Received: Decodable {
    var pskID: String
    var pskCategory: String

    enum CodingKeys: String, CodingKey {
        case pskID = "psk_id"
        case pskCategory = "psk_category"
    }
}

// MARK: - Server -> client

struct ServerHelloReceived: Decodable {
    var name: String
    var languages: [String]?
}

struct ServerActivateReceived: Decodable {
    struct Pairing: Decodable {
        var method: String
        /// The dynamic code's emission format: "digits" or "qr_code".
        var format: String?
    }

    var activities: [String]
    var activeRoles: [String]?
    var pairing: Pairing?

    enum CodingKeys: String, CodingKey {
        case activities, pairing
        case activeRoles = "active_roles"
    }
}

struct ServerTimeReceived: Decodable {
    var clientTransmitted: Int64
    var serverReceived: Int64
    var serverTransmitted: Int64

    enum CodingKeys: String, CodingKey {
        case clientTransmitted = "client_transmitted"
        case serverReceived = "server_received"
        case serverTransmitted = "server_transmitted"
    }
}

struct PairAbortMessage: Codable {
    var reason: String
}

// Dynamic Pairing Code flow (pairing.md, Messages). Binary values are base64url.

struct ServerPairInitReceived: Codable {
    /// In the first round only.
    var nonceA: String?

    enum CodingKeys: String, CodingKey {
        case nonceA = "nonce_A"
    }
}

struct ServerPairAuthReceived: Codable {
    /// The server's CPace share `Ya`.
    var pakeMsg1: String

    enum CodingKeys: String, CodingKey {
        case pakeMsg1 = "pake_msg_1"
    }
}

struct ServerPairConfirmReceived: Codable {
    /// The server's confirmation tag `Ta`.
    var serverKC: String

    enum CodingKeys: String, CodingKey {
        case serverKC = "server_kc"
    }
}

// MARK: - Client -> server

/// `player@v1_support` in client/hello (roles/player/v1.md).
public struct PlayerSupport: Codable, Sendable, Equatable {
    /// In priority order, the first preferred.
    public var supportedFormats: [AudioFormatSpec]
    /// The most bytes of audio chunks the player holds at once.
    public var bufferCapacity: Int

    public init(supportedFormats: [AudioFormatSpec], bufferCapacity: Int) {
        self.supportedFormats = supportedFormats
        self.bufferCapacity = bufferCapacity
    }

    enum CodingKeys: String, CodingKey {
        case supportedFormats = "supported_formats"
        case bufferCapacity = "buffer_capacity"
    }
}

struct ClientHelloMessage: Encodable {
    /// The pairing PSK: every client implements it. No `locations`: the token is shown by the app.
    struct PairMethodDescriptor: Encodable {}

    /// The code is shown on this device's screen, as six digits.
    struct DynamicCodeDescriptor: Encodable {
        var outChannels = ["display"]
        var formats = ["digits"]

        enum CodingKeys: String, CodingKey {
            case formats
            case outChannels = "out_channels"
        }
    }

    struct PairMethods: Encodable {
        var pairingPSK = PairMethodDescriptor()
        var dynamicPairingCode = DynamicCodeDescriptor()

        enum CodingKeys: String, CodingKey {
            case pairingPSK = "pairing_psk"
            case dynamicPairingCode = "dynamic_pairing_code"
        }
    }

    struct UnpairedAccess: Encodable {
        var enabled: Bool
    }

    var name: String
    var deviceInfo: DeviceInfoMessage
    var supportedRoles: [String]
    /// Required when `player@v1` is listed, absent otherwise.
    var playerSupport: PlayerSupport?
    var supportedPairMethods = PairMethods()
    var unpairedAccess: UnpairedAccess

    enum CodingKeys: String, CodingKey {
        case name
        case deviceInfo = "device_info"
        case supportedRoles = "supported_roles"
        case playerSupport = "player@v1_support"
        case supportedPairMethods = "supported_pair_methods"
        case unpairedAccess = "unpaired_access"
    }
}

struct DeviceInfoMessage: Encodable {
    var productName: String
    var manufacturer: String
    var softwareVersion: String

    enum CodingKeys: String, CodingKey {
        case manufacturer
        case productName = "product_name"
        case softwareVersion = "software_version"
    }
}

struct ClientTimeMessage: Encodable {
    var clientTransmitted: Int64

    enum CodingKeys: String, CodingKey {
        case clientTransmitted = "client_transmitted"
    }
}

/// The `player` object of client/state (roles/player/v1.md): always sent whole.
public struct PlayerState: Codable, Sendable, Equatable {
    public var volume: Int?
    public var muted: Bool?
    public var outputDelayMs: Int
    public var requiredLeadTimeMs: Int
    public var minBufferMs: Int
    /// A subset of "volume", "mute", "set_output_delay".
    public var supportedCommands: [String]
    /// The format the player currently prefers, one of its supported formats; nil for no override.
    public var format: AudioFormatSpec?

    public init(volume: Int? = nil, muted: Bool? = nil, outputDelayMs: Int = 0, requiredLeadTimeMs: Int = 0,
                minBufferMs: Int = 0, supportedCommands: [String] = [], format: AudioFormatSpec? = nil) {
        self.volume = volume
        self.muted = muted
        self.outputDelayMs = outputDelayMs
        self.requiredLeadTimeMs = requiredLeadTimeMs
        self.minBufferMs = minBufferMs
        self.supportedCommands = supportedCommands
        self.format = format
    }

    enum CodingKeys: String, CodingKey {
        case volume, muted, format
        case outputDelayMs = "output_delay_ms"
        case requiredLeadTimeMs = "required_lead_time_ms"
        case minBufferMs = "min_buffer_ms"
        case supportedCommands = "supported_commands"
    }
}

struct ClientStateMessage: Encodable, Equatable {
    var available: Bool
    var player: PlayerState?
}

struct ClientPairInitMessage: Codable {
    var pairingIndex: Int
    /// The commitment to nonce_B, in the Dynamic Pairing Code flow.
    var commitB: String?

    enum CodingKeys: String, CodingKey {
        case pairingIndex = "pairing_index"
        case commitB = "commit_B"
    }
}

struct ClientPairAuthMessage: Codable {
    /// This client's CPace share `Yb`.
    var pakeMsg2: String

    enum CodingKeys: String, CodingKey {
        case pakeMsg2 = "pake_msg_2"
    }
}

struct ClientPairConfirmMessage: Codable {
    /// This client's confirmation tag `Tb`.
    var clientKC: String
    /// In the Dynamic Pairing Code flow only.
    var wrappedNonceB: String?

    enum CodingKeys: String, CodingKey {
        case clientKC = "client_kc"
        case wrappedNonceB = "wrapped_nonce_B"
    }
}

struct ClientPairPendingMessage: Codable {
    var pairingIndex: Int
    var message: String?

    enum CodingKeys: String, CodingKey {
        case message
        case pairingIndex = "pairing_index"
    }
}

/// The new long-term PSK: plain in the Pairing PSK flow, wrapped in the code flows.
struct ClientPairFinalizeMessage: Codable {
    /// base64url, 43 characters.
    var longTermPSK: String?
    /// base64url, 64 characters.
    var wrappedPSK: String?

    enum CodingKeys: String, CodingKey {
        case longTermPSK = "long_term_psk"
        case wrappedPSK = "wrapped_psk"
    }
}

struct ClientGoodbyeMessage: Encodable {
    var reason: String
}

struct EmptyPayload: Codable {}
