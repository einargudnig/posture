import SwiftUI

/// Day-by-day and hour-by-hour history.
///
/// Reads and aggregates off the main thread on appear — 90 days is ~43k lines,
/// which is quick but not free, and this window opens rarely.
struct HistoryView: View {
    @EnvironmentObject private var model: PostureModel

    @State private var days: [DaySummary] = []
    @State private var hours: [HourSummary] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            section("Last 14 days") {
                if days.isEmpty {
                    empty("Nothing recorded yet. History builds up as you wear your AirPods.")
                } else {
                    DayBars(days: days)
                }
            }

            section("When it goes wrong") {
                if hours.allSatisfy({ $0.slouchFraction == nil }) {
                    empty("Not enough measured time yet to show a pattern by hour.")
                } else {
                    HourStrip(hours: hours)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Text(model.todayText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reveal File", action: model.revealHistory)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .padding(24)
        .frame(width: 560, height: 460)
        .background(.background)
        .task {
            guard !loaded else { return }
            loaded = true
            await reload()
        }
    }

    private func reload() async {
        let store = model.historyStore
        let (newDays, newHours) = await Task.detached(priority: .userInitiated) {
            let records = store.load()
            return (
                HistoryRollup.days(records, limit: 14),
                HistoryRollup.hours(records)
            )
        }.value
        days = newDays
        hours = newHours
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2)
                .tracking(1.2)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func empty(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
    }
}

/// One bar per day, height is the share of measured time spent upright. Days
/// with too little measured time are drawn hollow rather than given a number
/// they haven't earned.
private struct DayBars: View {
    let days: [DaySummary]

    var body: some View {
        // Fixed-width columns, left aligned: a single day should look like one
        // day, not stretch to fill the window.
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { day in
                VStack(spacing: 6) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .frame(height: 110)
                        if let upright = day.uprightFraction {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(upright > 0.7 ? Color.green : Color.orange)
                                .frame(height: max(4, 110 * upright))
                        }
                    }
                    Text(Self.label(day.day))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 26)
                .help(Self.tooltip(day))
            }
            Spacer(minLength: 0)
        }
    }

    private static func label(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return String(formatter.string(from: date).prefix(2))
    }

    private static func tooltip(_ day: DaySummary) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let when = formatter.string(from: day.day)
        guard let upright = day.uprightFraction else {
            return "\(when) — only \(Format.duration(day.observed)) measured"
        }
        return String(
            format: "%@ — %.0f%% upright over %@",
            when, upright * 100, Format.duration(day.observed))
    }
}

/// Slouching by hour of day, pooled across the whole window.
private struct HourStrip: View {
    let hours: [HourSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(hours) { hour in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colour(for: hour))
                        .frame(height: 26)
                        .help(tooltip(hour))
                }
            }
            HStack {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text("\(hour):00")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func colour(for hour: HourSummary) -> Color {
        guard let fraction = hour.slouchFraction else { return Color.secondary.opacity(0.12) }
        // Green through amber: the darker the band, the more of that hour you
        // spent past your limit.
        return Color.orange.opacity(0.15 + min(fraction, 1) * 0.75)
    }

    private func tooltip(_ hour: HourSummary) -> String {
        guard let fraction = hour.slouchFraction else {
            return String(format: "%02d:00 — not enough measured time", hour.hour)
        }
        return String(
            format: "%02d:00 — %.0f%% slouched over %@",
            hour.hour, fraction * 100, Format.duration(hour.observed))
    }
}
