// swift-tools-version: 6.2
// BOFFIN: BoffinViewer
// Dependency rule (CLAUDE.md): enforced here and re-checked by Tools/check-module-graph.sh in CI.

import PackageDescription

let package = Package(
    name: "BoffinViewer",
    // iOS 26 is the real deployment target. The macOS platform exists only so
    // that `swift test` can run these suites on the host without booting a
    // simulator, so keep it as LOW as the sources compile against: pinning it
    // to the newest macOS makes the test binaries unloadable on any older
    // machine or CI runner ("built for macOS X which is newer than running OS").
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: [
        .library(name: "BoffinViewer", targets: ["BoffinViewer"])
    ],
    dependencies: [
        .package(path: "../BoffinCore"),
        .package(path: "../BoffinStructure"),
    ],
    targets: [
        .target(
            name: "BoffinViewer",
            dependencies: [
                .product(name: "BoffinCore", package: "BoffinCore"),
                .product(name: "BoffinStructure", package: "BoffinStructure"),
            ],
            // Phase 7 vendors the Mol* UMD build here and flips this to
            // resources: [.copy("Resources")]. Excluded until then so SPM does
            // not warn about unhandled files.
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BoffinViewerTests",
            dependencies: ["BoffinViewer"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
