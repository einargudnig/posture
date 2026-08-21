import SwiftUI

@main
struct PostureApp: App {
    // Deliberately not `@StateObject`: observing the model here would make
    // every posture reading re-evaluate this Scene body, and SwiftUI rebuilds
    // the main menu and Dock menu when it does. Views that need to react
    // observe it themselves, so only those subtrees invalidate.
    //
    // Computed rather than stored, because a stored property initialiser runs
    // before `init()` — i.e. before NSApplication exists — and the model
    // touches NSApp while starting up.
    private var model: PostureModel { .shared }

    init() {
        if CommandLine.arguments.contains("--probe") { Probe.run() }
    }

    var body: some Scene {
        Window("Posture", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Posture") { NSApp.orderFrontStandardAboutPanel(nil) }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

/// The icon has to track state, so the observation lives here — in a leaf view
/// — instead of on the App, where it would invalidate every Scene.
struct MenuBarLabel: View {
    @ObservedObject var model: PostureModel

    var body: some View {
        Image(systemName: model.symbolName)
    }
}

/// Deliberately thin — the window is the real UI, and this exists so you can
/// glance at your posture without one in the way.
struct MenuBarContent: View {
    @EnvironmentObject private var model: PostureModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.statusText)
        if model.isCalibrated, let drop = model.dropDegrees {
            Text(String(format: "%.0f° of %.0f°", drop, model.thresholdDegrees))
        }
        Divider()
        Button("Open Posture") { show { openWindow(id: "main") } }
        Button(model.isCalibrated ? "Recalibrate" : "Calibrate") {
            show {
                openWindow(id: "main")
                model.startCalibration()
            }
        }
        .disabled(!model.isStreaming)
        Button(model.enabled ? "Pause Monitoring" : "Resume Monitoring") {
            model.enabled.toggle()
        }
        Divider()
        Button("Settings…") { show { openSettings() } }
            .keyboardShortcut(",", modifiers: .command)
        Button("Quit Posture") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    /// Menu bar apps start out inactive, so a window opened from here lands
    /// behind whatever you were using unless the app is activated first.
    private func show(_ action: () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        action()
    }
}
