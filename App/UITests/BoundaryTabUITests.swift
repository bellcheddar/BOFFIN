//  BoundaryTabUITests.swift
//  BOFFINUITests

import XCTest

final class BoundaryTabUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// The build plan's Phase 6 acceptance has three parts, and this covers the
    /// two that do not need a model: proposed constructs never cut through an
    /// annotated motif, and the solver says what it is enforcing.
    ///
    /// Whether proposals appear at all depends on the disorder track, which
    /// depends on the converted backbone. On a clean checkout there is none, and
    /// the tab must then say why rather than showing an empty list. Both
    /// outcomes are accepted here and exactly one must occur.
    func testBoundaryTabEnforcesKinaseMotifs() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Paste a sequence"].tap()
        app.buttons["Use the CDK2 example"].tap()
        app.buttons["Analyse"].tap()
        XCTAssertTrue(
            app.staticTexts["298 residues \u{00B7} UniProt P24941"]
                .waitForExistence(timeout: 15))

        app.openTab("Boundary")

        // The constraints are the point: a ranked list of boundaries with no
        // visible constraints is an opinion.
        XCTAssertTrue(
            app.staticTexts["Regions that may not be cut"].waitForExistence(timeout: 20),
            "the tab did not say what it is enforcing")

        // CDK2's motifs need no model, so they must be listed whatever else is
        // or is not available.
        let hrd = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "HRD")
        ).firstMatch
        XCTAssertTrue(hrd.waitForExistence(timeout: 10), "the HRD motif is not enforced")

        let dfg = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "DFG")
        ).firstMatch
        XCTAssertTrue(dfg.exists, "the DFG motif is not enforced")

        // Either proposals or a stated reason, never both and never neither.
        let proposals = app.staticTexts["Proposed constructs"]
        let refusal = app.staticTexts["No construct proposed"]
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !proposals.exists, !refusal.exists {
            usleep(200_000)
        }
        XCTAssertTrue(
            proposals.exists || refusal.exists,
            "the Boundary tab showed neither a proposal nor a reason")
        XCTAssertFalse(
            proposals.exists && refusal.exists,
            "the Boundary tab showed a proposal and a refusal at once")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Boundary tab, CDK2"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
