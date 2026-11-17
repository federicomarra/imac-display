import AppKit

/// Captures the iMac's keyboard and mouse and forwards them to the Mac.
/// The mouse is decoupled from the iMac cursor so relative motion can move the
/// Mac's cursor across all of its screens.
///
/// ⌃⌥⌘⌫ (Control-Option-Command-Delete) toggles forwarding, so the iMac can
/// always be used locally again.
final class InputCapture {
    var onEvent: ((InputEvent) -> Void)?
    /// Called on the main thread when forwarding is switched on or off.
    var onForwardingChanged: ((Bool) -> Void)?

    private var monitor: Any?
    private(set) var isForwarding = false

    private let mask: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .scrollWheel, .keyDown, .keyUp, .flagsChanged,
    ]

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
        setForwarding(true)
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        setForwarding(false)
    }

    private func setForwarding(_ on: Bool) {
        guard on != isForwarding else { return }
        isForwarding = on
        if on {
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
        onForwardingChanged?(on)
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, event.keyCode == 51, modifiers.contains([.control, .option, .command]) {
            setForwarding(!isForwarding)
            return true
        }
        guard isForwarding else { return false }

        let flags = UInt64(event.modifierFlags.rawValue)
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if event.deltaX != 0 || event.deltaY != 0 {
                onEvent?(.mouseMove(dx: Float(event.deltaX), dy: Float(event.deltaY)))
            }
        case .leftMouseDown, .leftMouseUp:
            onEvent?(.mouseButton(button: 0, down: event.type == .leftMouseDown,
                                  clickCount: UInt8(clamping: event.clickCount)))
        case .rightMouseDown, .rightMouseUp:
            onEvent?(.mouseButton(button: 1, down: event.type == .rightMouseDown,
                                  clickCount: UInt8(clamping: event.clickCount)))
        case .otherMouseDown, .otherMouseUp:
            onEvent?(.mouseButton(button: UInt8(clamping: max(2, event.buttonNumber)),
                                  down: event.type == .otherMouseDown,
                                  clickCount: UInt8(clamping: event.clickCount)))
        case .scrollWheel:
            onEvent?(.scroll(dx: Float(event.scrollingDeltaX), dy: Float(event.scrollingDeltaY),
                             continuous: event.hasPreciseScrollingDeltas))
        case .keyDown, .keyUp:
            onEvent?(.key(keyCode: event.keyCode, down: event.type == .keyDown, flags: flags))
        case .flagsChanged:
            onEvent?(.flagsChanged(keyCode: event.keyCode, flags: flags))
        default:
            return false
        }
        return true
    }
}
