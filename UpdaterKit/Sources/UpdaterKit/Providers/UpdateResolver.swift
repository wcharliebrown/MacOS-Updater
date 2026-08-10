import Foundation

/// Which detection sources to consult.
public struct SourceOptions: Sendable, Hashable {
    public var homebrew = true
    public var macAppStore = true
    public var sparkle = true
    public var system = true

    public init() {}
    public static let all = SourceOptions()
}

/// What the app knows about the tools it depends on, so missing dependencies can be
/// reported to the user instead of silently producing an empty list.
public struct ToolAvailability: Sendable, Hashable {
    public let homebrewPath: String?
    public let masPath: String?

    public var hasHomebrew: Bool { homebrewPath != nil }
    public var hasMAS: Bool { masPath != nil }

    public static func detect() -> ToolAvailability {
        ToolAvailability(homebrewPath: ProcessRunner.homebrewPath, masPath: ProcessRunner.masPath)
    }
}

public struct UpdateReport: Sendable {
    public let candidates: [UpdateCandidate]
    /// Apps no source could speak to at all.
    public let unmatched: [InstalledApp]
    public let scannedAppCount: Int
    public let tools: ToolAvailability
    public let catalogCount: Int

    public var outdated: [UpdateCandidate] {
        candidates.filter { $0.relation == .updateAvailable }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
    public var upToDate: [UpdateCandidate] { candidates.filter { $0.relation == .upToDate } }
    /// Matched to a source, but the versions could not be reconciled. Shown separately
    /// rather than being quietly counted as current.
    public var undetermined: [UpdateCandidate] { candidates.filter { $0.relation == .unknown } }
    public var newerThanCatalog: [UpdateCandidate] { candidates.filter { $0.relation == .ahead } }
    public var systemUpdates: [UpdateCandidate] { candidates.filter { $0.source == .system } }
}

/// Runs every enabled source and reconciles their answers into one list.
public struct UpdateResolver: Sendable {
    let catalog: CaskCatalog?
    let overrides: OverrideTable
    let options: SourceOptions

    public init(catalog: CaskCatalog?, overrides: OverrideTable = .empty, options: SourceOptions = .all) {
        self.catalog = catalog
        self.overrides = overrides
        self.options = options
    }

    public func resolve(apps: [InstalledApp]? = nil) async -> UpdateReport {
        let installed = apps ?? InstalledAppScanner().scan()
        let tools = ToolAvailability.detect()

        // Sources are independent; run them concurrently.
        async let masCandidates: [UpdateCandidate] =
            options.macAppStore ? MASProvider().candidates(installed: installed) : []
        async let systemCandidates: [UpdateCandidate] =
            options.system ? SystemProvider().candidates() : []
        async let sparkleCandidates: [UpdateCandidate] =
            options.sparkle ? SparkleProvider().candidates(for: installed) : []

        let caskCandidates: [UpdateCandidate]
        if options.homebrew, let catalog {
            caskCandidates = CaskProvider(catalog: catalog, overrides: overrides).candidates(for: installed)
        } else {
            caskCandidates = []
        }

        let mas = await masCandidates
        let system = await systemCandidates
        let sparkle = await sparkleCandidates

        var resolved = [UpdateCandidate]()
        var claimed = Set<InstalledApp>()

        // 1. Mac App Store wins for any app it reports — those apps carry a receipt and
        //    must keep updating through the App Store.
        for candidate in mas {
            resolved.append(candidate)
            if let app = candidate.app { claimed.insert(app) }
        }

        // 2. The cask catalog is the workhorse for everything else.
        for candidate in caskCandidates {
            guard let app = candidate.app, !claimed.contains(app) else { continue }
            resolved.append(candidate)
            claimed.insert(app)
        }

        // 3. Sparkle fills the remaining gaps only. Where a cask already covers an app
        //    the curated version is preferred: vendor feeds carry prerelease channels
        //    and stale URLs that produce noisier results.
        for candidate in sparkle {
            guard let app = candidate.app, !claimed.contains(app) else { continue }
            resolved.append(candidate)
            claimed.insert(app)
        }

        resolved.append(contentsOf: system)

        // Apps that carry an App Store receipt are accounted for even when `mas`
        // reported nothing about them — silence from mas means "current".
        let unmatched = installed.filter { !claimed.contains($0) && !$0.isMASInstalled }

        return UpdateReport(
            candidates: resolved,
            unmatched: unmatched,
            scannedAppCount: installed.count,
            tools: tools,
            catalogCount: catalog?.count ?? 0
        )
    }
}
