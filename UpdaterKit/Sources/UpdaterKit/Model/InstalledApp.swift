import Foundation

/// An application bundle discovered on disk.
public struct InstalledApp: Sendable, Hashable, Identifiable {
    public var id: String { url.path }

    public let url: URL
    /// Bundle file name including the `.app` extension, e.g. `"Google Chrome.app"`.
    /// This is the key the Homebrew cask catalog indexes apps by.
    public let bundleFileName: String
    /// Human-facing name, e.g. `"Google Chrome"`.
    public let displayName: String
    public let bundleID: String?
    public let shortVersion: String?
    public let bundleVersion: String?
    /// A `Contents/_MASReceipt/receipt` is present — the reliable Mac App Store signal.
    public let isMASInstalled: Bool
    /// `SUFeedURL` from Info.plist, when the app ships Sparkle.
    public let sparkleFeedURL: URL?
    /// Spotlight's `kMDItemLastUsedDate` — the "Last Opened" date Finder shows.
    /// nil when Spotlight has no usage record, which is common even for apps that
    /// have been used; nil therefore means "unknown", never "unused".
    public let lastUsedDate: Date?

    public init(
        url: URL,
        bundleFileName: String,
        displayName: String,
        bundleID: String?,
        shortVersion: String?,
        bundleVersion: String?,
        isMASInstalled: Bool,
        sparkleFeedURL: URL?,
        lastUsedDate: Date? = nil
    ) {
        self.url = url
        self.bundleFileName = bundleFileName
        self.displayName = displayName
        self.bundleID = bundleID
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
        self.isMASInstalled = isMASInstalled
        self.sparkleFeedURL = sparkleFeedURL
        self.lastUsedDate = lastUsedDate
    }

    /// Best available version string for display.
    public var displayVersion: String {
        shortVersion ?? bundleVersion ?? "—"
    }

    /// Whole days since the app was last opened, per Spotlight's records.
    /// nil when there is no record — deliberately not treated as unused, because
    /// absence of data is not evidence of absence of use.
    public func unusedDays(asOf now: Date = Date()) -> Int? {
        guard let lastUsedDate else { return nil }
        return max(0, Int(now.timeIntervalSince(lastUsedDate) / 86_400))
    }
}
