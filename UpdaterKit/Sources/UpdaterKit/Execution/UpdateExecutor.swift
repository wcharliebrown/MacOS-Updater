import Foundation
#if canImport(AppKit)
import AppKit
#endif

public enum UpdateOutcome: Sendable, Equatable {
    case succeeded
    case failed(exitCode: Int32)
    case handedOff(String)
    case skipped(String)

    public var isSuccess: Bool { self == .succeeded }
}

/// Carries out an `UpdatePlan`, streaming the tool's output as it goes.
public struct UpdateExecutor: Sendable {
    let runner: ProcessRunner
    /// Print the command instead of running it.
    public let dryRun: Bool

    public init(runner: ProcessRunner = ProcessRunner(), dryRun: Bool = false) {
        self.runner = runner
        self.dryRun = dryRun
    }

    public func execute(
        _ plan: UpdatePlan,
        log: @escaping @Sendable (String) -> Void
    ) async -> UpdateOutcome {
        if case .manual(let reason) = plan.strategy {
            log("Manual step required: \(reason)")
            if let url = plan.manualURL {
                log("Opening \(url.absoluteString)")
                if !dryRun { await Self.open(url) }
            }
            return .handedOff(reason)
        }

        guard let executable = plan.executable else {
            return .skipped("No command available for \(plan.candidate.displayName)")
        }

        if dryRun {
            log("[dry run] \(plan.commandLine)")
            return .succeeded
        }

        // Root prompts cannot be answered from a GUI subprocess; running the command
        // here would block forever on an invisible password prompt. Hand the exact
        // command to Terminal, where the user can authenticate.
        if plan.requiresTerminal {
            log("Requires an administrator password — opening Terminal.")
            await Self.openInTerminal(plan.commandLine)
            return .handedOff("Running in Terminal")
        }

        log("$ \(plan.commandLine)")
        do {
            let status = try await runner.stream(executable, arguments: plan.arguments) { line in
                log(line)
            }
            return status == 0 ? .succeeded : .failed(exitCode: status)
        } catch {
            log("error: \(error)")
            return .failed(exitCode: -1)
        }
    }

    // MARK: - Handing work to the user

    @MainActor
    static func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Writes the command to a temporary script and opens it in Terminal, so the user
    /// can see and authenticate exactly what runs.
    @MainActor
    static func openInTerminal(_ command: String) {
        #if canImport(AppKit)
        let script = """
        #!/bin/zsh
        echo "MacOS Updater is running:"
        echo "  \(command)"
        echo
        \(command)
        echo
        echo "Done. You can close this window."
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macos-updater-\(UUID().uuidString).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
        #endif
    }

    /// Asks a running app to quit so its bundle can be replaced. Returns false if it
    /// is still running afterwards, so the caller can tell the user rather than
    /// letting Homebrew fail halfway through.
    @MainActor
    public static func quitApplication(bundleID: String, timeout: TimeInterval = 20) async -> Bool {
        #if canImport(AppKit)
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier?.lowercased() == bundleID.lowercased()
        }
        guard !running.isEmpty else { return true }
        for application in running { application.terminate() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let stillRunning = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier?.lowercased() == bundleID.lowercased()
            }
            if !stillRunning { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
        #else
        return true
        #endif
    }
}
