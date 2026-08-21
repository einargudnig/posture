import Foundation

enum PostureState: Equatable {
    case unknown
    case good
    case slouching
}

enum PostureEvent: Equatable {
    case none
    case enteredSlouch
    case recovered
    case alert
}

struct PostureConfig {
    /// Degrees of downward head pitch, relative to the calibrated baseline,
    /// that counts as slouching.
    var thresholdDegrees: Double = 12
    /// Hysteresis band. Recovery requires coming back within
    /// `thresholdDegrees - recoveryDegrees` so the state doesn't chatter.
    var recoveryDegrees: Double = 5
    /// How long a slouch must persist before it is worth interrupting for.
    var sustainSeconds: Double = 25
    /// Gap after the first nag. Each ignored nag doubles it.
    var cooldownSeconds: Double = 120
    /// Ceiling on the backed-off gap, so the app never goes fully silent.
    var maxCooldownSeconds: Double = 1800
    /// Smoothing time constant for the pitch signal, in seconds.
    var smoothingSeconds: Double = 0.8
}

/// Turns a raw stream of head-pitch samples into "should I nag you" decisions.
///
/// The sensor part of posture monitoring is easy; this type holds the only
/// genuinely opinionated logic in the app.
final class PostureAnalyzer {
    var config: PostureConfig
    /// Calibrated upright pitch, in radians. Nil until the user calibrates.
    var baseline: Double?
    /// Set if the head-down direction turns out to be +pitch on your hardware.
    var invertPitch = false

    private(set) var state: PostureState = .unknown
    private(set) var smoothedPitch: Double?
    private(set) var totalSeconds: Double = 0
    private(set) var slouchSeconds: Double = 0

    private var slouchStart: Date?
    private var lastAlert: Date?
    private var lastSample: Date?
    private(set) var ignoredNags = 0

    init(config: PostureConfig = PostureConfig()) {
        self.config = config
    }

    /// Downward deviation from baseline in degrees. Positive = head dropped.
    var dropDegrees: Double? {
        guard let baseline, let smoothedPitch else { return nil }
        let delta = (baseline - smoothedPitch) * 180 / .pi
        return invertPitch ? -delta : delta
    }

    /// Gap the app is currently waiting out before it will nag again.
    /// Doubles per ignored nag, capped, and drops back to the base gap the
    /// moment you sit up.
    var currentCooldownSeconds: Double {
        guard ignoredNags > 0 else { return config.cooldownSeconds }
        let backedOff = config.cooldownSeconds * pow(2, Double(ignoredNags - 1))
        return min(backedOff, config.maxCooldownSeconds)
    }

    func calibrate(to pitch: Double) {
        baseline = pitch
        smoothedPitch = pitch
        state = .good
        slouchStart = nil
        lastAlert = nil
        ignoredNags = 0
    }

    func reset() {
        state = .unknown
        smoothedPitch = nil
        slouchStart = nil
        lastAlert = nil
        lastSample = nil
        ignoredNags = 0
    }

    func resetStats() {
        totalSeconds = 0
        slouchSeconds = 0
    }

    /// Feed one sample. Returns what, if anything, the UI should react to.
    @discardableResult
    func ingest(pitch: Double, at now: Date = Date()) -> PostureEvent {
        let dt = lastSample.map { now.timeIntervalSince($0) } ?? 0
        lastSample = now

        // Exponential moving average, frame-rate independent.
        if let previous = smoothedPitch, dt > 0 {
            let alpha = 1 - exp(-dt / config.smoothingSeconds)
            smoothedPitch = previous + alpha * (pitch - previous)
        } else if smoothedPitch == nil {
            smoothedPitch = pitch
        }

        guard baseline != nil, let drop = dropDegrees else { return .none }

        if dt > 0, dt < 1 {
            totalSeconds += dt
            if state == .slouching { slouchSeconds += dt }
        }

        return advance(drop: drop, now: now)
    }

    // MARK: - The decision

    /// Given the current downward deviation, decide what happens next.
    ///
    /// `sustainSeconds` buys tolerance for glancing at the keyboard, at the
    /// cost of letting short slumps slide.
    ///
    /// Nagging backs off exponentially: each nag you ignore doubles the gap
    /// before the next one, capped by `maxCooldownSeconds`. The bet is that
    /// ignoring a nudge means you're deep in something, and that an app which
    /// gets quieter when you're busy is one you don't reach for the mute
    /// button on. The cost is real — on the days you slouch for three hours
    /// straight, it fades to a nudge every 30 minutes. Sitting up resets it,
    /// so the full-strength behaviour is always one good posture away.
    private func advance(drop: Double, now: Date) -> PostureEvent {
        let isDown = drop > config.thresholdDegrees
        let isBack = drop < config.thresholdDegrees - config.recoveryDegrees

        switch state {
        case .unknown, .good:
            guard isDown else { return .none }
            state = .slouching
            slouchStart = now
            return .enteredSlouch

        case .slouching:
            if isBack {
                state = .good
                slouchStart = nil
                ignoredNags = 0
                return .recovered
            }
            guard let start = slouchStart,
                  now.timeIntervalSince(start) >= config.sustainSeconds
            else { return .none }

            if let last = lastAlert,
               now.timeIntervalSince(last) < currentCooldownSeconds {
                return .none
            }
            lastAlert = now
            ignoredNags += 1
            return .alert
        }
    }
}
