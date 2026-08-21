import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: PostureModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var handledLaunch = false

    var body: some View {
        VStack(spacing: 22) {
            PostureGauge(
                drop: model.isCalibrated ? model.dropDegrees : nil,
                threshold: model.thresholdDegrees,
                isActive: model.enabled && model.isStreaming,
                symbol: model.symbolName
            )
            .padding(.top, 6)

            VStack(spacing: 5) {
                Text(model.statusText)
                    .font(.title3.weight(.medium))
                Text(model.guidanceText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 34, alignment: .top)
            }

            if model.isCalibrated && model.isStreaming {
                HistoryChart(
                    history: model.history,
                    threshold: model.thresholdDegrees,
                    tint: .secondary
                )
                stats
            } else {
                Spacer().frame(height: 44)
            }

            action
        }
        .padding(24)
        .frame(width: 320)
        .background(.background)
        .onAppear {
            model.chartIsVisible = true
            // Menu-bar-only means exactly that: don't throw a window up at
            // login. Opening it from the menu still works, and this only fires
            // for the window SwiftUI restores at launch.
            if !handledLaunch {
                handledLaunch = true
                if model.menuBarOnly { dismissWindow(id: "main") }
            }
        }
        .onDisappear { model.chartIsVisible = false }
    }

    // MARK: - Stats

    private var stats: some View {
        HStack(spacing: 0) {
            tile("Upright", model.uprightText)
            divider
            tile("Session", model.sessionText)
            divider
            tile("Ignored", "\(model.ignoredNags)")
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 24)
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.body, design: .rounded).weight(.medium))
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Primary action

    @ViewBuilder
    private var action: some View {
        if model.motionStatus == .denied {
            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(
                    URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Motion"
                    )!)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        } else {
            HStack(spacing: 8) {
                Button {
                    model.startCalibration()
                } label: {
                    Text(model.isCalibrated ? "Recalibrate" : "Calibrate")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!model.isStreaming || model.calibrationCountdown != nil)

                Button {
                    model.enabled.toggle()
                } label: {
                    Image(systemName: model.enabled ? "pause.fill" : "play.fill")
                        .frame(width: 16)
                }
                .controlSize(.large)
                .help(model.enabled ? "Pause monitoring" : "Resume monitoring")
            }
        }
    }
}
