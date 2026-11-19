#if os(macOS)
import Foundation
import SendspinClientKit
import TandemServerKit

/// One Apple Music song as it's captured: what the tap hears, cut into blocks for the engine.
@available(macOS 14.2, *)
final class AppleMusicStream: LiveStream, @unchecked Sendable {
    let trackID: String
    private let onClose: @Sendable (AppleMusicStream) -> Void
    private let lock = NSLock()
    private var blocks: [PCMBuffer] = []
    private var pending: [Float] = []
    private var accepting = false
    private var sawSound = false
    private var ended = false

    /// A twentieth of a second at the usual rate.
    private static let blockFrames = 2_400
    /// More than this waiting means nobody reads: the oldest go.
    private static let limit = 200

    init(trackID: String, onClose: @escaping @Sendable (AppleMusicStream) -> Void) {
        self.trackID = trackID
        self.onClose = onClose
    }

    /// The song plays now: what's heard from here on is its sound.
    func accept() {
        lock.withLock { accepting = true }
    }

    func append(_ samples: [Float], sampleRate: Int, channels: Int) {
        lock.withLock {
            guard accepting, !ended else { return }
            // The silence before the first sound isn't part of the song.
            if !sawSound {
                guard samples.contains(where: { $0 != 0 }) else { return }
                sawSound = true
            }
            pending += samples
            let size = Self.blockFrames * channels
            while pending.count >= size {
                blocks.append(PCMBuffer(samples: Array(pending.prefix(size)), sampleRate: sampleRate, channels: channels))
                pending.removeFirst(size)
            }
            if blocks.count > Self.limit { blocks.removeFirst(blocks.count - Self.limit) }
        }
    }

    /// The song is over, or can't play: what was captured is still read, then the stream ends.
    func finish() {
        lock.withLock { ended = true }
    }

    var hasEnded: Bool { lock.withLock { ended } }

    func read() -> LiveRead {
        lock.withLock {
            if !blocks.isEmpty { return .block(blocks.removeFirst()) }
            return ended ? .ended : .wait
        }
    }

    func close() {
        finish()
        onClose(self)
    }
}
#endif
