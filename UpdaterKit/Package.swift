// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UpdaterKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UpdaterKit", targets: ["UpdaterKit"]),
        .executable(name: "updater-cli", targets: ["updater-cli"]),
        .executable(name: "MacOSUpdater", targets: ["MacOSUpdater"]),
    ],
    targets: [
        .target(
            name: "UpdaterKit",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "updater-cli",
            dependencies: ["UpdaterKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MacOSUpdater",
            dependencies: ["UpdaterKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "UpdaterKitTests",
            dependencies: ["UpdaterKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
