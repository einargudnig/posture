import CoreMotion
import Foundation

/// `Posture.app/Contents/MacOS/Posture --probe` — prints live head angles.
///
/// Useful for confirming the AirPods are streaming at all, and for checking
/// which way `pitch` moves when you look down (that decides `invertPitch`).
enum Probe {
    static func run() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let motion = HeadphoneMotion()
        var samples = 0

        print("available: \(motion.isAvailable)")
        print("authorization: \(CMHeadphoneMotionManager.authorizationStatus().rawValue)")

        motion.onStatus = { print("status: \($0)") }
        motion.onPitch = { pitch in
            samples += 1
            guard samples % 10 == 0 else { return }
            print(String(format: "pitch %+7.2f°", pitch * 180 / .pi))
        }
        motion.start()

        print("Streaming. Look down — note whether pitch goes negative. Ctrl-C to stop.")
        RunLoop.main.run()
        exit(0)
    }
}
