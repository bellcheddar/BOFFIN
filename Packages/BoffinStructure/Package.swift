// swift-tools-version: 6.2
// BOFFIN: BoffinStructure
// Dependency rule (CLAUDE.md): enforced here and re-checked by Tools/check-module-graph.sh in CI.

import PackageDescription

let package = Package(
    name: "BoffinStructure",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "BoffinStructure", targets: ["BoffinStructure"])
    ],
    dependencies: [
        .package(path: "../BoffinCore")
    ],
    targets: [
        .target(
            name: "BoffinStructure",
            dependencies: [
                .product(name: "BoffinCore", package: "BoffinCore")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BoffinStructureTests",
            dependencies: ["BoffinStructure"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
