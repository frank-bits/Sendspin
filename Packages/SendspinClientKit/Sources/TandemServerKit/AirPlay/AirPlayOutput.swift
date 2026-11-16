import Foundation
import SendspinClientKit

/// Answers a speaker's requests for the time, from the server's clock.
struct TimingResponder {
    let socket: UDPSocket

    init(queue: DispatchQueue, localAddress: String) throws {
        let box = SocketBox()
        socket = try UDPSocket(queue: queue, localAddress: localAddress) { packet, sender in
            guard let reply = RAOP.timingReply(to: packet, nowMicros: RAOP.clockMicros()) else {
                Log.debug("AirPlay timing port: unknown packet \(packet.prefix(8).map { String(format: "%02x", $0) }.joined())")
                return
            }
            box.socket?.send(reply, to: sender)
            box.count += 1
            if box.count == 1 || box.count.isMultiple(of: 20) { Log.debug("AirPlay: the speaker asked the time \(box.count) times") }
        }
        box.socket = socket
    }
}

/// Sends again the audio packets a speaker says it missed.
struct ResendResponder {
    let socket: UDPSocket

    /// `again` sends a packet a second time; without it, it goes back wrapped on this socket,
    /// as the first AirPlay has it.
    init(queue: DispatchQueue, localAddress: String, history: PacketHistory,
         again: (@Sendable (Data) -> Void)? = nil) throws {
        let box = SocketBox()
        socket = try UDPSocket(queue: queue, localAddress: localAddress) { packet, sender in
            guard let request = RAOP.resendRequest(packet) else {
                Log.debug("AirPlay control port: unknown packet \(packet.prefix(8).map { String(format: "%02x", $0) }.joined())")
                return
            }
            Log.debug("AirPlay: asked again for \(request.count) packets from \(request.first)")
            for offset in 0..<min(request.count, 64) {
                guard let lost = history.packet(request.first &+ UInt16(offset)) else { continue }
                if let again { again(lost) } else { box.socket?.send(RAOP.resendReply(lost), to: sender) }
            }
        }
        box.socket = socket
    }
}

/// A socket for its own receive handler to answer on. Set once, before any packet arrives.
private final class SocketBox: @unchecked Sendable {
    weak var socket: UDPSocket?
    /// Packets answered, counted on the socket's queue.
    var count = 0
}

/// A speaker as a member of a playback group.
final class AirPlayOutput: GroupOutput {
    let stream: AirPlayStream
    private let events: AsyncStream<AirPlayStream.Event>.Continuation

    init(speaker: AirPlaySpeaker, volume: Int, muted: Bool, onStatus: @escaping @Sendable (AirPlayStream.Status) -> Void) {
        let stream = AirPlayStream(speaker: speaker, volume: volume, muted: muted, onStatus: onStatus)
        let (events, continuation) = AsyncStream.makeStream(of: AirPlayStream.Event.self)
        self.stream = stream
        self.events = continuation
        // One at a time, in order: audio is a sequence.
        Task {
            for await event in events { await stream.handle(event) }
            await stream.close()
        }
    }

    func play(_ pcm: PCMBuffer, timestampUs: Int64) {
        events.yield(.audio(pcm, playUs: timestampUs))
    }

    func stop() {
        events.yield(.stop)
    }

    func describe(title: String?, artist: String?, album: String?) {
        events.yield(.details(title: title, artist: artist, album: album))
    }

    /// The speaker left the group: let it go, and wait until it's told.
    func shutdown() async {
        events.finish()
        await stream.close()
    }
}
