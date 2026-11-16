import AVFoundation
import Foundation
import Network
import SendspinClientKit
import Testing
@testable import TandemServerKit

@Suite struct RAOPTests {
    /// The uncompressed ALAC frame: a 23-bit header, then each sample, high byte first.
    @Test func alacFrameShiftsSamplesBySevenBits() {
        let frame = RAOP.alacFrame([0x1234, -1][...])
        // 0010 0000 | 0000 0000 | 0000 001s, the rest of the samples, then the end tag: 111.
        #expect(Array(frame) == [0x20, 0x00, 0x02, 0x24, 0x69, 0xFF, 0xFF, 0xC0])
    }

    @Test func aPacketOfAudioIsTheSizeReceiversExpect() {
        let frame = RAOP.alacFrame([Int16](repeating: 0, count: RAOP.framesPerPacket * 2)[...])
        #expect(frame.count == 1_412)
    }

    @Test func audioPacketsCarrySequenceTimestampAndSource() {
        let packet = RAOP.audioPacket(sequence: 0x0102, timestamp: 0x0A0B0C0D, source: 0x11223344, first: true, payload: Data([9]))
        #expect(Array(packet) == [0x80, 0xE0, 0x01, 0x02, 0x0A, 0x0B, 0x0C, 0x0D, 0x11, 0x22, 0x33, 0x44, 9])
        #expect(RAOP.audioPacket(sequence: 0, timestamp: 0, source: 0, first: false, payload: Data())[1] == 0x60)
    }

    /// The latency we state leaves out the receiver's share, which it adds itself.
    @Test func syncPacketsStateTheLatencyLessTheReceiversShare() {
        let packet = RAOP.syncPacket(first: true, timestamp: 100_000, receiverLatency: 11_025, nowMicros: 2_500_000)
        #expect(packet.count == 20)
        #expect(Array(packet[0..<4]) == [0x90, 0xD4, 0x00, 0x07])
        #expect(packet[4..<8].reduce(0) { $0 << 8 | UInt32($1) } == 100_000 - 77_175)
        // 2.5 s: two seconds, and half of 2^32.
        #expect(Array(packet[8..<16]) == [0, 0, 0, 2, 0x80, 0, 0, 0])
        #expect(packet[16..<20].reduce(0) { $0 << 8 | UInt32($1) } == 100_000)
        #expect(RAOP.syncPacket(first: false, timestamp: 0, receiverLatency: 0, nowMicros: 0)[0] == 0x80)
    }

    @Test func timingRequestsAreAnsweredWithTheirOwnTransmitTime() throws {
        var request = Data([0x80, 0xD2, 0x00, 0x07]) + Data(count: 20)
        request.append(contentsOf: [1, 2, 3, 4, 5, 6, 7, 8])
        let reply = try #require(RAOP.timingReply(to: request, nowMicros: 1_000_000))
        #expect(reply.count == 32)
        #expect(reply[1] == 0xD3)
        #expect(Array(reply[8..<16]) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(Array(reply[16..<24]) == [0, 0, 0, 1, 0, 0, 0, 0])
        #expect(RAOP.timingReply(to: Data([0x80, 0xD4]) + Data(count: 30), nowMicros: 0) == nil)
    }

    @Test func resendRequestsNameTheFirstPacketAndHowMany() throws {
        let request = try #require(RAOP.resendRequest(Data([0x80, 0xD5, 0, 1, 0x12, 0x34, 0, 3])))
        #expect(request.first == 0x1234)
        #expect(request.count == 3)
        #expect(RAOP.resendRequest(Data([0x80, 0xD4, 0, 1, 0, 0, 0, 0])) == nil)
        #expect(Array(RAOP.resendReply(Data([7, 8]))) == [0x80, 0xD6, 0x00, 0x01, 7, 8])
    }

    @Test func volumeRunsFromMinusThirtyDecibelsToNone() {
        #expect(RAOP.decibels(volume: 100, muted: false) == 0)
        #expect(RAOP.decibels(volume: 50, muted: false) == -15)
        #expect(RAOP.decibels(volume: 0, muted: false) == -144)
        #expect(RAOP.decibels(volume: 80, muted: true) == -144)
    }

    @Test func monoBecomesStereoAndLoudSamplesAreClipped() {
        #expect(RAOP.stereo16([0.5, -2], channels: 1) == [16_384, 16_384, -32_768, -32_768])
        #expect(RAOP.stereo16([1, 0, 0.25, -0.25], channels: 2) == [32_767, 0, 8_192, -8_192])
    }

    @Test func oldPacketsAreForgotten() {
        let history = PacketHistory()
        for sequence in 0..<1_100 { history.store(Data([UInt8(sequence % 256)]), sequence: UInt16(sequence)) }
        #expect(history.packet(10) == nil)
        #expect(history.packet(1_099) == Data([UInt8(1_099 % 256)]))
    }

