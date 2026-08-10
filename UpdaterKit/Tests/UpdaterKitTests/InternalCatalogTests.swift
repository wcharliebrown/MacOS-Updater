import Testing
import Foundation
@testable import UpdaterKit

/// Homebrew 6.0.16 replaced `cask.jws.json` with
/// `internal/packages.<arch>_<codename>.jws.json`. The payload is an object keyed by
/// token, `artifacts` became `raw_artifacts` holding Ruby-symbol pairs, and per-OS
/// `variations` are gone. Reading the old path alone silently yields zero casks —
/// which reads as "nothing needs updating".
@Suite("Homebrew internal package index")
struct InternalCatalogTests {

    static let fixture: String = {
        let payload = """
        {"metadata":{},"casks":{
          "iterm2":{"names":["iTerm2"],"version":"3.6.11","homepage":"https://iterm2.com",
            "auto_updates":true,"raw_artifacts":[[":app",["iTerm.app"]]]},
          "zoom":{"names":["Zoom"],"version":"7.1.5.84650","raw_artifacts":[
            [":pkg",["zoomusInstaller.pkg"]],
            [":uninstall",{":launchctl":["us.zoom.ZoomDaemon"],":signal":["KILL","us.zoom.xos"],
              ":delete":["/Applications/zoom.us.app"]}]]},
          "rolling":{"names":["Rolling"],"version":"latest","raw_artifacts":[[":app",["Rolling.app"]]]},
          "oldcask":{"names":["Old"],"version":"1.0","disable_args":{},"raw_artifacts":[[":app",["Old.app"]]]}
        }}
        """
        let escaped = payload
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
        return "{\"payload\":\"\(escaped)\",\"signatures\":[]}"
    }()

    @Test("parses the token-keyed payload")
    func parsesTokenKeyedPayload() throws {
        let catalog = try CaskCatalog.load(data: Data(Self.fixture.utf8), variationKeys: ["tahoe"])
        #expect(catalog.cask(token: "iterm2")?.version == "3.6.11")
        // The token is the dictionary key; there is no `token` field to read.
        #expect(catalog.cask(token: "iterm2")?.name == "iTerm2")
    }

    @Test("reads app names out of raw_artifacts symbol pairs")
    func parsesRawArtifacts() throws {
        let catalog = try CaskCatalog.load(data: Data(Self.fixture.utf8), variationKeys: [])
        #expect(catalog.cask(forAppFileName: "iTerm.app")?.token == "iterm2")
    }

    @Test("still recognises pkg-only casks by bundle id and delete path")
    func parsesUninstallStanza() throws {
        let catalog = try CaskCatalog.load(data: Data(Self.fixture.utf8), variationKeys: [])
        #expect(catalog.cask(forBundleID: "us.zoom.xos")?.token == "zoom")
        #expect(catalog.cask(forBundleID: "us.zoom.ZoomDaemon") == nil)
        #expect(catalog.cask(token: "zoom")?.requiresAdmin == true)
        #expect(catalog.cask(token: "zoom")?.secondaryAppNames == ["zoom.us.app"])
    }

    @Test("drops versionless casks and marks disabled ones")
    func handlesEdgeCases() throws {
        let catalog = try CaskCatalog.load(data: Data(Self.fixture.utf8), variationKeys: [])
        #expect(catalog.cask(token: "rolling") == nil)
        #expect(catalog.cask(token: "oldcask")?.disabled == true)
    }

    /// Runs only where Homebrew has actually written the new index, so the parser is
    /// checked against the real file rather than only against a fixture.
    @Test("parses the real index when Homebrew has written one")
    func parsesRealIndexIfPresent() throws {
        guard let url = CaskCatalog.brewInternalCacheURL() else { return }
        let catalog = try CaskCatalog.load(from: url)
        #expect(catalog.count > 1000)
        #expect(catalog.appIndexCount > 1000)
        // Spot-check an app that is only identifiable through its uninstall stanza.
        #expect(catalog.cask(forBundleID: "us.zoom.xos") != nil)
    }
}
