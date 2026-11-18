import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: SenderController
    @ObservedObject private var settings = SenderSettings.shared

    var body: some View {
        Form {
            Section("Display") {
                Text("The iMac is a separate screen, like a monitor on HDMI: change its resolution and arrangement in System Settings → Displays.")
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
                Toggle("Play the Mac's sound on the iMac", isOn: $settings.audioEnabled)
                if settings.audioEnabled && AudioOutputDevice.bundledDriverURL != nil {
                    if controller.audioOutputNeedsInstall {
                        HStack {
                            Text("Install the audio output to pick the iMac in Sound settings, with volume and mute, while connected.")
                            Spacer()
                            Button("Install Audio Output…") { controller.installAudioOutput() }
                        }
                    } else {
                        Text("While connected, pick the iMac as the output in Sound settings or in the menu bar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = controller.audioOutputError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
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
                    Text("Changes to quality, audio and input apply to the next connection, or now with this button.")
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
