import CoreGraphics
import Foundation

/// Creates the extra screen that the Mac sees in extend mode.
/// Uses the private CGVirtualDisplay API (declared in Config/Sender-Bridging-Header.h),
/// the same one used by BetterDisplay and DeskPad.
final class VirtualDisplayManager {
    private var display: CGVirtualDisplay?

    var displayID: CGDirectDisplayID? {
        display?.displayID
    }

    /// Returns the display ID of the new screen, or nil if macOS refused to create it.
    func create(name: String, serial: UInt32, preset: ResolutionPreset) -> CGDirectDisplayID? {
        destroy()

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = 4608
        descriptor.maxPixelsHigh = 2592
        // Physical size of the iMac 21.5" panel, so macOS picks sensible defaults.
        descriptor.sizeInMillimeters = CGSize(width: 476, height: 268)
        descriptor.vendorID = 0x494D
        descriptor.productID = 0x4453
        // A stable serial lets macOS remember where the screen is arranged.
        descriptor.serialNum = serial
        descriptor.terminationHandler = { _, _ in }

        let display = CGVirtualDisplay(descriptor: descriptor)

        let settings = CGVirtualDisplaySettings()
        // With hiDPI on, macOS also offers each mode at half size in Retina ("looks like").
        settings.hiDPI = 1
        let pixelModes: [(UInt32, UInt32)] = [(4608, 2592), (4096, 2304), (3200, 1800), (2560, 1440), (1920, 1080)]
        settings.modes = pixelModes.map { CGVirtualDisplayMode(width: $0.0, height: $0.1, refreshRate: 60) }
        guard display.apply(settings) else { return nil }

        self.display = display
        let id = display.displayID
        Self.select(preset, on: id)
        // The mode list is sometimes published a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.select(preset, on: id) }
        return id
    }

    func destroy() {
        // Releasing the object removes the screen.
        display = nil
    }

    static func select(_ preset: ResolutionPreset, on displayID: CGDirectDisplayID) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return }
        let points = preset.pointSize
        let pixels = preset.pixelSize
        let exact = modes.first {
            $0.width == points.width && $0.height == points.height
                && $0.pixelWidth == pixels.width && $0.pixelHeight == pixels.height
        }
        let fallback = modes.first { $0.width == points.width && $0.height == points.height }
        guard let mode = exact ?? fallback else { return }
        if let current = CGDisplayCopyDisplayMode(displayID),
           current.width == mode.width, current.height == mode.height, current.pixelWidth == mode.pixelWidth {
            return
        }
        CGDisplaySetDisplayMode(displayID, mode, nil)
    }

    /// Pixel size of the display's current mode.
    static func pixelSize(of displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return (mode.pixelWidth, mode.pixelHeight)
    }
}
