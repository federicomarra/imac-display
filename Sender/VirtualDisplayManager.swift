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
    /// Like any monitor, its resolution is chosen in System Settings → Displays and macOS
    /// remembers it per iMac (by serial). Only the first time an iMac connects does the
    /// app pick one: Retina "looks like 2048 × 1152", the iMac's own resolution.
    func create(name: String, serial: UInt32) -> CGDirectDisplayID? {
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
        // The iMac's native size first, in case macOS falls back to the first mode.
        let pixelModes: [(UInt32, UInt32)] = [(4096, 2304), (4608, 2592), (3200, 1800), (2560, 1440), (1920, 1080)]
        settings.modes = pixelModes.map { CGVirtualDisplayMode(width: $0.0, height: $0.1, refreshRate: 60) }
        guard display.apply(settings) else { return nil }

        self.display = display
        let id = display.displayID
        let seen = UserDefaults.standard.array(forKey: Self.configuredSerialsKey) as? [Int] ?? []
        if !seen.contains(Int(serial)) {
            UserDefaults.standard.set(seen + [Int(serial)], forKey: Self.configuredSerialsKey)
            Self.selectRetina(on: id)
            // The mode list is sometimes published a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.selectRetina(on: id) }
        }
        return id
    }

    /// Serials of the iMacs whose screen already got its first resolution.
    private static let configuredSerialsKey = "configuredDisplaySerials"

    func destroy() {
        // Releasing the object removes the screen.
        display = nil
    }

    /// Selects "looks like 2048 × 1152", rendered at 4096 × 2304.
    private static func selectRetina(on displayID: CGDirectDisplayID) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return }
        let exact = modes.first { $0.width == 2048 && $0.height == 1152 && $0.pixelWidth == 4096 && $0.pixelHeight == 2304 }
        guard let mode = exact ?? modes.first(where: { $0.width == 2048 && $0.height == 1152 }) else { return }
        if let current = CGDisplayCopyDisplayMode(displayID),
           current.width == mode.width, current.height == mode.height, current.pixelWidth == mode.pixelWidth {
            return
        }
        CGDisplaySetDisplayMode(displayID, mode, nil)
    }
}
