import Foundation

public struct VersionComparison: Sendable, Hashable {
    public let relation: VersionRelation
    public let confidence: MatchConfidence
    /// The installed string actually used for the comparison, for display/debugging.
    public let comparedInstalled: String?
    public let comparedUpstream: String?
}

/// Reconciles an app's `Info.plist` versions with a Homebrew cask version.
///
/// These two rarely use the same scheme. The rules below were derived from real
/// installed apps: Docker ships `4.86.0,236216` against short `4.86.0` / bundle
/// `236216`; Zoom ships `7.1.5.84650` against short `7.1.5 (84650)`; Cursor appends a
/// commit hash. The tokenizer treats every non-alphanumeric run as a separator, which
/// collapses most of that variance for free.
public enum VersionComparator {

    public static func evaluate(
        shortVersion: String?,
        bundleVersion: String?,
        upstream: String,
        override: VersionOverride? = nil
    ) -> VersionComparison {
        let trimZeros = override?.trimTrailingZeros ?? false

        func prepare(_ value: String) -> VersionTokens {
            var tokens = VersionTokens(value)
            if trimZeros { tokens = tokens.trimmingTrailingZeros() }
            return tokens
        }

        // Homebrew packs an optional build into the version as `marketing,build`.
        let parts = upstream.split(separator: ",", maxSplits: 1).map(String.init)
        let marketing = parts.first ?? upstream
        let build = parts.count > 1 ? parts[1] : nil

        var upstreamCandidates = [prepare(marketing)]
        if let build { upstreamCandidates.append(prepare(build)) }
        if build != nil { upstreamCandidates.append(prepare(upstream)) }
        // Feeds sometimes prefix the product name onto the version.
        for candidate in upstreamCandidates {
            let stripped = candidate.strippingLeadingAlpha()
            if stripped != candidate && !stripped.isEmpty { upstreamCandidates.append(stripped) }
        }

        // Installed candidates, honouring an override's choice of Info.plist key.
        var rawInstalled = [String]()
        switch override?.versionKey ?? .auto {
        case .short:
            if let shortVersion { rawInstalled.append(shortVersion) }
        case .bundle:
            if let bundleVersion { rawInstalled.append(bundleVersion) }
        case .auto:
            if let shortVersion { rawInstalled.append(shortVersion) }
            if let bundleVersion, bundleVersion != shortVersion { rawInstalled.append(bundleVersion) }
            if let shortVersion, let bundleVersion, shortVersion != bundleVersion {
                rawInstalled.append("\(shortVersion).\(bundleVersion)")
            }
        }

        var installedCandidates = rawInstalled.map { value -> VersionTokens in
            var tokens = prepare(value)
            if let drop = override?.dropLeadingSegments {
                tokens = tokens.droppingLeadingTokens(drop)
            }
            return tokens
        }
        for candidate in installedCandidates {
            let stripped = candidate.strippingLeadingAlpha()
            if stripped != candidate && !stripped.isEmpty { installedCandidates.append(stripped) }
        }
        installedCandidates.removeAll(where: \.isEmpty)

        guard !installedCandidates.isEmpty else {
            return VersionComparison(
                relation: .unknown, confidence: .none,
                comparedInstalled: nil, comparedUpstream: marketing
            )
        }

        // 1. Any candidate pair equal → up to date, high confidence.
        for installed in installedCandidates {
            for upstreamTokens in upstreamCandidates
            where VersionTokens.compare(installed, upstreamTokens) == .orderedSame {
                return VersionComparison(
                    relation: .upToDate, confidence: .exact,
                    comparedInstalled: installed.description,
                    comparedUpstream: upstreamTokens.description
                )
            }
        }

        // 2. Token-suffix rescue, for schemes that prefix an unrelated component onto
        //    the real version. Requires at least two tokens so it can't fire on noise.
        var marketingTokens = prepare(marketing)
        let strippedMarketing = marketingTokens.strippingLeadingAlpha()
        if !strippedMarketing.isEmpty { marketingTokens = strippedMarketing }
        if marketingTokens.count >= 2 {
            for installed in installedCandidates where marketingTokens.isTokenSuffix(of: installed) {
                return VersionComparison(
                    relation: .upToDate, confidence: .heuristic,
                    comparedInstalled: installed.description,
                    comparedUpstream: marketingTokens.description
                )
            }
        }

        // 3. Upstream carries extra trailing components the app never publishes
        //    (ExpressVPN ships `14.2.0` against a cask version of `14.2.0.13656`).
        //    The marketing parts agree, and the build difference is unobservable from
        //    the bundle, so treat it as current rather than nagging forever.
        if marketingTokens.count >= 2 {
            for installed in installedCandidates
            where installed.count >= 2 && installed.isTokenPrefix(of: marketingTokens) {
                return VersionComparison(
                    relation: .upToDate, confidence: .heuristic,
                    comparedInstalled: installed.description,
                    comparedUpstream: marketingTokens.description
                )
            }
        }

        // 4. Ordered comparison. Prefer a candidate with the same shape as the
        //    upstream version; a differing token count usually means differing schemes.
        //    Numeric prefixes are considered here but deliberately not in the equality
        //    tier above, so a prerelease is never flattened into its release version.
        let orderingCandidates = installedCandidates + installedCandidates.map { $0.numericPrefix() }
        let sameShape = orderingCandidates.first { $0.count == marketingTokens.count && !$0.isEmpty }
        let chosen = sameShape ?? installedCandidates[0]
        let confidence: MatchConfidence = sameShape != nil ? .exact : .heuristic

        switch VersionTokens.compare(chosen, marketingTokens) {
        case .orderedAscending:
            return VersionComparison(
                relation: .updateAvailable, confidence: confidence,
                comparedInstalled: chosen.description, comparedUpstream: marketingTokens.description
            )
        case .orderedDescending:
            // Installed is newer than the catalog. Genuine on beta channels, but far
            // more often a scheme mismatch — so never treat it as actionable.
            return VersionComparison(
                relation: .ahead, confidence: .heuristic,
                comparedInstalled: chosen.description, comparedUpstream: marketingTokens.description
            )
        case .orderedSame:
            return VersionComparison(
                relation: .upToDate, confidence: confidence,
                comparedInstalled: chosen.description, comparedUpstream: marketingTokens.description
            )
        }
    }
}
