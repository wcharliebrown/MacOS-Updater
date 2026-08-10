import Foundation
import Observation
import SwiftUI
import UpdaterKit

/// Everything the UI observes. All mutation happens on the main actor; the expensive
/// work (catalog parsing, subprocesses, network) runs off it.
@MainActor
@Observable
final class UpdaterModel {
    private(set) var report: UpdateReport?
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private(set) var statusMessage: String?
    private(set) var catalogOrigin: CatalogStore.Origin?

    /// Identifiers of updates currently being installed.
    private(set) var inProgress = Set<String>()
    /// Captured once per scan so rows don't query NSWorkspace on every render.
    private(set) var runningBundleIDs = Set<String>()
    private(set) var outcomes = [String: UpdateOutcome]()
    private(set) var log = [String]()

    var settings = AppSettings()

    /// A removal awaiting user confirmation — set by row context menus, consumed by
    /// the window-level confirmation dialog. Centralised because per-row dialogs
    /// inside a List have proven unreliable on macOS.
    struct PendingRemoval {
        let app: InstalledApp
        let candidate: UpdateCandidate?
    }
    var pendingRemoval: PendingRemoval?

    func requestRemoval(app: InstalledApp, candidate: UpdateCandidate?) {
        pendingRemoval = PendingRemoval(app: app, candidate: candidate)
    }

    private let store = CatalogStore()
    private var scheduler: BackgroundScheduler?

    var outdatedCount: Int { report?.outdated.count ?? 0 }

    // MARK: - Scanning

    func refresh(force: Bool = false) async {
        guard !isScanning else { return }
        isScanning = true
        statusMessage = nil
        defer { isScanning = false }

        let catalog: CaskCatalog?
        do {
            catalog = try await store.catalog(forceRefresh: force)
            catalogOrigin = await store.origin
        } catch {
            catalog = nil
            statusMessage = "Could not load the Homebrew cask catalog: \(error)"
        }

        let overrides = OverrideTable.loadMerged()
        let options = settings.sourceOptions
        let resolver = UpdateResolver(catalog: catalog, overrides: overrides, options: options)

        let previousCount = report?.outdated.count
        let fresh = await resolver.resolve()

        report = fresh
        lastScan = Date()
        runningBundleIDs = UpdatePlanner.currentRunningBundleIDs()

        if settings.notifyOnNewUpdates, let previousCount, fresh.outdated.count > previousCount {
            Notifier.notify(newCount: fresh.outdated.count - previousCount, total: fresh.outdated.count)
        }
    }

    // MARK: - Updating

    func update(_ candidate: UpdateCandidate) async {
        let key = candidate.id
        guard !inProgress.contains(key) else { return }
        inProgress.insert(key)
        defer { inProgress.remove(key) }

        let plan = UpdatePlanner.plan(for: candidate)
        append("── \(candidate.displayName): \(plan.summary)")

        // Homebrew cannot replace a bundle that is running.
        if let bundleID = plan.runningApplicationBundleID {
            append("Quitting \(candidate.displayName)…")
            let quit = await UpdateExecutor.quitApplication(bundleID: bundleID)
            guard quit else {
                append("\(candidate.displayName) is still running — update skipped.")
                outcomes[key] = .skipped(
                    "\(candidate.displayName) didn't quit (it may be asking for "
                    + "confirmation). Quit it manually, then click Update again."
                )
                return
            }
        }

        let executor = UpdateExecutor(dryRun: settings.dryRun)
        let outcome = await executor.execute(plan) { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
        outcomes[key] = outcome

        switch outcome {
        case .succeeded: append("✓ \(candidate.displayName) finished")
        case .failed(let code): append("✗ \(candidate.displayName) failed (exit \(code))")
        case .handedOff(let reason): append("→ \(candidate.displayName): \(reason)")
        case .skipped(let reason): append("• \(candidate.displayName): \(reason)")
        }

        // Re-scan so the row reflects reality rather than an assumption of success.
        if outcome.isSuccess && !settings.dryRun {
            await refresh()
        }
    }

    func updateAll() async {
        guard let report else { return }
        // Sequential: concurrent `brew` invocations contend for the same lock.
        for candidate in report.outdated where UpdatePlanner.plan(for: candidate).strategy.isAutomatic {
            await update(candidate)
        }
    }

    /// "Last opened 8 months ago", once an app crosses the unused threshold.
    /// Currently-running apps are never flagged, whatever Spotlight says — a menu bar
    /// app launched at login months ago can carry a stale last-used date.
    func unusedMessage(for app: InstalledApp) -> String? {
        let threshold = settings.unusedThresholdDays
        guard threshold > 0,
              let days = app.unusedDays(), days >= threshold,
              let lastUsed = app.lastUsedDate
        else { return nil }
        if let bundleID = app.bundleID?.lowercased(), runningBundleIDs.contains(bundleID) {
            return nil
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last opened \(formatter.localizedString(for: lastUsed, relativeTo: Date()))"
    }

    func isBusy(_ app: InstalledApp) -> Bool { inProgress.contains(app.id) }

    func remove(app: InstalledApp, candidate: UpdateCandidate?) async {
        guard !inProgress.contains(app.id) else { return }
        inProgress.insert(app.id)
        defer { inProgress.remove(app.id) }

        let plan = RemovalPlanner.plan(for: app, candidate: candidate)
        append("── Remove \(app.displayName): \(plan.summary)")

        // A running app holds its bundle open; quit it before touching anything.
        if let bundleID = app.bundleID,
           UpdatePlanner.currentRunningBundleIDs().contains(bundleID.lowercased()) {
            append("Quitting \(app.displayName)…")
            guard await UpdateExecutor.quitApplication(bundleID: bundleID) else {
                append("\(app.displayName) is still running — removal skipped.")
                outcomes[app.id] = .skipped(
                    "\(app.displayName) didn't quit. Quit it manually, then try again."
                )
                return
            }
        }

        let outcome = await RemovalExecutor(dryRun: settings.dryRun).execute(plan) { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }

        outcomes[app.id] = outcome
        switch outcome {
        case .succeeded: append("✓ \(app.displayName) removed")
        case .failed(let code): append("✗ Removing \(app.displayName) failed (exit \(code))")
        case .handedOff(let reason): append("→ \(app.displayName): \(reason)")
        case .skipped(let reason): append("• \(app.displayName): \(reason)")
        }

        if outcome.isSuccess && !settings.dryRun { await refresh() }
    }

    func append(_ line: String) {
        log.append(line)
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    func clearLog() { log.removeAll() }

    // MARK: - Background schedule

    func startScheduler() {
        scheduler = BackgroundScheduler(interval: settings.refreshInterval) { [weak self] in
            await self?.refresh()
        }
        scheduler?.start()
    }

    func rescheduleIfNeeded() {
        scheduler?.stop()
        startScheduler()
    }
}
