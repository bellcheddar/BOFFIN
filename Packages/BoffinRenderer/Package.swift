// swift-tools-version: 6.2
// BOFFIN: BoffinRenderer
// Dependency rule (CLAUDE.md): enforced here and re-checked by Tools/check-module-graph.sh in CI.

import PackageDescription

let package = Package(
    name: "BoffinRenderer",
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: [.library(name: "BoffinRenderer", targets: ["BoffinRenderer"])],
    dependencies: [
        .package(path: "../BoffinCore"),
        .package(path: "../BoffinStructure"),
    ],
    targets: [
        .target(
            name: "BoffinRenderer",
            dependencies: ["BoffinCore", "BoffinStructure"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BoffinRendererTests",
            dependencies: ["BoffinRenderer", "BoffinStructure"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
