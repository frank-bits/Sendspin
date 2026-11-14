import Foundation
import SendspinClientKit

/// How newly chosen music joins the queue.
public enum QueueInsertion: String, Sendable {
    /// Play now, in place of the queue.
    case replace
    /// Play now, keeping the rest of the queue after it.
    case play
    /// Play after the current track.
    case next
    /// Play after everything queued.
    case add
}

extension PlaybackEngine {
    /// Put `tracks` in the queue. `startAt` is the one to begin with, for `replace`.
    public func enqueue(_ tracks: [LibraryTrack], _ insertion: QueueInsertion = .replace, startAt: Int = 0,
                        shuffle wanted: Bool? = nil) async {
        guard !tracks.isEmpty else { return }
        let wasEmpty = queue.isEmpty
        switch wasEmpty ? .replace : insertion {
        case .replace:
            queue = tracks
            unshuffled = nil
            cursor = tracks.indices.contains(startAt) ? startAt : 0
            if wanted ?? shuffle {
                shuffle = true
                shuffleQueue(keepingFirst: wanted != true || startAt != 0)
            } else {
                shuffle = false
            }
            await start(at: 0)
        case .play:
            let place = min(queue.count, (currentIndex ?? cursor) + 1)
            queue.insert(contentsOf: tracks, at: place)
            unshuffled?.append(contentsOf: tracks)
            cursor = place
            await start(at: 0)
        case .next:
            queue.insert(contentsOf: tracks, at: min(queue.count, (currentIndex ?? cursor) + 1))
            unshuffled?.append(contentsOf: tracks)
            await publish()
        case .add:
            queue.append(contentsOf: tracks)
            unshuffled?.append(contentsOf: tracks)
            await publish()
        }
    }

    /// The place in the queue of the track that's heard.
    private var currentIndex: Int? {
        guard let track = currentTrack else { return nil }
        return queue.firstIndex(of: track)
    }

    public func setShuffle(_ on: Bool) async {
        guard on != shuffle else { return }
        shuffle = on
        if on {
            shuffleQueue(keepingFirst: true)
        } else if let original = unshuffled {
            let current = currentTrack
            queue = original
            unshuffled = nil
            cursor = current.flatMap { queue.firstIndex(of: $0) } ?? 0
        }
        await publish()
    }

    /// Shuffle what follows the current track; it stays first, unless the whole queue is
    /// to start in a random place.
    private func shuffleQueue(keepingFirst: Bool) {
        unshuffled = queue
        guard queue.indices.contains(cursor) else { return }
        if keepingFirst {
            let current = queue.remove(at: cursor)
            queue = [current] + queue.shuffled()
        } else {
            queue.shuffle()
        }
        cursor = 0
    }

    /// `mode` is "off", "one" or "all".
    public func setRepeat(_ mode: String) async {
        guard ["off", "one", "all"].contains(mode), mode != repeatMode else { return }
        repeatMode = mode
        await publish()
    }

    /// A controller's command for the queue (roles/controller/v1.md).
    func handle(_ command: ControllerCommand) async {
        switch command.command {
        case "play": await play()
        case "pause": await pause()
        case "stop": await stop()
        case "next": await next()
        case "previous": await previous()
        case "repeat_off": await setRepeat("off")
        case "repeat_one": await setRepeat("one")
        case "repeat_all": await setRepeat("all")
        case "shuffle": await setShuffle(true)
        case "unshuffle": await setShuffle(false)
        case "seek":
            if let position = command.positionMs { await seek(to: Double(position) / 1_000) }
        case "seek_relative":
            if let offset = command.offsetMs { await seek(by: Double(offset) / 1_000) }
        default:
            break
        }
    }
}
