import AudioToolbox
import CoreAudio
import Foundation

enum AudioCaptureError: LocalizedError {
    case failed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case let .failed(step, status):
            return String(format: NSLocalizedString("System audio could not be captured (%@, error %d). Check “System Audio Recording” in System Settings → Privacy & Security.", comment: "Audio error"), step, Int(status))
        }
    }
}

/// Captures everything the Mac plays through a Core Audio process tap (macOS 14.2+).
/// The tap is created with `.mutedWhenTapped`, so while streaming the sound comes
/// out of the iMac only and the Mac's own speakers stay silent.
final class SystemAudioCapturer {
    /// Called on the audio queue with interleaved Float32 samples.
    var onFormat: ((AudioFormatMessage) -> Void)?
    var onSamples: ((Data) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "imacdisplay.sender.audio", qos: .userInteractive)

    func start() throws {
        stop()

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "iMacDisplay"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw AudioCaptureError.failed("tap", status) }

        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "iMacDisplay Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ],
            ],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr else {
            stop()
            throw AudioCaptureError.failed("aggregate device", status)
        }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else {
            stop()
            throw AudioCaptureError.failed("format", status)
        }
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
            stop()
            throw AudioCaptureError.failed("unsupported format", -1)
        }

        let channels = Int(format.mChannelsPerFrame)
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let message = AudioFormatMessage(sampleRate: format.mSampleRate, channels: channels)
        queue.async { [weak self] in self?.onFormat?(message) }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
            self?.process(inputData, channels: channels, nonInterleaved: nonInterleaved)
        }
        guard status == noErr, procID != nil else {
            stop()
            throw AudioCaptureError.failed("io proc", status)
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stop()
            throw AudioCaptureError.failed("start", status)
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func process(_ inputData: UnsafePointer<AudioBufferList>, channels: Int, nonInterleaved: Bool) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard channels > 0, buffers.count > 0 else { return }

        if !nonInterleaved {
            let buffer = buffers[0]
            guard let source = buffer.mData, buffer.mDataByteSize > 0 else { return }
            onSamples?(Data(bytes: source, count: Int(buffer.mDataByteSize)))
            return
        }

        let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        guard frames > 0 else { return }
        var interleaved = Data(count: frames * channels * MemoryLayout<Float>.size)
        interleaved.withUnsafeMutableBytes { raw in
            let destination = raw.bindMemory(to: Float.self)
            for channel in 0..<min(channels, buffers.count) {
                guard let source = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<frames {
                    destination[frame * channels + channel] = source[frame]
                }
            }
        }
        onSamples?(interleaved)
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr else { throw AudioCaptureError.failed("output device", status) }

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let value = uid?.takeRetainedValue() else {
            throw AudioCaptureError.failed("output device UID", status)
        }
        return value as String
    }
}
