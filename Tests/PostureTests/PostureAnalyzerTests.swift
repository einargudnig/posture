import Foundation
import Testing

@testable import Posture

/// Feeds `seconds` worth of samples at 25 Hz and returns every event raised.
private func drive(
    _ analyzer: PostureAnalyzer, pitchDegrees: Double, seconds: Double, from start: Date
) -> [PostureEvent] {
    var events: [PostureEvent] = []
    let step = 1.0 / 25
    for index in 0..<Int(seconds / step) {
        let at = start.addingTimeInterval(Double(index) * step)
        let event = analyzer.ingest(pitch: pitchDegrees * .pi / 180, at: at)
        if case .none = event { continue }
        events.append(event)
    }
    return events
}

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

@Test func sittingUpNeverAlerts() {
    let analyzer = PostureAnalyzer()
    analyzer.calibrate(to: 0)
    let events = drive(analyzer, pitchDegrees: -3, seconds: 300, from: epoch)
    #expect(events.isEmpty)
    #expect(analyzer.state == .good)
}

@Test func briefGlanceDownDoesNotAlert() {
    var config = PostureConfig()
    config.sustainSeconds = 25
    let analyzer = PostureAnalyzer(config: config)
    analyzer.calibrate(to: 0)

    // Ten seconds looking at the keyboard, then back up.
    let down = drive(analyzer, pitchDegrees: -30, seconds: 10, from: epoch)
    let up = drive(analyzer, pitchDegrees: 0, seconds: 10, from: epoch.addingTimeInterval(10))

    #expect(down == [.enteredSlouch])
    #expect(up == [.recovered])
}

@Test func sustainedSlouchAlertsOnce() {
    var config = PostureConfig()
    config.sustainSeconds = 25
    config.cooldownSeconds = 120
    let analyzer = PostureAnalyzer(config: config)
    analyzer.calibrate(to: 0)

    let events = drive(analyzer, pitchDegrees: -30, seconds: 100, from: epoch)
    #expect(events.filter { $0 == .alert }.count == 1)
    #expect(events.first == .enteredSlouch)
}

/// Timestamps, relative to `epoch`, at which an alert fired.
private func alertTimes(
    _ analyzer: PostureAnalyzer, pitchDegrees: Double, seconds: Double, from start: Date
) -> [Double] {
    var times: [Double] = []
    let step = 1.0 / 25
    for index in 0..<Int(seconds / step) {
        let offset = Double(index) * step
        let at = start.addingTimeInterval(offset)
        if analyzer.ingest(pitch: pitchDegrees * .pi / 180, at: at) == .alert {
            times.append((start.timeIntervalSince(epoch) + offset).rounded())
        }
    }
    return times
}

@Test func ignoredNagsBackOffExponentially() {
    var config = PostureConfig()
    config.sustainSeconds = 10
    config.cooldownSeconds = 60
    config.maxCooldownSeconds = .infinity
    let analyzer = PostureAnalyzer(config: config)
    analyzer.calibrate(to: 0)

    // First nag at t=10, then gaps of 60, 120, 240, 480.
    let times = alertTimes(analyzer, pitchDegrees: -30, seconds: 1000, from: epoch)
    #expect(times == [10, 70, 190, 430, 910])
}

@Test func backoffIsCappedSoItNeverGoesSilent() {
    var config = PostureConfig()
    config.sustainSeconds = 10
    config.cooldownSeconds = 60
    config.maxCooldownSeconds = 120
    let analyzer = PostureAnalyzer(config: config)
    analyzer.calibrate(to: 0)

    // Gaps of 60, then 120 forever — never wider than the cap.
    let times = alertTimes(analyzer, pitchDegrees: -30, seconds: 600, from: epoch)
    #expect(times == [10, 70, 190, 310, 430, 550])
}

@Test func sittingUpResetsTheBackoff() {
    var config = PostureConfig()
    config.sustainSeconds = 10
    config.cooldownSeconds = 60
    let analyzer = PostureAnalyzer(config: config)
    analyzer.calibrate(to: 0)

    // Ignore four nags (t = 10, 70, 190, 430), widening the gap to 480s.
    _ = alertTimes(analyzer, pitchDegrees: -30, seconds: 500, from: epoch)
    #expect(analyzer.ignoredNags == 4)
    #expect(analyzer.currentCooldownSeconds == 480)

    // Sit up for a moment.
    let recovery = drive(
        analyzer, pitchDegrees: 0, seconds: 5, from: epoch.addingTimeInterval(500))
    #expect(recovery == [.recovered])
    #expect(analyzer.ignoredNags == 0)
    #expect(analyzer.currentCooldownSeconds == 60)

    // Back to full strength: next slouch nags after sustain, not after 240s.
    let times = alertTimes(
        analyzer, pitchDegrees: -30, seconds: 30, from: epoch.addingTimeInterval(505))
    #expect(times == [515])
}

@Test func calibratingResetsTheBackoff() {
    var config = PostureConfig()
    config.sustainSeconds = 10
    config.cooldownSeconds = 60
    let analyzer = PostureAnalyzer(config: config)
    analyzer.calibrate(to: 0)
    _ = alertTimes(analyzer, pitchDegrees: -30, seconds: 500, from: epoch)
    #expect(analyzer.ignoredNags > 0)

    analyzer.calibrate(to: 0)
    #expect(analyzer.ignoredNags == 0)
}

@Test func hysteresisStopsChatterAtTheThreshold() {
    var config = PostureConfig()
    config.thresholdDegrees = 12
    config.recoveryDegrees = 5
    config.smoothingSeconds = 0.01  // effectively unsmoothed
    config.sustainSeconds = .infinity  // isolate state transitions from nagging
    let analyzer = PostureAnalyzer(config: config)
    analyzer.calibrate(to: 0)

    var now = epoch
    var events: [PostureEvent] = []
    for _ in 0..<20 {
        events += drive(analyzer, pitchDegrees: -13, seconds: 1, from: now)
        now = now.addingTimeInterval(1)
        events += drive(analyzer, pitchDegrees: -9, seconds: 1, from: now)
        now = now.addingTimeInterval(1)
    }
    // -13° crosses the 12° limit but -9° stays inside the 7° recovery line,
    // so this should latch once and never bounce back.
    #expect(events == [.enteredSlouch])
}

@Test func smoothingRejectsASingleSpike() {
    var config = PostureConfig()
    config.smoothingSeconds = 0.8
    let analyzer = PostureAnalyzer(config: config)
    analyzer.calibrate(to: 0)
    _ = drive(analyzer, pitchDegrees: 0, seconds: 5, from: epoch)

    // One 40ms sample at -60°, then straight back.
    let spike = analyzer.ingest(
        pitch: -60 * .pi / 180, at: epoch.addingTimeInterval(5))
    #expect(spike == .none)
}

@Test func invertedHardwareFlipsTheSign() {
    let analyzer = PostureAnalyzer()
    analyzer.invertPitch = true
    analyzer.calibrate(to: 0)
    let events = drive(analyzer, pitchDegrees: +30, seconds: 5, from: epoch)
    #expect(events == [.enteredSlouch])
}

@Test func uncalibratedNeverAlerts() {
    let analyzer = PostureAnalyzer()
    let events = drive(analyzer, pitchDegrees: -45, seconds: 300, from: epoch)
    #expect(events.isEmpty)
    #expect(analyzer.state == .unknown)
}
