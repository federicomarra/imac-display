import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: SenderController
    @ObservedObject private var settings = SenderSettings.shared

    var body: some View {
        Form {
            Section("Display") {
                Picker("Mode", selection: $settings.displayMode) {
                    Text("Extend the desktop (separate screen)").tag(DisplayMode.extend)
                    Text("Mirror the main screen").tag(DisplayMode.mirror)
                }
                // Switch the running stream right away: a mode that only applied on the
                // next connection left the iMac mirroring after choosing Extend.
                .onChange(of: settings.displayMode) { controller.restartStream() }
                Picker("Resolution", selection: $settings.resolutionPreset) {
                    Text("Retina – looks like 2048 × 1152").tag(ResolutionPreset.retina2048)
                    Text("More space – looks like 2304 × 1296").tag(ResolutionPreset.retina2304)
                    Text("Native 4096 × 2304 (1:1, very small text)").tag(ResolutionPreset.native4096)
                }
                .disabled(settings.displayMode == .mirror)
                .onChange(of: settings.resolutionPreset) { controller.applyResolution() }
                Text("In extend mode you can also change the resolution and arrangement in System Settings → Displays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Quality") {
                Picker("When the connection can't keep up", selection: $settings.qualityPolicy) {
                    Text("Lower the frame rate (keeps text sharp)").tag(QualityPolicy.reduceFrameRate)
                    Text("Lower the resolution (keeps motion smooth)").tag(QualityPolicy.reduceResolution)
                    Text("Compress more (keeps both, more artifacts)").tag(QualityPolicy.reduceQuality)
                }
                Picker("Maximum frame rate", selection: $settings.maxFrameRate) {
                    Text(verbatim: "60 fps").tag(60)
                    Text(verbatim: "45 fps").tag(45)
                    Text(verbatim: "30 fps").tag(30)
                }
                VStack(alignment: .leading) {
                    Text("Maximum bitrate: \(Int(settings.maxBitrateMbps)) Mbit/s")
                    Slider(value: $settings.maxBitrateMbps, in: 10...100, step: 5)
                    Text("Wi-Fi usually manages 20–40 Mbit/s; Ethernet and Thunderbolt 60–100 Mbit/s.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Video codec", selection: $settings.codec) {
                    Text("Automatic").tag(CodecPreference.automatic)
                    Text(verbatim: "H.264").tag(CodecPreference.h264)
                    Text(verbatim: "HEVC").tag(CodecPreference.hevc)
                }
            }

            Section("Audio and input") {
                Toggle("Play the Mac's sound on the iMac only", isOn: $settings.audioEnabled)
                Toggle("Control the Mac with the iMac's keyboard and mouse", isOn: $settings.inputEnabled)
                if settings.inputEnabled && !controller.accessibilityGranted {
                    HStack {
                        Text("iMacDisplay needs the Accessibility permission for this.")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") { controller.openAccessibilitySettings() }
                    }
                }
            }

            Section("Connection") {
                Toggle("Connect automatically to the last iMac", isOn: $settings.autoConnect)
                Toggle("Open iMacDisplay at login", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.launchAtLogin = $0 }))
                Button("Forget Paired iMacs") { controller.forgetPairings() }
                Text("Connections over a Thunderbolt cable, Ethernet or Wi-Fi are chosen automatically, fastest first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if controller.isStreaming {
                Section {
                    Button("Apply Changes Now") { controller.restartStream() }
                    Text("Changes to display, quality, audio and input apply to the next connection, or now with this button.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 520)
    }
}
