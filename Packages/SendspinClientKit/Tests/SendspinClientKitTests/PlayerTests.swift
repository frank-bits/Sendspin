import Foundation
import Testing
@testable import SendspinClientKit

struct AudioChunkTests {
    @Test func parsesTimestampSendAheadAndAudio() throws {
        // Timestamp 0x0000_0001_0000_0002, send_ahead 0x0001_0000, then three bytes of audio.
        let body = Data([0, 0, 0, 1, 0, 0, 0, 2, 0, 1, 0, 0, 0xAA, 0xBB, 0xCC])
        let chunk = try #require(AudioChunk(body))
        #expect(chunk.timestampUs == 0x0000_0001_0000_0002)
        #expect(chunk.sendAheadUs == 0x0001_0000)
        #expect(chunk.audio == Data([0xAA, 0xBB, 0xCC]))
    }

    @Test func parsesANegativeTimestampAndASliceOfLargerData() throws {
        let whole = Data([9, 9] + [UInt8](repeating: 0xFF, count: 8) + [0, 0, 0, 0])
        let chunk = try #require(AudioChunk(whole.dropFirst(2)))
        #expect(chunk.timestampUs == -1)
        #expect(chunk.audio.isEmpty)
    }

    @Test func rejectsABodyShorterThanTheHeader() {
        #expect(AudioChunk(Data(repeating: 0, count: 11)) == nil)
    }
}

struct PlayerEngineTests {
    @Test func offersTheOutputRateFirstThenTheOther() {
        let at441 = PlayerEngine.support(outputRate: 44_100).supportedFormats
        #expect(at441.map(\.sampleRate) == [44_100, 44_100, 48_000, 48_000])
        #expect(at441.map(\.codec) == ["flac", "pcm", "flac", "pcm"])
        // A rate servers needn't support isn't offered: 48 kHz leads, and the output converts.
        #expect(PlayerEngine.support(outputRate: 96_000).supportedFormats.first?.sampleRate == 48_000)
    }

    @Test func stateOffersVolumeAndMute() {
        let state = PlayerEngine.state(volume: 30, muted: true)
        #expect(state.volume == 30 && state.muted == true)
        #expect(state.supportedCommands == ["volume", "mute"])
    }

    @Test func monoBecomesStereoAndExtraChannelsAreDropped() {
        #expect(PlayerEngine.stereo([1, 2], channels: 1) == [1, 1, 2, 2])
        #expect(PlayerEngine.stereo([1, 2, 3, 4], channels: 2) == [1, 2, 3, 4])
        #expect(PlayerEngine.stereo([1, 2, 3, 4, 5, 6], channels: 3) == [1, 2, 4, 5])
    }

    @Test func decodesStreamMessages() throws {
        let start = Data(#"{"type":"stream/start","payload":{"server_transmitted":5,"player":{"codec":"flac","sample_rate":48000,"channels":2,"bit_depth":16,"codec_header":"ZkxhQw=="}}}"#.utf8)
        let player = try #require(try MessageCoding.payload(StreamStartReceived.self, from: start).player)
        #expect(player.codec == "flac" && player.sampleRate == 48_000 && player.bitDepth == 16)
        #expect(Data(base64Encoded: try #require(player.codecHeader)) == Data("fLaC".utf8))

        let clear = Data(#"{"type":"stream/clear","payload":{"server_transmitted":5,"from_timestamp":77,"roles":["player"]}}"#.utf8)
        #expect(try MessageCoding.payload(StreamClearReceived.self, from: clear).fromTimestamp == 77)
        let end = Data(#"{"type":"stream/end","payload":{}}"#.utf8)
        #expect(try MessageCoding.payload(StreamEndReceived.self, from: end).roles == nil)
        let command = Data(#"{"type":"server/command","payload":{"player":{"command":"volume","volume":40}}}"#.utf8)
        #expect(try MessageCoding.payload(PlayerCommandReceived.self, from: command).player?.volume == 40)
    }

    @Test func decodes16BitLittleEndianPCM() throws {
        let decoder = try #require(SourceDecoder(format: SourceFormat(codec: "pcm", channels: 2, sampleRate: 48_000, bitDepth: 16)))
        // 0x4000 = half scale, 0x8000 = negative full scale.
        let samples = try #require(decoder.decode(Data([0x00, 0x40, 0x00, 0x80])))
        #expect(samples == [0.5, -1])
        // Not a whole number of frames.
        #expect(decoder.decode(Data([0, 0, 0])) == nil)
    }
}

struct PlayoutAnchoringTests {
    static let rate = 48_000
    static let frameUs = 1_000_000.0 / Double(rate)

    private func render(_ buffer: PlayoutBuffer, frames: Int, atUs: Double) -> [Float] {
        var output = [Float](repeating: -9, count: frames * 2)
        output.withUnsafeMutableBufferPointer { buffer.render(into: $0.baseAddress!, frames: frames, outputUs: atUs) }
        return output
    }

    private func write(_ buffer: PlayoutBuffer, first: Int, count: Int, atUs: Int64) {
        let samples = (0..<count).flatMap { [Float(first + $0), Float(first + $0)] }
        samples.withUnsafeBufferPointer { buffer.write($0, timestampUs: atUs) }
    }

    @Test func truncateKeepsOnlyFramesDueBeforeTheTime() {
        let buffer = PlayoutBuffer(sampleRate: Self.rate)
        write(buffer, first: 1, count: 480, atUs: 1_000_000)
        buffer.truncate(fromUs: 1_005_000)  // 5 ms = 240 frames
        #expect(buffer.queuedFrames == 240)
        buffer.truncate(fromUs: 2_000_000)  // after the end: nothing more goes
        #expect(buffer.queuedFrames == 240)
        buffer.truncate(fromUs: 0)  // before the start: everything goes
        #expect(buffer.queuedFrames == 0)
    }

    @Test func audioWrittenAfterATruncateContinuesFromThere() {
        let buffer = PlayoutBuffer(sampleRate: Self.rate)
        write(buffer, first: 1, count: 480, atUs: 1_000_000)
        buffer.truncate(fromUs: 1_005_000)
        write(buffer, first: 1_000, count: 48, atUs: 1_005_000)
        let output = render(buffer, frames: 288, atUs: 1_000_000)
        #expect(output[0] == 1)
        #expect(output[2 * 239] == 240)
        #expect(output[2 * 240] == 1_000)
    }

    @Test func aContinuousWriteReanchorsTheQueueOnItsTimestamp() {
        let buffer = PlayoutBuffer(sampleRate: Self.rate)
        write(buffer, first: 1, count: 480, atUs: 1_000_000)
        // The next chunk's time moved 300 µs later than the queue's end: within continuity, so it
        // joins with no silence inserted, and the whole queue is now due 300 µs later.
        write(buffer, first: 481, count: 480, atUs: 1_010_300)
        #expect(buffer.queuedFrames == 960)
        // Rendering at the re-anchored start time needs no one-shot correction beyond the first.
        _ = render(buffer, frames: 48, atUs: 1_000_300)
        #expect(buffer.counters.snaps == 1)
        #expect(abs(buffer.smoothedErrorUs) < 1)
    }
}
