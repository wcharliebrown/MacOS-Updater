import Foundation

/// Periodic background check.
///
/// `NSBackgroundActivityScheduler` lets macOS pick a moment that suits the system,
/// so a daily check does not fight the user for CPU or wake a sleeping machine.
final class BackgroundScheduler: @unchecked Sendable {
    private let scheduler: NSBackgroundActivityScheduler
    private let action: @Sendable () async -> Void

    init(interval: TimeInterval, action: @escaping @Sendable () async -> Void) {
        self.action = action
        scheduler = NSBackgroundActivityScheduler(identifier: "com.dialogs.MacOSUpdater.refresh")
        scheduler.repeats = true
        scheduler.interval = interval
        // Allow macOS to shift the check by up to half the interval.
        scheduler.tolerance = interval / 2
        scheduler.qualityOfService = .utility
    }

    func start() {
        scheduler.schedule { [action] completion in
            Task {
                await action()
                completion(.finished)
            }
        }
    }

    func stop() { scheduler.invalidate() }
}
