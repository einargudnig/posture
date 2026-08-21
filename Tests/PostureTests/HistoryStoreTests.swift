import Foundation
import Testing

@testable import Posture

private func temporaryStore(retentionDays: Int = 90) -> HistoryStore {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("posture-tests-\(UUID().uuidString)")
        .appendingPathComponent("history.jsonl")
    return HistoryStore(url: url, retentionDays: retentionDays)
}

private let epoch = Date(timeIntervalSince1970: 1_755_780_000)

private func minute(_ offset: Int, observed: Double = 60, slouched: Double = 0,
                    drop: Double = 3) -> MinuteRecord {
    MinuteRecord(
        start: epoch.addingTimeInterval(Double(offset) * 60),
        observed: observed, slouched: slouched, meanDrop: drop)
}

// MARK: - Storage

@Test func recordsSurviveARoundTrip() {
    let store = temporaryStore()
    defer { store.clear() }

    let written = [minute(0), minute(1, slouched: 20), minute(2, observed: 41.5)]
    written.forEach(store.append)

    #expect(store.load() == written)
}

@Test func aTruncatedFinalLineIsToleratedAndTheRestSurvives() throws {
    let store = temporaryStore()
    defer { store.clear() }

    [minute(0), minute(1)].forEach(store.append)
    // What a crash mid-write leaves behind.
    var data = try Data(contentsOf: store.url)
    data.append(contentsOf: Array(#"{"t":1755780120,"obs":12.0,"slo"#.utf8))
    try data.write(to: store.url)

    #expect(store.load().count == 2)
}

@Test func anUnwritableLocationNeverThrows() {
    // Monitoring must not stop because history can't be written.
    let store = HistoryStore(url: URL(fileURLWithPath: "/System/nope/history.jsonl"))
    store.append(minute(0))
    #expect(store.load().isEmpty)
}

@Test func trimDropsRecordsPastRetention() {
    let store = temporaryStore(retentionDays: 7)
    defer { store.clear() }

    // Floored to a whole minute, exactly as the model writes them — an
    // arbitrary Date carries sub-second precision that seconds-since-1970
    // encoding does not preserve, so equality after a round trip would fail on
    // floating point rather than on the logic under test.
    let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
    let old = MinuteRecord(
        start: now.addingTimeInterval(-8 * 86_400), observed: 60, slouched: 0, meanDrop: 1)
    let recent = MinuteRecord(
        start: now.addingTimeInterval(-2 * 86_400), observed: 60, slouched: 0, meanDrop: 1)
    [old, recent].forEach(store.append)

    store.trim(now: now)
    #expect(store.load() == [recent])
}

// MARK: - Rollups

@Test func daysAggregateObservedAndSlouchedTime() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Atlantic/Reykjavik")!

    // Past the 10-minute floor, so a percentage is earned.
    let records = (0..<15).map { i in
        minute(i, observed: 60, slouched: i < 6 ? 60 : 0)
    }
    let days = HistoryRollup.days(records, calendar: calendar)

    #expect(days.count == 1)
    #expect(days[0].observed == 900)
    #expect(days[0].slouched == 360)
    #expect(days[0].uprightFraction == 0.6)
}

@Test func daysSplitAcrossALocalDayBoundary() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Atlantic/Reykjavik")!

    let midnight = calendar.startOfDay(for: epoch)
    let records = [
        MinuteRecord(start: midnight.addingTimeInterval(-60), observed: 60, slouched: 60,
                     meanDrop: 20),
        MinuteRecord(start: midnight, observed: 60, slouched: 0, meanDrop: 1),
    ]
    let days = HistoryRollup.days(records, calendar: calendar)

    #expect(days.count == 2)
    #expect(days[0].slouched == 60)
    #expect(days[1].slouched == 0)
}

@Test func aShortDayReportsNoPercentageRatherThanAConfidentOne() {
    // Eleven observed minutes should not produce "62% upright".
    let short = DaySummary(day: epoch, observed: 9 * 60, slouched: 4 * 60)
    #expect(short.uprightFraction == nil)

    let enough = DaySummary(day: epoch, observed: 20 * 60, slouched: 5 * 60)
    #expect(enough.uprightFraction == 0.75)
}

@Test func gapsAreExcludedFromTheDenominator() {
    // Minutes with no sensor data are simply absent, so an hour with the
    // AirPods out doesn't dilute the day.
    let records = [minute(0, observed: 60, slouched: 60), minute(120, observed: 60, slouched: 0)]
    let days = HistoryRollup.days(records)

    #expect(days.first?.observed == 120)
    #expect(days.first?.uprightFraction == nil)  // only 2 minutes measured
}

@Test func hoursPoolAcrossEveryDayInTheWindow() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Atlantic/Reykjavik")!

    let hour = calendar.component(.hour, from: epoch)
    let sameHourTomorrow = epoch.addingTimeInterval(86_400)
    let records = [
        MinuteRecord(start: epoch, observed: 300, slouched: 150, meanDrop: 14),
        MinuteRecord(start: sameHourTomorrow, observed: 300, slouched: 90, meanDrop: 9),
    ]
    let hours = HistoryRollup.hours(records, calendar: calendar)

    #expect(hours.count == 24)
    #expect(hours[hour].observed == 600)
    #expect(hours[hour].slouchFraction == 0.4)
    #expect(hours[(hour + 1) % 24].slouchFraction == nil)
}

@Test func todayPicksOutOnlyTodaysRecords() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Atlantic/Reykjavik")!

    let records = [
        MinuteRecord(start: epoch.addingTimeInterval(-86_400), observed: 600, slouched: 600,
                     meanDrop: 25),
        MinuteRecord(start: epoch, observed: 900, slouched: 180, meanDrop: 5),
    ]
    let summary = HistoryRollup.day(records, containing: epoch, calendar: calendar)

    #expect(summary.observed == 900)
    #expect(summary.slouched == 180)
    #expect(summary.uprightFraction == 0.8)
}
