import CryptoKit
import Foundation
import Network
import SendspinClientKit

/// Connecting the AirPlay 2 way: pair without a code, switch the control connection to
/// encrypted frames, then set the session and its one stream up with property lists. The
/// audio and its timing are as in the first AirPlay, except that every packet is sealed.
extension AirPlayStream {
    enum PairingFailure: Error, CustomStringConvertible {
        case refused(String)

        var description: String {
            switch self {
            case .refused(let step): "wouldn't pair (\(step))"
            }
        }
    }

    /// The code every speaker takes for the pairing that stores nothing.
    private static let transientCode = "3939"

    func connectAirPlay2() async throws {
        let instance = (0..<8).map { _ in String(format: "%02X", UInt8.random(in: .min ... .max)) }.joined()
        let rtsp = RTSPClient(endpoint: speaker.endpoint, headers: [
            ("User-Agent", "AirPlay/409.16"), ("X-Apple-Client-Name", "Tandem"), ("Client-Instance", instance),
            ("DACP-ID", instance), ("Active-Remote", "\(UInt32.random(in: .min ... .max))"),
        ])
        var sockets: [UDPSocket] = []
        var events: NWConnection?
        var following: (clock: PTPClock, peer: String)?
        var clockAddress = ""
        do {
            let (local, remote) = try await rtsp.open()
            _ = try await rtsp.send("GET", "/info", lenient: true)
            let secret = try await pair(over: rtsp)
            await rtsp.secure(with: secret)

            let clock = try TimingResponder(queue: queue, localAddress: local)
            sockets.append(clock.socket)
            let audio = try UDPSocket(queue: queue, localAddress: local) { _, _ in }
            sockets.append(audio)
            let destination = AddressBox()
            // A packet asked for again goes out as it first did, on the audio socket.
            let control = try ResendResponder(queue: queue, localAddress: local, history: history) { [weak audio] packet in
                if let address = destination.address { audio?.send(packet, to: address) }
            }
            sockets.append(control.socket)

            let streamID = UInt32.random(in: 1 ... .max)
            let uri = "rtsp://\(remote)/\(streamID)"
            let colons = stride(from: 0, to: 16, by: 2).map { offset -> String in
                let start = instance.index(instance.startIndex, offsetBy: offset)
                return String(instance[start..<instance.index(start, offsetBy: 2)])
            }.joined(separator: ":")
            var setup: [String: Any] = ["deviceID": colons, "sessionUUID": UUID().uuidString]
            if speaker.followsClock {
                // The speaker takes its time from our clock on the network, which it's told
                // about here and starts hearing from at once.
                let network = try PTPClock.shared()
                // The clock speaks from whichever of our addresses the system picks for
                // this speaker, which is the one to name: speakers follow clocks by address.
                clockAddress = UDPSocket.sourceAddress(toward: remote) ?? local
                network.add(peer: remote)
                following = (network, remote)
                try await Task.sleep(for: .milliseconds(300))
                let peer: [String: Any] = [
                    "ID": UUID().uuidString, "DeviceType": 0, "ClockID": Int64(bitPattern: PTPClock.identity),
                    "SupportsClockPortMatchingOverride": false, "Addresses": [clockAddress],
                ]
                setup.merge([
                    "timingProtocol": "PTP", "name": "Tandem", "macAddress": String(colons.prefix(17)),
                    "groupUUID": UUID().uuidString, "groupContainsGroupLeader": false,
                    "timingPeerInfo": peer, "timingPeerList": [peer],
                ]) { _, new in new }
            } else {
                setup.merge(["timingProtocol": "NTP", "timingPort": Int(clock.socket.port)]) { _, new in new }
            }
            let session = try await plist(rtsp.send("SETUP", uri, body: Self.plist(setup),
                                                   contentType: "application/x-apple-binary-plist"))
            if let port = (session["eventPort"] as? NSNumber)?.uint16Value, port != 0,
               let eventPort = NWEndpoint.Port(rawValue: port) {
                // The speaker reports on this connection. We don't read what it says, but it
                // expects the connection to be there.
                let connection = NWConnection(host: NWEndpoint.Host(remote), port: eventPort, using: .tcp)
                connection.start(queue: queue)
                events = connection
            }
            // Before the stream is set up, as Apple's senders have it: some speakers play
            // nothing otherwise.
            _ = try await rtsp.send("RECORD", uri)
            let stream: [String: Any] = [
                "audioFormat": 0x40000, "audioMode": "default", "controlPort": Int(control.socket.port), "ct": 2,
                "isMedia": true, "latencyMax": RAOP.latencyFrames, "latencyMin": RAOP.receiverLatencyFrames,
                "shk": secret.prefix(32), "spf": RAOP.framesPerPacket, "sr": RAOP.sampleRate, "type": 96,
                "supportsDynamicStreamID": false, "streamConnectionID": Int(streamID),
            ]
            let answer = try await plist(rtsp.send("SETUP", uri, body: Self.plist(["streams": [stream]]),
                                                   contentType: "application/x-apple-binary-plist"))
            guard let ports = (answer["streams"] as? [[String: Any]])?.first,
                  let dataPort = (ports["dataPort"] as? NSNumber)?.uint16Value, dataPort != 0,
                  let controlPort = (ports["controlPort"] as? NSNumber)?.uint16Value, controlPort != 0,
                  let audioAddress = UDPSocket.address(remote, port: dataPort),
                  let controlAddress = UDPSocket.address(remote, port: controlPort)
            else { throw RTSPClient.Failure.malformed }
            destination.address = audioAddress
            if following != nil {
                // Who keeps time together: the speaker and us.
                let peers = try PropertyListSerialization.data(fromPropertyList: [remote, clockAddress], format: .binary, options: 0)
                _ = try await rtsp.send("SETPEERS", uri, body: peers, contentType: "/peer-list-changed")
            }
            Log.debug("\(speaker.name): AirPlay 2 ports data \(dataPort), control \(controlPort); ours control "
                + "\(control.socket.port), timing \(clock.socket.port)")

            try await begin(Link(rtsp: rtsp, uri: uri, audio: audio, control: control.socket, timing: clock.socket,
                                 audioAddress: audioAddress, controlAddress: controlAddress,
                                 receiverLatency: RAOP.receiverLatencyFrames, audioKey: SymmetricKey(data: secret.prefix(32)),
                                 // A stream on the network clock goes by that clock, not by a number.
                                 streamID: following == nil ? streamID : 0, events: events,
                                 clock: following?.clock, remote: remote))
            Log.info("\(speaker.name): AirPlay 2 connected from \(local)\(following == nil ? "" : ", on our clock")")
        } catch {
            sockets.forEach { $0.close() }
            events?.cancel()
            if let following { following.clock.remove(peer: following.peer) }
            rtsp.close()
            throw error
        }
    }

