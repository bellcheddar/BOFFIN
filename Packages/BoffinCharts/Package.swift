// swift-tools-version: 6.2
// BOFFIN: BoffinCharts
// Dependency rule (CLAUDE.md): enforced here and re-checked by Tools/check-module-graph.sh in CI.

import PackageDescription

let package = Package(
    name: "BoffinCharts",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "BoffinCharts", targets: ["BoffinCharts"])
    ],
    dependencies: [
        .package(path: "../BoffinCore")
    ],
    targets: [
        .target(
            name: "BoffinCharts",
            dependencies: [
                .product(name: "BoffinCore", package: "BoffinCore")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BoffinChartsTests",
            dependencies: ["BoffinCharts"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
