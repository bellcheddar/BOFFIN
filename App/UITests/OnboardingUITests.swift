//  OnboardingUITests.swift
//  BOFFINUITests
//
//  The one test that launches WITHOUT `-boffin.skip-onboarding`.
//
//  Every other UI test passes that argument, which is the ordinary way to keep
//  a first-run sheet out of tests that are about something else, and it carries
//  the ordinary hazard: a switch that suppresses a feature everywhere looks
//  exactly like a feature that was never wired up. Fourteen green tests would
//  say nothing about whether onboarding exists. This one does.
//
//  It also asserts the sheet is dismissible and that its example button lands a
//  real sequence in the app, because a welcome screen whose call to action does
//  nothing is worse than no welcome screen.

import XCTest

final class OnboardingUITests: XCTestCase {

    /// A fresh install shows the welcome sheet.
    ///
    /// `resetAuthorizationStatus` is not enough: the flag lives in
    /// `UserDefaults`, which survives between runs in a simulator, so the
    /// defaults key is cleared through the argument domain instead. Passing the
    /// key with a `NO` value at launch puts a false in the argument domain,
    /// which takes precedence over anything a previous run persisted.
    func testFirstRunShowsWelcome() {
        let app = XCUIApplication()
        app.launchArguments += ["-boffin.onboarding.seen.v1", "<false/>"]
        app.launch()

        let sheet = app.otherElements["boffin.onboarding"]
        XCTAssertTrue(
            sheet.waitForExistence(timeout: 30),
            "the welcome sheet did not appear on a first run")

        XCTAssertTrue(
            app.staticTexts["Nothing leaves this device"].exists,
            "the on-device claim is the first thing a new user needs and it is missing")
        XCTAssertTrue(
            app.staticTexts["It will tell you when it is guessing"].exists,
            "the limitations paragraph is missing, which is the half that is easy to drop")
    }

    /// The call to action loads a sequence and gets out of the way.
    func testExampleFromWelcomeLoadsASequence() {
        let app = XCUIApplication()
        app.launchArguments += ["-boffin.onboarding.seen.v1", "<false/>"]
        app.launch()

        let example = app.buttons["boffin.onboarding.example.1UBQ"]
        XCTAssertTrue(
            example.waitForExistence(timeout: 30),
            "the welcome sheet offered no example to start from")
        example.tap()

        // The sheet dismisses and the Order tab is showing a real sequence
        // rather than its own empty state.
        XCTAssertTrue(
            app.navigationBars["Order"].waitForExistence(timeout: 15),
            "loading an example did not dismiss the welcome sheet")
        XCTAssertFalse(
            app.buttons["boffin.empty.paste"].exists,
            "the Order tab is still empty, so the example never loaded")
    }

    /// Dismissing without choosing leaves a usable app.
    func testWelcomeIsDismissible() {
        let app = XCUIApplication()
        app.launchArguments += ["-boffin.onboarding.seen.v1", "<false/>"]
        app.launch()

        let done = app.buttons["boffin.onboarding.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 30), "the welcome sheet has no way out")
        done.tap()

        XCTAssertTrue(
            app.navigationBars["Order"].waitForExistence(timeout: 15),
            "dismissing the welcome sheet did not reveal the app")
    }
}
