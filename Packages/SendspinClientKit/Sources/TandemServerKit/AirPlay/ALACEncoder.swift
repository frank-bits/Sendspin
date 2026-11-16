import AVFoundation
import Foundation

/// Compresses AirPlay's packets of audio with Apple's lossless encoder.
final class ALACEncoder {
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioCompressedBuffer

    /// Nil where the system has no lossless encoder.
    init?() {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(RAOP.sampleRate), mFormatID: kAudioFormatAppleLossless,
            mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(RAOP.framesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: 2,
            mBitsPerChannel: 0, mReserved: 0)
        guard let lossless = AVAudioFormat(streamDescription: &description),
              let plain = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(RAOP.sampleRate),
                                        channels: 2, interleaved: true),
              let converter = AVAudioConverter(from: plain, to: lossless),
              let input = AVAudioPCMBuffer(pcmFormat: plain, frameCapacity: AVAudioFrameCount(RAOP.framesPerPacket))
        else { return nil }
        self.converter = converter
        self.input = input
        output = AVAudioCompressedBuffer(format: lossless, packetCapacity: 1, maximumPacketSize: 8_192)
    }

    /// One packet's worth of interleaved stereo samples as a lossless frame; nil when the
    /// encoder gave none.
    func encode(_ samples: ArraySlice<Int16>) -> Data? {
        guard samples.count == RAOP.framesPerPacket * 2, let channel = input.int16ChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: source.count)
        }
        input.frameLength = AVAudioFrameCount(RAOP.framesPerPacket)
        output.packetCount = 0
        output.byteLength = 0
        var fed = false
        var error: NSError?
        let input = input
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.packetCount == 1, let sizes = output.packetDescriptions else { return nil }
        return Data(bytes: output.data, count: Int(sizes.pointee.mDataByteSize))
    }
}
