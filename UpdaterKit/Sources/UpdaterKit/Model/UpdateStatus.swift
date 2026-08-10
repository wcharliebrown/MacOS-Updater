import Foundation

/// Where an update candidate's information came from.
public enum UpdateSource: String, Sendable, Codable, CaseIterable {
    case homebrew
    case macAppStore
    case sparkle
    case system
}

/// How confident we are that installed and upstream versions were compared correctly.
public enum MatchConfidence: String, Sendable, Codable {
    /// A version candidate compared equal or ordered cleanly.
    case exact
    /// Matched only via a looser rule (segment-suffix, override transform).
    case heuristic
    /// The two version strings could not be reconciled.
    case none
}

public enum VersionRelation: String, Sendable, Codable {
    case upToDate
    case updateAvailable
    /// Installed version is newer than upstream — typically a beta channel.
    /// Never offer a downgrade in this state.
    case ahead
    case unknown
}

/// The result of comparing one installed app against one upstream source.
public struct UpdateCandidate: Sendable, Hashable, Identifiable {
    public var id: String { (app?.id ?? "") + "|" + source.rawValue + "|" + identifier }

    public let app: InstalledApp?
    /// Token / adam ID / softwareupdate label, depending on `source`.
    public let identifier: String
    public let source: UpdateSource
    public let installedVersion: String?
    public let latestVersion: String?
    public let relation: VersionRelation
    public let confidence: MatchConfidence
    /// The app ships its own updater (cask `auto_updates`), so it may fix itself.
    public let selfUpdating: Bool
    /// Homebrew's Caskroom has an entry for this app — brew actually installed or
    /// adopted it. False for apps that were installed by hand and merely *identified*
    /// through the cask catalog; showing those as "Homebrew" misdescribes them.
    public let managedByHomebrew: Bool
    /// Installing requires admin rights — cannot be done from a GUI subprocess.
    public let requiresAdmin: Bool
    public let homepage: URL?

    public init(
        app: InstalledApp?,
        identifier: String,
        source: UpdateSource,
        installedVersion: String?,
        latestVersion: String?,
        relation: VersionRelation,
        confidence: MatchConfidence,
        selfUpdating: Bool = false,
        managedByHomebrew: Bool = false,
        requiresAdmin: Bool = false,
        homepage: URL? = nil
    ) {
        self.app = app
        self.identifier = identifier
        self.source = source
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.relation = relation
        self.confidence = confidence
        self.selfUpdating = selfUpdating
        self.managedByHomebrew = managedByHomebrew
        self.requiresAdmin = requiresAdmin
        self.homepage = homepage
    }

    public var displayName: String {
        app?.displayName ?? identifier
    }
}
