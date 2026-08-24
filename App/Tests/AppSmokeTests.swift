//  AppSmokeTests.swift
//  BOFFINTests

import Testing

@testable import BOFFIN

@Suite("App shell")
struct AppSmokeTests {

    @Test("The app target links every module")
    func appLinksEveryModule() {
        // Phase 0 acceptance: the shell builds with the full module graph
        // wired. Real behaviour is tested inside each package.
        #expect(Bool(true))
    }
}
