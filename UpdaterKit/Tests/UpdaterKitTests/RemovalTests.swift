import Testing
import Foundation
@testable import UpdaterKit

@Suite("Removal")
struct RemovalTests {

    static func installedApp(
        name: String = "Example", directory: String = "/Applications"
    ) -> InstalledApp {
        InstalledApp(
            url: URL(fileURLWithPath: "\(directory)/\(name).app"),
            bundleFileName: "\(name).app", displayName: name,
            bundleID: "com.example.\(name.lowercased())",
            shortVersion: "1.0", bundleVersion: "1.0",
            isMASInstalled: false, sparkleFeedURL: nil
        )
    }

    @Test("a brew-managed app is uninstalled through Homebrew")
    func brewManagedUsesUninstall() throws {
        let brew = try UpdatePlannerTests.FakeBrew(); defer { brew.cleanup() }
        try brew.addCaskroomEntry("electrum/4.8.0")

        let plan = RemovalPlanner.plan(
            for: Self.installedApp(name: "Electrum"),
            candidate: UpdatePlannerTests.candidate(source: .homebrew, identifier: "electrum"),
            tools: ToolAvailability(homebrewPath: brew.brewPath, masPath: nil)
        )
        #expect(plan.method == .homebrewUninstall)
        #expect(plan.arguments == ["uninstall", "--cask", "electrum"])
    }

    @Test("an app brew does not manage is trashed, not brew-uninstalled")
    func unmanagedFallsBackToTrash() throws {
        // `brew uninstall` on an app outside the Caskroom would just error.
        let brew = try UpdatePlannerTests.FakeBrew(); defer { brew.cleanup() }
        let plan = RemovalPlanner.plan(
            for: Self.installedApp(name: "Tunnelblick"),
            candidate: UpdatePlannerTests.candidate(source: .homebrew, identifier: "tunnelblick"),
            tools: ToolAvailability(homebrewPath: brew.brewPath, masPath: nil)
        )
        #expect(plan.method == .trash)
    }

    @Test("apps with no update source can still be removed — to the Trash")
    func untrackedGoesToTrash() {
        let plan = RemovalPlanner.plan(for: Self.installedApp(name: "Homesick"), candidate: nil)
        #expect(plan.method == .trash)
        #expect(plan.summary.contains("Trash"))
    }

    @Test("an admin cask's uninstall is handed to Terminal")
    func adminUninstallGoesToTerminal() throws {
        let brew = try UpdatePlannerTests.FakeBrew(); defer { brew.cleanup() }
        try brew.addCaskroomEntry("zoom/7.1.5.84650")
        let plan = RemovalPlanner.plan(
            for: Self.installedApp(name: "zoom.us"),
            candidate: UpdatePlannerTests.candidate(source: .homebrew, identifier: "zoom",
                                                    requiresAdmin: true),
            tools: ToolAvailability(homebrewPath: brew.brewPath, masPath: nil)
        )
        #expect(plan.method == .homebrewUninstall)
        #expect(plan.requiresTerminal)
    }

    @Test("a duplicate copy outside /Applications is trashed, never brew-uninstalled")
    func duplicateCopyIsTrashed() throws {
        // Regression: two Vellum bundles existed at once — brew's in /Applications
        // and a stray in ~/Applications. `brew uninstall` aimed at the stray would
        // have deleted the managed copy instead.
        let brew = try UpdatePlannerTests.FakeBrew(); defer { brew.cleanup() }
        try brew.addCaskroomEntry("vellum/4.1.4,41400")
        let plan = RemovalPlanner.plan(
            for: Self.installedApp(name: "Vellum", directory: "/Users/someone/Applications"),
            candidate: UpdatePlannerTests.candidate(source: .homebrew, identifier: "vellum"),
            tools: ToolAvailability(homebrewPath: brew.brewPath, masPath: nil)
        )
        #expect(plan.method == .trash)
    }

    @Test("dry run reports what would happen without touching anything")
    func dryRunDoesNothing() async {
        let plan = RemovalPlanner.plan(for: Self.installedApp(), candidate: nil)
        let recorder = LogRecorder()
        let outcome = await RemovalExecutor(dryRun: true).execute(plan) { recorder.append($0) }
        #expect(outcome == .succeeded)
        #expect(recorder.lines.contains { $0.contains("dry run") && $0.contains("Trash") })
        // The fake app path obviously still "exists" untouched — nothing was trashed.
    }
}

