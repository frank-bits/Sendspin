import AudioToolbox
import Foundation
#if os(iOS)
import AVFAudio
#endif

enum AudioOutputError: Error, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    case noOutputUnit

    var description: String {
        switch self {
        case let .coreAudio(call, status): "\(call) failed (\(status))"
        case .noOutputUnit: "no audio output unit"
        }
    }
}

/// Plays stereo audio on the system's current output so that each frame is heard at its due
/// time on this device's clock (`ServerClock`, host time in µs).
///
/// The output unit takes audio at the stream's sample rate and reports when each render will
/// reach the hardware; the output's latency is added to that, and `PlayoutBuffer` keeps the
/// audio aligned by dropping or repeating single frames as the clocks drift.
/// Adapted from sendspin-mac's SendspinAudio/LocalPlayer.swift (see UPSTREAM.md).
public final class AudioOutput: @unchecked Sendable {
    public let sampleRate: Int

    private let queue = DispatchQueue(label: "sendspin.audio-output", qos: .userInteractive)

    // Under `lock`: shared by the writer and the render callback.
    private let lock = NSLock()
    private let playout: PlayoutBuffer
    private var latencyUs: Double
    private var targetGain: Float = 1
    private var wantsOutput = false

    // Render thread only.
    private var gain: Float = 1

    // On `queue`.
    private var unit: AudioUnit?
    private var running = false

    public init(sampleRate: Int) {
        self.sampleRate = sampleRate
        playout = PlayoutBuffer(sampleRate: sampleRate)
        latencyUs = OutputDevice.latencyUs()
    }

    deinit {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
        }
    }

    /// How long after its render timestamp a frame is heard, in µs.
    public var outputLatencyUs: Double { lock.withLock { latencyUs } }

    /// Perceived volume 0-100 as amplitude `(volume / 100)^1.5` (roles/player/v1.md); changes
    /// ramp over one render so they don't click.
    public func setVolume(_ volume: Int, muted: Bool) {
        let amplitude = Float(pow(Double(min(100, max(0, volume))) / 100, 1.5))
        lock.withLock { targetGain = muted ? 0 : amplitude }
    }

    /// Queue interleaved stereo frames, the first due at `timestampUs` on this device's clock.
    /// The output starts with the first audio.
    func write(_ samples: [Float], timestampUs: Int64) {
        let start = lock.withLock {
            samples.withUnsafeBufferPointer { playout.write($0, timestampUs: timestampUs) }
            let start = !wantsOutput
            wantsOutput = true
            return start
        }
        if start { queue.async { self.applyRunning() } }
    }

    /// Drop everything queued; the output keeps running (stream/clear).
    func clear() {
        lock.withLock { playout.reset() }
    }

    /// Drop the queued audio due at or after `timestampUs` (stream/clear with from_timestamp).
    func truncate(fromUs timestampUs: Int64) {
        lock.withLock { playout.truncate(fromUs: timestampUs) }
    }

    /// Drop everything queued and stop the output (stream/end).
    func stop() {
        lock.withLock {
            playout.reset()
            wantsOutput = false
        }
        queue.async { self.applyRunning() }
    }

    /// The smoothed sync error in µs and the corrections made so far.
    var statistics: (errorUs: Double, counters: PlayoutBuffer.Counters) {
        lock.withLock { (playout.smoothedErrorUs, playout.counters) }
    }

    // MARK: Output

    /// Start or stop the output, as playback needs it.
    private func applyRunning() {
        let wanted = lock.withLock { wantsOutput }
        guard wanted != running else { return }
        if wanted {
            do {
                #if os(iOS)
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)
                #endif
                let latency = OutputDevice.latencyUs()
                lock.withLock { latencyUs = latency }
                let unit = try unit ?? makeUnit()
                self.unit = unit
                try check("AudioOutputUnitStart", AudioOutputUnitStart(unit))
                running = true
                Log.info("Playing at \(sampleRate) Hz, " + String(format: "output latency %.1f ms", latency / 1000))
            } catch {
                Log.error("Couldn't start the audio output: \(error)")
                disposeUnit()
            }
        } else if let unit {
            AudioOutputUnitStop(unit)
            running = false
            let counters = lock.withLock {
                defer { playout.counters = PlayoutBuffer.Counters() }
                return playout.counters
            }
            Log.info("Stopped playing: \(counters.snaps) resyncs, \(counters.droppedFrames) frames dropped and "
                + "\(counters.repeatedFrames) repeated for drift, \(counters.underruns) underruns")
        }
    }

    private func disposeUnit() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        running = false
    }

    private func check(_ call: String, _ status: OSStatus) throws {
        if status != noErr { throw AudioOutputError.coreAudio(call, status) }
    }

    /// The system's output unit, taking interleaved stereo float at the stream's rate.
    private func makeUnit() throws -> AudioUnit {
        #if os(macOS)
        let subType = kAudioUnitSubType_DefaultOutput
        #else
        let subType = kAudioUnitSubType_RemoteIO
        #endif
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw AudioOutputError.noOutputUnit }
        var newUnit: AudioUnit?
        try check("AudioComponentInstanceNew", AudioComponentInstanceNew(component, &newUnit))
        guard let unit = newUnit else { throw AudioOutputError.noOutputUnit }
        do {
            let channels = UInt32(PlayoutBuffer.channels)
            var format = AudioStreamBasicDescription(
                mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
                mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
            try check("set stream format", AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
            var callback = AURenderCallbackStruct(
                inputProc: { refCon, _, timestamp, _, frameCount, ioData in
                    guard let ioData else { return noErr }
                    Unmanaged<AudioOutput>.fromOpaque(refCon).takeUnretainedValue()
                        .render(ioData, frames: Int(frameCount), timestamp: timestamp.pointee)
                    return noErr
                },
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check("set render callback", AudioUnitSetProperty(
                unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try check("AudioUnitInitialize", AudioUnitInitialize(unit))
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        return unit
    }

    /// On the render thread: the frames heard from the timestamp plus the output latency.
    private func render(_ ioData: UnsafeMutablePointer<AudioBufferList>, frames: Int, timestamp: AudioTimeStamp) {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard let samples = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let target: Float
        if timestamp.mFlags.contains(.hostTimeValid) {
            let hostUs = Double(ServerClock.micros(fromHostTime: timestamp.mHostTime))
            target = lock.withLock {
                playout.render(into: samples, frames: frames, outputUs: hostUs + latencyUs)
                return targetGain
            }
        } else {
            samples.update(repeating: 0, count: frames * PlayoutBuffer.channels)
            target = gain
        }
        guard gain != 1 || target != 1 else { return }
        // A change of volume ramps over this render; then the gain is constant.
        let step = (target - gain) / Float(max(1, frames))
        for frame in 0..<frames {
            let frameGain = gain + step * Float(frame + 1)
            samples[2 * frame] *= frameGain
            samples[2 * frame + 1] *= frameGain
        }
        gain = target
    }
}
