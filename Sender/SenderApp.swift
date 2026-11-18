import SwiftUI

@main
struct IMacDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SenderController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(controller)
        } label: {
            Image(systemName: controller.isStreaming ? "display.2" : "display")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(controller)
        }
    }
}

/// Opening the app again while it runs (double-click in Finder) shows the menu bar
/// panel in a window, so the app stays reachable when a full menu bar hides its icon
/// behind the notch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI keeps applicationShouldHandleReopen for itself, so take the
        // reopen Apple event directly, after SwiftUI has installed its handlers.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(showWindow),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEReopenApplication))
    }

    @objc private func showWindow() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: MenuContentView().environmentObject(SenderController.shared)))
            window.title = "iMacDisplay"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