@Suite("Source labelling")
struct SourceLabelTests {
    /// The badge must distinguish "brew manages this" from "identified via brew's
    /// catalog" — a hand-installed Tunnelblick is not a Homebrew app.
    @Test("caskroom presence drives managedByHomebrew")
    func managedFlag() throws {
        let catalog = try CaskCatalogTests.catalog()
        let caskroom = FileManager.default.temporaryDirectory
            .appendingPathComponent("caskroom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: caskroom.appendingPathComponent("firefox"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: caskroom) }

        let firefox = InstalledApp(
            url: URL(fileURLWithPath: "/Applications/Firefox.app"),
            bundleFileName: "Firefox.app", displayName: "Firefox",
            bundleID: "org.mozilla.firefox", shortVersion: "153.0.3",
            bundleVersion: "153.0.3", isMASInstalled: false, sparkleFeedURL: nil
        )

        let managed = CaskProvider(catalog: catalog, caskroomRoot: caskroom)
            .candidate(for: firefox)
        #expect(managed?.managedByHomebrew == true)

        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("caskroom-empty-\(UUID().uuidString)")
        let unmanaged = CaskProvider(catalog: catalog, caskroomRoot: empty)
            .candidate(for: firefox)
        #expect(unmanaged?.managedByHomebrew == false)

        // A duplicate outside brew's appdir is not "managed" even with a Caskroom entry.
        let stray = InstalledApp(
            url: URL(fileURLWithPath: "/Users/someone/Applications/Firefox.app"),
            bundleFileName: "Firefox.app", displayName: "Firefox",
            bundleID: "org.mozilla.firefox", shortVersion: "153.0.3",
            bundleVersion: "153.0.3", isMASInstalled: false, sparkleFeedURL: nil
        )
        let strayCandidate = CaskProvider(catalog: catalog, caskroomRoot: caskroom)
            .candidate(for: stray)
        #expect(strayCandidate?.managedByHomebrew == false)
    }
}

@Suite("Privileged bundles")
struct PrivilegedBundleTests {
    @Test("root-owned bundles are detected")
    func detectsRootOwnership() throws {
        // Mail.app ships with macOS and is always root-owned; a fresh temp file is
        // always owned by the current user.
        #expect(UpdatePlanner.needsPrivilegedReplace(
            URL(fileURLWithPath: "/System/Applications/Mail.app")))

        let mine = FileManager.default.temporaryDirectory
            .appendingPathComponent("owned-\(UUID().uuidString)")
        try Data().write(to: mine)
        defer { try? FileManager.default.removeItem(at: mine) }
        #expect(!UpdatePlanner.needsPrivilegedReplace(mine))
        #expect(!UpdatePlanner.needsPrivilegedReplace(nil))
    }

    @Test("a root-owned app's brew update is handed to Terminal")
    func rootOwnedUpdateGoesToTerminal() throws {
        // Regression: Tunnelblick self-secures by setting root ownership on its own
        // bundle, so `brew install --force` from a GUI subprocess failed every time —
        // silently. In Terminal, brew can prompt for sudo.
        let brew = try UpdatePlannerTests.FakeBrew(); defer { brew.cleanup() }
        let rootOwned = InstalledApp(
            url: URL(fileURLWithPath: "/System/Applications/Mail.app"),
            bundleFileName: "Mail.app", displayName: "Mail",
            bundleID: "com.example.rootowned", shortVersion: "1.0", bundleVersion: "1.0",
            isMASInstalled: false, sparkleFeedURL: nil
        )
        let candidate = UpdateCandidate(
            app: rootOwned, identifier: "tunnelblick", source: .homebrew,
            installedVersion: "1.0", latestVersion: "2.0",
            relation: .updateAvailable, confidence: .exact
        )
        let plan = UpdatePlanner.plan(
            for: candidate,
            tools: ToolAvailability(homebrewPath: brew.brewPath, masPath: nil),
            runningBundleIDs: []
        )
        #expect(plan.requiresTerminal)
    }
}

@Suite("Usage tracking")
struct UsageTests {
    static func app(lastUsed: Date?) -> InstalledApp {
        InstalledApp(
            url: URL(fileURLWithPath: "/Applications/Example.app"),
            bundleFileName: "Example.app", displayName: "Example",
            bundleID: "com.example.app", shortVersion: "1.0", bundleVersion: "1.0",
            isMASInstalled: false, sparkleFeedURL: nil, lastUsedDate: lastUsed
        )
    }

    @Test("counts whole days since last open")
    func countsDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let opened120DaysAgo = now.addingTimeInterval(-120 * 86_400)
        #expect(Self.app(lastUsed: opened120DaysAgo).unusedDays(asOf: now) == 120)
        #expect(Self.app(lastUsed: now).unusedDays(asOf: now) == 0)
    }

    @Test("no usage record means unknown, not unused")
    func nilIsUnknown() {
        // Spotlight has no record for some genuinely-used apps (observed live for
        // Electrum and DiffMerge), so nil must never read as "unused for ages".
        #expect(Self.app(lastUsed: nil).unusedDays() == nil)
    }

    @Test("a clock skewed into the future clamps to zero")
    func futureDateClamps() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(86_400)
        #expect(Self.app(lastUsed: future).unusedDays(asOf: now) == 0)
    }
}
