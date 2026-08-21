import Foundation
import ServiceManagement
import UpdaterKit

/// User preferences, persisted in `UserDefaults`.
struct AppSettings {
    private enum Key {
        static let homebrew = "source.homebrew"
        static let macAppStore = "source.macAppStore"
        static let sparkle = "source.sparkle"
        static let system = "source.system"
        static let interval = "refreshIntervalHours"
        static let notify = "notifyOnNewUpdates"
        static let dryRun = "dryRun"
        static let unusedDays = "unusedThresholdDays"
        static let launched = "hasLaunchedBefore"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.homebrew: true, Key.macAppStore: true, Key.sparkle: true, Key.system: true,
            Key.interval: 24.0, Key.notify: true, Key.dryRun: false,
            Key.unusedDays: 90,
        ])
    }

    var useHomebrew: Bool {
        get { defaults.bool(forKey: Key.homebrew) }
        nonmutating set { defaults.set(newValue, forKey: Key.homebrew) }
    }
    var useMacAppStore: Bool {
        get { defaults.bool(forKey: Key.macAppStore) }
        nonmutating set { defaults.set(newValue, forKey: Key.macAppStore) }
    }
    var useSparkle: Bool {
        get { defaults.bool(forKey: Key.sparkle) }
        nonmutating set { defaults.set(newValue, forKey: Key.sparkle) }
    }
    var useSystem: Bool {
        get { defaults.bool(forKey: Key.system) }
        nonmutating set { defaults.set(newValue, forKey: Key.system) }
    }
    /// Hours between automatic checks.
    var refreshIntervalHours: Double {
        get { max(1, defaults.double(forKey: Key.interval)) }
        nonmutating set { defaults.set(newValue, forKey: Key.interval) }
    }
    var notifyOnNewUpdates: Bool {
        get { defaults.bool(forKey: Key.notify) }
        nonmutating set { defaults.set(newValue, forKey: Key.notify) }
    }
    /// Days without an open before an app is flagged as unused. 0 disables it.
    var unusedThresholdDays: Int {
        get { defaults.integer(forKey: Key.unusedDays) }
        nonmutating set { defaults.set(newValue, forKey: Key.unusedDays) }
    }

    /// False only until the app has finished launching once. Deliberately absent from
    /// `register(defaults:)` — a missing key reading `false` is the whole point.
    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Key.launched) }
        nonmutating set { defaults.set(newValue, forKey: Key.launched) }
    }

    /// Print commands instead of running them — useful before trusting the app.
    var dryRun: Bool {
        get { defaults.bool(forKey: Key.dryRun) }
        nonmutating set { defaults.set(newValue, forKey: Key.dryRun) }
    }

    var refreshInterval: TimeInterval { refreshIntervalHours * 3600 }

    var sourceOptions: SourceOptions {
        var options = SourceOptions()
        options.homebrew = useHomebrew
        options.macAppStore = useMacAppStore
        options.sparkle = useSparkle
        options.system = useSystem
        return options
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        nonmutating set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Could not change the login item: \(error)")
            }
        }
    }
}
