import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications

/// Owns the sensor and the analyzer, and republishes just enough for SwiftUI.
///
/// The analyzer is fed at the full ~25 Hz sensor rate, but `@Published`
/// properties are refreshed on a 10 Hz timer — driving SwiftUI at sensor rate
/// burns CPU redrawing a number that hasn't visibly changed.
@MainActor
final class PostureModel: ObservableObject {
    /// Held here rather than in an `@StateObject` on the `App`. A `@StateObject`
    /// at App level makes every change re-evaluate the Scene body, and SwiftUI
    /// treats that as a reason to rebuild the main menu and Dock menu.
    static let shared = PostureModel()

    /// Everything the UI reads, in one value.
    ///
    /// This is deliberately a single `@Published` rather than a field each.
    /// Nine separate published properties meant nine `objectWillChange` events
    /// per tick, and because SwiftUI rebuilds a Scene's whole body when an
    /// observed object changes, that was rebuilding the app's main menu and
    /// Dock menu ten times a second whether or not a number had moved.
    ///
    /// Values are quantised to the precision actually rendered, so an
    /// unchanging display produces no events at all.
    struct Live: Equatable {
        var motionStatus: MotionStatus = .waiting
        var postureState: PostureState = .unknown
        var dropDegrees: Double?
        var isCalibrated = false
        var slouchFraction: Double?
        var sessionSeconds: Double = 0
        var ignoredNags = 0
        var currentCooldown: Double = 120
        var calibrationCountdown: Int?
        /// Recent head-drop samples for the sparkline, oldest first.
        var history: [Double] = []
    }

    @Published private(set) var live = Live()

    var motionStatus: MotionStatus { live.motionStatus }
    var postureState: PostureState { live.postureState }
    var dropDegrees: Double? { live.dropDegrees }
    var isCalibrated: Bool { live.isCalibrated }
    var slouchFraction: Double? { live.slouchFraction }
    var sessionSeconds: Double { live.sessionSeconds }
    var ignoredNags: Int { live.ignoredNags }
    var currentCooldown: Double { live.currentCooldown }
    var calibrationCountdown: Int? { live.calibrationCountdown }
    var history: [Double] { live.history }

