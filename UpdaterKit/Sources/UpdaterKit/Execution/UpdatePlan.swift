import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// How an update will be carried out.
public enum UpdateStrategy: Sendable, Hashable {
    /// `brew upgrade --cask` — the app is already managed by Homebrew.
    case homebrewUpgrade
    /// `brew install --cask --adopt` — a hand-installed app that is already at the
    /// catalog's version, brought under Homebrew's management without re-downloading.
    /// Homebrew only adopts artifacts identical to the ones it would install, so this
    /// is valid only when the versions already agree.
    case homebrewAdopt
    /// `brew install --cask --force` — a hand-installed app that is *behind*. Adopting
    /// here would be wrong: Homebrew would record the catalog version while leaving the
    /// old bundle in place, so the app never actually updates.
    case homebrewInstallOver
    /// `brew reinstall --cask` — Homebrew's records claim the current version but the
    /// bundle on disk is older, so an upgrade would no-op. Only detectable because we
    /// read the real version out of Info.plist.
    case homebrewReinstall
    case masUpgrade
    case softwareUpdate
    /// Cannot be automated here; hand off to the user.
    case manual(reason: String)

    public var isAutomatic: Bool {
        if case .manual = self { return false }
        return true
    }
}

/// A concrete, inspectable description of what will run. Building this separately from
/// executing it is what makes `--dry-run` and the confirmation UI honest: the string
/// shown to the user is the command that runs.
public struct UpdatePlan: Sendable {
    public let candidate: UpdateCandidate
    public let strategy: UpdateStrategy
    public let executable: String?
    public let arguments: [String]
    /// The app is running and should be quit first.
    public let runningApplicationBundleID: String?
    /// Needs root, which a GUI subprocess cannot obtain — must be handed to Terminal.
    public let requiresTerminal: Bool
    /// For `.manual`, what to open.
    public let manualURL: URL?

    public var commandLine: String {
        guard let executable else { return "" }
        return ([executable] + arguments)
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }

    /// A one-line explanation shown before the user commits to anything.
    public var summary: String {
        switch strategy {
        case .homebrewUpgrade:
            return "Upgrade via Homebrew"
        case .homebrewAdopt:
            return "Adopt into Homebrew — Homebrew takes over managing this app"
        case .homebrewInstallOver:
            return "Install over the existing app via Homebrew — Homebrew takes over managing it"
        case .homebrewReinstall:
            return "Reinstall via Homebrew — its records disagree with the installed version"
        case .masUpgrade:
            return "Update through the Mac App Store"
        case .softwareUpdate:
            return "Install via softwareupdate (requires an administrator password)"
        case .manual(let reason):
            return reason
        }
    }
}

public enum UpdatePlanner {
    /// Homebrew's Caskroom is the ground truth for whether brew already manages an app.
    static func caskroomURL(homebrewPath: String, token: String) -> URL {
        // /opt/homebrew/bin/brew → /opt/homebrew/Caskroom/<token>
        let prefix = URL(fileURLWithPath: homebrewPath)
            .deletingLastPathComponent()   // bin
            .deletingLastPathComponent()   // prefix
        return prefix.appendingPathComponent("Caskroom/\(token)")
    }

