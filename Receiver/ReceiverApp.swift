import AppKit
import IOKit.pwr_mgt

@main
enum ReceiverMain {
    // NSApplication keeps only a weak reference to its delegate.
    static let delegate = ReceiverAppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}

final class ReceiverAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: ReceiverWindowController!
    private var server: ReceiverServer!
    private let input = InputCapture()
    private let display = DisplayAdjuster()
    private let audio = AudioPlayer()

    private var systemSleepAssertion: IOPMAssertionID = 0
    private var displaySleepAssertion: IOPMAssertionID = 0
    private var loginMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpLoginItem()
        buildMenu()

        windowController = ReceiverWindowController()
        windowController.show()

        server = ReceiverServer(videoView: windowController.videoView, audio: audio, display: display)
        server.onStatus = { [weak self] status in self?.handle(status) }
        input.onEvent = { [weak self] event in self?.server.sendInput(event) }
        server.start()

        // Stay awake and discoverable while the app is open; the screen may still sleep.
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "iMacDisplay Receiver is waiting for a Mac" as CFString,
                                    &systemSleepAssertion)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.display.reapplyColor()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.display.reapplyColor()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        input.stop()
        if systemSleepAssertion != 0 { IOPMAssertionRelease(systemSleepAssertion) }
        if displaySleepAssertion != 0 { IOPMAssertionRelease(displaySleepAssertion) }
    }

    // MARK: - Status

    private func handle(_ status: ReceiverServer.Status) {
        windowController.show(status, receiverName: server.receiverName)
        switch status {
        case .connected:
            wakeDisplay()
            windowController.show()
            NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication]
            input.start()
            if displaySleepAssertion == 0 {
                IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "iMacDisplay is showing a Mac" as CFString,
                                            &displaySleepAssertion)
            }
        case .pairing:
            wakeDisplay()
            windowController.show()
            stopStreamingState()
        default:
            stopStreamingState()
        }
    }

    private func stopStreamingState() {
        input.stop()
        NSApp.presentationOptions = []
        if displaySleepAssertion != 0 {
            IOPMAssertionRelease(displaySleepAssertion)
            displaySleepAssertion = 0
        }
    }

    private func wakeDisplay() {
        var assertion: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("iMacDisplay" as CFString, kIOPMUserActiveLocal, &assertion)
    }

    // MARK: - Login item

    private func setUpLoginItem() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didSetUpLoginItem") {
            LoginItem.setEnabled(true)
            defaults.set(true, forKey: "didSetUpLoginItem")
        } else {
            LoginItem.refreshIfEnabled()
        }
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        sender.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func forgetPairedMacs(_ sender: NSMenuItem) {
        server.forgetPairedMacs()
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu

        appMenu.addItem(withTitle: NSLocalizedString("About iMacDisplay Receiver", comment: "Menu"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())

        let login = NSMenuItem(title: NSLocalizedString("Open at Login", comment: "Menu"),
                               action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        appMenu.addItem(login)
        loginMenuItem = login

        let forget = NSMenuItem(title: NSLocalizedString("Forget Paired Macs", comment: "Menu"),
                                action: #selector(forgetPairedMacs(_:)), keyEquivalent: "")
        forget.target = self
        appMenu.addItem(forget)

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Quit iMacDisplay Receiver", comment: "Menu"),
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        NSApp.mainMenu = mainMenu
    }
}
