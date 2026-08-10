import Foundation

/// Supplies the cask catalog, preferring Homebrew's own cache and falling back to a
/// direct download for machines where Homebrew is absent or has never run.
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
    let refreshInterval: TimeInterval
    let session: URLSession

    private var cached: CaskCatalog?
    private var cachedOrigin: Origin?

    public init(refreshInterval: TimeInterval = 6 * 3600, session: URLSession = .shared) {
        self.refreshInterval = refreshInterval
        self.session = session
    }

    public static func downloadedCatalogURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacOSUpdater/cask.json")
    }

    public var origin: Origin? { cachedOrigin }

    /// Returns a catalog, downloading one only when Homebrew's cache is unavailable
    /// and the local copy is missing or stale.
    public func catalog(forceRefresh: Bool = false) async throws -> CaskCatalog {
        if let cached, !forceRefresh { return cached }

        // Preference order is by fidelity, not by convenience: only the first two
        // sources carry the per-OS `variations` that keep 1347 casks honest.
        if let brewCache = CaskCatalog.brewCacheURL() {
            let catalog = try CaskCatalog.load(from: brewCache)
            cached = catalog
            cachedOrigin = .homebrewCache(brewCache)
            return catalog
        }

        let local = Self.downloadedCatalogURL()
        if !forceRefresh, let catalog = try? loadIfFresh(at: local) {
            cached = catalog
            cachedOrigin = .downloaded(local)
            return catalog
        }

        do {
            try await download(to: local)
            let catalog = try CaskCatalog.load(from: local)
            cached = catalog
            cachedOrigin = .downloaded(local)
            return catalog
        } catch {
            // Offline, or the API is unreachable. Fall back to whatever is on disk
            // rather than reporting that nothing needs updating.
            if let catalog = try? CaskCatalog.load(from: local) {
                cached = catalog
                cachedOrigin = .downloaded(local)
                return catalog
            }
            if let internalCache = CaskCatalog.brewInternalCacheURL(),
               let catalog = try? CaskCatalog.load(from: internalCache) {
                cached = catalog
                cachedOrigin = .homebrewInternalCache(internalCache)
                return catalog
            }
            throw error
        }
    }

    private func loadIfFresh(at url: URL) throws -> CaskCatalog {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < refreshInterval
        else { throw CaskCatalogError.sourceNotFound }
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
