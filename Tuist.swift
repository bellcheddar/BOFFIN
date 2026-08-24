//  Tuist.swift
//  BOFFIN
//
//  Tuist 4.x configuration. The generated .xcodeproj is disposable and is not
//  committed: regenerate with `tuist generate`.

import ProjectDescription

let tuist = Tuist(
    project: .tuist(
        compatibleXcodeVersions: .upToNextMajor("26.0"),
        swiftVersion: "6.2"
    )
)
