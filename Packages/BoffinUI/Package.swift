// swift-tools-version: 6.2
// BOFFIN: BoffinUI
// Dependency rule (CLAUDE.md): enforced here and re-checked by Tools/check-module-graph.sh in CI.

import PackageDescription

let package = Package(
    name: "BoffinUI",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "BoffinUI", targets: ["BoffinUI"])
    ],
    dependencies: [
        .package(path: "../BoffinCore")
    ],
    targets: [
        .target(
            name: "BoffinUI",
            dependencies: [
                .product(name: "BoffinCore", package: "BoffinCore")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BoffinUITests",
            dependencies: ["BoffinUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
