import AudioToolbox
import CoreAudio

/// The iMac's system volume and mute: those of the default output device, the same ones
/// the volume keys change. The Mac mirrors them on its "iMac" audio output.
final class SystemVolume {
    /// Called on the main thread when volume or mute change on the iMac.
    var onChange: ((AudioVolumeMessage) -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var listener: AudioObjectPropertyListenerBlock?
    private let selectors = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute]

    /// Call on the main thread.
    func start() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.followDefaultDevice()
        }
        followDefaultDevice()
    }

    var level: AudioVolumeMessage {
        var volume: Float32 = 1
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.address(selectors[0])
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = selectors[1]
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return AudioVolumeMessage(volume: volume, muted: muted != 0)
    }

    func set(_ level: AudioVolumeMessage) {
        var volume = Float32(min(max(level.volume, 0), 1))
        var muted: UInt32 = level.muted ? 1 : 0
        var address = Self.address(selectors[0])
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        address.mSelector = selectors[1]
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muted)
    }

    /// Moves the volume listeners to the current default output (headphones plugged in…).
    private func followDefaultDevice() {
        if let listener, device != kAudioObjectUnknown {
            for selector in selectors {
                var address = Self.address(selector)
                AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener)
            }
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        device = id

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.onChange?(self.level)
        }
        self.listener = listener
        for selector in selectors {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
        }
        onChange?(level)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
