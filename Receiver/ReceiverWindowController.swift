import AppKit

/// Borderless windows can't become key by default; the receiver needs key status
/// to get keyboard and mouse events.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Full-screen window with the video and a status panel on top.
final class ReceiverWindowController: NSObject {
    let window: KeyableWindow
    let videoView: VideoView

    private let panel = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    override init() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        window = KeyableWindow(contentRect: screen.frame,
                               styleMask: [.borderless],
                               backing: .buffered,
                               defer: false,
                               screen: screen)
        videoView = VideoView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init()

        window.backgroundColor = .black
        window.isOpaque = true
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenNone]

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        videoView.autoresizingMask = [.width, .height]
        content.addSubview(videoView)

        titleLabel.font = .systemFont(ofSize: 34, weight: .semibold)
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 96, weight: .bold)
        detailLabel.font = .systemFont(ofSize: 20)
        hintLabel.font = .systemFont(ofSize: 15)
        for label in [titleLabel, codeLabel, detailLabel, hintLabel] {
            label.textColor = .white
            label.alignment = .center
            label.maximumNumberOfLines = 3
        }
        detailLabel.textColor = NSColor(white: 0.8, alpha: 1)
        hintLabel.textColor = NSColor(white: 0.6, alpha: 1)

        panel.orientation = .vertical
        panel.alignment = .centerX
        panel.spacing = 18
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addArrangedSubview(titleLabel)
        panel.addArrangedSubview(codeLabel)
        panel.addArrangedSubview(detailLabel)
        panel.addArrangedSubview(hintLabel)
        content.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.8),
        ])

        window.contentView = content
    }

    func show() {
        window.setFrame(window.screen?.frame ?? window.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func show(_ status: ReceiverServer.Status, receiverName: String) {
        codeLabel.isHidden = true
        panel.isHidden = false
        hintLabel.stringValue = ""
        switch status {
        case .starting:
            titleLabel.stringValue = NSLocalizedString("Starting…", comment: "Receiver status")
            detailLabel.stringValue = ""
        case .waiting:
            titleLabel.stringValue = NSLocalizedString("Waiting for your Mac", comment: "Receiver status")
            detailLabel.stringValue = String(format: NSLocalizedString("Open iMacDisplay on your Mac and choose “%@”.", comment: "Receiver status detail"), receiverName)
        case let .pairing(pin, senderName):
            titleLabel.stringValue = NSLocalizedString("Pairing code", comment: "Receiver status")
            codeLabel.stringValue = pin
            codeLabel.isHidden = false
            detailLabel.stringValue = String(format: NSLocalizedString("Enter this code on “%@”.", comment: "Receiver pairing detail"), senderName)
        case .connected:
            // The video covers the screen; the panel stays hidden.
            panel.isHidden = true
        case let .failed(message):
            titleLabel.stringValue = NSLocalizedString("Something went wrong", comment: "Receiver status")
            detailLabel.stringValue = message
        }
        if case .connected = status {} else {
            hintLabel.stringValue = NSLocalizedString("While connected, ⌃⌥⌘⌫ gives keyboard and mouse back to the iMac.", comment: "Receiver hint")
        }
    }
}
