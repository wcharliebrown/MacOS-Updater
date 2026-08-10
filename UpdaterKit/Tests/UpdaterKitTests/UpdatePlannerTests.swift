import Testing
import Foundation
@testable import UpdaterKit

@Suite("Update planning")
struct UpdatePlannerTests {

    /// A fake Homebrew prefix so the Caskroom check can be exercised without touching
    /// the real one.
    struct FakeBrew {
        let root: URL
        var brewPath: String { root.appendingPathComponent("bin/brew").path }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("brew-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: brewPath, contents: Data())
        }

        func addCaskroomEntry(_ token: String) throws {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Caskroom/\(token)"), withIntermediateDirectories: true)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    static func candidate(
        source: UpdateSource, identifier: String, requiresAdmin: Bool = false,
        bundleID: String? = nil, relation: VersionRelation = .updateAvailable,
        latestVersion: String? = "2.0"
    ) -> UpdateCandidate {
        let app = bundleID.map {
            InstalledApp(url: URL(fileURLWithPath: "/Applications/Example.app"),
                         bundleFileName: "Example.app", displayName: "Example", bundleID: $0,
                         shortVersion: "1.0", bundleVersion: "1.0",
                         isMASInstalled: false, sparkleFeedURL: nil)
        }
        return UpdateCandidate(
            app: app, identifier: identifier, source: source, installedVersion: "1.0",
            latestVersion: latestVersion, relation: relation, confidence: .exact,
            requiresAdmin: requiresAdmin
        )
    }

    @Test("an unmanaged app that is behind is installed over, never adopted")
    func installsOverUnmanagedOutdatedApp() throws {
        // Regression: `--adopt` on an outdated app makes Homebrew record the catalog
        // version while leaving the old bundle in place. Vellum hit exactly this —
        // the Caskroom read 4.1.4 while /Applications/Vellum.app stayed at 4.1.3,
        // after which `brew upgrade` did nothing, forever.
        let brew = try FakeBrew(); defer { brew.cleanup() }
        let plan = UpdatePlanner.plan(
            for: Self.candidate(source: .homebrew, identifier: "vellum"),
            tools: ToolAvailability(homebrewPath: brew.brewPath, masPath: nil),
            runningBundleIDs: []
        )
        #expect(plan.strategy == .homebrewInstallOver)
        #expect(plan.arguments == ["install", "--cask", "--force", "vellum"])
        #expect(!plan.arguments.contains("--adopt"))
        // The user must be told this hands ownership to Homebrew.
        #expect(plan.summary.contains("Homebrew takes over"))
    }

    @Test("an unmanaged app already at the catalog version is adopted")
    func adoptsUnmanagedCurrentApp() throws {
        let brew = try FakeBrew(); defer { brew.cleanup() }
        let plan = UpdatePlanner.plan(
            for: Self.candidate(source: .homebrew, identifier: "iterm2", relation: .upToDate),
            tools: ToolAvailability(homebrewPath: brew.brewPath, masPath: nil),
            runningBundleIDs: []
        )
        #expect(plan.strategy == .homebrewAdopt)
        #expect(plan.arguments == ["install", "--cask", "--adopt", "iterm2"])
    }

    @Test("a stale Homebrew record triggers a reinstall, not a no-op upgrade")
    func reinstallsWhenRecordsAreStale() throws {
        // Homebrew claims 4.1.4 is installed but the bundle is older, so `upgrade`
        // would report "already installed". Only detectable because the real version
        // is read from Info.plist rather than trusted from Homebrew's records.
        let brew = try FakeBrew(); defer { brew.cleanup() }
        try brew.addCaskroomEntry("vellum/4.1.4,41400")
        let plan = UpdatePlanner.plan(
            for: Self.candidate(source: .homebrew, identifier: "vellum",
                                latestVersion: "4.1.4,41400"),
            tools: ToolAvailability(homebrewPath: brew.brewPath, masPath: nil),
            runningBundleIDs: []
        )
        #expect(plan.strategy == .homebrewReinstall)
        #expect(plan.arguments == ["reinstall", "--cask", "vellum"])
    }