    @Test func transportParametersAreRead() {
        let values = AirPlayStream.parameters("RTP/AVP/UDP;unicast;mode=record;server_port=6000;control_port=6001;timing_port=6002")
        #expect(values["server_port"] == "6000")
        #expect(values["control_port"] == "6001")
    }
}

@Suite struct AirPlayBrowserTests {
    private let endpoint = NWEndpoint.hostPort(host: "192.168.1.2", port: 7000)

    @Test func aSonosOrWiiMSpeakerIsTaken() throws {
        let speaker = try #require(AirPlayBrowser.speaker(
            instance: "804AF2902540@Bedroom", txt: ["et": "0,4", "cn": "0,1", "am": "Era 100"], endpoint: endpoint))
        #expect(speaker.id == "804AF2902540")
        #expect(speaker.name == "Bedroom")
        #expect(speaker.model == "Era 100")
        #expect(speaker.wantsAuthSetup)
    }

    @Test func aNameMayHoldAnAtSign() throws {
        let speaker = try #require(AirPlayBrowser.speaker(instance: "AA@Me@Home", txt: ["et": "0,1", "cn": "0,1"], endpoint: endpoint))
        #expect(speaker.name == "Me@Home")
        #expect(!speaker.wantsAuthSetup)
    }

    /// Apple's own devices, and speakers with a password, can't be played on this way.
    @Test func appleDevicesAndPasswordsAreLeftOut() {
        #expect(AirPlayBrowser.speaker(instance: "AA@Apple TV", txt: ["et": "0,3,5", "cn": "0,1,2,3"], endpoint: endpoint) == nil)
        #expect(AirPlayBrowser.speaker(instance: "AA@Locked", txt: ["et": "0,1", "cn": "0,1", "pw": "true"], endpoint: endpoint) == nil)
        #expect(AirPlayBrowser.speaker(instance: "AA@Encrypted", txt: ["et": "1", "cn": "0,1"], endpoint: endpoint) == nil)
        #expect(AirPlayBrowser.speaker(instance: "NoAddress", txt: ["et": "0", "cn": "1"], endpoint: endpoint) == nil)
    }
}

@Suite struct AirPlaySettingsTests {
    @Test func speakerSettingsSurviveARestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let group = PlaybackGroup(name: "Test", leadMs: 500)
        let speakers = AirPlaySpeakers(group: group, store: try ServerStore(directory: directory)) { _ in }
        await speakers.setEnabled("AA", true)
        await speakers.setVolume("AA", 140)
        let saved = try ServerStore(directory: directory).airPlaySettings["AA"]
        #expect(saved?.enabled == true)
        #expect(saved?.volume == 100)
        // Switched on but not on the network: listed, and it takes no part in the group.
        let listed = await speakers.speakers
        #expect(listed.map(\.id) == ["AA"])
        #expect(listed.first?.present == false)
        #expect(await group.requiredLeadMs() == PlaybackGroup.sendMarginMs)
    }
}

@Suite struct ALACFrameTests {
    /// Noise can't be compressed, so Apple's encoder writes it out as it is: the same frame
    /// ours must be, byte for byte, for a speaker's decoder to read it.
    @Test func ourFramesAreWhatApplesEncoderWritesForNoise() throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(RAOP.sampleRate), mFormatID: kAudioFormatAppleLossless,
            mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(RAOP.framesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0,
            mReserved: 0)
        let lossless = try #require(AVAudioFormat(streamDescription: &description))
        let plain = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(RAOP.sampleRate),
                                               channels: 2, interleaved: true))
        let encoder = try #require(AVAudioConverter(from: plain, to: lossless))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: plain, frameCapacity: AVAudioFrameCount(RAOP.framesPerPacket)))
        input.frameLength = AVAudioFrameCount(RAOP.framesPerPacket)
        var samples = [Int16]()
        var state: UInt32 = 12_345
        let channel = try #require(input.int16ChannelData)[0]
        for index in 0..<RAOP.framesPerPacket * 2 {
            state = state &* 1_664_525 &+ 1_013_904_223
            samples.append(Int16(truncatingIfNeeded: state >> 16))
            channel[index] = samples[index]
        }
        let output = AVAudioCompressedBuffer(format: lossless, packetCapacity: 4, maximumPacketSize: 8_192)
        var fed = false
        var error: NSError?
        encoder.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        #expect(error == nil)
        let size = Int(try #require(output.packetDescriptions).pointee.mDataByteSize)
        let theirs = Data(bytes: output.data, count: size)
        #expect(theirs == RAOP.alacFrame(samples[...]))
    }
}
