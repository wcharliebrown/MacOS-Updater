import Foundation

/// A concrete, inspectable description of how an app would be removed. As with
/// `UpdatePlan`, planning is separate from executing so the confirmation dialog can
/// show exactly what will happen before anything does.
public struct RemovalPlan: Sendable {
    public enum Method: Sendable, Hashable {
        /// Homebrew manages this app, so Homebrew removes it — that also clears its
        /// Caskroom records, which plain deletion would leave stale.
        case homebrewUninstall
        /// Move the bundle to the Trash. Recoverable, and the only sensible option
        /// for apps no package manager owns.
        case trash
    }

    public let app: InstalledApp
    public let method: Method
    public let executable: String?
    public let arguments: [String]
    /// The cask's uninstall stanza includes pkg components, which need root.
    public let requiresTerminal: Bool

    public var commandLine: String {
        guard let executable else { return "" }
        return ([executable] + arguments)
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }

    public var summary: String {
        switch method {
        case .homebrewUninstall:
            return "Uninstall with Homebrew — removes the app and Homebrew's records of it"
        case .trash:
            return "Move \(app.displayName) to the Trash (recoverable)"
        }
    }
}

public enum RemovalPlanner {
    public static func plan(
        for app: InstalledApp,
        candidate: UpdateCandidate?,
        tools: ToolAvailability = .detect()
    ) -> RemovalPlan {
        // Only route through Homebrew when it genuinely manages *this bundle*.
        // Brew removes from its appdir (/Applications), so running `brew uninstall`
        // against a duplicate copy in ~/Applications would delete the wrong app.
        if let candidate, candidate.source == .homebrew,
           app.url.deletingLastPathComponent().path == "/Applications",
           let brew = tools.homebrewPath,
           FileManager.default.fileExists(
               atPath: UpdatePlanner.caskroomURL(homebrewPath: brew, token: candidate.identifier).path
           ) {
            return RemovalPlan(
                app: app,
                method: .homebrewUninstall,
                executable: brew,
                arguments: ["uninstall", "--cask", candidate.identifier],
                requiresTerminal: candidate.requiresAdmin
            )
        }

        return RemovalPlan(
            app: app, method: .trash, executable: nil, arguments: [], requiresTerminal: false
        )
    }
}

public struct RemovalExecutor: Sendable {
    let runner: ProcessRunner
    public let dryRun: Bool

    public init(runner: ProcessRunner = ProcessRunner(), dryRun: Bool = false) {
        self.runner = runner
        self.dryRun = dryRun
    }

    public func execute(
        _ plan: RemovalPlan,
        log: @escaping @Sendable (String) -> Void
    ) async -> UpdateOutcome {
        switch plan.method {
        case .trash:
            if dryRun {
                log("[dry run] move \(plan.app.url.path) to the Trash")
                return .succeeded
            }
            do {
                try FileManager.default.trashItem(at: plan.app.url, resultingItemURL: nil)
                log("Moved \(plan.app.displayName) to the Trash.")
                return .succeeded
            } catch {
                // Bundles installed by a root pkg (XQuartz) are owned by root; a user
                // process cannot trash those directly. Finder can — it shows the
                // administrator password prompt — so ask it to do the move.
                log("Direct move to the Trash failed (\(error.localizedDescription)).")
                log("Asking Finder instead — approve the prompt; an administrator password may be required…")
                return await trashViaFinder(plan.app, log: log)
            }

        case .homebrewUninstall:
            guard let executable = plan.executable else {
                return .skipped("Homebrew is not available")
            }
            if dryRun {
                log("[dry run] \(plan.commandLine)")
                return .succeeded
            }
            if plan.requiresTerminal {
                log("Requires an administrator password — opening Terminal.")
                await UpdateExecutor.openInTerminal(plan.commandLine)
                return .handedOff("Running in Terminal")
            }
            log("$ \(plan.commandLine)")
            do {
                let status = try await runner.stream(executable, arguments: plan.arguments) { log($0) }
                return status == 0 ? .succeeded : .failed(exitCode: status)
            } catch {
                log("error: \(error)")
                return .failed(exitCode: -1)
            }
        }
    }

    private func trashViaFinder(
        _ app: InstalledApp,
        log: @escaping @Sendable (String) -> Void
    ) async -> UpdateOutcome {
        let script = "tell application \"Finder\" to delete (POSIX file \"\(app.url.path)\" as alias)"
        do {
            // Long timeout: the user has to answer the automation prompt and possibly
            // type an administrator password.
            let result = try await runner.run(
                "/usr/bin/osascript", arguments: ["-e", script], timeout: 600
            )
            if result.succeeded {
                log("Moved \(app.displayName) to the Trash via Finder.")
                return .succeeded
            }
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            log(detail.isEmpty ? "Finder could not remove it." : detail)
            if detail.contains("-1743") {
                log("Automation permission was denied. Allow it under "
                    + "System Settings → Privacy & Security → Automation, then try again.")
            }
            return .failed(exitCode: result.exitCode)
        } catch {
            log("error: \(error)")
            return .failed(exitCode: -1)
        }
    }
}
