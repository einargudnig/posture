import SwiftUI

/// Head drop as a fraction of the limit, drawn as a ring.
///
/// The ring is deliberately the only saturated colour in the window — posture
/// is the one thing worth looking at, and everything else is chrome.
struct PostureGauge: View {
    let drop: Double?
    let threshold: Double
    let isActive: Bool
    let symbol: String

    private var fraction: Double {
        guard let drop, threshold > 0 else { return 0 }
        return min(max(drop / threshold, 0), 1)
    }

    private var tint: Color {
        guard isActive, drop != nil else { return .secondary }
        // Green until you're most of the way to the limit, then amber, then red.
        switch fraction {
        case ..<0.7: return .green
        case ..<1: return .yellow
        default: return .orange
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, style: StrokeStyle(lineWidth: 10, lineCap: .round))

            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: fraction)

            center
        }
        .frame(width: 132, height: 132)
    }

    @ViewBuilder
    private var center: some View {
        if let drop, isActive {
            VStack(spacing: 0) {
                Text(String(format: "%.0f°", drop))
                    .font(.system(size: 38, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: Int(drop))
                Text("of \(Int(threshold))°")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
        }
    }
}

/// Last minute of head drop. Down on screen means head down, so the line
/// falling past the dashed limit reads the way it feels.
struct HistoryChart: View {
    let history: [Double]
    let threshold: Double
    let tint: Color

    private let lower = -10.0

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let upper = max(threshold * 1.8, 20)
            let limitY = y(for: threshold, in: size, upper: upper)

            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: limitY))
                    path.addLine(to: CGPoint(x: size.width, y: limitY))
                }
                .stroke(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                if history.count > 1 {
                    line(in: size, upper: upper)
                        .stroke(
                            tint.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
        }
        .frame(height: 44)
    }

    private func y(for value: Double, in size: CGSize, upper: Double) -> CGFloat {
        let clamped = min(max(value, lower), upper)
        return CGFloat((clamped - lower) / (upper - lower)) * size.height
    }

    private func line(in size: CGSize, upper: Double) -> Path {
        Path { path in
            let step = size.width / CGFloat(max(history.count - 1, 1))
            for (index, value) in history.enumerated() {
                let point = CGPoint(
                    x: CGFloat(index) * step, y: y(for: value, in: size, upper: upper))
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
        }
    }
}
