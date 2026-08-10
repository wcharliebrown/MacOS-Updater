import Foundation

/// Finds application bundles on disk and reads the metadata needed to identify them.
public struct InstalledAppScanner: Sendable {
    /// Locations scanned by default. `/System/Applications` is deliberately excluded:
    /// those ship with macOS and are updated by `softwareupdate`, not by us.
    public static var defaultSearchPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
        ]
    }

    public let searchPaths: [URL]

    public init(searchPaths: [URL] = InstalledAppScanner.defaultSearchPaths) {
        self.searchPaths = searchPaths
    }

    public func scan() -> [InstalledApp] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var apps = [InstalledApp]()

        for directory in searchPaths {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries where entry.pathExtension == "app" {
                let path = entry.resolvingSymlinksInPath().path
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                if let app = Self.readBundle(at: entry) { apps.append(app) }
            }
        }

        return apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Reads `Contents/Info.plist` directly rather than going through `Bundle`, which
    /// caches every bundle it touches for the process lifetime.
    static func readBundle(at url: URL) -> InstalledApp? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return nil }

        let bundleID = plist["CFBundleIdentifier"] as? String
        let fileName = url.lastPathComponent
        let displayName = (fileName as NSString).deletingPathExtension
        let receiptURL = url.appendingPathComponent("Contents/_MASReceipt/receipt")
        let isMASInstalled = FileManager.default.fileExists(atPath: receiptURL.path)

        // Apple's bundled apps are `softwareupdate`'s business, not ours — but Apple
        // apps bought from the App Store (Xcode, Keynote, Numbers, Pages, iMovie) do
        // carry a receipt and must stay in the list.
        if let bundleID, bundleID.hasPrefix("com.apple."), !isMASInstalled { return nil }

        // Never list ourselves — offering Update/Remove on the running updater from
        // inside itself is a footgun, not a feature.
        if bundleID == "com.dialogs.MacOSUpdater" { return nil }

        return InstalledApp(
            url: url,
            bundleFileName: fileName,
            displayName: displayName,
            bundleID: bundleID,
            shortVersion: (plist["CFBundleShortVersionString"] as? String)?
                .trimmingCharacters(in: .whitespaces),
            bundleVersion: (plist["CFBundleVersion"] as? String)?
                .trimmingCharacters(in: .whitespaces),
            isMASInstalled: isMASInstalled,
            sparkleFeedURL: (plist["SUFeedURL"] as? String).flatMap(URL.init(string:)),
            lastUsedDate: NSMetadataItem(url: url)?
                .value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
        )
    }
}
