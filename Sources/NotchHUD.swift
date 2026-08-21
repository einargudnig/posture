import AppKit
import SwiftUI

/// A borderless panel parked in the menu bar, hard up against the left edge of
/// the notch.
///
/// This replaces the status item. A status item competes for menu bar space and
/// loses silently — on a notched Mac, overflow is hidden behind the notch with
/// no indication the item exists at all. The left "ear" beside the notch is
/// usually empty, so parking there means the reading is simply always visible.
@MainActor
final class NotchHUD {
    private var panel: NSPanel?
    private let model: PostureModel

    /// Width is enough for the sparkline plus a two-digit reading. Kept narrow
    /// so it stays clear of the frontmost app's menus.
    private let width: CGFloat = 104

    /// `auxiliaryTopLeftArea` stops a little short of the physical notch, which
    /// leaves a sliver of wallpaper between the two. The panel is extended to
    /// run underneath the notch instead — the overlap is black-on-black, so it
    /// costs nothing and closes the seam.
    private let notchOverlap: CGFloat = 14

    init(model: PostureModel) {
        self.model = model
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        if panel == nil { panel = makePanel() }
        reposition()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// AppKit clamps window frames to the screen's visible area, which pushes
    /// anything aimed at the menu bar down by exactly the bar's height. This is
    /// the whole reason for the subclass.
    private final class MenuBarPanel: NSPanel {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }
    }

    /// A non-key window swallows the click that would activate it, so without
    /// this the first click on the panel does nothing at all.
    private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private func makePanel() -> NSPanel {
        let panel = MenuBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        // Above the menu bar, on every space, and never a window the user has
        // to manage: no shadow, no cycling, no activation.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Order matters: `isFloatingPanel` assigns `.floating` (level 3), which
        // silently undoes any level set before it. Level 3 sits *below* the menu
        // bar, so the panel still drew on top but clicks fell through to the
        // menu bar behind it.
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false

        panel.contentView = FirstMouseHostingView(
            rootView: NotchHUDView(model: model, trailingInset: notchOverlap + 12)
                .environmentObject(model))
        return panel
    }

    /// Anchors to the right edge of the screen's top-left auxiliary area — the
    /// strip beside the notch — so the panel sits flush against it.
    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }

        let bar = screen.safeAreaInsets.top > 0
            ? screen.safeAreaInsets.top
            : NSStatusBar.system.thickness

        let frame: NSRect
        if let ear = screen.auxiliaryTopLeftArea {
            frame = NSRect(
                x: ear.maxX - width, y: ear.maxY - bar,
                width: width + notchOverlap, height: bar)
        } else {
            // No notch: sit at the top-right of the menu bar instead, where a
            // status item would have been.
            frame = NSRect(
                x: screen.frame.maxX - width - 12,
                y: screen.frame.maxY - bar,
                width: width, height: bar)
        }
        panel.setFrame(frame, display: true)
    }
}

/// The contents: a live sparkline and the current reading, sized to the menu
/// bar. Clicking it opens the window, which is the job the status item menu
/// used to do.
private struct NotchHUDView: View {
    @ObservedObject var model: PostureModel
    /// Keeps the reading clear of the notch that the panel now runs beneath.
    var trailingInset: CGFloat = 12

    private var tint: Color {
        guard model.enabled, model.isStreaming else { return .secondary }
        if !model.isCalibrated { return .secondary }
        return model.postureState == .slouching ? .orange : .green
    }

    var body: some View {
        HStack(spacing: 6) {
            if model.isCalibrated, model.isStreaming, !model.history.isEmpty {
                NotchSparkline(history: model.history, threshold: model.thresholdDegrees)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .frame(width: 46, height: 11)
            } else {
                Image(systemName: model.symbolName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 46)
            }

            // Gated on the sensor: the analyzer keeps its last smoothed value
            // when the AirPods come out, and showing a stale angle reads as a
            // live one.
            Text(
                model.isStreaming && model.isCalibrated
                    ? (model.dropDegrees.map { String(format: "%.0f°", $0) } ?? "—")
                    : "—"
            )
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .frame(width: 30, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, trailingInset)
        // Reads as the notch widening rather than as a panel sitting near it:
        // pure black, flush to the screen edge and to the notch, with only the
        // outer bottom corner rounded — the same corner the notch itself has.
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 10,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(.black)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.showMainWindow() }
        .help("Posture — click to open")
    }
}

/// The same shape as the window's chart, scaled down to menu bar height.
private struct NotchSparkline: Shape {
    let history: [Double]
    let threshold: Double

    func path(in rect: CGRect) -> Path {
        let lower = -10.0
        let upper = max(threshold * 1.8, 20)
        // Only the recent tail fits at this size.
        let points = history.suffix(60)
        guard points.count > 1 else { return Path() }

        return Path { path in
            let step = rect.width / CGFloat(points.count - 1)
            for (index, value) in points.enumerated() {
                let clamped = min(max(value, lower), upper)
                let y = CGFloat((clamped - lower) / (upper - lower)) * rect.height
                let point = CGPoint(x: CGFloat(index) * step, y: y)
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
        }
    }
}
