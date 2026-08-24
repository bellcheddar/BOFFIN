// swift-tools-version: 6.2
// BOFFIN: BoffinData
// Dependency rule (CLAUDE.md): enforced here and re-checked by Tools/check-module-graph.sh in CI.

import PackageDescription

let package = Package(
    name: "BoffinData",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "BoffinData", targets: ["BoffinData"])
    ],
    dependencies: [
        .package(path: "../BoffinCore")
    ],
    targets: [
        .target(
            name: "BoffinData",
            dependencies: [
                .product(name: "BoffinCore", package: "BoffinCore")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BoffinDataTests",
            dependencies: ["BoffinData"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
