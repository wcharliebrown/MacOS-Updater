import Foundation

public enum CaskCatalogError: Error, CustomStringConvertible {
    case sourceNotFound
    case malformed(String)

    public var description: String {
        switch self {
        case .sourceNotFound:
            return "No Homebrew cask catalog found. Install Homebrew, or let the app download the catalog."
        case .malformed(let detail):
            return "Cask catalog is malformed: \(detail)"
        }
    }
}

/// The Homebrew cask catalog, indexed for lookup by installed app bundle name.
///
/// This is the workhorse source: it describes upstream versions for ~7700 apps
/// regardless of how they were installed, which is what makes it possible to detect
/// updates for directly-downloaded apps that expose no update feed of their own.
public struct CaskCatalog: Sendable {
    private let byAppName: [String: Cask]
    private let byBundleID: [String: Cask]
    private let bySecondaryAppName: [String: Cask]
    private let byToken: [String: Cask]

    public var count: Int { byToken.count }
    public var appIndexCount: Int { byAppName.count }
    public var bundleIDIndexCount: Int { byBundleID.count }

    init(casks: [Cask]) {
        var byToken = [String: Cask]()
        var byAppName = [String: Cask]()
        var byBundleID = [String: Cask]()
        var bySecondaryAppName = [String: Cask]()

        // Several casks can claim the same app or bundle id (`firefox` vs
        // `firefox@beta`); `ambiguityRank` keeps the plain, supported one.
        func insert(_ cask: Cask, _ key: String, into index: inout [String: Cask]) {
            if let existing = index[key], existing.ambiguityRank <= cask.ambiguityRank { return }
            index[key] = cask
        }

        for cask in casks {
            byToken[cask.token] = cask
            for appName in cask.appNames { insert(cask, appName.lowercased(), into: &byAppName) }
            for bundleID in cask.bundleIDs { insert(cask, bundleID.lowercased(), into: &byBundleID) }
            for appName in cask.secondaryAppNames { insert(cask, appName.lowercased(), into: &bySecondaryAppName) }
        }
        self.byToken = byToken
        self.byAppName = byAppName
        self.byBundleID = byBundleID
        self.bySecondaryAppName = bySecondaryAppName
    }

    public func cask(forAppFileName name: String) -> Cask? {
        byAppName[name.lowercased()]
    }

    public func cask(forBundleID bundleID: String) -> Cask? {
        byBundleID[bundleID.lowercased()]
    }

    /// Strongest available match: declared app artifact, then bundle id for
    /// pkg-based casks, then — as weak evidence — an `uninstall.delete` path.
    public func match(for app: InstalledApp) -> (cask: Cask, provenance: MatchProvenance)? {
        if let cask = byAppName[app.bundleFileName.lowercased()] {
            return (cask, .appArtifact)
        }
        if let bundleID = app.bundleID?.lowercased(), let cask = byBundleID[bundleID] {
            return (cask, .bundleID)
        }
        if let cask = bySecondaryAppName[app.bundleFileName.lowercased()] {
            return (cask, .deletePath)
        }
        return nil
    }

    public func cask(token: String) -> Cask? {
        byToken[token]
    }

    // MARK: - Loading

    /// Homebrew's own API cache, refreshed whenever the user runs `brew update`.
    public static func brewCacheURL() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Homebrew/api/cask.jws.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Homebrew 6.0.16+ writes a single arch- and release-specific package index in
    /// place of the old `cask.jws.json`.
    public static func brewInternalCacheURL(
        codename: String? = Platform.currentCodename,
        isARM: Bool = Platform.isARM
    ) -> URL? {
        guard let codename else { return nil }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Homebrew/api/internal")
        let arch = isARM ? "arm64_" : ""
        let candidate = directory.appendingPathComponent("packages.\(arch)\(codename).jws.json")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }

        // Fall back to any package index present, rather than failing on a codename
        // this build does not know about yet.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let match = entries.first(where: {
            $0.hasPrefix("packages.") && $0.hasSuffix(".jws.json")
        }) else { return nil }
        return directory.appendingPathComponent(match)
    }

    public static func load(
        from url: URL,
        variationKeys: [String] = Platform.currentVariationKeys
    ) throws -> CaskCatalog {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try load(data: data, variationKeys: variationKeys)
    }

    /// Accepts either the JWS envelope (`cask.jws.json`) or a plain cask array
    /// (`cask.json` from formulae.brew.sh).
    public static func load(data: Data, variationKeys: [String]) throws -> CaskCatalog {
        let root = try JSONSerialization.jsonObject(with: data)
        let rawCasks: [[String: Any]]

        if let array = root as? [[String: Any]] {
            // formulae.brew.sh/api/cask.json — a plain array.
            rawCasks = array
        } else if let envelope = root as? [String: Any],
                  let payload = envelope["payload"] as? String,
                  let payloadData = payload.data(using: .utf8) {
            let decoded = try JSONSerialization.jsonObject(with: payloadData)

            if let array = decoded as? [[String: Any]] {
                // cask.jws.json — the payload is a JSON string holding a cask array.
                rawCasks = array
            } else if let object = decoded as? [String: Any],
                      let casks = object["casks"] as? [String: [String: Any]] {
                // Homebrew 6.0.16+ replaced cask.jws.json with
                // internal/packages.<arch>_<codename>.jws.json, whose payload is an
                // object keyed by token. It carries no `variations`, so it is a lower
                // fidelity source and only used when nothing better is available.
                let parsed = casks.compactMap { Cask(internalRaw: $0.value, token: $0.key) }
                return CaskCatalog(casks: parsed)
            } else {
                throw CaskCatalogError.malformed("JWS payload is neither a cask array nor a package index")
            }
        } else {
            throw CaskCatalogError.malformed("unrecognised top-level structure")
        }

        let casks = rawCasks.compactMap { Cask(raw: $0, variationKeys: variationKeys) }
        return CaskCatalog(casks: casks)
    }
}

