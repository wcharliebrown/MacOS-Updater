import Foundation

/// Checks apps that ship a Sparkle appcast feed.
///
/// Feeds are vendor-controlled and frequently unreliable — Tunnelblick's advertised
/// `SUFeedURL` returns 404 — so every failure mode here is non-fatal: a bad feed
/// simply yields no candidate rather than an error the user has to dismiss.
public struct SparkleProvider: Sendable {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func candidates(for apps: [InstalledApp]) async -> [UpdateCandidate] {
        await withTaskGroup(of: UpdateCandidate?.self) { group in
            for app in apps where app.sparkleFeedURL != nil {
                group.addTask { await self.candidate(for: app) }
            }
            var results = [UpdateCandidate]()
            for await candidate in group {
                if let candidate { results.append(candidate) }
            }
            return results
        }
    }

    public func candidate(for app: InstalledApp) async -> UpdateCandidate? {
        guard let feedURL = app.sparkleFeedURL else { return nil }

        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 20
        // Some feeds vary their response by user agent, and a few reject the default.
        request.setValue(
            "\(app.displayName)/\(app.displayVersion) Sparkle/2.0",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let newest = AppcastParser.newestItem(in: data, currentOS: ProcessInfo.processInfo.operatingSystemVersion)
        else { return nil }

        let comparison = VersionComparator.evaluate(
            shortVersion: app.shortVersion,
            bundleVersion: app.bundleVersion,
            upstream: newest.displayVersion
        )

        return UpdateCandidate(
            app: app,
            identifier: app.bundleID ?? app.bundleFileName,
            source: .sparkle,
            installedVersion: app.displayVersion,
            latestVersion: newest.displayVersion,
            relation: comparison.relation,
            confidence: comparison.confidence,
            selfUpdating: true,
            requiresAdmin: newest.installationType == "package",
            homepage: newest.enclosureURL
        )
    }
}

/// Minimal Sparkle appcast reader. Versions may live on `<item>` child elements or as
/// attributes of `<enclosure>`, so both are collected.
enum AppcastParser {
    struct Item: Sendable, Equatable {
        var shortVersion: String?
        var version: String?
        var minimumSystemVersion: String?
        var channel: String?
        var enclosureURL: URL?
        /// Sparkle's `installationType`; `package` means a pkg that needs admin rights.
        var installationType: String?

        /// Prefer the marketing version; fall back to the build number.
        var displayVersion: String { shortVersion ?? version ?? "" }
        var isStable: Bool { channel == nil || channel?.isEmpty == true }
    }

    static func newestItem(
        in data: Data,
        currentOS: OperatingSystemVersion
    ) -> Item? {
        let items = parse(data)
            .filter { !$0.displayVersion.isEmpty }
            .filter(\.isStable)
            .filter { item in
                // Never offer a build this machine is too old to run.
                guard let minimum = item.minimumSystemVersion else { return true }
                let installed = VersionTokens("\(currentOS.majorVersion).\(currentOS.minorVersion).\(currentOS.patchVersion)")
                return VersionTokens.compare(VersionTokens(minimum), installed) != .orderedDescending
            }

        return items.max { lhs, rhs in
            VersionTokens.compare(
                VersionTokens(lhs.displayVersion), VersionTokens(rhs.displayVersion)
            ) == .orderedAscending
        }
    }

    static func parse(_ data: Data) -> [Item] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return delegate.items }
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items = [Item]()
        private var current: Item?
        private var elementName: String?
        private var text = ""

        func parser(
            _ parser: XMLParser, didStartElement name: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
        ) {
            elementName = name
            text = ""

            switch name {
            case "item":
                current = Item()
            case "enclosure":
                guard current != nil else { break }
                if let value = attributes["sparkle:shortVersionString"], current?.shortVersion == nil {
                    current?.shortVersion = value
                }
                if let value = attributes["sparkle:version"], current?.version == nil {
                    current?.version = value
                }
                if let url = attributes["url"] { current?.enclosureURL = URL(string: url) }
                if let type = attributes["sparkle:installationType"] { current?.installationType = type }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser, didEndElement name: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "sparkle:shortVersionString" where !value.isEmpty:
                current?.shortVersion = value
            case "sparkle:version" where !value.isEmpty:
                current?.version = value
            case "sparkle:minimumSystemVersion" where !value.isEmpty:
                current?.minimumSystemVersion = value
            case "sparkle:channel" where !value.isEmpty:
                current?.channel = value
            case "item":
                if let current { items.append(current) }
                current = nil
            default:
                break
            }
            text = ""
        }
    }
}
