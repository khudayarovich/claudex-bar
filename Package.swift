// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClaudexBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudexBar", targets: ["ClaudexBar"]),
        .executable(name: "claudex-probe", targets: ["ClaudexProbe"]),
        .library(name: "ClaudexCore", targets: ["ClaudexCore"]),
    ],
    targets: [
        // Pure logic: models, parsers, data sources, presentation math. No AppKit/SwiftUI.
        .target(
            name: "ClaudexCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The notch-island app (AppKit lifecycle + SwiftUI views).
        .executableTarget(
            name: "ClaudexBar",
            dependencies: ["ClaudexCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Read-only diagnostics CLI used for verification.
        .executableTarget(
            name: "ClaudexProbe",
            dependencies: ["ClaudexCore"]
        ),
        .testTarget(
            name: "ClaudexCoreTests",
            dependencies: ["ClaudexCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
