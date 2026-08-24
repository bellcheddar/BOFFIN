// swift-tools-version: 6.2
// BOFFIN: BoffinML
// Dependency rule (CLAUDE.md): enforced here and re-checked by Tools/check-module-graph.sh in CI.

import PackageDescription

let package = Package(
    name: "BoffinML",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "BoffinML", targets: ["BoffinML"])
    ],
    dependencies: [
        .package(path: "../BoffinCore")
    ],
    targets: [
        .target(
            name: "BoffinML",
            dependencies: [
                .product(name: "BoffinCore", package: "BoffinCore")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BoffinMLTests",
            dependencies: ["BoffinML"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
