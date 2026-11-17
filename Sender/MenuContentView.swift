import SwiftUI

/// Content of the menu bar window.
struct MenuContentView: View {
    @EnvironmentObject private var controller: SenderController
    @Environment(\.openSettings) private var openSettings
    @State private var pin = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "display")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iMacDisplay")
                        .font(.headline)
                    statusText
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            switch controller.state {
            case .pairing(let name):
                pairingSection(name: name)
            case .streaming:
                streamingSection
            case .connecting:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            case .idle, .failed:
                receiverList
            }

            if !controller.accessibilityGranted && controller.settings.inputEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("To use the iMac's keyboard and mouse, allow iMacDisplay in Accessibility.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Open Accessibility Settings") {
                        controller.openAccessibilitySettings()
                    }
                    .controlSize(.small)
                }
            }

            Divider()

            HStack {
                if controller.isActive {
                    Button("Disconnect") { controller.disconnect() }
                }
                Spacer()
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Button("Quit") {
                    controller.disconnect()
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder
    private var statusText: some View {
        switch controller.state {
        case .idle:
            Text("Not connected")
        case .connecting(let name):
            Text("Connecting to \(name)…")
        case .pairing(let name):
            Text("Pairing with \(name)")
        case .streaming(let name):
            Text("Connected to \(name)")
        case .failed(let message):
            Text(message)
        }
    }

    // MARK: - Receivers

    private var receiverList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iMacs on the network")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if controller.receivers.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching… Open iMacDisplay Receiver on the iMac.")
                        .font(.callout)
                }
            } else {
                ForEach(controller.receivers) { receiver in
                    Button {
                        controller.connect(to: receiver)
                    } label: {
                        Label(receiver.name, systemImage: "desktopcomputer")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Pairing

    private func pairingSection(name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter the code shown on \(name).")
            HStack {
                TextField("Code", text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title3, design: .monospaced))
                    .onSubmit(submit)
                Button("Pair", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pin.trimmingCharacters(in: .whitespaces).count != 6)
            }
            if let error = controller.pairingError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func submit() {
        controller.submitPIN(pin)
        pin = ""
    }

    // MARK: - Streaming

    private var streamingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let stats = controller.stats
            Text(verbatim: "\(stats.width)×\(stats.height) · \(stats.fps)/\(stats.targetFPS) fps · \(String(format: "%.1f", stats.megabitsPerSecond)) Mbit/s · \(stats.roundTripMilliseconds) ms")
                .font(.caption.monospacedDigit())
            HStack(spacing: 6) {
                Text(linkName(stats.link))
                Text(verbatim: "·")
                Text(verbatim: stats.codec)
                if controller.settings.audioEnabled {
                    Text(verbatim: "·")
                    Text(stats.audioActive ? LocalizedStringKey("Audio on the iMac") : LocalizedStringKey("No audio"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let warning = stats.warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let display = controller.displayState {
                VStack(alignment: .leading, spacing: 6) {
                    Text("iMac screen")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    sliderRow(title: "Brightness", systemImage: "sun.max",
                              value: display.brightness, range: 0...1,
                              enabled: display.brightnessSupported) { controller.setBrightness($0) }
                    sliderRow(title: "Gamma", systemImage: "circle.lefthalf.filled",
                              value: display.gamma, range: 0.5...2,
                              enabled: true) { controller.setGamma($0) }
                    sliderRow(title: "Warmth", systemImage: "thermometer.medium",
                              value: display.warmth, range: -1...1,
                              enabled: true) { controller.setWarmth($0) }
                    Button("Reset Colors") { controller.resetColor() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func sliderRow(title: LocalizedStringKey, systemImage: String, value: Float,
                           range: ClosedRange<Double>, enabled: Bool,
                           onChange: @escaping (Float) -> Void) -> some View {
        HStack {
            Image(systemName: systemImage)
                .frame(width: 18)
                .help(Text(title))
            Slider(value: Binding(get: { Double(value) }, set: { onChange(Float($0)) }), in: range)
                .disabled(!enabled)
        }
    }

    private func linkName(_ link: LinkKind) -> LocalizedStringKey {
        switch link {
        case .thunderbolt: return "Thunderbolt cable"
        case .ethernet: return "Ethernet"
        case .wifi: return "Wi-Fi"
        case .other: return "Other network"
        case .unknown: return "Network"
        }
    }
}
