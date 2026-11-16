import Foundation
import SendspinClientKit

/// The messages of the clock AirPlay 2 speakers follow: the Precision Time Protocol in the
/// dialect Apple's senders speak. A speaker takes its time from the sender, and some (Sonos
/// among them) play nothing until they have locked on to that clock.
enum PTP {
    static let eventPort: UInt16 = 319
    static let generalPort: UInt16 = 320

    enum Kind: UInt8 {
        case sync = 0x0, delayRequest = 0x1, followUp = 0x8, delayResponse = 0x9, announce = 0xB, signaling = 0xC
    }

    private static let twoStep: UInt16 = 0x0200, unicast: UInt16 = 0x0400, timescale: UInt16 = 0x0008

    /// The 34 bytes every message starts with. The first byte's upper half is 1: speakers
    /// discard messages of the plain protocol, which has 0 there.
    static func header(_ kind: Kind, length: Int, flags: UInt16, clock: UInt64, sequence: UInt16, control: UInt8 = 0,
                       interval: Int8) -> Data {
        var header = Data([0x10 | kind.rawValue, 2])
        header.append(bigEndian: UInt16(length))
        header.append(contentsOf: [0, 0])
        header.append(bigEndian: flags)
        header.append(Data(count: 12))
        header.append(bigEndian: clock)
        // The port number Apple's senders give.
        header.append(contentsOf: [0x80, 0x05])
        header.append(bigEndian: sequence)
        header.append(contentsOf: [control, UInt8(bitPattern: interval)])
        return header
    }

    /// A time as the protocol writes it: 48 bits of seconds, then 32 of nanoseconds.
    static func timestamp(_ nanos: UInt64) -> Data {
        var data = Data()
        let seconds = nanos / 1_000_000_000
        data.append(bigEndian: UInt16(truncatingIfNeeded: seconds >> 32))
        data.append(bigEndian: UInt32(truncatingIfNeeded: seconds))
        data.append(bigEndian: UInt32(nanos % 1_000_000_000))
        return data
    }

    /// "Here is a clock, and how good it is": as good as a phone's, which outranks a speaker's own.
    static func announce(clock: UInt64, sequence: UInt16) -> Data {
        var message = header(.announce, length: 76, flags: unicast | timescale, clock: clock, sequence: sequence, interval: 0)
        message.append(Data(count: 13))
        // Priority 128, clock class 6, accuracy 100 ns, variance, priority 128 again.
        message.append(contentsOf: [128, 6, 0x21, 0x43, 0x6A, 128])
        message.append(bigEndian: clock)
        // No steps removed; the time comes from GPS.
        message.append(contentsOf: [0, 0, 0x20])
        // The path so far: this clock alone.
        message.append(contentsOf: [0x00, 0x08, 0x00, 0x08])
        message.append(bigEndian: clock)
        return message
    }

    /// The first half of telling the time: the moment this leaves is the time meant.
    static func sync(clock: UInt64, sequence: UInt16) -> Data {
        header(.sync, length: 44, flags: unicast | timescale | twoStep, clock: clock, sequence: sequence, interval: -3)
            + Data(count: 10)
    }

    /// The second half: when the sync message left.
    static func followUp(clock: UInt64, sequence: UInt16, sentNanos: UInt64) -> Data {
        var message = header(.followUp, length: 96, flags: unicast | timescale, clock: clock, sequence: sequence, interval: -3)
        message.append(timestamp(sentNanos))
        // Two additions Apple's senders make: rate details, all zero, and the clock's id again.
        message.append(contentsOf: [0x00, 0x03, 0x00, 0x1C, 0x00, 0x80, 0xC2, 0x00, 0x00, 0x01])
        message.append(Data(count: 22))
        message.append(contentsOf: [0x00, 0x03, 0x00, 0x10, 0x00, 0x0D, 0x93, 0x00, 0x00, 0x04])
        message.append(bigEndian: clock)
        message.append(contentsOf: [0, 0])
        return message
    }

    /// The answer to a speaker measuring how long its messages take to reach us: when its
    /// request arrived, with its own id and number. Nil for anything but such a request.
    static func delayResponse(to request: Data, clock: UInt64, receivedNanos: UInt64) -> Data? {
        let request = Data(request)
        guard request.count >= 44, request[0] & 0x0F == Kind.delayRequest.rawValue else { return nil }
        let sequence = UInt16(request[30]) << 8 | UInt16(request[31])
        return header(.delayResponse, length: 54, flags: unicast | timescale | twoStep, clock: clock, sequence: sequence,
                      interval: -3) + timestamp(receivedNanos) + request[20..<30]
    }

