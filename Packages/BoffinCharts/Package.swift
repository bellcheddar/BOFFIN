// swift-tools-version: 6.2
// BOFFIN: BoffinCharts
// Dependency rule (CLAUDE.md): enforced here and re-checked by Tools/check-module-graph.sh in CI.

import PackageDescription

let package = Package(
    name: "BoffinCharts",
    // iOS 26 is the real deployment target. The macOS platform exists only so
    // that `swift test` can run these suites on the host without booting a
    // simulator, so keep it as LOW as the sources compile against: pinning it
    // to the newest macOS makes the test binaries unloadable on any older
    // machine or CI runner ("built for macOS X which is newer than running OS").
    platforms: [.iOS(.v26), .macOS(.v14)],
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
