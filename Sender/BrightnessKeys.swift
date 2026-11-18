import AppKit

/// The Mac's brightness keys adjust the iMac when the pointer is on its screen, and
/// whenever its screen mirrors the Mac's, like MonitorControl does for external
/// monitors: macOS has no brightness control for a virtual screen, so Control Center's
/// slider can't work. Everywhere else the keys reach the Mac untouched.
/// Needs the Accessibility permission, which the app already uses for the iMac's input.
final class BrightnessKeys {
    /// The iMac's screen while its brightness can be set, nil otherwise. Main thread.
    var iMacDisplay: (() -> CGDirectDisplayID?)?
    /// A key press meant for the iMac. Main thread.
    var onKey: ((_ up: Bool, _ fine: Bool) -> Void)?

    private var tap: CFMachPort?

    // From IOKit/hidsystem/ev_keymap.h (NX_SYSDEFINED aux control buttons).
    private static let auxControlButtons: Int16 = 8
    private static let brightnessUp = 2
    private static let brightnessDown = 3

    /// Call on the main thread; does nothing until Accessibility is granted.
    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: Self.callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
    }

    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        return Unmanaged<BrightnessKeys>.fromOpaque(info).takeUnretainedValue().handle(type, event)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let key = NSEvent(cgEvent: event), key.type == .systemDefined, key.subtype.rawValue == Self.auxControlButtons else {
            return Unmanaged.passUnretained(event)
        }
        let code = (key.data1 & 0xFFFF_0000) >> 16
        guard code == Self.brightnessUp || code == Self.brightnessDown,
              let display = iMacDisplay?(),
              CGDisplayIsInMirrorSet(display) != 0 || CGDisplayBounds(display).contains(event.location) else {
            return Unmanaged.passUnretained(event)
        }
        let down = (key.data1 & 0xFF00) >> 8 == 0x0A
        if down {
            onKey?(code == Self.brightnessUp, key.modifierFlags.contains([.option, .shift]))
        }
        return nil // the Mac's own screen must not change too
    }
}

/// The system's brightness indicator, shown on a given screen (private OSD.framework,
/// the same one MonitorControl uses). Does nothing if macOS doesn't provide it.
enum BrightnessIndicator {
    private typealias ShowImage = @convention(c) (AnyObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, Bool) -> Void

    private static let osd: (manager: AnyObject, selector: Selector, show: ShowImage)? = {
        guard Bundle(path: "/System/Library/PrivateFrameworks/OSD.framework")?.load() == true,
              let managerClass = NSClassFromString("OSDManager") as AnyObject?,
              let manager = managerClass.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() else { return nil }
        let selector = NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")
        guard let method = class_getInstanceMethod(type(of: manager), selector) else { return nil }
        return (manager, selector, unsafeBitCast(method_getImplementation(method), to: ShowImage.self))
    }()

    /// `brightness` 0...1. Call on the main thread.
    static func show(_ brightness: Float, on display: CGDirectDisplayID) {
        guard let osd else { return }
        // Image 1 is the brightness sun; 64 chiclets draw macOS's 16 blocks in quarter steps.
        let filled = UInt32((min(max(brightness, 0), 1) * 64).rounded())
        osd.show(osd.manager, osd.selector, 1, display, 0x1F4, 1000, filled, 64, false)
    }
}
