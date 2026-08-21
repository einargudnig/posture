import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: PostureModel

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AlertSettings()
                .tabItem { Label("Alerts", systemImage: "bell") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 480, height: 510)
        .onAppear(perform: model.refreshNotificationStatus)
    }
}

/// One tuning control: title on the left, slider and its plain-English
/// consequence on the right. Every adjustable value in Settings uses this, so
/// they all read the same way.
private struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let caption: String

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 3) {
                Slider(value: $value, in: range, step: step)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject private var model: PostureModel

    var body: some View {
        Form {
            Section {
                // Captions stay short and roughly equal in width on purpose:
                // LabeledContent drops its content onto a second line once the
                // content is too wide, so a long caption in one row silently
                // misaligns it against its neighbours.
                SettingSlider(
                    title: "Sensitivity", value: $model.thresholdDegrees,
                    range: 5...30, step: 1,
                    caption: "Slouching starts \(Int(model.thresholdDegrees))° below baseline."
                )
                SettingSlider(
                    title: "Grace period", value: $model.sustainSeconds,
                    range: 5...180, step: 5,
                    caption: "Ignores slouches under \(Format.duration(model.sustainSeconds))."
                )
            } header: {
                Text("Detection")
            } footer: {
                Text(
                    "The grace period is what stops a glance down at your keyboard counting as a slouch."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Toggle("Menu bar only (hide Dock icon)", isOn: $model.menuBarOnly)
            } header: {
                Text("Startup")
            } footer: {
                if let error = model.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Alerts

private struct AlertSettings: View {
    @EnvironmentObject private var model: PostureModel

    var body: some View {
        Form {
            Section {
                Toggle("Show a notification", isOn: $model.showNotifications)
                Toggle("Play a sound", isOn: $model.playSound)
                Picker("Sound", selection: $model.soundName) {
                    ForEach(PostureModel.availableSounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .disabled(!model.playSound)
            } header: {
                Text("When you slouch too long")
            } footer: {
                if model.showNotifications && model.notificationsDenied {
                    Label(
                        "Notifications are turned off for Posture in System Settings.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else if !model.showNotifications && !model.playSound {
                    Text("With both off, only the menu bar icon changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                SettingSlider(
                    title: "First nudge after", value: $model.cooldownSeconds,
                    range: 30...600, step: 30,
                    caption: Format.duration(model.cooldownSeconds))
                SettingSlider(
                    title: "Never quieter than", value: $model.maxCooldownSeconds,
                    range: 300...3600, step: 300,
                    caption: Format.duration(model.maxCooldownSeconds))
            } header: {
                Text("Pacing")
            } footer: {
                Text(
                    "Each nudge you ignore doubles the wait before the next one, up to the limit above. Sitting up resets it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @EnvironmentObject private var model: PostureModel

    var body: some View {
        Form {
            Section {
                Toggle("Invert pitch direction", isOn: $model.invertPitch)
            } header: {
                Text("Sensor")
            } footer: {
                Text("Turn this on only if the reading climbs when you look down.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Baseline") {
                    Text(model.isCalibrated ? "Calibrated" : "Not set")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Status") {
                    Text(model.statusText).foregroundStyle(.secondary)
                }
                LabeledContent("Session stats") {
                    Button("Reset", action: model.resetStats)
                }
            } header: {
                Text("State")
            }

            Section {
                Text("Posture reads head orientation from your AirPods. Nothing leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
