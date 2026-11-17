import SwiftUI

@main
struct IMacDisplayApp: App {
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
