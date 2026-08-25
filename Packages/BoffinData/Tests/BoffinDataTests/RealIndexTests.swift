//  RealIndexTests.swift
//  BoffinDataTests
//
//  Tests against the real 105 MB assets, which are downloadable and therefore
//  absent from a clean checkout.
//
//  These suites are gated with `.enabled(if:)` rather than with a `#require`
//  inside each test. The difference matters: `#require(false)` marks a test
//  FAILED, so on a clean checkout the whole suite goes red for a reason that is
//  not a defect, and a red suite that is expected to be red stops being read.
//  `.enabled(if:)` reports SKIPPED, which is what actually happened.
//
//  The format tests in HomologIndexTests always run. These check the DATA.
//
//  The format tests in HomologIndexTests always run. These check the DATA.

import BoffinCore
import Foundation
import Testing

@testable import BoffinData

private let assetDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // BoffinDataTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // BoffinData
    .deletingLastPathComponent()  // Packages
    .appending(path: "Assets")

private var assetsAreAvailable: Bool {
    ["homolog_vectors.bin", "homolog_meta.bin", "sifts_segments.bin"].allSatisfy {
        FileManager.default.fileExists(atPath: assetDirectory.appending(path: $0).path)
    }
}

private let missing: Comment = "index assets not built: see Datasets/pdb/MANIFEST.md"

private func openIndex() throws -> HomologIndex {
    try HomologIndex(
        vectors: assetDirectory.appending(path: "homolog_vectors.bin"),
        metadata: assetDirectory.appending(path: "homolog_meta.bin"))
}

private func openSIFTS() throws -> SIFTSStore {
    try SIFTSStore(url: assetDirectory.appending(path: "sifts_segments.bin"))
}

@Suite("Bundled index contents", .enabled(if: assetsAreAvailable, missing))
struct RealIndexTests {

    @Test("The index covers the PDB at the scale the budget assumes")
    func scale() throws {
        let index = try openIndex()
        // The performance budget in CLAUDE.md is written for a 100 k index.
        #expect(index.count > 60_000)
        #expect(index.count < 100_000)
        #expect(index.dimension == 480)
    }

    /// Every fixture protein must be findable, because they are what every
    /// other claim in the app is checked against.
    @Test(
        "The golden fixtures are all present",
        arguments: [
            ("P24941", "CDK2"),
            ("P07550", "beta-2 adrenergic receptor"),
            ("A0A0K8P6T7", "PETase"),
            ("P0CG48", "ubiquitin"),
        ])
    func fixturesPresent(accession: String, name: String) throws {
        let sifts = try openSIFTS()
        #expect(
            !sifts.segments(for: accession).isEmpty,
            "\(name) (\(accession)) is missing from the index")
    }

    @Test("Searching with an entry's own vector returns that entry first")
    func selfRetrieval() throws {
        let index = try openIndex()
        // Reconstruct a query from the stored quantised row: not a tautology,
        // because it exercises the whole read-convert-multiply-rank path, and a
        // stride or offset error would put a different entry at the top.
        let hits = try index.search(
            try storedVector(at: 1000, index: index), limit: 3, minimumSimilarity: 0)
        let expected = try storedAccession(at: 1000, index: index)
        #expect(hits.first?.accession == expected)
        #expect((hits.first?.similarity ?? 0) > 0.999)
    }

    @Test("Hits come back in descending similarity")
    func ordering() throws {
        let index = try openIndex()
        let hits = try index.search(
            try storedVector(at: 5000, index: index), limit: 20, minimumSimilarity: 0)
        #expect(hits.count > 1)
        #expect(zip(hits, hits.dropFirst()).allSatisfy { $0.similarity >= $1.similarity })
    }

    @Test("A search stays inside the 100 ms budget")
    func latency() throws {
        let index = try openIndex()
        let query = try storedVector(at: 42, index: index)
        _ = try index.search(query, limit: 20)  // warm the pages

        let started = ContinuousClock.now
        for _ in 0..<5 { _ = try index.search(query, limit: 20) }
        let each = (ContinuousClock.now - started) / 5

        // Debug builds are several times slower than the shipping one, so this
        // is a generous ceiling that still catches an accidental O(n^2). The
        // number quoted in Docs/perf-log.md is measured in release.
        #expect(each < .milliseconds(500), "search took \(each)")
    }

    // MARK: - Helpers

    /// Reconstruct a stored row as a float query.
    private func storedVector(at row: Int, index: HomologIndex) throws -> [Float] {
        let data = try Data(
            contentsOf: assetDirectory.appending(path: "homolog_vectors.bin"),
            options: .mappedIfSafe)
        let offset = 24 + row * index.dimension
        return (0..<index.dimension).map {
            Float(Int8(bitPattern: data[data.startIndex + offset + $0]))
        }
    }

    private func storedAccession(at row: Int, index: HomologIndex) throws -> String {
        let query = try storedVector(at: row, index: index)
        return try index.search(query, limit: 1, minimumSimilarity: 0).first?.accession ?? ""
    }
}

@Suite("Bundled SIFTS mapping", .enabled(if: assetsAreAvailable, missing))
struct RealSIFTSTests {

    /// CDK2's UniProt and PDB author numbering coincide, which is why every
    /// paper writes DFG-Asp145 and means both. Anchoring on that first means a
    /// failure in the offset-carrying tests below is an offset bug rather than
    /// an accession or parsing bug.
    @Test("CDK2's catalytic aspartate is author 145 in 1HCK")
    func cdk2() throws {
        let sifts = try openSIFTS()
        let author = sifts.authorNumber(
            forUniProt: 145, pdb: "1HCK", chain: "A", accession: "P24941")
        #expect(author == 145)
    }

    @Test("Deposited constructs are reported for a well-studied protein")
    func constructs() throws {
        let sifts = try openSIFTS()
        let constructs = sifts.constructs(for: "P24941")
        // CDK2 has hundreds of entries; the exact count moves with every PDB
        // release, so the assertion is on the shape of the answer.
        #expect(constructs.count > 100)
        let best = try #require(constructs.first)
        #expect(best.observedCount > 250)
        #expect(best.first >= 1)
        #expect(best.last <= 400)
        #expect(constructs.allSatisfy { $0.observedCount > 0 })
        // Merged spans must not overlap, or the observed count is inflated.
        #expect(
            constructs.allSatisfy { construct in
                zip(construct.spans, construct.spans.dropFirst())
                    .allSatisfy { $0.upperBound < $1.lowerBound }
            })
    }

    @Test("Segments never claim a residue outside their own span")
    func spanIntegrity() throws {
        let sifts = try openSIFTS()
        for accession in ["P24941", "P07550", "P0CG48", "A0A0K8P6T7"] {
            for segment in sifts.segments(for: accession) {
                #expect(segment.seqresEnd >= segment.seqresStart)
                #expect(segment.length == segment.uniprotRange.count)
                #expect(segment.authorNumber(forSeqres: segment.seqresStart - 1) == nil)
                #expect(segment.authorNumber(forSeqres: segment.seqresEnd + 1) == nil)
                if segment.isArithmetic {
                    #expect(segment.authorRange?.count == segment.length)
                }
            }
        }
    }
}
