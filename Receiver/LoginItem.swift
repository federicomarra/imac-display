import Foundation

/// Opens the receiver at login through a LaunchAgent (SMAppService needs macOS 13,
/// the iMac runs macOS 12).
enum LoginItem {
    static let label = "com.federicomarra.imacdisplay.receiver"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            let agent: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
            ]
            do {
                try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
                try data.write(to: plistURL, options: .atomic)
            } catch {
                NSLog("iMacDisplay: could not write the login item: \(error)")
            }
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }

    /// Keeps the path in the LaunchAgent correct if the app was moved.
    static func refreshIfEnabled() {
        if isEnabled {
            setEnabled(true)
        }
    }
}
