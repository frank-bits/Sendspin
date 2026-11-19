#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation
import SendspinClientKit

/// Hears what one other process plays, and keeps it from this Mac's own speakers meanwhile.
///
/// macOS asks the user once to let Tandem record system audio. It only works in an app the
/// user runs at the Mac's screen: a process started over SSH hears silence.
@available(macOS 14.2, *)
final class ProcessTap: @unchecked Sendable {
    let sampleRate: Int
    let channels: Int
    /// CoreAudio's object for the process that's tapped.
    let process: AudioObjectID

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let lock = NSLock()
    private var sink: (@Sendable ([Float]) -> Void)?

    /// CoreAudio's object for the process with this bundle identifier, once it has played.
    static func process(bundleID: String) -> AudioObjectID? {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return nil }
        return objects.first { object in
            var name = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var nameAddress = Self.address(kAudioProcessPropertyBundleID)
            let status = withUnsafeMutablePointer(to: &name) {
                AudioObjectGetPropertyData(object, &nameAddress, 0, nil, &nameSize, $0)
            }
            return status == noErr && name as String == bundleID
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Nil when the tap can't be made: no output device, or the system refuses.
    init?(process: AudioObjectID) {
        self.process = process
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var output = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &output) == noErr else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        guard withUnsafeMutablePointer(to: &uid, { AudioObjectGetPropertyData(output, &address, 0, nil, &size, $0) }) == noErr
        else { return nil }

        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return nil }
        address.mSelector = kAudioTapPropertyFormat
        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
              format.mSampleRate > 0, format.mChannelsPerFrame > 0
        else {
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        sampleRate = Int(format.mSampleRate.rounded())
        let tapped = Int(format.mChannelsPerFrame)
        channels = min(2, tapped)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tandem Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: uid as String,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid as String]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        let kept = channels
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, DispatchQueue(label: "tandem.tap")) {
            [weak self] _, input, _, _, _ in
            guard let self else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var samples: [Float] = []
            if interleaved {
                guard let buffer = buffers.first, let data = buffer.mData else { return }
                let values = data.assumingMemoryBound(to: Float32.self)
                let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size / tapped
                samples.reserveCapacity(frames * kept)
                for frame in 0..<frames {
                    for channel in 0..<kept { samples.append(values[frame * tapped + channel]) }
                }
            } else {
                guard buffers.count >= kept, let first = buffers.first else { return }
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float32>.size
                samples.reserveCapacity(frames * kept)
                for frame in 0..<frames {
                    for channel in 0..<kept {
                        guard let data = buffers[channel].mData else { return }
                        samples.append(data.assumingMemoryBound(to: Float32.self)[frame])
                    }
                }
            }
            let sink = self.lock.withLock { self.sink }
            sink?(samples)
        }
        guard status == noErr, AudioDeviceStart(device, ioProc) == noErr else {
            teardown()
            return nil
        }
    }

    /// Who gets what's heard, as interleaved samples; nil for nobody.
    func send(to sink: (@Sendable ([Float]) -> Void)?) {
        lock.withLock { self.sink = sink }
    }

    private func teardown() {
        if let ioProc {
            AudioDeviceStop(device, ioProc)
            AudioDeviceDestroyIOProcID(device, ioProc)
        }
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
    }

    deinit { teardown() }
}
#endif
