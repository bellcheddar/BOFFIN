//  LibraryUITests.swift
//  BOFFINUITests
//
//  The library is the app's only persistent state, and the sync toggle is the
//  only thing that sends anything off the device. Both are worth a test that
//  drives the real interface.

import XCTest

final class LibraryUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testSavingASequenceAndFindingItAgain() {
        let app = XCUIApplication()
        app.launchSkippingOnboarding()
        app.tapButton("Paste a sequence", timeout: 30)
        app.tapButton("Use the CDK2 example", timeout: 30)
        app.tapButton("Analyse", timeout: 30)
        XCTAssertTrue(
            app.staticTexts["298 residues \u{00B7} UniProt P24941"]
                .waitForExistence(timeout: 300),
            "the sequence never loaded")

        app.tapButton("Library", timeout: 20)
        let save = app.buttons["boffin.library.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 20), "no save button")
        save.tap()

        // The saved row carries the residue count, which is what distinguishes
        // a real entry from an empty placeholder row.
        let row = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "298 residues")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the sequence was not saved")
    }

    func testSyncIsOffUntilAskedFor() {
        let app = XCUIApplication()
        app.launchSkippingOnboarding()
        app.tapButton("Library", timeout: 30)

        let toggle = app.switches["boffin.library.sync"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "no sync toggle")
        // Default OFF is the whole basis of the app's claim that nothing
        // leaves the device. A default that drifted to on would make the
        // README's headline sentence untrue without anything failing.
        XCTAssertEqual(toggle.value as? String, "0", "iCloud sync defaults to ON")
    }
}