    @Test("an app already in the Caskroom is upgraded in place")
    func upgradesManagedApp() throws {
        let brew = try FakeBrew(); defer { brew.cleanup() }
        try brew.addCaskroomEntry("iterm2/3.6.10")
        let plan = UpdatePlanner.plan(
            for: Self.candidate(source: .homebrew, identifier: "iterm2"),
            tools: ToolAvailability(homebrewPath: brew.brewPath, masPath: nil),
            runningBundleIDs: []
        )
        #expect(plan.strategy == .homebrewUpgrade)
        #expect(plan.arguments == ["upgrade", "--cask", "iterm2"])
    }

    @Test("a cask needing root is handed to Terminal, never run silently")
    func adminGoesToTerminal() throws {
        let brew = try FakeBrew(); defer { brew.cleanup() }
        let plan = UpdatePlanner.plan(
            for: Self.candidate(source: .homebrew, identifier: "zoom", requiresAdmin: true),
            tools: ToolAvailability(homebrewPath: brew.brewPath, masPath: nil),
            runningBundleIDs: []
        )
        // Running this in-process would block forever on an invisible sudo prompt.
        #expect(plan.requiresTerminal)
    }

    @Test("a running app is flagged so it can be quit first")
    func detectsRunningApp() throws {
        let brew = try FakeBrew(); defer { brew.cleanup() }
        let plan = UpdatePlanner.plan(
            for: Self.candidate(source: .homebrew, identifier: "tunnelblick",
                                bundleID: "net.tunnelblick.tunnelblick"),
            tools: ToolAvailability(homebrewPath: brew.brewPath, masPath: nil),
            runningBundleIDs: ["net.tunnelblick.tunnelblick"]
        )
        #expect(plan.runningApplicationBundleID == "net.tunnelblick.tunnelblick")
    }

    @Test("missing Homebrew degrades to a manual step instead of a broken command")
    func missingHomebrew() {
        let plan = UpdatePlanner.plan(
            for: Self.candidate(source: .homebrew, identifier: "electrum"),
            tools: ToolAvailability(homebrewPath: nil, masPath: nil), runningBundleIDs: []
        )
        #expect(!plan.strategy.isAutomatic)
        #expect(plan.executable == nil)
    }

    @Test("App Store updates go through mas when the adam id is known")
    func masUpgrade() {
        let plan = UpdatePlanner.plan(
            for: Self.candidate(source: .macAppStore, identifier: "497799835"),
            tools: ToolAvailability(homebrewPath: nil, masPath: "/opt/homebrew/bin/mas"),
            runningBundleIDs: []
        )
        #expect(plan.strategy == .masUpgrade)
        #expect(plan.arguments == ["upgrade", "497799835"])
    }

    @Test("a non-numeric App Store identifier falls back to opening the App Store")
    func masWithoutAdamID() {
        let plan = UpdatePlanner.plan(
            for: Self.candidate(source: .macAppStore, identifier: "com.example.app"),
            tools: ToolAvailability(homebrewPath: nil, masPath: "/opt/homebrew/bin/mas"),
            runningBundleIDs: []
        )
        #expect(!plan.strategy.isAutomatic)
    }

    @Test("system updates always require an administrator")
    func systemUpdate() {
        let plan = UpdatePlanner.plan(
            for: Self.candidate(source: .system, identifier: "macOS Tahoe 26.7-25G100"),
            tools: .detect(), runningBundleIDs: []
        )
        #expect(plan.strategy == .softwareUpdate)
        #expect(plan.requiresTerminal)
    }

    @Test("Sparkle updates are handed off, not installed in place")
    func sparkleIsManual() {
        // This build delegates to package managers; it never swaps app bundles itself.
        let plan = UpdatePlanner.plan(
            for: Self.candidate(source: .sparkle, identifier: "org.xquartz.X11"),
            tools: .detect(), runningBundleIDs: []
        )
        #expect(!plan.strategy.isAutomatic)
    }

    @Test("a dry run reports success without running anything")
    func dryRunExecutes() async throws {
        let brew = try FakeBrew(); defer { brew.cleanup() }
        let plan = UpdatePlanner.plan(
            for: Self.candidate(source: .homebrew, identifier: "electrum"),
            tools: ToolAvailability(homebrewPath: brew.brewPath, masPath: nil), runningBundleIDs: []
        )
        let recorder = LogRecorder()
        let outcome = await UpdateExecutor(dryRun: true).execute(plan) { recorder.append($0) }
        #expect(outcome == .succeeded)
        #expect(recorder.lines.contains { $0.contains("dry run") && $0.contains("--force") })
    }
}

/// Minimal thread-safe log sink for assertions.
final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [String]()

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(line)
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
