import Testing
import Foundation
@testable import UpdaterKit

@Suite("Mac App Store parsing")
struct MASProviderTests {
    /// `mas` writes one JSON object per line rather than an array, and emits an empty
    /// record for any app Spotlight has not indexed — observed live for iHosts and
    /// Slack. Those blanks must not become nameless update rows.
    @Test("reads JSON Lines and drops Spotlight blanks")
    func parsesJSONLines() {
        let output = """
        {"name":""}
        {"adamID":1352778147,"bundleID":"com.bitwarden.desktop","name":"Bitwarden","version":"2026.7.0"}
        {"name":""}
        {"adamID":497799835,"bundleID":"com.apple.dt.Xcode","name":"Xcode","version":"26.6","latestVersion":"26.7"}
        """
        let records = MASProvider.parse(jsonLines: output)
        #expect(records.count == 2)
        #expect(records[0].name == "Bitwarden")
        #expect(records[1].latestVersion == "26.7")
    }

    @Test("survives non-JSON noise on the stream")
    func ignoresNoise() {
        let output = """
        Warning: Found a likely App Store app that is not indexed in Spotlight
        {"adamID":1,"bundleID":"com.example.app","name":"Example","version":"1.0"}
        """
        #expect(MASProvider.parse(jsonLines: output).count == 1)
    }

    @Test("a record with no identity at all is discarded")
    func discardsEmptyRecords() {
        #expect(MASProvider.parse(jsonLines: #"{"version":"1.0"}"#).isEmpty)
    }
}

@Suite("softwareupdate parsing")
struct SystemProviderTests {
    @Test("reads labels and restart requirement")
    func parsesListing() {
        let output = """
        Software Update Tool

        Finding available software
        Software Update found the following new or updated software:
        * Label: macOS Tahoe 26.7-25G100
        \tTitle: macOS Tahoe, Version: 26.7, Size: 6123456KiB, Recommended: YES, Action: restart,
        * Label: Safari18.6MojaveAuto-18.6
        \tTitle: Safari, Version: 18.6, Size: 123456KiB, Recommended: YES,
        """
        let candidates = SystemProvider.parse(output)
        #expect(candidates.count == 2)
        #expect(candidates[0].identifier == "macOS Tahoe 26.7-25G100")
        #expect(candidates[0].latestVersion == "26.7")
        // Every softwareupdate install needs root.
        #expect(candidates.allSatisfy { $0.requiresAdmin })
    }

    @Test("no updates yields no candidates")
    func parsesEmptyListing() {
        #expect(SystemProvider.parse("No new software available.\nSoftware Update Tool").isEmpty)
    }
}

@Suite("Sparkle appcast parsing")
struct SparkleTests {
    static let currentOS = OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 1)

    /// Mirrors XQuartz's real feed, which prefixes the product name onto the version
    /// and installs via a package.
    static let xquartzFeed = """
    <?xml version="1.0"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
      <item><title>2.8.6</title>
        <enclosure url="https://example.com/XQuartz-2.8.6.pkg"
          sparkle:shortVersionString="XQuartz-2.8.6" sparkle:installationType="package"/>
      </item>
      <item><title>2.8.5</title>
        <enclosure url="https://example.com/XQuartz-2.8.5.pkg"
          sparkle:shortVersionString="XQuartz-2.8.5" sparkle:installationType="package"/>
      </item>
    </channel></rss>
    """

    @Test("picks the newest item, not the first")
    func picksNewest() throws {
        let item = try #require(
            AppcastParser.newestItem(in: Data(Self.xquartzFeed.utf8), currentOS: Self.currentOS)
        )
        #expect(item.shortVersion == "XQuartz-2.8.6")
        #expect(item.installationType == "package")
    }

    @Test("a product-name prefix does not invert the comparison")
    func productNamePrefix() {
        // Regression: `XQuartz-2.8.6` once compared as older than `2.8.5`, because the
        // leading alpha token outranked the numeric one.
        let result = VersionComparator.evaluate(
            shortVersion: "2.8.5", bundleVersion: "2.8.5", upstream: "XQuartz-2.8.6"
        )
        #expect(result.relation == .updateAvailable)
    }

    @Test("reads versions from item elements as well as enclosure attributes")
    func elementStyleVersions() throws {
        let feed = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
          <item><sparkle:shortVersionString>8.0.3</sparkle:shortVersionString>
                <sparkle:version>6303</sparkle:version></item>
        </channel></rss>
        """
        let item = try #require(AppcastParser.newestItem(in: Data(feed.utf8), currentOS: Self.currentOS))
        #expect(item.shortVersion == "8.0.3")
        #expect(item.version == "6303")
    }

    @Test("skips prerelease channels")
    func skipsChannels() throws {
        let feed = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
          <item><sparkle:shortVersionString>3.0</sparkle:shortVersionString>
                <sparkle:channel>beta</sparkle:channel></item>
          <item><sparkle:shortVersionString>2.0</sparkle:shortVersionString></item>
        </channel></rss>
        """
        let item = try #require(AppcastParser.newestItem(in: Data(feed.utf8), currentOS: Self.currentOS))
        #expect(item.shortVersion == "2.0")
    }

    @Test("skips builds this machine is too old to run")
    func respectsMinimumSystemVersion() throws {
        let feed = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
          <item><sparkle:shortVersionString>9.0</sparkle:shortVersionString>
                <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion></item>
          <item><sparkle:shortVersionString>8.0</sparkle:shortVersionString>
                <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion></item>
        </channel></rss>
        """
        let item = try #require(AppcastParser.newestItem(in: Data(feed.utf8), currentOS: Self.currentOS))
        #expect(item.shortVersion == "8.0")
    }

    @Test("malformed feeds yield nothing rather than throwing")
    func malformedFeed() {
        #expect(AppcastParser.newestItem(in: Data("<html>404</html>".utf8), currentOS: Self.currentOS) == nil)
        #expect(AppcastParser.newestItem(in: Data(), currentOS: Self.currentOS) == nil)
    }
}
