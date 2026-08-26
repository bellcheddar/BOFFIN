//  ScreenshotCaptureTests.swift
//  BOFFINUITests
//
//  Captures App Store screenshots at whatever size the host simulator is.
//
//  A test rather than `simctl io screenshot`, because the interesting screens
//  are several taps in and simctl cannot drive the interface. The images come
//  out as attachments in the .xcresult and are extracted from there.
//
//  Not part of the normal suite: it is filtered to by name when screenshots
//  are wanted, and it asserts nothing about appearance, since a test that
//  fails on how something looks fails on every deliberate change too.

import XCTest

final class ScreenshotCaptureTests: XCTestCase {

    override func setUp() { continueAfterFailure = true }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        // Kept whether or not the test passes: the images ARE the output.
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCaptureAppStoreScreenshots() {
        let app = XCUIApplication()
        app.launchSkippingOnboarding()

        // The example sequence rather than a pasted one: it is CDK2, which is
        // the protein every other fixture and benchmark in the project uses.
        app.tapButton("Paste a sequence", timeout: 30)
        app.tapButton("Use the CDK2 example", timeout: 30)
        app.tapButton("Analyse", timeout: 30)

        // The backbone is compiled by Core ML on first load, which is about a
        // minute here, so this waits far longer than a normal test would.
        let loaded = app.staticTexts["298 residues \u{00B7} UniProt P24941"]
        XCTAssertTrue(loaded.waitForExistence(timeout: 300), "the sequence never loaded")

        for (tab, name) in [
            ("Fitness", "02-fitness"), ("Family", "03-family"),
            ("Boundary", "04-boundary"),
        ] {
            app.openTab(tab)
            // Long enough for the tab's own analysis to land, since an empty
            // panel is a worse screenshot than a slow one.
            Thread.sleep(forTimeInterval: 25)
            capture(app, name)
        }

        app.openTab("Structure")
        app.tapButton("Load 1UBQ", timeout: 30)
        Thread.sleep(forTimeInterval: 40)
        capture(app, "05-structure")

        // Order is captured LAST, and that is deliberate rather than tidy.
        // Taken first, it caught a freshly booted simulator's "Ready for Apple
        // Intelligence" notification banner across the top of the frame: not
        // usable on a store listing, and the sort of thing missed entirely if
        // you only check that the capture succeeded. By this point in the run
        // the banner is long gone.
        app.openTab("Order")
        Thread.sleep(forTimeInterval: 5)
        capture(app, "01-order")
    }
}
