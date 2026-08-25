// swift-tools-version: 6.2
// BOFFIN: BoffinData
// Dependency rule (CLAUDE.md): enforced here and re-checked by Tools/check-module-graph.sh in CI.

import PackageDescription

let package = Package(
    name: "BoffinData",
    // iOS 26 is the real deployment target. The macOS platform exists only so
    // that `swift test` can run these suites on the host without booting a
    // simulator, so keep it as LOW as the sources compile against: pinning it
    // to the newest macOS makes the test binaries unloadable on any older
    // machine or CI runner ("built for macOS X which is newer than running OS").
    platforms: [.iOS(.v26), .macOS(.v14)],
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
            // The family numbering tables are 0.5 MB and are needed at runtime,
            // so they are committed and bundled rather than downloaded. They
            // are also the artefact that must never drift from what the motif
            // and numbering code expects.
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BoffinDataTests",
            dependencies: ["BoffinData"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
