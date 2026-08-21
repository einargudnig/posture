import Foundation

/// UserDefaults-backed settings. Nothing here is secret, so plain defaults.
enum Prefs {
    /// Defaults are registered inside this lazy initializer rather than from an
    /// explicit setup call: stored-property initializers in the model read
    /// these before any `init()` body runs, and an unregistered key silently
    /// reads back as 0 rather than failing.
    private static let store: UserDefaults = {
        let store = UserDefaults.standard
        store.register(defaults: [
            Key.threshold: 12.0,
            Key.sustain: 25.0,
            Key.cooldown: 120.0,
            Key.maxCooldown: 1800.0,
            Key.invert: false,
            Key.enabled: true,
            Key.sound: true,
            Key.notify: true,
            Key.soundName: "Submarine",
            Key.menuBarOnly: false,
            Key.notchHUD: true,
            Key.hasOnboarded: false,
        ])
        return store
    }()

    private enum Key {
        static let baseline = "baselinePitch"
        static let hasBaseline = "hasBaseline"
        static let threshold = "thresholdDegrees"
        static let sustain = "sustainSeconds"
        static let cooldown = "cooldownSeconds"
        static let maxCooldown = "maxCooldownSeconds"
        static let invert = "invertPitch"
        static let enabled = "monitoringEnabled"
        static let sound = "playSound"
        static let notify = "showNotifications"
        static let soundName = "alertSoundName"
        static let menuBarOnly = "menuBarOnly"
        static let notchHUD = "showNotchHUD"
        static let hasOnboarded = "hasOnboarded"
    }

    static var baseline: Double? {
        get { store.bool(forKey: Key.hasBaseline) ? store.double(forKey: Key.baseline) : nil }
        set {
            store.set(newValue != nil, forKey: Key.hasBaseline)
            store.set(newValue ?? 0, forKey: Key.baseline)
        }
    }

    static var thresholdDegrees: Double {
        get { store.double(forKey: Key.threshold) }
        set { store.set(newValue, forKey: Key.threshold) }
    }

    static var sustainSeconds: Double {
        get { store.double(forKey: Key.sustain) }
        set { store.set(newValue, forKey: Key.sustain) }
    }

    static var cooldownSeconds: Double {
        get { store.double(forKey: Key.cooldown) }
        set { store.set(newValue, forKey: Key.cooldown) }
    }

    static var maxCooldownSeconds: Double {
        get { store.double(forKey: Key.maxCooldown) }
        set { store.set(newValue, forKey: Key.maxCooldown) }
    }

    static var invertPitch: Bool {
        get { store.bool(forKey: Key.invert) }
        set { store.set(newValue, forKey: Key.invert) }
    }

    static var enabled: Bool {
        get { store.bool(forKey: Key.enabled) }
        set { store.set(newValue, forKey: Key.enabled) }
    }

    static var playSound: Bool {
        get { store.bool(forKey: Key.sound) }
        set { store.set(newValue, forKey: Key.sound) }
    }

    static var showNotifications: Bool {
        get { store.bool(forKey: Key.notify) }
        set { store.set(newValue, forKey: Key.notify) }
    }

    static var soundName: String {
        get { store.string(forKey: Key.soundName) ?? "Submarine" }
        set { store.set(newValue, forKey: Key.soundName) }
    }

    static var menuBarOnly: Bool {
        get { store.bool(forKey: Key.menuBarOnly) }
        set { store.set(newValue, forKey: Key.menuBarOnly) }
    }

    static var showNotchHUD: Bool {
        get { store.bool(forKey: Key.notchHUD) }
        set { store.set(newValue, forKey: Key.notchHUD) }
    }

    static var hasOnboarded: Bool {
        get { store.bool(forKey: Key.hasOnboarded) }
        set { store.set(newValue, forKey: Key.hasOnboarded) }
    }
}
