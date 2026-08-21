import CoreMotion
import Foundation

enum MotionStatus: Equatable {
    case unsupported
    case denied
    case waiting
    case streaming
}

/// Thin wrapper over CMHeadphoneMotionManager.
///
/// AirPods only emit device motion while they are in your ears; taking them
/// out silently stops the stream rather than reporting an error, so we treat
/// "no sample for a while" as not-worn.
final class HeadphoneMotion: NSObject, CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()
    private let queue = OperationQueue()

    var onPitch: ((Double) -> Void)?
    var onStatus: ((MotionStatus) -> Void)?

    private(set) var status: MotionStatus = .waiting {
        didSet {
            guard status != oldValue else { return }
            let status = status
            DispatchQueue.main.async { self.onStatus?(status) }
        }
    }

    override init() {
        super.init()
        queue.name = "posture.motion"
        queue.maxConcurrentOperationCount = 1
        manager.delegate = self
    }

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable else {
            status = .unsupported
            return
        }
        if CMHeadphoneMotionManager.authorizationStatus() == .denied {
            status = .denied
            return
        }
        status = .waiting
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self else { return }
            if error != nil {
                self.status = CMHeadphoneMotionManager.authorizationStatus() == .denied
                    ? .denied : .waiting
                return
            }
            guard let motion else { return }
            self.status = .streaming
            let pitch = motion.attitude.pitch
            DispatchQueue.main.async { self.onPitch?(pitch) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        status = .waiting
    }

    /// Called when the AirPods are put in / taken out.
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        status = .streaming
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        status = .waiting
    }
}
