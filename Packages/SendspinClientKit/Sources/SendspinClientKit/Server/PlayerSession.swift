import CryptoKit
import Foundation
import Network

// Adapted from sendspin-mac's PlayerSession.swift (see UPSTREAM.md): split over several files.

/// One dialed player: runs the Noise handshake, answers time sync, tracks player state
/// and delivers the group's audio in the negotiated format (Sendspin 1, server-initiated).
public actor PlayerSession {
    /// Asked once per connection with the player's `client_id`: may it play? Unpaired, that's
    /// the operator's approval; paired, whether it's wanted at all.
    public typealias Approval = @Sendable (_ clientID: String, _ paired: Bool) async -> Bool

    /// What the user has the device for: a speaker in the group, an input played on it, or both.
    public struct Uses: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let speaker = Uses(rawValue: 1)
        public static let input = Uses(rawValue: 2)
    }

    /// A block of an input's audio, with the server-clock time to treat as its capture.
    public struct InputBlock: Sendable {
        public var pcm: PCMBuffer
        public var captureTimeUs: Int64
    }

    public nonisolated let url: URL
    public nonisolated let updates: AsyncStream<PlayerStatus>
    /// The input's audio while it streams, for the group to play.
    public nonisolated let inputAudio: AsyncStream<InputBlock>
    let inputContinuation: AsyncStream<InputBlock>.Continuation

    let identity: ServerIdentity
    let pairings: PlayerPairings
    let approve: Approval
    /// Asked, separately, whether the device may be played as an input: never implied by
    /// anything else the user did with it (roles/source/v1.md, Unpaired access).
    let approveInput: Approval?
    var uses: Uses
    /// This connection's answers from `approve` and `approveInput`.
    var speakerApproved = false
    var inputApproved = false
    /// Only reading the client's hello, to learn its roles (`probe`).
    var probing = false
    var probedHello: ClientHello?
    /// The player connected to us (client-initiated); otherwise we dial `url`.
    let incoming: WebSocketConnection?
    public nonisolated let isIncoming: Bool
    let updatesContinuation: AsyncStream<PlayerStatus>.Continuation
    var status = PlayerStatus() {
        didSet { if status != oldValue { updatesContinuation.yield(status) } }
    }

    var socket: WebSocketConnection?
    var channel: SecureChannel?
    var hello: ClientHello?
    /// server/activate made the player ours: its role active, in our group.
    var activated = false
    /// It answered our long-term PSK on the Sentinel: it lost our pairing.
    var notRecognized = false

    // Pairing, the server's side (pairing.md).
    /// The pairing the operator started on this session; once done it's an ordinary paired one.
    var pairingRequest: PairingRequest?
    /// The group's track details, for the metadata role.
    var trackDetails: MetadataState?
    var pairingFinished = false
    var attempt: PairingAttempt?
    /// Pairing activations sent since the last Noise handshake (pairing.md, PAKE: `sid`).
    var pairingIndex = 0
    /// A wrong static code: the next prompt says so.
    var staticCodeWasWrong = false
    var pairingInitTimeout: Task<Void, Never>?
    /// What the connection's handshake needs again for a re-handshake.
    var suite: NoiseSuite = .chaChaPoly
    var clientKey: Curve25519.KeyAgreement.PublicKey?
    /// The PSK the connection runs on now.
    var connectionPSK = SendspinPSK.sentinel
    /// Between our Noise message 1 of a re-handshake and the client's message 2.
    var rehandshake: (handshake: NoiseInitiatorHandshake, psk: Data, longTerm: Bool, then: AfterRehandshake)?
    /// A re-handshake gets the handshake's timeout too: without message 2, the connection closes
    /// (connection.md, Failure Handling).
    var rehandshakeTimeout: Task<Void, Never>?
    /// How the connection ends when we end it ourselves, as when a pairing fails.
    var endOfConnection: SessionEnd?
    /// The group let go of the player (`shutdown()`): its connection ends by our doing.
    var shuttingDown = false
    /// The activities last declared: playback only while there's something to play.
    var declaredActivities: [String] = []
    /// The user just chose the player: declare playback before the sound gets here, as for a
    /// play command, so a server holding it doesn't turn us away first.
    var claiming: Bool
    /// Any server/activate went out, so the player may send its other messages.
    var sentActivation = false
    /// Re-handshaken, and no server/activate under the new keys yet: it goes first
    /// (connection.md, Re-handshake).
    var activationOwed = false
    var available = false
    /// The client/state with the `player` object arrived since the role was activated: only then
    /// may its stream start and commands go out (messaging.md, stream/start).
    var ready = false
    /// Converts group audio to the player's format; rebuilt when the source or the
    /// preferred bit depth changes.
    var pipeline: PlayerAudioPipeline?
    var pipelineBitDepthPreference: Int?
    var unsupportedSourceWarned = false
    var streaming = false
    var droppedChunks = 0
    var buffer = PlayerBufferAccount()
    var outputDelayUs: Int64 = 0
    var capacityDrops = 0
    /// The roles server/activate gives the connection.
    var activeRoles: [String] = []

    // The visualizer role (roles/visualizer/v1.md).
    /// The client/state visualizer object since the role was activated: only then may its
    /// stream start.
    var visualizerRequest: VisualizerConfig?
    /// The visualizer stream, while one is active.
    var visualizer: VisualizerAnalyzer?
    var visualizerBuffer = VisualizerBufferAccount()
    var visualizerDrops = 0

    // The controller role (roles/controller/v1.md).
    /// The group the player was added to, which carries out its controller's commands.
    weak var playbackGroup: PlaybackGroup?
    /// The controller state last sent.
    var controllerState: GroupControllerState?

    // The artwork role (roles/artwork/v1.md): its stream, without images.
    /// The client/state artwork object since the role was activated.
    var artworkRequest: ArtworkConfig?
    /// The channels of the active artwork stream.
    var artworkStream: ArtworkConfig?

    // The source role (roles/source/v1.md): the device's input, played on the group.
    /// The user wants the input playing: it's started whenever the connection allows.
    var inputWanted = false
    /// The client/state source object since the role was activated: only then may start go out.
    var sourceReady = false
    /// The client holds our start, as far as we know: a stop or its unavailability clears it.
    var startPending = false
    /// Starts not yet answered by client-stream/start, which may still come after a stop.
    var startsUnanswered = 0
    /// The open input stream, from client-stream/start to client-stream/end. Without a decoder
    /// its audio is discarded: it came after a stop, or in a format we can't decode.
    var inputStream: (decoder: SourceDecoder?, timeline: InputTimeline)?
    /// Its input came in a format we can't decode: stopped, and not started again until it's
    /// chosen anew or connects again.
    var inputUndecodable = false
    var undecodableChunks = 0

    var group: (id: String, name: String)?
    var playing = false
    /// The player left the group (see `PlayerStatus.Connection.left`).
    var left = false
    /// It left by `switch`, not by becoming unavailable or `client/leave`.
    var leftBySwitch = false
    /// This attempt's WebSocket opened: the player is on the network.
    var reached = false
    /// The stopped group of its own a held player, or one that left, is in.
    var soloGroupID: String?
    var lastGroupUpdate: GroupUpdate?

    /// A player we dial and keep connected. One the user just `chosen` is claimed for playback
    /// when it connects.
    public init(url: URL, identity: ServerIdentity, pairings: PlayerPairings = PlayerPairings(),
                uses: Uses = .speaker, chosen: Bool = false, pairing: PairingRequest? = nil,
                approve: @escaping Approval, approveInput: Approval? = nil) {
        self.url = url
        self.identity = identity
        self.pairings = pairings
        self.uses = uses
        pairingRequest = pairing
        self.approve = approve
        self.approveInput = approveInput
        claiming = chosen
        incoming = nil
        isIncoming = false
        (updates, updatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        (inputAudio, inputContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// What a probe learned of a device.
    public struct Probe: Sendable {
        public var clientID: String
        /// Its roles, as `PlayerStatus.supportedRoles` has them.
        public var roles: [String]
        /// We're paired with it: the handshake ran on our long-term PSK.
        public var paired: Bool
        public var hello: ClientHello
    }

    /// Connect once, read the device's hello and close: which roles it has, before the user
    /// chooses it. Nothing is activated, and a connection without activities ranks lowest, so
    /// it takes the device from no other server (connection.md, Multiple servers).
    public static func probe(url: URL, identity: ServerIdentity, pairings: PlayerPairings) async throws -> Probe? {
        let session = PlayerSession(url: url, identity: identity, pairings: pairings) { _, _ in false }
        return try await session.probeOnce()
    }

    func probeOnce() async throws -> Probe? {
        probing = true
        defer {
            socket?.close()
            updatesContinuation.finish()
        }
        _ = try await connectAndServe()
        guard let probedHello, let clientID = status.clientID else { return nil }
        return Probe(clientID: clientID, roles: status.supportedRoles, paired: status.paired, hello: probedHello)
    }

    /// A player that connected to us. It's served once: we can't reconnect to it.
    public init(incoming connection: IncomingConnection, identity: ServerIdentity,
                pairings: PlayerPairings = PlayerPairings(), approve: @escaping Approval) {
        url = URL(string: "ws://\(connection.remoteDescription)") ?? URL(string: "ws://incoming")!
        self.identity = identity
        self.pairings = pairings
        uses = .speaker
        pairingRequest = nil
        self.approve = approve
        approveInput = nil
        incoming = connection.socket
        isIncoming = true
        claiming = false
        (updates, updatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        (inputAudio, inputContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    public var currentStatus: PlayerStatus { status }
}
