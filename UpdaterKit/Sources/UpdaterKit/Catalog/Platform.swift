import Foundation

/// Resolves the Homebrew "variation" keys that apply to this machine.
///
/// Homebrew publishes per-OS overrides under keys like `tahoe` and `arm64_tahoe`.
/// 1347 casks override `version` this way, so ignoring variations produces false
/// "update available" results — `anaconda`, for example, is `2026.07-1` at top level
/// but `2025.06-1` on macOS 26.
public enum Platform {
    /// Homebrew's macOS codenames, keyed by major version.
    /// Homebrew already ships data for macOS 27 (`golden_gate`).
    static let codenamesByMajor: [Int: String] = [
        27: "golden_gate",
        26: "tahoe",
        15: "sequoia",
        14: "sonoma",
        13: "ventura",
        12: "monterey",
        11: "big_sur",
    ]

    public static func codename(forMajor major: Int, minor: Int) -> String? {
        if major == 10 && minor == 15 { return "catalina" }
        return codenamesByMajor[major]
    }

    public static var currentCodename: String? {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return codename(forMajor: v.majorVersion, minor: v.minorVersion)
    }

    public static var isARM: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Variation keys to try, most specific first.
    public static func variationKeys(codename: String?, isARM: Bool) -> [String] {
        guard let codename else { return [] }
        return isARM ? ["arm64_\(codename)", codename] : [codename]
    }

    public static var currentVariationKeys: [String] {
        variationKeys(codename: currentCodename, isARM: isARM)
    }
}