    /// A message Apple's senders add every second, with two fields of their own.
    static func signaling(clock: UInt64, sequence: UInt16) -> Data {
        var message = header(.signaling, length: 106, flags: unicast | timescale, clock: clock, sequence: sequence,
                             control: 0x05, interval: -128)
        message.append(Data(count: 10))
        message.append(contentsOf: [0x00, 0x03, 0x00, 0x16, 0x00, 0x0D, 0x93, 0x00, 0x00, 0x01, 0x00, 0x00, 0x03, 0x01])
        message.append(Data(count: 12))
        message.append(contentsOf: [0x00, 0x03, 0x00, 0x20, 0x00, 0x0D, 0x93, 0x00, 0x00, 0x05, 0x00, 0x00, 0x03, 0x01])
        message.append(Data(count: 22))
        return message
    }
}

/// The clock this machine offers AirPlay 2 speakers: it tells each of them the time eight
/// times a second, and answers when they measure the way to us. Its time is the server's
/// clock, the one the music is scheduled on.
final class PTPClock: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case portsTaken

        var description: String {
            "can't offer it a clock: something else on this computer uses the clock ports (319 and 320)"
        }
    }

    /// What the clock goes by on the network: the same for every speaker, for as long as we run.
    static let identity = UInt64.random(in: 1 ... .max) | 0x0000_00FF_FE00_0000

    /// The time on the clock, in nanoseconds since 1970.
    static func nowNanos(_ serverMicros: Int64 = ServerClock.nowMicros()) -> UInt64 {
        UInt64(max(0, serverMicros + epochOffset)) * 1_000
    }

    private static let epochOffset = Int64(Date().timeIntervalSince1970 * 1_000_000) - ServerClock.nowMicros()

    private static let lock = NSLock()
    private nonisolated(unsafe) static var running: PTPClock?

    /// The one clock of this process. Its ports are fixed by the protocol and low, which the
    /// system only lets a program take on all of the machine's addresses at once.
    static func shared() throws -> PTPClock {
        try lock.withLock {
            if let running { return running }
            let clock = try PTPClock()
            running = clock
            return clock
        }
    }

    private let queue = DispatchQueue(label: "tandem.airplay.clock")
    private var event: UDPSocket!
    private var general: UDPSocket!
    /// The speakers that follow the clock, with how many streams each has.
    private var peers: [String: (count: Int, event: sockaddr_in, general: sockaddr_in)] = [:]
    private var timer: (any DispatchSourceTimer)?
    private var ticks = 0
    private var syncs: UInt16 = 0, announces: UInt16 = 0, signals: UInt16 = 0

    private init() throws {
        do {
            let general = try UDPSocket(queue: queue, port: PTP.generalPort) { _, _ in }
            self.general = general
            event = try UDPSocket(queue: queue, port: PTP.eventPort) { [weak general] packet, sender in
                let received = Self.nowNanos()
                guard let answer = PTP.delayResponse(to: packet, clock: Self.identity, receivedNanos: received) else { return }
                var address = sender
                address.sin_port = PTP.generalPort.bigEndian
                general?.send(answer, to: address)
            }
        } catch {
            Log.debug("AirPlay clock: \(error)")
            general?.close()
            throw Failure.portsTaken
        }
    }

    /// Have a speaker follow the clock; it's told the time at once.
    func add(peer address: String) {
        guard let event = UDPSocket.address(address, port: PTP.eventPort),
              let general = UDPSocket.address(address, port: PTP.generalPort) else { return }
        queue.async {
            self.peers[address] = ((self.peers[address]?.count ?? 0) + 1, event, general)
            self.announce()
            self.sync()
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(125), repeating: .milliseconds(125), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func remove(peer address: String) {
        queue.async {
            guard let peer = self.peers[address] else { return }
            self.peers[address] = peer.count > 1 ? (peer.count - 1, peer.event, peer.general) : nil
            if self.peers.isEmpty {
                self.timer?.cancel()
                self.timer = nil
            }
        }
    }

    private func tick() {
        ticks += 1
        if ticks.isMultiple(of: 8) { announce() }
        sync()
    }

    private func announce() {
        let announce = PTP.announce(clock: Self.identity, sequence: announces)
        let signaling = PTP.signaling(clock: Self.identity, sequence: signals)
        announces &+= 1
        signals &+= 1
        for peer in peers.values {
            general.send(announce, to: peer.general)
            general.send(signaling, to: peer.general)
        }
    }

    private func sync() {
        let message = PTP.sync(clock: Self.identity, sequence: syncs)
        for peer in peers.values {
            event.send(message, to: peer.event)
            general.send(PTP.followUp(clock: Self.identity, sequence: syncs, sentNanos: Self.nowNanos()), to: peer.general)
        }
        syncs &+= 1
    }
}
