//  NeuralEngineBarUITests.swift
//  BOFFINUITests
//
//  The bar exists to show the Neural Engine really working, so a test that
//  only checked it was on screen would miss the point entirely.
//
//  It does NOT try to catch the indicator mid-pulse. The first version did,
//  and failed: on a warm simulator the backbone is already compiled and a
//  whole analysis finishes in 373 ms, well inside the polling interval. The
//  thing that proves the bar is wired to real work is the evidence it leaves
//  behind -- a pass count and a duration it could not have without having run
//  something.

import XCTest

final class NeuralEngineBarUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testTheBarIsAbsentBeforeItHasRunAnything() {
        let app = XCUIApplication()
        app.launchSkippingOnboarding()

        // Absent before anything has run: it is an indicator, not chrome, and
        // a strip permanently announcing "idle" would take 24 points from
        // every screen to say nothing.
        let bar = app.otherElements["boffin.ane-bar"]
        XCTAssertFalse(
            bar.waitForExistence(timeout: 5),
            "the bar is on screen before the model has run: \(bar.label)")
    }

    func testTheBarReportsTheWorkItActuallyDid() throws {
        let app = XCUIApplication()
        app.launchSkippingOnboarding()
        let bar = app.otherElements["boffin.ane-bar"]

        app.tapButton("Paste a sequence", timeout: 30)
        app.tapButton("Use the CDK2 example", timeout: 30)
        app.tapButton("Analyse", timeout: 30)
        XCTAssertTrue(
            app.staticTexts["298 residues \u{00B7} UniProt P24941"]
                .waitForExistence(timeout: 300),
            "the sequence never loaded")

        // The models are gitignored, so a CI checkout has none and no pass can
        // run. The bar is then correctly ABSENT, and asserting it appears
        // would be asserting that a build without models behaves as though it
        // had them. Skipped with the reason stated rather than passed
        // vacuously.
        if app.staticTexts["Analysis models are not bundled in this build."]
            .waitForExistence(timeout: 20)
        {
            throw XCTSkip("no analysis models in this build, so no pass can run")
        }

        // Counted passes are the evidence: the bar cannot know this number
        // without the model having run, so its presence is what distinguishes
        // an indicator from a decoration.
        var reported = false
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if bar.label.contains("pass") { reported = true; break }
            usleep(200_000)
        }
        XCTAssertTrue(reported, "the bar reports no passes after analysing: \(bar.label)")
        XCTAssertTrue(
            bar.label.contains("last"),
            "the bar reports no duration for the pass it ran: \(bar.label)")
        // And it settles: an indicator left active after the work has finished
        // says the hardware is busy when it is not.
        XCTAssertTrue(bar.label.contains("idle"), "the bar never settled: \(bar.label)")
        // The measured residency, stated as SCHEDULED rather than used: it
        // comes from MLComputePlan, and a plan is not an execution trace.
        XCTAssertTrue(
            bar.label.contains("746 of 755"),
            "the bar does not state the measured residency: \(bar.label)")
        XCTAssertTrue(bar.label.contains("scheduled"), "residency stated as more than a plan")
    }
}
