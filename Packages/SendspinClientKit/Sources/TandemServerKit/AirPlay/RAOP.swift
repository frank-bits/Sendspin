import Foundation
import SendspinClientKit

/// The bytes of AirPlay's audio protocol in its older form (RAOP), which Sonos, WiiM and most
/// other makers' speakers still accept: 44.1 kHz 16-bit stereo over RTP, unencrypted, with
/// the sender as the clock.
enum RAOP {
    static let sampleRate = 44_100
    static let framesPerPacket = 352
    /// How long after a sender hands a frame over a receiver plays it: two seconds, as iTunes
    /// has it. Part of it is the receiver's own share, which it reports (`Audio-Latency`).
    static let latencyFrames = 88_200
    /// The share a receiver takes when it doesn't say.
    static let receiverLatencyFrames = 11_025

    /// Interleaved stereo samples as an ALAC frame that isn't compressed: 23 bits of header,
    /// the samples, most significant byte first, and the three bits that end a frame. Every
    /// receiver decodes it, and it spares us an encoder.
    static func alacFrame(_ samples: ArraySlice<Int16>) -> Data {
        var frame = Data(count: samples.count * 2 + 4)
        // Stereo, no size given (352 frames), not compressed.
        frame[0] = 0x20
        frame[2] = 0x02
        var index = 2
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            frame[index] |= UInt8(bits >> 15)
            frame[index + 1] = UInt8((bits >> 7) & 0xFF)
            frame[index + 2] = UInt8((bits & 0x7F) << 1)
            index += 2
        }
        // The end tag (7), without which Apple's decoder looks for another channel element.
        frame[index] |= 0x01
        frame[index + 1] = 0xC0
        return frame
    }

    /// An audio packet. The first of a stream, or after a flush, carries the marker.
    static func audioPacket(sequence: UInt16, timestamp: UInt32, source: UInt32, first: Bool, payload: Data) -> Data {
        var packet = Data([0x80, first ? 0xE0 : 0x60])
        packet.append(bigEndian: sequence)
        packet.append(bigEndian: timestamp)
        packet.append(bigEndian: source)
        packet.append(payload)
        return packet
    }

    /// A sync packet, sent about once a second: at time `nowMicros` on our clock the frame
    /// `timestamp` is handed over, to be played the latency later. Receivers add their own
    /// share to the latency we state, so ours leaves it out.
    static func syncPacket(first: Bool, timestamp: UInt32, receiverLatency: Int, nowMicros: Int64) -> Data {
        var packet = Data([first ? 0x90 : 0x80, 0xD4, 0x00, 0x07])
        packet.append(bigEndian: timestamp &- UInt32(max(0, latencyFrames - receiverLatency)))
        packet.append(bigEndian: ntp(nowMicros))
        packet.append(bigEndian: timestamp)
        return packet
    }

    /// The answer to a receiver asking for the time; nil for anything else.
    static func timingReply(to request: Data, nowMicros: Int64) -> Data? {
        let request = Data(request)
        guard request.count >= 32, request[1] & 0x7F == 0x52 else { return nil }
        var reply = Data([0x80, 0xD3, 0x00, 0x07, 0, 0, 0, 0])
        // Its transmit time comes back as the origin; we received and answer at once.
        reply.append(request[24..<32])
        reply.append(bigEndian: ntp(nowMicros))
        reply.append(bigEndian: ntp(nowMicros))
        return reply
    }

    /// What plays, as the tagged list AirPlay carries it in. A Sonos speaker plays nothing
    /// until it has been sent one, so there is always a title.
    static func trackDetails(title: String, artist: String?, album: String?) -> Data {
        // The kind of item (a song), then the texts.
        var items = Data("mikd".utf8) + Data([0, 0, 0, 1, 2])
        for (tag, text) in [("minm", title), ("asar", artist ?? ""), ("asal", album ?? "")] {
            let bytes = Data(text.utf8.prefix(240))
            items.append(Data(tag.utf8))
            items.append(bigEndian: UInt32(bytes.count))
            items.append(bytes)
        }
        var list = Data("mlit".utf8)
        list.append(bigEndian: UInt32(items.count))
        return list + items
    }

    /// The packets a receiver missed and asks for again; nil for anything else.
    static func resendRequest(_ packet: Data) -> (first: UInt16, count: Int)? {
        let packet = Data(packet)
        guard packet.count >= 8, packet[1] & 0x7F == 0x55 else { return nil }
        return (UInt16(packet[4]) << 8 | UInt16(packet[5]), Int(packet[6]) << 8 | Int(packet[7]))
    }

    /// An audio packet sent again.
    static func resendReply(_ audioPacket: Data) -> Data {
        Data([0x80, 0xD6, 0x00, 0x01]) + audioPacket
    }

    /// The server's clock as the time of day NTP counts, in microseconds since 1900. Speakers
    /// only compare our times with each other, but a time near zero may look wrong to one.
    static func clockMicros(_ serverMicros: Int64 = ServerClock.nowMicros()) -> Int64 {
        serverMicros + epochOffset
    }

    private static let epochOffset = Int64((Date().timeIntervalSince1970 + 2_208_988_800) * 1_000_000) - ServerClock.nowMicros()

    /// A time as NTP has it: seconds, then a 32-bit fraction.
    static func ntp(_ micros: Int64) -> UInt64 {
        let seconds = UInt64(micros / 1_000_000) & 0xFFFF_FFFF
        let fraction = (UInt64(micros % 1_000_000) << 32) / 1_000_000
        return seconds << 32 | fraction
    }

    /// Volume as AirPlay has it: decibels from -30 (quietest) to 0, and -144 for silence.
    static func decibels(volume: Int, muted: Bool) -> Double {
        guard !muted, volume > 0 else { return -144 }
        return -30 + 30 * Double(min(volume, 100)) / 100
    }

    /// Float samples, mono or stereo, as interleaved 16-bit stereo.
    static func stereo16(_ samples: [Float], channels: Int) -> [Int16] {
        func convert(_ sample: Float) -> Int16 { Int16(max(-32_768, min(32_767, (sample * 32_768).rounded()))) }
        if channels == 1 { return samples.flatMap { [convert($0), convert($0)] } }
        var output = [Int16]()
        output.reserveCapacity(samples.count / channels * 2)
        var index = 0
        while index + 1 < samples.count {
            output.append(convert(samples[index]))
            output.append(convert(samples[index + 1]))
            index += channels
        }
        return output
    }
}

extension Data {
    mutating func append<Value: FixedWidthInteger>(bigEndian value: Value) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

/// The audio packets sent lately, for a receiver that missed some.
final class PacketHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [UInt16: Data] = [:]
    private var order: [UInt16] = []
    private static let limit = 1_024

    func store(_ packet: Data, sequence: UInt16) {
        lock.withLock {
            packets[sequence] = packet
            order.append(sequence)
            if order.count > Self.limit { packets[order.removeFirst()] = nil }
        }
    }

    func packet(_ sequence: UInt16) -> Data? {
        lock.withLock { packets[sequence] }
    }

    func clear() {
        lock.withLock {
            packets = [:]
            order = []
        }
    }
}
