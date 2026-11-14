import Foundation

// Excerpts from sendspin-mac files that are otherwise server-side (see UPSTREAM.md):
// Protocol/Messages.swift, PlayerSession.swift, Discovery/PlayerBrowser.swift and
// Transport/ServiceListener.swift.

public enum AudioCodec: String, Codable, Sendable {
    case pcm, flac, opus
}

public struct AudioFormatSpec: Codable, Hashable, Sendable {
    public var codec: String
    public var channels: Int
    public var sampleRate: Int
    public var bitDepth: Int

    public init(codec: AudioCodec, channels: Int, sampleRate: Int, bitDepth: Int) {
        self.codec = codec.rawValue
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }

    enum CodingKeys: String, CodingKey {
        case codec, channels
        case sampleRate = "sample_rate"
        case bitDepth = "bit_depth"
    }
}

public struct NoiseHandshakeMessage: Codable, Sendable {
    /// base64url Noise handshake bytes.
    public var data: String
}

enum MessageCoding {
    /// A JSON message isn't an object with a `type` string and a `payload` object: a protocol
    /// error, on which the receiver MUST close (messaging.md, Binary Message ID Structure).
    struct Malformed: Error {}

    private struct Incoming<Payload: Decodable>: Decodable {
        var payload: Payload
    }

    private struct Outgoing<Payload: Encodable>: Encodable {
        var type: String
        var payload: Payload
    }

    static func type(of data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String, object["payload"] is [String: Any]
        else { throw Malformed() }
        return type
    }

    static func payload<P: Decodable>(_: P.Type, from data: Data) throws -> P {
        try JSONDecoder().decode(Incoming<P>.self, from: data).payload
    }

    /// The UTF-8 JSON bytes, exactly as they go on the wire.
    static func encode<P: Encodable>(type: String, payload: P) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return try encoder.encode(Outgoing(type: type, payload: payload))
    }
}

enum SessionError: Error, CustomStringConvertible {
    case handshake(String)
    /// A pairing protocol error (pairing.md): the connection closes without a message.
    case pairing(String)
    /// A message a role's rules say closes the connection.
    case protocolViolation(String)

    var description: String {
        switch self {
        case .handshake(let detail): "handshake failed: \(detail)"
        case .pairing(let detail): "pairing protocol error: \(detail)"
        case .protocolViolation(let detail): "protocol error: \(detail)"
        }
    }
}

/// Thread-safe one-shot flag for resuming a continuation exactly once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

extension String {
    /// The longest prefix of whole characters that fits in `limit` bytes of UTF-8.
    func truncated(toUTF8Bytes limit: Int) -> String {
        guard utf8.count > limit else { return self }
        var result = ""
        var bytes = 0
        for character in self {
            bytes += character.utf8.count
            guard bytes <= limit else { break }
            result.append(character)
        }
        return result
    }
}
