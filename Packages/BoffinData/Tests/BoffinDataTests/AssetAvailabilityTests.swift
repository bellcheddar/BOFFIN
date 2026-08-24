//  AssetAvailabilityTests.swift
//  BoffinDataTests

import Testing

@testable import BoffinData

@Suite("Asset availability")
struct AssetAvailabilityTests {

    @Test("Availability distinguishes never-fetched from user-purged")
    func purgedIsDistinctFromNotDownloaded() {
        // The UI copy differs: one offers a download, the other explains that
        // the user removed it. Collapsing them loses that.
        #expect(AssetAvailability.notDownloaded != AssetAvailability.purged)
    }
}
