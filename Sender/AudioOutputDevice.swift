import AppKit
import CoreAudio

/// The iMac as an audio output of the Mac, provided by the iMacDisplay Audio driver
/// (AudioDriver/, installed into /Library/Audio/Plug-Ins/HAL). While connected the app
/// publishes the output under the iMac's name; what apps play to it is captured with a
/// process tap on it and streamed. Its volume and mute mirror the iMac's system volume.
enum AudioOutputDevice {
    static let deviceUID = "com.federicomarra.imacdisplay.audio.device"
    private static let driverBundleID = "com.federicomarra.imacdisplay.audiodriver"
    private static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/iMacDisplay Audio.driver")
    /// Custom property of the driver: the output's name, empty = no output.
    private static let nameSelector: AudioObjectPropertySelector = 0x696D_644E // 'imdN'

    // MARK: - Driver

    static var bundledDriverURL: URL? {
        Bundle.main.url(forResource: "iMacDisplay Audio", withExtension: "driver")
    }

    /// The bundled driver isn't in /Library yet, or a different version is.
    static var needsInstall: Bool {
        guard let bundled = bundledDriverURL else { return false }
        return version(of: bundled) != version(of: installedURL)
    }

    private static func version(of driver: URL) -> String? {
        let plist = NSDictionary(contentsOf: driver.appendingPathComponent("Contents/Info.plist"))
        return plist?["CFBundleVersion"] as? String
    }

    /// Copies the bundled driver into /Library/Audio/Plug-Ins/HAL and restarts Core Audio,
    /// after macOS asks for an administrator password. Returns an error message on failure.
    /// Call on the main thread.
    static func install() -> String? {
        guard let source = bundledDriverURL else {
            return NSLocalizedString("This build of iMacDisplay doesn't include the audio driver. Build it with scripts/make-dmg.sh.", comment: "Audio driver install error")
        }
        func shell(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "mkdir -p /Library/Audio/Plug-Ins/HAL && rm -rf \(shell(installedURL.path))"
            + " && cp -R \(shell(source.path)) /Library/Audio/Plug-Ins/HAL/ && killall coreaudiod"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        guard let error else { return nil }
        if error[NSAppleScript.errorNumber] as? Int == -128 { return "" } // the user cancelled
        return error[NSAppleScript.errorMessage] as? String ?? NSLocalizedString("The audio driver could not be installed.", comment: "Audio driver install error")
    }

    // MARK: - Publishing

    /// Shows the output under `name` (nil hides it). Returns the output once Core Audio
    /// lists it, or nil when the driver isn't installed. Blocks up to 2 seconds.
    @discardableResult
    static func publish(_ name: String?) -> AudioObjectID? {
        guard let plugin = pluginID else { return nil }
        var value = (name ?? "") as CFString
        var address = Self.address(nameSelector)
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(plugin, &address, 0, nil, UInt32(MemoryLayout<CFString>.size), $0)
        }
        guard status == noErr, name != nil else { return nil }
        for _ in 0..<20 {
            if let device = deviceID { return device }
            usleep(100_000)
        }
        return nil
    }

    private static var pluginID: AudioObjectID? {
        translate(driverBundleID, with: kAudioHardwarePropertyTranslateBundleIDToPlugIn)
    }

    private static var deviceID: AudioObjectID? {
        translate(deviceUID, with: kAudioHardwarePropertyTranslateUIDToDevice)
    }

    private static func translate(_ string: String, with selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var qualifier = string as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(selector)
        let status = withUnsafePointer(to: &qualifier) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    // MARK: - Volume and mute

    static func level(of device: AudioObjectID) -> AudioVolumeMessage {
        var volume: Float32 = 1
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyMute
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return AudioVolumeMessage(volume: volume, muted: muted != 0)
    }

    static func setLevel(_ level: AudioVolumeMessage, on device: AudioObjectID) {
        var volume = Float32(min(max(level.volume, 0), 1))
        var muted: UInt32 = level.muted ? 1 : 0
        var address = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        address.mSelector = kAudioDevicePropertyMute
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muted)
    }

    /// Calls `onChange` on `queue` whenever volume or mute change. Call the returned
    /// closure to stop observing.
    static func observe(_ device: AudioObjectID, queue: DispatchQueue, onChange: @escaping () -> Void) -> () -> Void {
        let listener: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        let addresses = [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].map {
            Self.address($0, scope: kAudioObjectPropertyScopeOutput)
        }
        for var address in addresses {
            AudioObjectAddPropertyListenerBlock(device, &address, queue, listener)
        }
        return {
            for var address in addresses {
                AudioObjectRemovePropertyListenerBlock(device, &address, queue, listener)
            }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
