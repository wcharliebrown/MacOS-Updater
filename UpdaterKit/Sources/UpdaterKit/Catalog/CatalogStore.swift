import Foundation

/// Supplies the cask catalog, preferring Homebrew's own cache and falling back to a
/// direct download for machines where Homebrew is absent or has never run. Keeps the
/// catalog fresh by running `brew update` when the cache is older than the refresh
/// interval — Homebrew itself never refreshes it unless the user runs brew by hand.
public actor CatalogStore {
    public enum Origin: Sendable, Equatable {
        case homebrewCache(URL)
        case downloaded(URL)
        /// Homebrew 6.0.16+ internal index. Carries no per-OS `variations`, so a few
        /// casks report a version that does not apply to this macOS release.
        case homebrewInternalCache(URL)

        public var hasVariationData: Bool {
            if case .homebrewInternalCache = self { return false }
            return true
        }
    }

    static let remoteURL = URL(string: "https://formulae.brew.sh/api/cask.json")!
    /// How stale a catalog a forced refresh will tolerate — long enough to debounce
    /// repeated clicks on the refresh button, short enough to be honest.
    static let forcedMaxAge: TimeInterval = 5 * 60
    let refreshInterval: TimeInterval
    let session: URLSession

    private var cached: CaskCatalog?
    private var cachedOrigin: Origin?
    private var loadedAt: Date?

    public init(refreshInterval: TimeInterval = 6 * 3600, session: URLSession = .shared) {
        self.refreshInterval = refreshInterval
        self.session = session
    }

    public static func downloadedCatalogURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacOSUpdater/cask.json")
    }

    public var origin: Origin? { cachedOrigin }

    /// Returns a catalog no older than `refreshInterval`, running `brew update` (or
    /// downloading a fresh copy where Homebrew is absent) when the one on disk has
    /// gone stale. A forced refresh tolerates only `forcedMaxAge` of staleness.
    public func catalog(
        forceRefresh: Bool = false,
        log: (@Sendable (String) -> Void)? = nil
    ) async throws -> CaskCatalog {
        let maxAge = forceRefresh ? Self.forcedMaxAge : refreshInterval
        if let cached, !forceRefresh, let loadedAt,
           Date().timeIntervalSince(loadedAt) < refreshInterval {
            return cached
        }

        // Homebrew refreshes its API cache only when the user runs `brew update`
        // themselves (every brew invocation here sets HOMEBREW_NO_AUTO_UPDATE=1), so
        // without this step the catalog drifts stale indefinitely and updates are
        // silently missed.
        if let brew = ProcessRunner.homebrewPath {
            await runBrewUpdateIfStale(brew: brew, maxAge: maxAge, log: log)
        }

        // Preference order is by fidelity, not by convenience: only the first two
        // sources carry the per-OS `variations` that keep 1347 casks honest.
        if let brewCache = CaskCatalog.brewCacheURL() {
            let catalog = try CaskCatalog.load(from: brewCache)
            log?("Catalog: Homebrew cache, updated \(Self.ageDescription(of: brewCache)).")
            store(catalog, origin: .homebrewCache(brewCache))
            return catalog
        }

        let local = Self.downloadedCatalogURL()
        if let catalog = try? loadIfFresh(at: local, maxAge: maxAge) {
            log?("Catalog: downloaded copy, updated \(Self.ageDescription(of: local)).")
            store(catalog, origin: .downloaded(local))
            return catalog
        }

        do {
            log?("Downloading the cask catalog…")
            try await download(to: local)
            let catalog = try CaskCatalog.load(from: local)
            store(catalog, origin: .downloaded(local))
            return catalog
        } catch {
            // Offline, or the API is unreachable. Fall back to whatever is on disk
            // rather than reporting that nothing needs updating.
            if let catalog = try? CaskCatalog.load(from: local) {
                log?("Catalog download failed — using the copy from \(Self.ageDescription(of: local)).")
                store(catalog, origin: .downloaded(local))
                return catalog
            }
            if let internalCache = CaskCatalog.brewInternalCacheURL(),
               let catalog = try? CaskCatalog.load(from: internalCache) {
                store(catalog, origin: .homebrewInternalCache(internalCache))
                return catalog
            }
            throw error
        }
    }

    private func store(_ catalog: CaskCatalog, origin: Origin) {
        cached = catalog
        cachedOrigin = origin
        loadedAt = Date()
    }

    /// Runs `brew update` when Homebrew's API cache is missing or older than
    /// `maxAge`. Homebrew 6.0.16+ deletes the legacy `cask.jws.json` and maintains
    /// only the internal package index, so either file being fresh counts — the
    /// update also keeps `brew outdated` honest, which reads the same caches.
    /// Failure (offline, another brew holding the lock) is logged and swallowed —
    /// a stale catalog still beats no catalog.
    private func runBrewUpdateIfStale(
        brew: String, maxAge: TimeInterval, log: (@Sendable (String) -> Void)?
    ) async {
        let caches = [CaskCatalog.brewCacheURL(), CaskCatalog.brewInternalCacheURL()]
            .compactMap { $0 }
        if caches.contains(where: { !Self.isStale($0, olderThan: maxAge) }) {
            return
        }
        log?("Refreshing the Homebrew catalog (brew update)…")
        do {
            let result = try await ProcessRunner().run(
                brew, arguments: ["update", "--quiet"], timeout: 600)
            if !result.succeeded {
                log?("brew update exited \(result.exitCode) — continuing with the current catalog.")
            }
        } catch {
            log?("brew update failed (\(error)) — continuing with the current catalog.")
        }
    }

    static func isStale(_ url: URL, olderThan maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else { return true }
        return now.timeIntervalSince(modified) >= maxAge
    }

    static func ageDescription(of url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else { return "an unknown time ago" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: modified, relativeTo: Date())
    }

    private func loadIfFresh(at url: URL, maxAge: TimeInterval) throws -> CaskCatalog {
        guard !Self.isStale(url, olderThan: maxAge) else { throw CaskCatalogError.sourceNotFound }
        return try CaskCatalog.load(from: url)
    }

    private func download(to destination: URL) async throws {
        let (data, response) = try await session.data(from: Self.remoteURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CaskCatalogError.malformed("catalog download returned a non-200 response")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }
}
