//  ViewerEventTests.swift
//  BoffinViewerTests

import Testing

@testable import BoffinViewer

@Suite("Viewer bridge")
struct ViewerEventTests {

    @Test("A pick event carries author numbering, not a sequence index")
    func pickCarriesAuthorNumbering() {
        // The viewer speaks in the depositor's numbering. Translating to
        // sequence indices is BoffinCore's job, via SIFTS, and must not be
        // assumed to be the identity mapping.
        let event = ViewerEvent.picked(chainID: "A", authorNumber: 52)
        guard case .picked(let chainID, let authorNumber) = event else {
            Issue.record("Expected a pick event")
            return
        }
        #expect(chainID == "A")
        #expect(authorNumber == 52)
    }
}
