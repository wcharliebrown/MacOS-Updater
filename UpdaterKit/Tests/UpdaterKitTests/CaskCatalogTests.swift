import Testing
import Foundation
@testable import UpdaterKit

@Suite("Cask catalog")
struct CaskCatalogTests {

    /// Mirrors the real catalog's shapes: a JWS envelope whose payload is a JSON
    /// *string*, per-OS `variations`, dict-form app entries, and pkg-only casks that
    /// can only be identified through their `uninstall` stanza.
    static let fixture: String = {
        let casks = """
        [
          {"token":"iterm2","name":["iTerm2"],"version":"3.6.11","homepage":"https://iterm2.com",
           "auto_updates":true,"artifacts":[{"app":["iTerm.app"]}]},
          {"token":"thorium","name":["Thorium"],"version":"1.0","artifacts":[
           {"app":[{"target":"Thorium Browser.app"}]}]},
          {"token":"zoom","name":["Zoom"],"version":"7.1.5.84650","artifacts":[
           {"pkg":["zoom.pkg"]},
           {"uninstall":[{"launchctl":["us.zoom.ZoomDaemon"],"signal":["KILL","us.zoom.xos"],
            "delete":["/Applications/zoom.us.app"]}]}]},
          {"token":"anaconda","name":["Anaconda"],"version":"2026.07-1","artifacts":[
           {"uninstall":[{"delete":["/Applications/Anaconda-Navigator.app"]}]}],
           "variations":{"tahoe":{"version":"2025.06-1"}}},
          {"token":"someapp-latest","name":["Rolling"],"version":"latest","artifacts":[{"app":["Rolling.app"]}]},
          {"token":"firefox","name":["Firefox"],"version":"153.0.3","artifacts":[{"app":["Firefox.app"]}]},
          {"token":"firefox@beta","name":["Firefox Beta"],"version":"154.0b1","artifacts":[{"app":["Firefox.app"]}]}
        ]
        """
        let escaped = casks
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
        return "{\"payload\":\"\(escaped)\",\"signatures\":[]}"
    }()

    static func catalog(variationKeys: [String] = []) throws -> CaskCatalog {
        try CaskCatalog.load(data: Data(fixture.utf8), variationKeys: variationKeys)
    }

    @Test("unwraps the JWS payload")
    func parsesJWS() throws {
        let catalog = try Self.catalog()
        #expect(catalog.cask(token: "iterm2")?.version == "3.6.11")
    }

    @Test("indexes apps declared as artifacts")
    func appArtifactIndex() throws {
        let catalog = try Self.catalog()
        #expect(catalog.cask(forAppFileName: "iTerm.app")?.token == "iterm2")
    }

    @Test("handles the dict form of an app artifact")
    func dictAppArtifact() throws {
        let catalog = try Self.catalog()
        #expect(catalog.cask(forAppFileName: "Thorium Browser.app")?.token == "thorium")
    }

    @Test("identifies a pkg-only cask by the bundle id in its uninstall stanza")
    func bundleIDIndex() throws {
        let catalog = try Self.catalog()
        // `signal` carries the app's bundle id; `launchctl` names a daemon and must not.
        #expect(catalog.cask(forBundleID: "us.zoom.xos")?.token == "zoom")
        #expect(catalog.cask(forBundleID: "us.zoom.ZoomDaemon") == nil)
    }

    @Test("applies the variation matching this machine")
    func variationOverride() throws {
        // 1347 casks override `version` per-OS; ignoring them invents phantom updates.
        let plain = try Self.catalog()
        #expect(plain.cask(token: "anaconda")?.version == "2026.07-1")

        let tahoe = try Self.catalog(variationKeys: ["arm64_tahoe", "tahoe"])
        #expect(tahoe.cask(token: "anaconda")?.version == "2025.06-1")
    }

    @Test("drops casks with no comparable version")
    func skipsLatest() throws {
        let catalog = try Self.catalog()
        #expect(catalog.cask(token: "someapp-latest") == nil)
    }

    @Test("prefers the plain cask over a channel variant")
    func ambiguityResolution() throws {
        let catalog = try Self.catalog()
        #expect(catalog.cask(forAppFileName: "Firefox.app")?.token == "firefox")
    }

