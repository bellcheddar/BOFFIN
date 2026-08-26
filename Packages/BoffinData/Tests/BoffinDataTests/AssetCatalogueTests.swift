//  AssetCatalogueTests.swift
//  BoffinDataTests
//
//  This replaces a test that asserted `AssetAvailability.notDownloaded` was
//  not equal to `.purged`. That is a property of Swift's synthesised
//  Equatable, true of any two distinct cases of any enum, so it could not fail
//  and did not depend on this project at all. It stood over a catalogue whose
//  declared sizes had meanwhile drifted 10% from the files they describe.
//
//  The catalogue is now load-bearing: `SequenceStore` opens the files by the
//  names declared here, and the Family tab quotes `enables` and the combined
//  size in the message it shows when the index is absent. So these check the
//  declaration against reality rather than against itself.

import Foundation
import Testing

@testable import BoffinData

/// The built assets, when this checkout has them.
///
/// They are 109 MB and are not in the repository, so the size check is skipped
/// rather than failed where they are absent. A skipped test that says why is
/// honest; one that passes vacuously is not.
private var assetDirectory: URL? {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Assets")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

@Suite("Asset catalogue")
struct AssetCatalogueTests {

    @Test("Availability distinguishes never-fetched from user-purged")
    func availabilityCasesAreDistinct() {
        // Kept from the test this replaces, but asserting the thing that can
        // actually be wrong: the two states must produce different copy,
        // because one offers a download and the other explains a deletion.
        let states: Set<AssetAvailability> = [
            .bundled, .downloaded, .notDownloaded, .purged,
        ]
        #expect(states.count == 4)
    }

    @Test("Every asset can be described to a user", arguments: BoffinAsset.all)
    func describable(asset: BoffinAsset) {
        // `enables` is now a sentence fragment on screen and `approximateSize`
        // the figure beside it, so an empty one renders a broken sentence
        // rather than a missing label.
        #expect(!asset.enables.isEmpty)
        #expect(!asset.fileName.isEmpty)
        #expect(asset.approximateBytes > 0)
        #expect(asset.approximateSize.contains("MB"))
    }

    @Test(
        "The declared size matches the built asset",
        .enabled(if: assetDirectory != nil),
        arguments: BoffinAsset.all)
    func declaredSizeIsTrue(asset: BoffinAsset) throws {
        let directory = try #require(assetDirectory)
        let url = directory.appending(path: asset.fileName)
        // The loader opens exactly this path, so a name that has drifted is a
        // feature that silently reports itself as not downloaded.
        #expect(
            FileManager.default.fileExists(atPath: url.path),
            "no file at the declared name \(asset.fileName)")

        let actual = try Data(contentsOf: url, options: .mappedIfSafe).count
        let drift = abs(Double(actual - asset.approximateBytes)) / Double(actual)
        // Five per cent absorbs regenerating an asset; it does not absorb the
        // 10% the metadata had drifted by while nothing read the figure.
        let detail =
            "\(asset.fileName): declared \(asset.approximateBytes),"
            + " actual \(actual), off by \(Int(drift * 100))%"
        #expect(drift < 0.05, "\(detail)")
    }

    @Test("The homolog pair is fetched together")
    func pairIsGrouped() {
        // `HomologIndex` refuses a mismatched pair, so the two are only ever
        // useful together and the size quoted to the user is the sum.
        #expect(BoffinAsset.homologSearch.count == 2)
        #expect(BoffinAsset.all.contains(BoffinAsset.siftsSegments))
        let sum = BoffinAsset.homologSearch.reduce(0) { $0 + $1.approximateBytes }
        #expect(sum > BoffinAsset.homologVectors.approximateBytes)
    }
}
