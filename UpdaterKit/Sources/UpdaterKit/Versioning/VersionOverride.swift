import Foundation

/// Per-app corrections for the cases where a cask's version scheme and the app's
/// `Info.plist` cannot be reconciled by the general rules.
public struct VersionOverride: Sendable, Codable, Hashable {
    /// Force a specific cask token instead of matching by bundle file name.
    public var token: String?
    /// Which Info.plist key to compare: `short`, `bundle`, or `auto` (default).
    public var versionKey: VersionKey?
    /// Drop this many leading components from the installed version.
    public var dropLeadingSegments: Int?
    /// Trim trailing `.0` components from both sides before comparing.
    public var trimTrailingZeros: Bool?
    /// Never report this app at all.
    public var ignore: Bool?

    public enum VersionKey: String, Sendable, Codable {
        case short, bundle, auto
    }
}

/// Loads the bundled override table, merged with a user-editable file in
/// Application Support so quirks can be fixed without shipping a new build.
public struct OverrideTable: Sendable {
    private let byBundleID: [String: VersionOverride]

    public init(byBundleID: [String: VersionOverride]) {
        self.byBundleID = byBundleID
    }

    public func override(for bundleID: String?) -> VersionOverride? {
        guard let bundleID else { return nil }
        return byBundleID[bundleID]
    }

    public static let empty = OverrideTable(byBundleID: [:])

    public static func bundled() -> OverrideTable {
        guard let url = Bundle.module.url(forResource: "Overrides", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: VersionOverride].self, from: data)
        else {
            return .empty
        }
        return OverrideTable(byBundleID: decoded)
    }

    /// `~/Library/Application Support/MacOSUpdater/Overrides.json`, if present,
    /// takes precedence over bundled entries.
    public static func userOverrideURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacOSUpdater/Overrides.json")
    }

    public static func loadMerged() -> OverrideTable {
        var merged = [String: VersionOverride]()
        if let url = Bundle.module.url(forResource: "Overrides", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: VersionOverride].self, from: data) {
            merged = decoded
        }
        if let data = try? Data(contentsOf: userOverrideURL()),
           let decoded = try? JSONDecoder().decode([String: VersionOverride].self, from: data) {
            merged.merge(decoded) { _, user in user }
        }
        return OverrideTable(byBundleID: merged)
    }
}