    @Published var enabled = Prefs.enabled {
        didSet {
            Prefs.enabled = enabled
            // Pausing tears the sensor down rather than ignoring its samples.
            // CoreMotion keeps the AirPods' IMU and the Bluetooth link busy for
            // as long as anyone is subscribed, so a "paused" app that stays
            // subscribed still costs both devices power.
            if enabled {
                motion.start()
            } else {
                motion.stop()
                flushBucket()
                analyzer.reset()
                currentStatus = .waiting
            }
        }
    }
    @Published var playSound = Prefs.playSound {
        didSet { Prefs.playSound = playSound }
    }
    @Published var showNotifications = Prefs.showNotifications {
        didSet {
            Prefs.showNotifications = showNotifications
            if showNotifications { requestNotificationAccess() }
        }
    }
    @Published var soundName = Prefs.soundName {
        didSet {
            Prefs.soundName = soundName
            NSSound(named: soundName)?.play()
        }
    }
    @Published var hideDockIcon = Prefs.hideDockIcon {
        didSet {
            Prefs.hideDockIcon = hideDockIcon
            applyActivationPolicy()
        }
    }
    @Published var showNotchHUD = Prefs.showNotchHUD {
        didSet {
            Prefs.showNotchHUD = showNotchHUD
            applyNotchHUD()
        }
    }
    @Published var maxCooldownSeconds = Prefs.maxCooldownSeconds {
        didSet {
            Prefs.maxCooldownSeconds = maxCooldownSeconds
            analyzer.config.maxCooldownSeconds = maxCooldownSeconds
        }
    }
    /// Mirrors `SMAppService`, which is the source of truth — the user can
    /// revoke this from System Settings without the app ever hearing about it.
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet { applyLaunchAtLogin() }
    }
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var notificationsDenied = false
    @Published var invertPitch = Prefs.invertPitch {
        didSet {
            Prefs.invertPitch = invertPitch
            analyzer.invertPitch = invertPitch
        }
    }
    @Published var thresholdDegrees = Prefs.thresholdDegrees {
        didSet {
            Prefs.thresholdDegrees = thresholdDegrees
            analyzer.config.thresholdDegrees = thresholdDegrees
        }
    }
    @Published var sustainSeconds = Prefs.sustainSeconds {
        didSet {
            Prefs.sustainSeconds = sustainSeconds
            analyzer.config.sustainSeconds = sustainSeconds
        }
    }
    @Published var cooldownSeconds = Prefs.cooldownSeconds {
        didSet {
            Prefs.cooldownSeconds = cooldownSeconds
            analyzer.config.cooldownSeconds = cooldownSeconds
        }
    }

    private let motion = HeadphoneMotion()
    private let analyzer = PostureAnalyzer()
    private var calibrationSamples: [Double] = []
    private var calibrationDeadline: Date?
    private var uiTimer: Timer?
    private var isSyncingLoginItem = false
    private var notchHUD: NotchHUD?
    private var currentStatus: MotionStatus = .waiting
    private var historyTick = 0
    private var lastSampleAt: Date?

    private let store = HistoryStore()
    /// The minute currently being accumulated. Flushed at each minute boundary,
    /// and whenever monitoring stops, so a pause or a quit doesn't silently
    /// discard the minute in progress.
    private var bucketStart: Date?
    private var bucketObserved: TimeInterval = 0
    private var bucketSlouched: TimeInterval = 0
    private var bucketDropSum: Double = 0
    /// Running totals for the current local day, seeded from the file at launch
    /// so the window never has to parse history to show one line.
    @Published private(set) var todayObserved: TimeInterval = 0
    @Published private(set) var todaySlouched: TimeInterval = 0
    private var todayStart = Calendar.current.startOfDay(for: Date())

    /// Set by the window while it's on screen. With no window there is nothing
    /// to animate, so the sparkline stops accumulating and the snapshot stops
    /// changing — which is the whole point of the diffing above.
    var chartIsVisible = false {
        didSet { if !chartIsVisible { historyTick = 0 } }
    }

    /// ~60 seconds of history at the 5 Hz append rate.
    private let historyLimit = 300

    init() {
        analyzer.config.thresholdDegrees = Prefs.thresholdDegrees
        analyzer.config.sustainSeconds = Prefs.sustainSeconds
        analyzer.config.cooldownSeconds = Prefs.cooldownSeconds
        analyzer.config.maxCooldownSeconds = Prefs.maxCooldownSeconds
        analyzer.invertPitch = Prefs.invertPitch
        if let baseline = Prefs.baseline { analyzer.restoreBaseline(baseline) }

        motion.onPitch = { [weak self] pitch in
            MainActor.assumeIsolated { self?.handle(pitch: pitch) }
        }
        motion.onStatus = { [weak self] status in
            MainActor.assumeIsolated { self?.currentStatus = status }
        }
        if enabled { motion.start() }

        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }

        if showNotifications { requestNotificationAccess() }
        // Don't steal focus during launch — SwiftUI is about to show the window.
        applyActivationPolicy(activate: false)
        applyNotchHUD()
        loadHistory()
        publish()
    }

    // MARK: - System integration

    /// Only ever prompts when macOS has no answer on file yet. Asking on every
    /// launch is how an app ends up feeling like it nags for permission.
    private func requestNotificationAccess() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                let denied = settings.authorizationStatus == .denied
                Task { @MainActor in self.notificationsDenied = denied }
                return
            }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                Task { @MainActor in self.refreshNotificationStatus() }
            }
        }
    }

    /// Ask the system rather than trusting the one-shot grant result — the
    /// user can flip this in System Settings long after we asked, and a
    /// request that fails for other reasons shouldn't read as "denied".
    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in self.notificationsDenied = denied }
        }
    }

    private func applyNotchHUD() {
        if notchHUD == nil { notchHUD = NotchHUD(model: self) }
        showNotchHUD ? notchHUD?.show() : notchHUD?.hide()
    }

    /// Brings the window back. The strip beside the notch took over the job the
    /// status item menu used to do, and this is the only part of it that
    /// mattered.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // WindowKeeper hides the window rather than letting it close, so there
        // is normally one to order front. The reopen event is only a fallback
        // for the case where it genuinely went away.
        if let window = WindowKeeper.mainWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
    }

    private func applyActivationPolicy(activate: Bool = true) {
        // `.accessory` drops the Dock slot and ⌘-Tab entry. The window still
        // opens on demand, and the strip beside the notch is unaffected.
        //
        // `NSApplication.shared`, not `NSApp`: this can run before the app has
        // finished starting, and `NSApp` is an implicitly-unwrapped optional
        // that traps when it hasn't been set up yet.
        let app = NSApplication.shared
        app.setActivationPolicy(hideDockIcon ? .accessory : .regular)
        if activate && !hideDockIcon { app.activate(ignoringOtherApps: true) }
    }

    private func applyLaunchAtLogin() {
        // The catch block writes back to `launchAtLogin`, which re-enters this
        // through didSet; the guard stops that becoming a loop.
        guard !isSyncingLoginItem else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            // Most often: the app isn't in /Applications, or the signature
            // isn't one launchd will accept. Report it rather than silently
            // leaving the toggle on with nothing registered.
            launchAtLoginError = error.localizedDescription
            isSyncingLoginItem = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            isSyncingLoginItem = false
        }
    }

    var statusText: String {
        if calibrationCountdown != nil { return "Hold still…" }
        if !enabled { return "Paused" }
        switch motionStatus {
        case .unsupported: return "No motion-capable AirPods"
        case .denied: return "Motion access denied"
        case .waiting: return "Waiting for AirPods"
        case .streaming:
            if !isCalibrated { return "Not calibrated" }
            return postureState == .slouching ? "Slouching" : "Posture OK"
        }
    }

    var symbolName: String {
        if calibrationCountdown != nil { return "record.circle" }
        if !enabled { return "pause.circle" }
        switch motionStatus {
        case .unsupported: return "xmark.circle"
        case .denied: return "hand.raised"
        case .waiting: return "airpodspro"
        case .streaming:
            if !isCalibrated { return "target" }
            return postureState == .slouching ? "exclamationmark.triangle.fill" : "figure.stand"
        }
    }

    var isStreaming: Bool { motionStatus == .streaming }

    /// The one line of context under the status. Always says what to do next
    /// when there is something to do, and stays quiet when there isn't.
    var guidanceText: String {
        if let countdown = calibrationCountdown {
            return "Sampling your baseline — \(countdown)s"
        }
        if !enabled { return "Monitoring is off. Nothing is being recorded." }
        switch motionStatus {
        case .denied:
            return "Posture needs Motion & Fitness access to read your AirPods."
        case .unsupported:
            return "Needs AirPods Pro, AirPods 3rd gen, AirPods Max or Beats Fit Pro."
        case .waiting:
            return "Put your AirPods in to start reading your posture."
        case .streaming:
            if !isCalibrated {
                return "Sit the way you want to sit, then calibrate."
            }
            if ignoredNags > 1 {
                return "Easing off — next nudge in \(Format.duration(currentCooldown))."
            }
            if postureState == .slouching {
                return "Head is below your baseline."
            }
            return "Nudges after \(Format.duration(sustainSeconds)) past \(Int(thresholdDegrees))°."
        }
    }

    var uprightText: String {
        slouchFraction.map { String(format: "%.0f%%", (1 - $0) * 100) } ?? "—"
    }

    var sessionText: String {
        sessionSeconds < 30 ? "—" : Format.duration(sessionSeconds)
    }

    // MARK: - Sensor

    private func handle(pitch: Double) {
        // Samples arriving is the only trustworthy evidence the sensor is live.
        let now = Date()
        let gap = lastSampleAt.map { now.timeIntervalSince($0) } ?? 0
        lastSampleAt = now
        currentStatus = .streaming

        if calibrationDeadline != nil {
            calibrationSamples.append(pitch)
            return
        }
        guard enabled else { return }
        let event = analyzer.ingest(pitch: pitch, at: now)
        // Same guard the analyzer uses for its own stats: a gap of a second or
        // more means the stream dropped out, not that a second was observed.
        if gap > 0, gap < 1 { record(seconds: gap, at: now) }
        if event == .alert { nag() }
    }

    // MARK: - History

    private func record(seconds: TimeInterval, at now: Date) {
        let minute = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        if let start = bucketStart, start != minute { flushBucket() }
        if bucketStart == nil || bucketStart != minute { bucketStart = minute }

        bucketObserved += seconds
        if analyzer.state == .slouching { bucketSlouched += seconds }
        // Time-weighted so a mean isn't skewed by an uneven sample rate.
        if let drop = analyzer.dropDegrees { bucketDropSum += drop * seconds }
    }

    /// Writes the minute in progress, if any. Safe to call at any time.
    func flushBucket() {
        defer {
            bucketStart = nil
            bucketObserved = 0
            bucketSlouched = 0
            bucketDropSum = 0
        }
        guard let start = bucketStart, bucketObserved > 0 else { return }
        let record = MinuteRecord(
            start: start,
            observed: bucketObserved,
            slouched: bucketSlouched,
            meanDrop: bucketDropSum / bucketObserved)
        store.append(record)
        addToToday(record)
    }

    private func addToToday(_ record: MinuteRecord) {
        let day = Calendar.current.startOfDay(for: record.start)
        if day != todayStart {
            todayStart = day
            todayObserved = 0
            todaySlouched = 0
        }
        todayObserved += record.observed
        todaySlouched += record.slouched
    }

    /// Trims and seeds today's totals off the main thread — parsing history
    /// must never delay launch.
    private func loadHistory() {
        let store = self.store
        Task.detached(priority: .utility) {
            store.trim()
            let summary = HistoryRollup.day(store.load(), containing: Date())
            await MainActor.run {
                self.todayStart = summary.day
                self.todayObserved = summary.observed
                self.todaySlouched = summary.slouched
            }
        }
    }

    var todaySummary: DaySummary {
        DaySummary(day: todayStart, observed: todayObserved, slouched: todaySlouched)
    }

    var todayText: String {
        let summary = todaySummary
        guard let upright = summary.uprightFraction else {
            return summary.observed > 0
                ? "Today · \(Format.duration(summary.observed)) so far"
                : "Today · nothing recorded yet"
        }
        return String(
            format: "Today · %.0f%% upright over %@",
            upright * 100, Format.duration(summary.observed))
    }

    func clearHistory() {
        store.clear()
        todayObserved = 0
        todaySlouched = 0
    }

    func revealHistory() {
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
    }

    var historyStore: HistoryStore { store }

    private func publish() {
        // Calibration is timer-driven, not sample-driven. If the AirPods stop
        // streaming mid-calibration the countdown still has to end, or the UI
        // wedges on "Hold still…" forever.
        // AirPods stop reporting motion the moment they leave your ears, but the
        // disconnect delegate doesn't reliably fire — so `.streaming` would
        // latch and the app would cheerfully report "Posture OK" while
        // measuring nothing at all. Silence is the signal.
        // `lastSampleAt` being nil means not one sample has ever arrived, which
        // is just as stale as an old one — the earlier version skipped that case
        // and let `.streaming` latch forever on the connect delegate alone.
        if currentStatus == .streaming,
           Date().timeIntervalSince(lastSampleAt ?? .distantPast) > 2 {
            currentStatus = .waiting
            flushBucket()
            analyzer.reset()
        }

        var next = live
        next.motionStatus = currentStatus

        if let deadline = calibrationDeadline {
            next.calibrationCountdown = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
            if Date() >= deadline {
                finishCalibration()
                next.calibrationCountdown = nil
            }
        } else {
            next.calibrationCountdown = nil
        }

        next.postureState = analyzer.state
        next.isCalibrated = analyzer.baseline != nil
        next.ignoredNags = analyzer.ignoredNags
        next.currentCooldown = analyzer.currentCooldownSeconds

        // Quantised to what actually gets rendered: whole degrees are shown, a
        // whole-second session clock, and a whole-percent upright figure. A
        // still head therefore produces an identical `Live` and no event.
        next.dropDegrees = analyzer.dropDegrees.map { ($0 * 2).rounded() / 2 }
        next.sessionSeconds = analyzer.totalSeconds.rounded()
        next.slouchFraction =
            analyzer.totalSeconds > 30
            ? (analyzer.slouchSeconds / analyzer.totalSeconds * 200).rounded() / 200
            : nil

        // Points are only worth accumulating while something is drawing them —
        // the window's chart, or the strip beside the notch.
        if chartIsVisible || showNotchHUD, let drop = analyzer.dropDegrees {
            historyTick += 1
            if historyTick % 2 == 0 {
                next.history.append(drop)
                if next.history.count > historyLimit {
                    next.history.removeFirst(next.history.count - historyLimit)
                }
            }
        } else if !next.history.isEmpty {
            next.history = []
        }

        if next != live { live = next }
    }

    private func nag() {
        if playSound { NSSound(named: soundName)?.play() }
        guard showNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = "Sit up"
        content.body =
            analyzer.dropDegrees.map {
                String(format: "Head is %.0f° below your baseline.", $0)
            } ?? "You've been slouching for a while."
        if analyzer.ignoredNags > 1 {
            content.body += String(
                format: " Easing off to every %@ — sit up to reset.",
                Format.duration(analyzer.currentCooldownSeconds))
        }
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Calibration

    func startCalibration() {
        calibrationSamples = []
        calibrationDeadline = Date().addingTimeInterval(3)
        live.calibrationCountdown = 3
    }

    private func finishCalibration() {
        calibrationDeadline = nil
        let samples = calibrationSamples.sorted()
        calibrationSamples = []
        guard !samples.isEmpty else { return }

        // Median, not mean — one head-turn during calibration shouldn't skew it.
        let median = samples[samples.count / 2]
        analyzer.calibrate(to: median)
        analyzer.resetStats()
        Prefs.baseline = median
        live.history = []
    }

    func resetStats() {
        analyzer.resetStats()
        publish()
    }

    /// Built-in alert sounds, filtered to the ones that actually resolve.
    static let availableSounds: [String] = [
        "Submarine", "Ping", "Glass", "Blow", "Bottle", "Funk", "Hero",
        "Morse", "Pop", "Purr", "Sosumi", "Tink",
    ].filter { NSSound(named: $0) != nil }
}

enum Format {
    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        return String(format: "%.1f h", seconds / 3600)
    }
}