    /// Pair without a code or anything kept: two exchanges, after which both sides hold the
    /// same 64-byte secret.
    private func pair(over rtsp: RTSPClient) async throws -> Data {
        func exchange(_ fields: [(UInt8, Data)], step: String) async throws -> [UInt8: Data] {
            let response = try await rtsp.send("POST", "/pair-setup", headers: [("X-Apple-HKP", "4")],
                                               body: TLV8.encode(fields), contentType: "application/octet-stream")
            let answer = TLV8.decode(response.body)
            if let error = answer[TLV8.error] { throw PairingFailure.refused("\(step), error \(error.first ?? 0)") }
            return answer
        }
        // State 1: a pairing by password proof, of the kind that stores nothing (flag 0x10).
        let first = try await exchange([(TLV8.state, Data([1])), (TLV8.method, Data([0])), (TLV8.flags, Data([0x10]))],
                                       step: "start")
        guard let salt = first[TLV8.salt], let theirKey = first[TLV8.publicKey] else { throw PairingFailure.refused("no key") }
        let client = SRPClient(secret: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        guard let proof = client.prove(username: "Pair-Setup", password: Self.transientCode, salt: salt, serverKey: theirKey)
        else { throw PairingFailure.refused("bad key") }
        let second = try await exchange([(TLV8.state, Data([3])), (TLV8.publicKey, client.publicKey), (TLV8.proof, proof.proof)],
                                        step: "proof")
        guard second[TLV8.proof] == proof.answer else { throw PairingFailure.refused("its proof doesn't match") }
        return proof.key
    }

    static func plist(_ values: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    }

    private func plist(_ response: RTSPClient.Response) throws -> [String: Any] {
        guard let values = try PropertyListSerialization.propertyList(from: response.body, format: nil) as? [String: Any]
        else { throw RTSPClient.Failure.malformed }
        return values
    }
}

/// Where a stream's audio goes, known only once the speaker answered the setup.
private final class AddressBox: @unchecked Sendable {
    var address: sockaddr_in?
}