    @Test("ranks a delete-path match below a real app artifact")
    func provenanceOrdering() throws {
        let catalog = try Self.catalog(variationKeys: ["tahoe"])

        let zoom = InstalledApp(
            url: URL(fileURLWithPath: "/Applications/zoom.us.app"), bundleFileName: "zoom.us.app",
            displayName: "zoom.us", bundleID: "us.zoom.xos", shortVersion: "7.1.5 (84650)",
            bundleVersion: "7.1.5.84650", isMASInstalled: false, sparkleFeedURL: nil)
        #expect(catalog.match(for: zoom)?.provenance == .bundleID)

        let navigator = InstalledApp(
            url: URL(fileURLWithPath: "/Applications/Anaconda-Navigator.app"),
            bundleFileName: "Anaconda-Navigator.app", displayName: "Anaconda-Navigator",
            bundleID: "com.anaconda.navigator", shortVersion: "2.7.1", bundleVersion: "2.7.1",
            isMASInstalled: false, sparkleFeedURL: nil)
        #expect(catalog.match(for: navigator)?.provenance == .deletePath)
    }

    @Test("a weak match never claims an app is outdated")
    func weakProvenanceCannotAssertUpdate() throws {
        let catalog = try Self.catalog(variationKeys: ["tahoe"])
        let provider = CaskProvider(catalog: catalog)

        // Anaconda-Navigator 2.7.1 vs the distribution's 2025.06-1 — different schemes.
        let navigator = InstalledApp(
            url: URL(fileURLWithPath: "/Applications/Anaconda-Navigator.app"),
            bundleFileName: "Anaconda-Navigator.app", displayName: "Anaconda-Navigator",
            bundleID: "com.anaconda.navigator", shortVersion: "2.7.1", bundleVersion: "2.7.1",
            isMASInstalled: false, sparkleFeedURL: nil)

        let candidate = try #require(provider.candidate(for: navigator))
        #expect(candidate.relation == .unknown)
    }

    @Test("App Store installs are left to mas")
    func masInstallsSkipped() throws {
        let catalog = try Self.catalog()
        let provider = CaskProvider(catalog: catalog)
        // Adopting a receipted app into Homebrew would detach it from App Store updates.
        let firefox = InstalledApp(
            url: URL(fileURLWithPath: "/Applications/Firefox.app"), bundleFileName: "Firefox.app",
            displayName: "Firefox", bundleID: "org.mozilla.firefox", shortVersion: "150.0",
            bundleVersion: "150.0", isMASInstalled: true, sparkleFeedURL: nil)
        #expect(provider.candidate(for: firefox) == nil)
    }
}

@Suite("Platform")
struct PlatformTests {
    @Test("maps macOS majors to Homebrew codenames")
    func codenames() {
        #expect(Platform.codename(forMajor: 26, minor: 6) == "tahoe")
        #expect(Platform.codename(forMajor: 15, minor: 0) == "sequoia")
        #expect(Platform.codename(forMajor: 10, minor: 15) == "catalina")
        #expect(Platform.codename(forMajor: 99, minor: 0) == nil)
    }

    @Test("tries the arch-specific variation first")
    func variationOrdering() {
        #expect(Platform.variationKeys(codename: "tahoe", isARM: true) == ["arm64_tahoe", "tahoe"])
        #expect(Platform.variationKeys(codename: "tahoe", isARM: false) == ["tahoe"])
        #expect(Platform.variationKeys(codename: nil, isARM: true).isEmpty)
    }
}

@Suite("Catalog staleness")
struct CatalogStalenessTests {

    /// The bug this guards against: the app trusted Homebrew's cache no matter how
    /// old it was, and since every brew invocation sets HOMEBREW_NO_AUTO_UPDATE=1,
    /// nothing ever refreshed it — updates were silently missed for days.
    @Test("a file older than maxAge is stale, a fresh one is not")
    func staleByAge() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("staleness-\(UUID().uuidString).json")
        try Data("[]".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date()
        #expect(!CatalogStore.isStale(url, olderThan: 3600, now: now))
        #expect(CatalogStore.isStale(url, olderThan: 3600, now: now.addingTimeInterval(2 * 3600)))
    }

    @Test("a missing file is always stale")
    func missingFileIsStale() {
        let url = URL(fileURLWithPath: "/nonexistent/cask.jws.json")
        #expect(CatalogStore.isStale(url, olderThan: .greatestFiniteMagnitude))
    }
}
