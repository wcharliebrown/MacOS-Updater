import Foundation

/// A version broken into numeric and alphabetic runs, the way Homebrew's own
/// `Version` class compares them: `1.10` sorts above `1.9`, and `1.0` above `1.0beta`.
struct VersionTokens: Equatable, CustomStringConvertible {
    enum Token: Equatable {
        case num(Int)
        case alpha(String)
    }

    let tokens: [Token]
    let raw: String

    var description: String { raw }
    var isEmpty: Bool { tokens.isEmpty }
    var count: Int { tokens.count }

    init(_ string: String) {
        self.raw = string
        var normalized = string.lowercased().trimmingCharacters(in: .whitespaces)
        if normalized.hasPrefix("v"), normalized.dropFirst().first?.isNumber == true {
            normalized.removeFirst()
        }

        var tokens = [Token]()
        var numberBuffer = ""
        var alphaBuffer = ""

        func flushNumber() {
            if !numberBuffer.isEmpty {
                // Overlong digit runs can overflow Int; clamp rather than crash.
                tokens.append(.num(Int(numberBuffer) ?? Int.max))
                numberBuffer = ""
            }
        }
        func flushAlpha() {
            if !alphaBuffer.isEmpty {
                tokens.append(.alpha(alphaBuffer))
                alphaBuffer = ""
            }
        }

        for character in normalized {
            if character.isNumber {
                flushAlpha()
                numberBuffer.append(character)
            } else if character.isLetter {
                flushNumber()
                alphaBuffer.append(character)
            } else {
                // Any separator (. - _ , space parens) ends the current run.
                flushNumber()
                flushAlpha()
            }
        }
        flushNumber()
        flushAlpha()

        self.tokens = tokens
    }

    /// Drops the first `n` numeric-led groups. Used by overrides for schemes like
    /// Brave's, where `CFBundleShortVersionString` prefixes the Chromium major
    /// (`151.1.93.134`) onto the real version (`1.93.134`).
    func droppingLeadingTokens(_ n: Int) -> VersionTokens {
        guard n > 0, n < tokens.count else { return self }
        return VersionTokens(tokens: Array(tokens.dropFirst(n)), raw: raw)
    }

    /// Removes trailing zero components so `1.93.134.0` and `1.93.134` compare equal.
    func trimmingTrailingZeros() -> VersionTokens {
        var trimmed = tokens
        while case .num(0) = trimmed.last {
            trimmed.removeLast()
        }
        return VersionTokens(tokens: trimmed, raw: raw)
    }

    private init(tokens: [Token], raw: String) {
        self.tokens = tokens
        self.raw = raw
    }

    static func compare(_ lhs: VersionTokens, _ rhs: VersionTokens) -> ComparisonResult {
        let maxCount = max(lhs.tokens.count, rhs.tokens.count)
        for index in 0..<maxCount {
            let a = index < lhs.tokens.count ? lhs.tokens[index] : nil
            let b = index < rhs.tokens.count ? rhs.tokens[index] : nil

            switch (a, b) {
            case let (.num(x)?, .num(y)?):
                if x != y { return x < y ? .orderedAscending : .orderedDescending }
            case let (.alpha(x)?, .alpha(y)?):
                if x != y { return x < y ? .orderedAscending : .orderedDescending }
            case (.num?, .alpha?):
                // 1.1 > 1.0beta — a numeric component outranks a prerelease tag.
                return .orderedDescending
            case (.alpha?, .num?):
                return .orderedAscending
            case let (nil, .num(y)?):
                if y != 0 { return .orderedAscending }
            case let (.num(x)?, nil):
                if x != 0 { return .orderedDescending }
            case (nil, .alpha?):
                // 1.0 > 1.0beta — the release outranks its own prerelease.
                return .orderedDescending
            case (.alpha?, nil):
                return .orderedAscending
            case (nil, nil):
                break
            }
        }
        return .orderedSame
    }

    /// Drops a leading product-name run, e.g. XQuartz publishes its Sparkle version
    /// as `XQuartz-2.8.6`. Without this the alpha token outranks the installed
    /// numeric version and a real update reads as "newer than upstream".
    func strippingLeadingAlpha() -> VersionTokens {
        var remaining = tokens
        while case .alpha = remaining.first {
            remaining.removeFirst()
        }
        return VersionTokens(tokens: remaining, raw: raw)
    }

    /// Leading run of numeric tokens, dropping trailing build tags such as
    /// Tunnelblick's `8.0.2 (build 6302)` → `8.0.2`.
    func numericPrefix() -> VersionTokens {
        var prefix = [Token]()
        for token in tokens {
            guard case .num = token else { break }
            prefix.append(token)
        }
        return VersionTokens(tokens: prefix, raw: raw)
    }

    /// True when `self`'s tokens are exactly the leading tokens of `other`.
    func isTokenPrefix(of other: VersionTokens) -> Bool {
        guard !tokens.isEmpty, tokens.count < other.tokens.count else { return false }
        return Array(other.tokens.prefix(tokens.count)) == tokens
    }

    /// True when `self`'s tokens are exactly the trailing tokens of `other`.
    func isTokenSuffix(of other: VersionTokens) -> Bool {
        guard !tokens.isEmpty, tokens.count < other.tokens.count else { return false }
        return Array(other.tokens.suffix(tokens.count)) == tokens
    }
}
