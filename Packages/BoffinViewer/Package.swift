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
            // The vendored Mol* build, copied verbatim: `.copy` rather than
            // `.process` because the JavaScript and CSS must reach the bundle
            // byte for byte, and because their relative paths inside the page
            // are what `loadFileURL` resolves against.
            //
            // The directory is `Web`, not `Resources`. A resource bundle whose
            // root contains a folder called `Resources` is read as a macOS-style
            // bundle and codesign refuses it outright: "bundle format
            // unrecognized, invalid, or unsuitable", at link time, with no clue
            // that a directory name caused it.
            resources: [.copy("Web")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BoffinViewerTests",
            dependencies: ["BoffinViewer"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
