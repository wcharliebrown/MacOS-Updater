import Foundation

/// Reports pending Mac App Store updates by asking `mas`.
///
/// We trust `mas`'s judgement about *what* is outdated rather than trying to
/// reimplement it: its JSON records do not reliably carry the available version, so a
/// missing "latest" is reported as unknown instead of being invented.
public struct MASProvider: Sendable {
    let masPath: String?
    let runner: ProcessRunner

    public init(masPath: String? = ProcessRunner.masPath, runner: ProcessRunner = ProcessRunner()) {
        self.masPath = masPath
        self.runner = runner
    }

    public var isAvailable: Bool { masPath != nil }

    public func candidates(installed: [InstalledApp]) async -> [UpdateCandidate] {
        guard let masPath else { return [] }
        guard let result = try? await runner.run(masPath, arguments: ["outdated", "--json"], timeout: 180),
              result.succeeded || !result.standardOutput.isEmpty
        else { return [] }

        let records = Self.parse(jsonLines: result.standardOutput)
        let byBundleID = Dictionary(
            installed.compactMap { app in app.bundleID.map { ($0.lowercased(), app) } },
            uniquingKeysWith: { first, _ in first }
        )

        return records.map { record in
            let app = record.bundleID.flatMap { byBundleID[$0.lowercased()] }
            return UpdateCandidate(
                app: app,
                identifier: record.adamID.map(String.init) ?? record.bundleID ?? record.name ?? "unknown",
                source: .macAppStore,
                installedVersion: app?.displayVersion ?? record.version,
                latestVersion: record.latestVersion,
                relation: .updateAvailable,
                confidence: record.latestVersion == nil ? .heuristic : .exact,
                selfUpdating: false,
                requiresAdmin: false,
                homepage: record.adamID.flatMap {
                    URL(string: "macappstore://apps.apple.com/app/id\($0)")
                }
            )
        }
    }

    // MARK: - Parsing

    struct Record: Sendable, Equatable {
        var adamID: Int?
        var bundleID: String?
        var name: String?
        var version: String?
        var latestVersion: String?
    }

    /// `mas` emits one JSON object per line — not an array — and writes a blank
    /// `{"name":""}` record for any app Spotlight has not indexed. Those blanks are
    /// dropped rather than surfaced as nameless updates.
    static func parse(jsonLines: String) -> [Record] {
        jsonLines.split(separator: "\n").compactMap { line -> Record? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            let record = Record(
                adamID: object["adamID"] as? Int,
                bundleID: object["bundleID"] as? String,
                name: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                version: object["version"] as? String,
                // The key for the pending version has varied across mas releases;
                // accept any of the spellings rather than guessing one.
                latestVersion: ["latestVersion", "availableVersion", "newVersion", "updateVersion"]
                    .lazy.compactMap { object[$0] as? String }.first
            )

            // A record with no identifying information at all is Spotlight noise.
            guard record.adamID != nil || record.bundleID != nil || record.name != nil else { return nil }
            return record
        }
    }
}
