import SwiftUI

/// Without a MenuBarExtra, SwiftUI terminates the app once the last window
/// closes — and the notch panel doesn't count as a window. Posture is meant to
/// keep monitoring with no window open, so that has to be turned off.
final class PostureAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        // No MenuBarExtra: the reading lives beside the notch instead. A status
        // item competes for menu bar space and loses silently when it overflows.
    }
}
