// swift-tools-version: 6.2
// BOFFIN: BoffinCore
// Dependency rule (CLAUDE.md): enforced here and re-checked by Tools/check-module-graph.sh in CI.

import PackageDescription

let package = Package(
    name: "BoffinCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "BoffinCore", targets: ["BoffinCore"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "BoffinCore",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BoffinCoreTests",
            dependencies: ["BoffinCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
