import SwiftUI

/// SwiftUI terminates a Window-scene app once the last window closes, and the
/// notch panel doesn't count as a window. Posture keeps monitoring with no
/// window open, so that has to be turned off.
final class PostureAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Writes the minute in progress so quitting doesn't discard it.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { PostureModel.shared.flushBucket() }
    }

    /// Lets the reopen event rebuild the Window scene, which is how the notch
    /// panel gets the window back after you've closed it.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        true
    }
}

@main
struct PostureApp: App {
    @NSApplicationDelegateAdaptor(PostureAppDelegate.self) private var appDelegate

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

        Window("History", id: "history") {
            HistoryView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .keyboardShortcut("y", modifiers: .command)

        Settings {
            SettingsView()
                .environmentObject(model)
        }

    }
}
