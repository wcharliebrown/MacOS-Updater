import Foundation

/// How an installed app was matched to a cask, strongest first.
public enum MatchProvenance: Sendable, Hashable {
    /// The cask declares an `app` artifact with this bundle name.
    case appArtifact
    /// The cask names this bundle id in its `uninstall` stanza.
    case bundleID
    /// Only an `uninstall.delete` path mentions this app. Weak.
    case deletePath

    public var isStrong: Bool { self != .deletePath }
}

/// One cask from the Homebrew catalog, reduced to the fields this app needs,
/// with per-OS variations already resolved for the running machine.
public struct Cask: Sendable, Hashable {
    public let token: String
    public let name: String
    public let version: String
    public let homepage: URL?
    /// Cask declares `auto_updates` — the app updates itself, so brew only reports
    /// it as outdated under `--greedy`, and its installed version may legitimately
    /// run ahead of the catalog.
    public let autoUpdates: Bool
    /// App bundle file names this cask installs, e.g. `"iTerm.app"`.
    public let appNames: [String]
    /// Bundle identifiers the cask names in its `uninstall` stanza. For casks that
    /// install via `pkg` there is no `app` artifact to index, so these are the only
    /// way to recognise the installed app (Zoom, Arq, ExpressVPN).
    public let bundleIDs: [String]
    /// App names recovered from `uninstall.delete` paths. Weak evidence: it means the
    /// cask *touches* the app, not that the app carries the cask's version. The
    /// `anaconda` cask deletes `Anaconda-Navigator.app`, but that app is a component
    /// versioned 2.7.1 against a distribution versioned 2025.06-1.
    public let secondaryAppNames: [String]
    /// Ships a `pkg` or `installer` artifact, so installing needs admin rights.
    public let requiresAdmin: Bool
    public let deprecated: Bool
    public let disabled: Bool

    /// Preference when several casks install the same app bundle name
    /// (`firefox` vs `firefox@beta` vs `firefox@nightly`). Lower wins.
    var ambiguityRank: (Int, Int, Int, String) {
        (disabled ? 1 : 0, deprecated ? 1 : 0, token.contains("@") ? 1 : 0, token)
    }
}