extension Cask {
    /// Builds a cask from raw JSON, applying the most specific matching variation.
    init?(raw: [String: Any], variationKeys: [String]) {
        guard let token = raw["token"] as? String else { return nil }

        // Per-OS overrides shadow top-level fields. Most specific key wins.
        var resolved = raw
        if let variations = raw["variations"] as? [String: [String: Any]] {
            for key in variationKeys {
                if let override = variations[key] {
                    resolved.merge(override) { _, new in new }
                    break
                }
            }
        }

        guard let version = resolved["version"] as? String, version != "latest" else {
            // `latest` casks carry no comparable version — brew can never tell whether
            // they are outdated, and neither can we.
            return nil
        }

        self.token = token
        self.name = (resolved["name"] as? [String])?.first ?? token
        self.version = version
        self.homepage = (resolved["homepage"] as? String).flatMap(URL.init(string:))
        self.autoUpdates = resolved["auto_updates"] as? Bool ?? false
        self.deprecated = resolved["deprecated"] as? Bool ?? false
        self.disabled = resolved["disabled"] as? Bool ?? false

        let artifacts = resolved["artifacts"] as? [[String: Any]] ?? []
        var appNames = [String]()
        var bundleIDs = [String]()
        var secondaryAppNames = [String]()
        var needsAdmin = false

        for artifact in artifacts {
            if artifact["pkg"] != nil || artifact["installer"] != nil {
                needsAdmin = true
            }

            if let apps = artifact["app"] as? [Any] {
                for entry in apps {
                    if let name = entry as? String {
                        appNames.append(name)
                    } else if let dict = entry as? [String: Any],
                              let target = dict["target"] as? String {
                        // Renamed on install: the on-disk name is the target.
                        appNames.append((target as NSString).lastPathComponent)
                    }
                }
            }

            for stanza in artifact["uninstall"] as? [[String: Any]] ?? [] {
                // `quit` is the app's own bundle id by convention; `signal` is
                // `[signalName, bundleID]`. `launchctl` names background daemons,
                // which are not app bundle ids, so it is deliberately not indexed.
                bundleIDs.append(contentsOf: Cask.bundleIDStrings(stanza["quit"]))
                bundleIDs.append(contentsOf: Cask.bundleIDStrings(stanza["signal"]))

                // `delete` paths reveal the installed app name for pkg casks,
                // e.g. Zoom's `/Applications/zoom.us.app`.
                for path in Cask.stringList(stanza["delete"]) where path.hasSuffix(".app") && !path.contains("*") {
                    secondaryAppNames.append((path as NSString).lastPathComponent)
                }
            }
        }

        self.appNames = appNames
        self.bundleIDs = bundleIDs
        self.secondaryAppNames = secondaryAppNames
        self.requiresAdmin = needsAdmin
    }
}

extension Cask {
    static func stringList(_ value: Any?) -> [String] {
        if let single = value as? String { return [single] }
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        return []
    }

    /// Filters a stanza value down to things that look like bundle identifiers,
    /// dropping signal names (`KILL`) and wildcards.
    static func bundleIDStrings(_ value: Any?) -> [String] {
        stringList(value).filter { $0.contains(".") && !$0.contains("*") }
    }
}

extension Cask {
    /// Builds a cask from Homebrew's internal package index (6.0.16+).
    ///
    /// That format differs from the public API in three ways that matter: casks are
    /// keyed by token rather than carrying one, `artifacts` becomes `raw_artifacts`
    /// holding Ruby-symbol pairs like `[":app", ["iTerm.app"]]`, and per-OS
    /// `variations` are absent entirely.
    init?(internalRaw raw: [String: Any], token: String) {
        guard let version = raw["version"] as? String, version != "latest" else { return nil }

        self.token = token
        self.name = (raw["names"] as? [String])?.first ?? token
        self.version = version
        self.homepage = (raw["homepage"] as? String).flatMap(URL.init(string:))
        self.autoUpdates = raw["auto_updates"] as? Bool ?? false
        self.deprecated = raw["deprecate_args"] != nil
        self.disabled = raw["disable_args"] != nil

        var appNames = [String]()
        var bundleIDs = [String]()
        var secondaryAppNames = [String]()
        var needsAdmin = false

        for entry in raw["raw_artifacts"] as? [[Any]] ?? [] {
            guard let kind = entry.first as? String else { continue }
            let value: Any? = entry.count > 1 ? entry[1] : nil

            switch kind {
            case ":app":
                for item in Cask.stringList(value) { appNames.append(item) }
                if let dict = value as? [String: Any], let target = dict[":target"] as? String {
                    appNames.append((target as NSString).lastPathComponent)
                }

            case ":pkg", ":installer":
                needsAdmin = true

            case ":uninstall", ":zap":
                guard let stanza = value as? [String: Any] else { break }
                bundleIDs.append(contentsOf: Cask.bundleIDStrings(stanza[":quit"]))
                bundleIDs.append(contentsOf: Cask.bundleIDStrings(stanza[":signal"]))
                for path in Cask.stringList(stanza[":delete"])
                where path.hasSuffix(".app") && !path.contains("*") {
                    secondaryAppNames.append((path as NSString).lastPathComponent)
                }

            default:
                break
            }
        }

        self.appNames = appNames
        self.bundleIDs = bundleIDs
        self.secondaryAppNames = secondaryAppNames
        self.requiresAdmin = needsAdmin
    }
}
