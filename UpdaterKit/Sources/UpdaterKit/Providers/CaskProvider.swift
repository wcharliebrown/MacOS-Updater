import Foundation

/// Matches installed apps against the Homebrew cask catalog.
///
/// This covers apps brew never installed — the catalog is used purely as a version
/// oracle keyed by bundle file name.
public struct CaskProvider: Sendable {
    let catalog: CaskCatalog
    let overrides: OverrideTable
    /// Skip apps installed from the Mac App Store. Adopting one into Homebrew would
    /// replace the receipted copy with a direct download and detach it from the
    /// App Store's own updates, so `mas` owns these apps instead.
    let skipMASInstalled: Bool
    /// Homebrew's Caskroom, used to tell apps brew actually manages apart from apps
    /// that are only *identified* through its catalog.
    let caskroomRoot: URL?

    public init(
        catalog: CaskCatalog,
        overrides: OverrideTable = .empty,
        skipMASInstalled: Bool = true,
        caskroomRoot: URL? = CaskProvider.defaultCaskroomRoot()
    ) {
        self.catalog = catalog
        self.overrides = overrides
        self.skipMASInstalled = skipMASInstalled
        self.caskroomRoot = caskroomRoot
    }

    public static func defaultCaskroomRoot() -> URL? {
        ProcessRunner.homebrewPath.map {
            URL(fileURLWithPath: $0)
                .deletingLastPathComponent()   // bin
                .deletingLastPathComponent()   // prefix
                .appendingPathComponent("Caskroom")
        }
    }

    public func candidates(for apps: [InstalledApp]) -> [UpdateCandidate] {
        apps.compactMap { candidate(for: $0) }
    }

    public func candidate(for app: InstalledApp) -> UpdateCandidate? {
        let override = overrides.override(for: app.bundleID)
        if override?.ignore == true { return nil }
        if skipMASInstalled && app.isMASInstalled { return nil }

        // An explicit token beats any inferred match.
        let cask: Cask
        let provenance: MatchProvenance
        if let token = override?.token, let overridden = catalog.cask(token: token) {
            cask = overridden
            provenance = .appArtifact
        } else if let match = catalog.match(for: app) {
            cask = match.cask
            provenance = match.provenance
        } else {
            return nil
        }

        var comparison = VersionComparator.evaluate(
            shortVersion: app.shortVersion,
            bundleVersion: app.bundleVersion,
            upstream: cask.version,
            override: override
        )

        // A `delete`-path match proves only that the cask touches this app, not that
        // the app is versioned by it, so it can confirm a match but never assert one
        // is behind. Without this, `anaconda` reports Anaconda-Navigator 2.7.1 as
        // outdated against the distribution version 2025.06-1.
        if !provenance.isStrong, comparison.relation == .updateAvailable {
            comparison = VersionComparison(
                relation: .unknown,
                confidence: .none,
                comparedInstalled: comparison.comparedInstalled,
                comparedUpstream: comparison.comparedUpstream
            )
        }

        // Managed means *this bundle* is the one brew installed. Brew's appdir is
        // /Applications; a duplicate copy elsewhere (e.g. ~/Applications) must not
        // wear the Homebrew label just because it shares a bundle name with a cask —
        // acting on it through brew would hit the /Applications copy instead.
        let inBrewAppdir = app.url.deletingLastPathComponent().path == "/Applications"
        let managed = inBrewAppdir && (caskroomRoot.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(cask.token).path)
        } ?? false)

        return UpdateCandidate(
            app: app,
            identifier: cask.token,
            source: .homebrew,
            installedVersion: app.displayVersion,
            latestVersion: cask.version,
            relation: comparison.relation,
            confidence: comparison.confidence,
            selfUpdating: cask.autoUpdates,
            managedByHomebrew: managed,
            requiresAdmin: cask.requiresAdmin,
            homepage: cask.homepage
        )
    }
}
