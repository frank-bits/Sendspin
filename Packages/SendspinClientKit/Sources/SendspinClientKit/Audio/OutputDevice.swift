import Foundation
#if os(macOS)
import CoreAudio
#else
import AVFAudio
#endif

/// The system's current audio output: its sample rate, and how long after a render timestamp
/// a frame is heard.
public enum OutputDevice {
    #if os(macOS)
    public static func sampleRate() -> Int {
        guard let device = defaultOutput(),
              let rate = scalar(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, as: Float64.self)
        else { return 48_000 }
        return Int(rate)
    }

    /// For the built-in outputs the stream's latency alone, since the render timestamp already
    /// includes the device's latency and safety offset; for any other output (Bluetooth,
    /// AirPlay, USB) the full latency apps are told for lip sync. This follows sendspin-mac's
    /// acoustic measurements (SendspinAudio/LocalPlayer.swift).
    public static func latencyUs() -> Double {
        guard let device = defaultOutput() else { return 0 }
        let scope = kAudioObjectPropertyScopeOutput
        let rate = Double(sampleRate())
        var frames = streamLatencyFrames(device)
        let transport = scalar(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, as: UInt32.self)
        if transport != kAudioDeviceTransportTypeBuiltIn {
            frames += scalar(device, kAudioDevicePropertyLatency, scope, as: UInt32.self) ?? 0
            frames += scalar(device, kAudioDevicePropertySafetyOffset, scope, as: UInt32.self) ?? 0
        }
        return Double(frames) / rate * 1_000_000
    }

    /// Call `handler` on the main queue whenever the default output device changes.
    public static func onChange(_ handler: @escaping @Sendable () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in handler() }
    }

    private static func defaultOutput() -> AudioObjectID? {
        scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
               kAudioObjectPropertyScopeGlobal, as: AudioObjectID.self).flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    private static func streamLatencyFrames(_ device: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return 0 }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr, let first = streams.first
        else { return 0 }
        return scalar(first, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, as: UInt32.self) ?? 0
    }

    private static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  _ scope: AudioObjectPropertyScope, as _: T.Type) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr,
              size == UInt32(MemoryLayout<T>.size) else { return nil }
        return value.pointee
    }
    #else
    public static func sampleRate() -> Int {
        Int(AVAudioSession.sharedInstance().sampleRate)
    }

    /// What the audio session reports for the current route. Not yet measured acoustically on
    /// iOS: Bluetooth and AirPlay routes in particular may need a manual offset.
    public static func latencyUs() -> Double {
        AVAudioSession.sharedInstance().outputLatency * 1_000_000
    }

    /// Call `handler` on the main queue when the audio route gains or loses a device, and when
    /// an interruption (a call, an alarm) ends.
    public static func onChange(_ handler: @escaping @Sendable () -> Void) {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            switch raw.flatMap(AVAudioSession.RouteChangeReason.init) {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override: handler()
            default: break
            }
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw.flatMap(AVAudioSession.InterruptionType.init) == .ended { handler() }
        }
    }
    #endif
}
