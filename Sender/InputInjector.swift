import ApplicationServices
import CoreGraphics
import Foundation

/// Replays the iMac's keyboard and mouse on the Mac. Needs the Accessibility permission.
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown = Set<UInt8>()
    private let lock = NSLock()

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    func handle(_ event: InputEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case let .mouseMove(dx, dy):
            moveMouse(dx: CGFloat(dx), dy: CGFloat(dy))
        case let .mouseButton(button, down, clickCount):
            press(button: button, down: down, clickCount: clickCount)
        case let .scroll(dx, dy, continuous):
            scroll(dx: dx, dy: dy, continuous: continuous)
        case let .key(keyCode, down, flags):
            guard let keyEvent = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return }
            keyEvent.flags = CGEventFlags(rawValue: flags)
            keyEvent.post(tap: .cghidEventTap)
        case let .flagsChanged(keyCode, flags):
            guard let flagsEvent = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true) else { return }
            flagsEvent.type = .flagsChanged
            flagsEvent.flags = CGEventFlags(rawValue: flags)
            flagsEvent.post(tap: .cghidEventTap)
        }
    }

    /// Releases any button still held, e.g. when the connection drops mid-drag.
    func releaseAll() {
        lock.lock()
        let held = buttonsDown
        lock.unlock()
        for button in held {
            handle(.mouseButton(button: button, down: false, clickCount: 1))
        }
    }

    // MARK: - Mouse

    private var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func moveMouse(dx: CGFloat, dy: CGFloat) {
        let current = cursorLocation
        let target = Self.clampToDisplays(CGPoint(x: current.x + dx, y: current.y + dy))
        let type: CGEventType
        let button: CGMouseButton
        if buttonsDown.contains(0) {
            type = .leftMouseDragged
            button = .left
        } else if buttonsDown.contains(1) {
            type = .rightMouseDragged
            button = .right
        } else if !buttonsDown.isEmpty {
            type = .otherMouseDragged
            button = .center
        } else {
            type = .mouseMoved
            button = .left
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        event.post(tap: .cghidEventTap)
    }

    private func press(button: UInt8, down: Bool, clickCount: UInt8) {
        let type: CGEventType
        let mouseButton: CGMouseButton
        switch button {
        case 0:
            type = down ? .leftMouseDown : .leftMouseUp
            mouseButton = .left
        case 1:
            type = down ? .rightMouseDown : .rightMouseUp
            mouseButton = .right
        default:
            type = down ? .otherMouseDown : .otherMouseUp
            mouseButton = CGMouseButton(rawValue: UInt32(button)) ?? .center
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: cursorLocation, mouseButton: mouseButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        if button >= 2 {
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        }
        event.post(tap: .cghidEventTap)
        if down {
            buttonsDown.insert(button)
        } else {
            buttonsDown.remove(button)
        }
    }

    private func scroll(dx: Float, dy: Float, continuous: Bool) {
        let vertical: Int32
        let horizontal: Int32
        if continuous {
            vertical = Int32(dy.rounded())
            horizontal = Int32(dx.rounded())
        } else {
            // Line-based wheels can report fractions; never round a real tick to zero.
            vertical = dy == 0 ? 0 : Int32(dy.rounded(.awayFromZero))
            horizontal = dx == 0 ? 0 : Int32(dx.rounded(.awayFromZero))
        }
        guard vertical != 0 || horizontal != 0,
              let event = CGEvent(scrollWheelEvent2Source: source,
                                  units: continuous ? .pixel : .line,
                                  wheelCount: 2,
                                  wheel1: vertical,
                                  wheel2: horizontal,
                                  wheel3: 0) else { return }
        if continuous {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        }
        event.post(tap: .cghidEventTap)
    }

    /// Keeps the cursor on one of the Mac's screens.
    private static func clampToDisplays(_ point: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return point }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return point }
        let frames = displays.prefix(Int(count)).map { CGDisplayBounds($0) }
        if frames.contains(where: { $0.contains(point) }) {
            return point
        }
        var best = point
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for frame in frames {
            let clamped = CGPoint(x: min(max(point.x, frame.minX), frame.maxX - 1),
                                  y: min(max(point.y, frame.minY), frame.maxY - 1))
            let distance = hypot(clamped.x - point.x, clamped.y - point.y)
            if distance < bestDistance {
                bestDistance = distance
                best = clamped
            }
        }
        return best
    }
}
