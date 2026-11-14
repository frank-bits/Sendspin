import AVFoundation
import Foundation
import SendspinClientKit

/// One music file, decoded a block at a time into the server's internal format: interleaved
/// float samples at the file's own rate, in mono or stereo.
final class AudioFileSource {
    enum SourceError: Error { case unreadable }

    let sampleRate: Int
    let channels: Int
    /// Seconds.
    let duration: Double

    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        sampleRate = Int(format.sampleRate.rounded())
        guard sampleRate > 0, format.channelCount > 0,
              // A tenth of a second at a time: whole microseconds at every usual rate.
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate / 10))
        else { throw SourceError.unreadable }
        self.buffer = buffer
        // More than two channels are cut to the first two: players take mono or stereo.
        channels = min(2, Int(format.channelCount))
        duration = Double(file.length) / format.sampleRate
    }

    /// Seconds into the file the next block starts at.
    var position: Double { Double(file.framePosition) / Double(sampleRate) }

    func seek(to seconds: Double) {
        file.framePosition = min(file.length, max(0, AVAudioFramePosition(seconds * Double(sampleRate))))
    }

    /// The next block, up to a tenth of a second; nil at the end of the file, or when it
    /// can't be read further.
    func next() -> PCMBuffer? {
        guard file.framePosition < file.length else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            Log.warning("Reading \(file.url.lastPathComponent) failed: \(error)")
            return nil
        }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return nil }
        var samples = [Float](repeating: 0, count: frames * channels)
        for channel in 0..<channels {
            let source = data[channel]
            for frame in 0..<frames { samples[frame * channels + channel] = source[frame] }
        }
        return PCMBuffer(samples: samples, sampleRate: sampleRate, channels: channels)
    }
}
