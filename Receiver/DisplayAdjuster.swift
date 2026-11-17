import AppKit
import CoreGraphics
import IOKit
import IOKit.graphics

/// Brightness, gamma and white point of the iMac's built-in screen.
final class DisplayAdjuster {
    private typealias GetBrightnessFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let displayID = CGMainDisplayID()
    private var getBrightness: GetBrightnessFunction?
    private var setBrightness: SetBrightnessFunction?
    private let defaults = UserDefaults.standard

    private(set) var gamma: Float
    private(set) var warmth: Float

    init() {
        // DisplayServices is a private framework that controls the built-in backlight.
        if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) {
            if let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
                getBrightness = unsafeBitCast(symbol, to: GetBrightnessFunction.self)
            }
            if let symbol = dlsym(handle, "DisplayServicesSetBrightness") {
                setBrightness = unsafeBitCast(symbol, to: SetBrightnessFunction.self)
            }
        }
        let standard = UserDefaults.standard
        let storedGamma = standard.object(forKey: "gamma") as? Float
        let storedWarmth = standard.object(forKey: "warmth") as? Float
        gamma = storedGamma ?? 1
        warmth = storedWarmth ?? 0
        applyColor()
    }

    var state: DisplayState {
        let current = brightness
        return DisplayState(brightnessSupported: current != nil,
                            brightness: current ?? 1,
                            gamma: gamma,
                            warmth: warmth)
    }

    func apply(_ message: DisplayControlMessage) {
        if let value = message.brightness {
            set(brightness: value)
        }
        if message.resetColor == true {
            gamma = 1
            warmth = 0
        }
        if let value = message.gamma {
            gamma = min(max(value, 0.5), 2)
        }
        if let value = message.warmth {
            warmth = min(max(value, -1), 1)
        }
        if message.gamma != nil || message.warmth != nil || message.resetColor == true {
            defaults.set(gamma, forKey: "gamma")
            defaults.set(warmth, forKey: "warmth")
            applyColor()
        }
    }

    /// macOS resets custom gamma tables in some situations (sleep, display changes).
    func reapplyColor() {
        applyColor()
    }

    // MARK: - Brightness

    private var brightness: Float? {
        if let getBrightness {
            var value: Float = 0
            if getBrightness(displayID, &value) == 0 {
                return value
            }
        }
        return ioKitBrightness()
    }

    private func set(brightness value: Float) {
        let clamped = min(max(value, 0), 1)
        if let setBrightness, setBrightness(displayID, clamped) == 0 {
            return
        }
        setIOKitBrightness(clamped)
    }

    private func forEachDisplayService(_ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            body(service)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private func ioKitBrightness() -> Float? {
        var result: Float?
        forEachDisplayService { service in
            guard result == nil else { return }
            var value: Float = 0
            if IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &value) == kIOReturnSuccess {
                result = value
            }
        }
        return result
    }

    private func setIOKitBrightness(_ value: Float) {
        forEachDisplayService { service in
            IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, value)
        }
    }

    // MARK: - Gamma and white point

    private func applyColor() {
        if gamma == 1 && warmth == 0 {
            CGDisplayRestoreColorSyncSettings()
            return
        }
        let exponent = 1 / gamma
        let (red, green, blue) = channelMaximums(for: warmth)
        CGSetDisplayTransferByFormula(displayID,
                                      0, red, exponent,
                                      0, green, exponent,
                                      0, blue, exponent)
    }

    private func channelMaximums(for warmth: Float) -> (Float, Float, Float) {
        if warmth >= 0 {
            return (1, 1 - 0.15 * warmth, 1 - 0.45 * warmth)
        }
        let cool = -warmth
        return (1 - 0.35 * cool, 1 - 0.1 * cool, 1)
    }
}
