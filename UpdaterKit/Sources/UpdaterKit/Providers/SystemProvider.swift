import Foundation

/// Pending macOS and system component updates, via `softwareupdate`.
public struct SystemProvider: Sendable {
    static let executable = "/usr/sbin/softwareupdate"
    let runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    public func candidates() async -> [UpdateCandidate] {
        guard let result = try? await runner.run(
            Self.executable, arguments: ["--list", "--no-scan"], timeout: 180
        ) else { return [] }

        // softwareupdate writes its listing to stderr on some macOS releases.
        return Self.parse(result.standardOutput + "\n" + result.standardError)
    }

    struct Entry: Sendable, Equatable {
        var label: String
        var title: String?
        var version: String?
        var requiresRestart: Bool
    }

    /// Parses the `* Label:` / `Title:` block format:
    ///
    ///     * Label: macOS Sequoia 15.1-24B83
    ///         Title: macOS Sequoia, Version: 15.1, Size: 6000000KiB, Recommended: YES, Action: restart,
    static func parse(_ output: String) -> [UpdateCandidate] {
        var entries = [Entry]()

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("* Label:") {
                let label = line.dropFirst("* Label:".count).trimmingCharacters(in: .whitespaces)
                if !label.isEmpty { entries.append(Entry(label: label, requiresRestart: false)) }
                continue
            }

            guard !entries.isEmpty, line.contains("Title:") else { continue }

            // The detail line is a flat comma-separated list of `Key: Value` pairs.
            var fields = [String: String]()
            for field in line.split(separator: ",") {
                let parts = field.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2 { fields[parts[0]] = parts[1] }
            }
            entries[entries.count - 1].title = fields["Title"]
            entries[entries.count - 1].version = fields["Version"]
            entries[entries.count - 1].requiresRestart = fields["Action"]?.contains("restart") ?? false
        }

        return entries.map { entry in
            UpdateCandidate(
                app: nil,
                identifier: entry.label,
                source: .system,
                installedVersion: nil,
                latestVersion: entry.version ?? entry.title,
                relation: .updateAvailable,
                confidence: .exact,
                selfUpdating: false,
                // softwareupdate installs need root, which a GUI subprocess cannot obtain.
                requiresAdmin: true,
                homepage: nil
            )
        }
    }
}
