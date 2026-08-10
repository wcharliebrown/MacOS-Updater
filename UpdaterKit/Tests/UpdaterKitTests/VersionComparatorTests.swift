import Testing
import Foundation
@testable import UpdaterKit

/// Every case below is taken from a real app/cask pair observed on a live machine.
/// They exist to stop the version-scheme quirks from regressing.
@Suite("Version comparison")
struct VersionComparatorTests {

    struct Case {
        let name: String
        let short: String?
        let bundle: String?
        let upstream: String
        let expected: VersionRelation
        var override: VersionOverride?
    }

    static let upToDateCases: [Case] = [
        // Comma-separated build components.
        .init(name: "Docker", short: "4.86.0", bundle: "236216", upstream: "4.86.0,236216", expected: .upToDate),
        .init(name: "Cursor", short: "3.15.6", bundle: "3.15.6",
              upstream: "3.15.6,a1f686545fd0ce8917bbd2449f733551a9bce420", expected: .upToDate),
        .init(name: "CarbonCopyCloner", short: "7.1.6", bundle: "8368", upstream: "7.1.6,8368", expected: .upToDate),
        // Parenthesised build flattens to the same tokens as a dotted one.
        .init(name: "Zoom", short: "7.1.5 (84650)", bundle: "7.1.5.84650",
              upstream: "7.1.5.84650", expected: .upToDate),
        // Plain, identical versions.
        .init(name: "Chrome", short: "151.0.7922.109", bundle: "7922.109",
              upstream: "151.0.7922.109", expected: .upToDate),
        .init(name: "Firefox", short: "153.0.3", bundle: "15326.7.15", upstream: "153.0.3", expected: .upToDate),
        .init(name: "iTerm", short: "3.6.11", bundle: "3.6.11", upstream: "3.6.11", expected: .upToDate),
        .init(name: "VSCode", short: "1.132.0", bundle: "1.132.0", upstream: "1.132.0", expected: .upToDate),
        // Upstream appends a build the app never publishes.
        .init(name: "ExpressVPN", short: "14.2.0", bundle: "14.2.0",
              upstream: "14.2.0.13656", expected: .upToDate),
        // Brave prefixes the Chromium major onto its own version; needs the override.
        .init(name: "Brave", short: "151.1.93.134", bundle: "193.134", upstream: "1.93.134.0",
              expected: .upToDate,
              override: VersionOverride(token: "brave-browser", versionKey: .short,
                                        dropLeadingSegments: 1, trimTrailingZeros: true)),
    ]

    static let outdatedCases: [Case] = [
        .init(name: "Electrum", short: "4.7.2", bundle: "4.7.2", upstream: "4.8.0", expected: .updateAvailable),
        // Leading "v" must not defeat the comparison.
        .init(name: "RaspberryPiImager", short: "v2.0.8", bundle: "2.0.8",
              upstream: "2.0.10", expected: .updateAvailable),
        // Trailing build tag on the installed side.
        .init(name: "Tunnelblick", short: "8.0.2 (build 6302)", bundle: "6302",
              upstream: "8.0.3,6303", expected: .updateAvailable),
        .init(name: "Vellum", short: "4.1.3", bundle: "41300", upstream: "4.1.4,41400", expected: .updateAvailable),
    ]

    @Test("recognises current versions", arguments: upToDateCases)
    func upToDate(testCase: Case) {
        let result = VersionComparator.evaluate(
            shortVersion: testCase.short, bundleVersion: testCase.bundle,
            upstream: testCase.upstream, override: testCase.override
        )
        #expect(result.relation == .upToDate, "\(testCase.name) → \(result.relation)")
    }

    @Test("recognises outdated versions", arguments: outdatedCases)
    func outdated(testCase: Case) {
        let result = VersionComparator.evaluate(
            shortVersion: testCase.short, bundleVersion: testCase.bundle,
            upstream: testCase.upstream, override: testCase.override
        )
        #expect(result.relation == .updateAvailable, "\(testCase.name) → \(result.relation)")
    }

    @Test("2.0.10 sorts above 2.0.8, not below")
    func numericNotLexicographic() {
        #expect(VersionTokens.compare(VersionTokens("2.0.8"), VersionTokens("2.0.10")) == .orderedAscending)
        #expect(VersionTokens.compare(VersionTokens("1.10"), VersionTokens("1.9")) == .orderedDescending)
    }

    @Test("a release outranks its own prerelease")
    func prereleaseOrdering() {
        #expect(VersionTokens.compare(VersionTokens("1.0beta2"), VersionTokens("1.0")) == .orderedAscending)
        #expect(VersionTokens.compare(VersionTokens("1.0"), VersionTokens("1.0.0")) == .orderedSame)
    }

    @Test("missing installed version cannot be judged")
    func missingVersion() {
        let result = VersionComparator.evaluate(
            shortVersion: nil, bundleVersion: nil, upstream: "1.2.3", override: nil
        )
        #expect(result.relation == .unknown)
        #expect(result.confidence == .none)
    }

    @Test("an installed version ahead of the catalog is never actionable")
    func aheadIsNotActionable() {
        let result = VersionComparator.evaluate(
            shortVersion: "9.0.0", bundleVersion: "9.0.0", upstream: "8.1.0", override: nil
        )
        #expect(result.relation == .ahead)
    }
}
