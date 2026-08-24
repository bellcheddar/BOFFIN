// swift-tools-version: 6.2
// BOFFIN: BoffinViewer
// Dependency rule (CLAUDE.md): enforced here and re-checked by Tools/check-module-graph.sh in CI.

import PackageDescription

let package = Package(
    name: "BoffinViewer",
    platforms: [.iOS(.v26), .macOS(.v26)],
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