    public static func plan(
        for candidate: UpdateCandidate,
        tools: ToolAvailability = .detect(),
        runningBundleIDs: Set<String> = UpdatePlanner.currentRunningBundleIDs()
    ) -> UpdatePlan {
        let runningID = candidate.app?.bundleID.flatMap {
            runningBundleIDs.contains($0.lowercased()) ? $0 : nil
        }

        switch candidate.source {
        case .homebrew:
            guard let brew = tools.homebrewPath else {
                return UpdatePlan(
                    candidate: candidate, strategy: .manual(reason: "Homebrew is not installed"),
                    executable: nil, arguments: [], runningApplicationBundleID: runningID,
                    requiresTerminal: false, manualURL: candidate.homepage
                )
            }
            let caskroom = caskroomURL(homebrewPath: brew, token: candidate.identifier)
            let managed = FileManager.default.fileExists(atPath: caskroom.path)
            let strategy = homebrewStrategy(
                for: candidate, managed: managed, caskroom: caskroom
            )

            let arguments: [String]
            switch strategy {
            case .homebrewUpgrade:      arguments = ["upgrade", "--cask", candidate.identifier]
            case .homebrewReinstall:    arguments = ["reinstall", "--cask", candidate.identifier]
            case .homebrewInstallOver:  arguments = ["install", "--cask", "--force", candidate.identifier]
            default:                    arguments = ["install", "--cask", "--adopt", candidate.identifier]
            }

            return UpdatePlan(
                candidate: candidate,
                strategy: strategy,
                executable: brew, arguments: arguments,
                runningApplicationBundleID: runningID,
                // A cask carrying a pkg needs sudo — as does replacing a bundle owned
                // by root (XQuartz's installer sets that; Tunnelblick sets it on
                // itself as a security measure). brew's password prompt only works in
                // a real terminal, so those cases are handed there.
                requiresTerminal: candidate.requiresAdmin
                    || Self.needsPrivilegedReplace(candidate.app?.url),
                manualURL: candidate.homepage
            )

        case .macAppStore:
            guard let mas = tools.masPath, Int(candidate.identifier) != nil else {
                return UpdatePlan(
                    candidate: candidate,
                    strategy: .manual(reason: "Update in the App Store"),
                    executable: nil, arguments: [], runningApplicationBundleID: runningID,
                    requiresTerminal: false,
                    manualURL: candidate.homepage ?? URL(string: "macappstore://showUpdatesPage")
                )
            }
            return UpdatePlan(
                candidate: candidate, strategy: .masUpgrade,
                executable: mas, arguments: ["upgrade", candidate.identifier],
                runningApplicationBundleID: runningID, requiresTerminal: false,
                manualURL: candidate.homepage
            )

        case .system:
            return UpdatePlan(
                candidate: candidate, strategy: .softwareUpdate,
                executable: "/usr/sbin/softwareupdate",
                arguments: ["--install", candidate.identifier],
                runningApplicationBundleID: nil,
                requiresTerminal: true,
                manualURL: nil
            )

        case .sparkle:
            // Installing a Sparkle update means downloading and swapping the bundle
            // ourselves, which this version deliberately does not do. Hand off instead.
            return UpdatePlan(
                candidate: candidate,
                strategy: .manual(reason: "Download from the vendor, or use the app's own updater"),
                executable: nil, arguments: [],
                runningApplicationBundleID: runningID, requiresTerminal: false,
                manualURL: candidate.homepage
            )
        }
    }

    /// Chooses between upgrade / reinstall / install-over / adopt.
    ///
    /// The distinction matters because `--adopt` on an outdated app records the
    /// catalog's version without replacing the bundle, which leaves Homebrew
    /// permanently convinced the app is current.
    static func homebrewStrategy(
        for candidate: UpdateCandidate, managed: Bool, caskroom: URL
    ) -> UpdateStrategy {
        let behind = candidate.relation == .updateAvailable

        guard managed else {
            return behind ? .homebrewInstallOver : .homebrewAdopt
        }
        guard behind else { return .homebrewUpgrade }

        // Homebrew already records the version we are trying to reach, yet the bundle
        // is older — `upgrade` would report "already installed" and change nothing.
        if let latest = candidate.latestVersion, caskroomRecords(version: latest, in: caskroom) {
            return .homebrewReinstall
        }
        return .homebrewUpgrade
    }

    /// Homebrew stores each installed version as a directory named after it.
    static func caskroomRecords(version: String, in caskroom: URL) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: caskroom.path)) ?? []
        return entries.contains { entry in
            !entry.hasPrefix(".") &&
            VersionTokens.compare(VersionTokens(entry), VersionTokens(version)) == .orderedSame
        }
    }

    /// True when the bundle belongs to another user — root, in practice — so the
    /// current user cannot replace or delete it without privileges.
    static func needsPrivilegedReplace(_ url: URL?) -> Bool {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let owner = attributes[.ownerAccountID] as? NSNumber
        else { return false }
        return owner.uint32Value != getuid()
    }

    public static func currentRunningBundleIDs() -> Set<String> {
        #if canImport(AppKit)
        return Set(NSWorkspace.shared.runningApplications.compactMap {
            $0.bundleIdentifier?.lowercased()
        })
        #else
        return []
        #endif
    }
}
