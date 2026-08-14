import Foundation
import UpdaterKit

// Thin front-end over UpdaterKit, used to verify engine output against
// `brew outdated --cask --greedy`, `mas outdated` and `softwareupdate --list`
// before any UI exists.

let arguments = Array(CommandLine.arguments.dropFirst())
let showAll = arguments.contains("--all")
let showDetail = arguments.contains("--detail") || showAll
let asJSON = arguments.contains("--json")

var options = SourceOptions.all
if arguments.contains("--no-network") {
    // Skips every source that would make a network request.
    options.sparkle = false
    options.macAppStore = false
    options.system = false
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

// Goes through CatalogStore rather than reading Homebrew's cache directly, so a
// missing or reformatted cache falls back to downloading the catalog instead of
// silently reporting zero casks.
let store = CatalogStore()
let catalog: CaskCatalog?
var catalogLoadTime: TimeInterval = 0
do {
    let clock = Date()
    catalog = try await store.catalog { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    catalogLoadTime = Date().timeIntervalSince(clock)
} catch {
    catalog = nil
    FileHandle.standardError.write(Data("warning: could not load the cask catalog: \(error)\n".utf8))
}
let catalogOrigin = await store.origin

let report = await UpdateResolver(
    catalog: catalog, overrides: OverrideTable.loadMerged(), options: options
).resolve()

if asJSON {
    struct Row: Encodable {
        let name: String, identifier: String, source: String
        let installed: String?, latest: String?
        let relation: String, confidence: String, selfUpdating: Bool, requiresAdmin: Bool
        let managedByHomebrew: Bool
    }
    let rows = report.candidates.map {
        Row(name: $0.displayName, identifier: $0.identifier, source: $0.source.rawValue,
            installed: $0.installedVersion, latest: $0.latestVersion,
            relation: $0.relation.rawValue, confidence: $0.confidence.rawValue,
            selfUpdating: $0.selfUpdating, requiresAdmin: $0.requiresAdmin,
            managedByHomebrew: $0.managedByHomebrew)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try encoder.encode(rows), encoding: .utf8)!)
    exit(0)
}

func row(_ candidate: UpdateCandidate) -> String {
    let name = candidate.displayName.padding(toLength: 26, withPad: " ", startingAt: 0)
    let installed = (candidate.installedVersion ?? "—").padding(toLength: 20, withPad: " ", startingAt: 0)
    let latest = (candidate.latestVersion ?? "—").padding(toLength: 22, withPad: " ", startingAt: 0)
    // `homebrew` always means brew manages the app; a catalog-only identification
    // prints as `catalog`.
    var flags = [candidate.source == .homebrew && !candidate.managedByHomebrew
                     ? "catalog" : candidate.source.rawValue]
    if candidate.confidence == .heuristic { flags.append("~heuristic") }
    if candidate.selfUpdating { flags.append("self-updating") }
    if candidate.requiresAdmin { flags.append("admin") }
    if let days = candidate.app?.unusedDays(), days >= 90 { flags.append("unused \(days)d") }
    return "  \(name)\(installed)\(latest)[\(flags.joined(separator: ", "))]"
}

let originLabel: String
switch catalogOrigin {
case .homebrewCache: originLabel = "homebrew cache"
case .downloaded: originLabel = "downloaded"
case .homebrewInternalCache:
    originLabel = "homebrew internal index (no per-OS variations)"
case nil: originLabel = "unavailable"
}
print("catalog: \(report.catalogCount) casks from \(originLabel) "
      + "(\(String(format: "%.2f", catalogLoadTime))s), variation=\(Platform.currentCodename ?? "unknown")")
print("tools:   brew=\(report.tools.homebrewPath ?? "MISSING")  mas=\(report.tools.masPath ?? "MISSING")")
print("scanned: \(report.scannedAppCount) apps → \(report.candidates.count) tracked\n")

print("OUTDATED (\(report.outdated.count))")
if report.outdated.isEmpty { print("  none") }
for candidate in report.outdated { print(row(candidate)) }

if !report.undetermined.isEmpty {
    print("\nUNDETERMINED (\(report.undetermined.count)) — matched a source, versions not comparable")
    for candidate in report.undetermined { print(row(candidate)) }
}

if !report.newerThanCatalog.isEmpty {
    print("\nNEWER THAN CATALOG (\(report.newerThanCatalog.count)) — informational, never actioned")
    for candidate in report.newerThanCatalog { print(row(candidate)) }
}

if arguments.contains("plan") || arguments.contains("--plan") {
    print("\nPLANS")
    if report.outdated.isEmpty { print("  nothing to do") }
    for candidate in report.outdated {
        let plan = UpdatePlanner.plan(for: candidate)
        print("\n  \(candidate.displayName)  [\(candidate.source.rawValue)]")
        print("    \(plan.summary)")
        if plan.commandLine.isEmpty {
            print("    open: \(plan.manualURL?.absoluteString ?? "—")")
        } else {
            print("    $ \(plan.commandLine)")
        }
        if let running = plan.runningApplicationBundleID {
            print("    ! running now — must quit \(running) first")
        }
        if plan.requiresTerminal {
            print("    ! needs an administrator password — will be handed to Terminal")
        }
    }
}

if showDetail {
    print("\nUP TO DATE (\(report.upToDate.count))")
    for candidate in report.upToDate.sorted(by: { $0.displayName < $1.displayName }) { print(row(candidate)) }

    print("\nNOT TRACKED BY ANY SOURCE (\(report.unmatched.count))")
    for app in report.unmatched {
        let sparkle = app.sparkleFeedURL != nil ? "  [has Sparkle feed]" : ""
        let used = app.lastUsedDate.map {
            "  last opened \($0.formatted(date: .abbreviated, time: .omitted))"
        } ?? "  no usage record"
        print("  \(app.bundleFileName.padding(toLength: 34, withPad: " ", startingAt: 0))\(app.displayVersion)\(sparkle)\(used)")
    }
}
