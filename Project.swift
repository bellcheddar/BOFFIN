//  Project.swift
//  BOFFIN
//
//  The single source of truth for project configuration.
//
//  Hard rule: never hand-edit the .pbxproj. Every target, capability and
//  resource change goes through this file, followed by `tuist generate`. The
//  generated project is gitignored precisely so that editing it is pointless.

import ProjectDescription

// Local SPM packages, one per module. The dependency rule between them is
// declared in each package manifest and re-checked by
// Tools/check-module-graph.sh in CI.
let packages: [Package] = [
    .local(path: "Packages/BoffinCore"),
    .local(path: "Packages/BoffinML"),
    .local(path: "Packages/BoffinData"),
    .local(path: "Packages/BoffinStructure"),
    .local(path: "Packages/BoffinViewer"),
    .local(path: "Packages/BoffinCharts"),
    .local(path: "Packages/BoffinUI"),
]

let baseSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.2",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "SWIFT_TREAT_WARNINGS_AS_ERRORS": "NO",
]

let project = Project(
    name: "BOFFIN",
    organizationName: "Marc C. Deller",
    packages: packages,
    settings: .settings(base: baseSettings),
    targets: [
        .target(
            name: "BOFFIN",
            destinations: [.iPhone, .iPad],
            product: .app,
            bundleId: "com.marcdeller.boffin",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(
                with: [
                    "CFBundleDisplayName": "BOFFIN",
                    "UILaunchScreen": ["UIColorName": "LaunchBackground"],
                    "UISupportedInterfaceOrientations": [
                        "UIInterfaceOrientationPortrait",
                        "UIInterfaceOrientationLandscapeLeft",
                        "UIInterfaceOrientationLandscapeRight",
                    ],
                    "UISupportedInterfaceOrientations~ipad": [
                        "UIInterfaceOrientationPortrait",
                        "UIInterfaceOrientationPortraitUpsideDown",
                        "UIInterfaceOrientationLandscapeLeft",
                        "UIInterfaceOrientationLandscapeRight",
                    ],
                    // BOFFIN works fully offline. No key here may imply
                    // otherwise, and no core path may require the network.
                    "ITSAppUsesNonExemptEncryption": false,
                ]
            ),
            sources: ["App/Sources/**"],
            resources: ["App/Resources/**"],
            dependencies: [
                .package(product: "BoffinCore"),
                .package(product: "BoffinML"),
                .package(product: "BoffinData"),
                .package(product: "BoffinStructure"),
                .package(product: "BoffinViewer"),
                .package(product: "BoffinCharts"),
                .package(product: "BoffinUI"),
            ],
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "BOFFINTests",
            destinations: [.iPhone, .iPad],
            product: .unitTests,
            bundleId: "com.marcdeller.boffin.tests",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .default,
            sources: ["App/Tests/**"],
            dependencies: [.target(name: "BOFFIN")],
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "BOFFINUITests",
            destinations: [.iPhone, .iPad],
            product: .uiTests,
            bundleId: "com.marcdeller.boffin.uitests",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .default,
            sources: ["App/UITests/**"],
            dependencies: [.target(name: "BOFFIN")],
            settings: .settings(base: baseSettings)
        ),
    ],
    schemes: [
        .scheme(
            name: "BOFFIN",
            shared: true,
            buildAction: .buildAction(targets: ["BOFFIN"]),
            testAction: .targets(
                ["BOFFINTests", "BOFFINUITests"],
                options: .options(coverage: true, codeCoverageTargets: ["BOFFIN"])
            ),
            runAction: .runAction(executable: "BOFFIN")
        )
    ]
)
