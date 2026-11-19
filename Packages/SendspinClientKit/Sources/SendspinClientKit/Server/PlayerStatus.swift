import CryptoKit
import Foundation
import Network

public struct PlayerStatus: Sendable, Equatable {
    public enum Connection: Sendable, Equatable {
        case connecting
        case connected
        /// Another server took the player over (goodbye `another_server`), or held it when we
        /// came with nothing to play (`concurrent_attempt`).
        case taken
        /// The player only admits paired servers, and this Mac isn't paired with it.
        case pairingRequired
        /// We're paired, but the player no longer recognizes this Mac (reset, or it dropped the
        /// record to make room): it can't play until paired again (connection.md, Sentinel
        /// Fallback).
        case notRecognized
        /// An unpaired player the user hasn't allowed yet: one that connected to us is held
        /// until then, one we found is dialed again once allowed.
        case awaitingApproval
        /// The player left the group: it's in use by something else (`available: false`) or
        /// sent `client/leave`. It stays connected in a stopped group of its own until the
        /// user selects it again (`rejoin()`): the spec doesn't let us take it back by ourselves.
        case left
        /// The player can't be reached: it dropped off the network, or the connection broke
        /// without a goodbye. The session keeps trying, and plays again once it's back.
        case unavailable
        case disconnected(reason: String?)
        case failed(String)
    }

    /// A speaker (player@v1 with its support object), an input (source@v1 with its), or both.
    public var isSpeaker: Bool { supportedRoles.contains("player@v1") }
    public var isInput: Bool { supportedRoles.contains("source@v1") }

    public var connection: Connection = .connecting
    public var name: String?
    /// The player's `client_id`: its Curve25519 public key, base64url.
    public var clientID: String?
    /// The connection runs on our pairing's long-term PSK.
    public var paired = false
    /// The pairing methods it offers, from its hello.
    public var pairMethods: PairMethods?
    /// A pairing the operator started on this session.
    public var pairing: PairingProgress?
    public var volume: Int?
    public var muted: Bool?
    public var canSetVolume = false
    public var canMute = false
    /// What the player needs queued: its min_buffer_ms plus output_delay_ms. The server
    /// must schedule audio at least this far ahead (player/v1.md, Server Audio Send Constraints).
    public var requiredBufferMs = 0
    /// Its first client/state with the `player` object arrived on this connection: its volume
    /// and what it needs queued are known.
    public var reportedPlayerState = false
    /// PCM and FLAC formats the player accepts (from its hello), its preference first.
    public var supportedFormats: [AudioFormatSpec] = []
    /// Format currently streamed to the player, while streaming.
    public var streamFormat: AudioFormatSpec?
    /// The roles it offers, from its hello: a speaker has `player@v1`, an input `source@v1`.
    public var supportedRoles: [String] = []
    /// Its input streams to us, and plays on the group.
    public var inputStreaming = false
    /// 'present' or 'absent', from an input with line sensing.
    public var inputSignal: String?

    public init() {}
}
