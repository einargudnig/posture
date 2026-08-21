import AppKit

/// Keeps the main window alive across closes.
///
/// SwiftUI destroys a `Window` scene when you close it and adds no menu item to
/// bring it back, so with the status item gone there was no route to the window
/// at all — reopening depends on an Apple event that isn't delivered when the
/// app opens its own bundle. Hiding instead of closing sidesteps all of that:
/// the window is always there to order front.
@MainActor
final class WindowKeeper: NSObject {
    static let shared = WindowKeeper()

    private static let title = "Posture"

    /// Idempotent — the close button is retargeted every time the window
    /// appears, so this survives the window being rebuilt.
    func install() {
        guard let window = Self.mainWindow else { return }
        window.isReleasedWhenClosed = false
        guard let close = window.standardWindowButton(.closeButton) else { return }
        close.target = self
        close.action = #selector(hideWindow)
    }

    @objc private func hideWindow() {
        Self.mainWindow?.orderOut(nil)
    }

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.canBecomeMain && $0.title == title }
    }
}
