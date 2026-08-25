//  HomologIndexTests.swift
//  BoffinDataTests
//
//  The index and SIFTS assets are 110 MB and are delivered by Background
//  Assets, so they are absent from a clean checkout. These suites therefore
//  come in two halves:
//
//  * format tests, which build a tiny index in a temporary directory and always
//    run, so a reader bug cannot hide behind a missing file;
//  * real-data tests, which skip with an explicit reason when the assets are
//    not present.
//
//  A test that silently passes because its input is missing is worse than no
//  test, so nothing here treats absence as success.

import BoffinCore
import Foundation
import Testing

@testable import BoffinData

/// Build the binary formats the app reads, matching `pack_index_assets.py`.
private struct SegmentRow {
    let accession: String
    let pdb: String
    let chain: String
    let seqres: ClosedRange<Int>
    let uniprot: Int
    let author: Int
    let arithmetic: Bool
}

private enum Fixture {

    /// Build a vector file, optionally with a whitening transform.
    ///
    /// The default is an identity transform (zero mean, no components), so the
    /// ranking tests read as plain cosine. `whitenedVectors` exercises the
    /// transform itself.
    static func vectors(
        _ rows: [[Float]], mean: [Float] = [], components: [[Float]] = [],
        floor: Float = 0.5
    ) -> Data {
        var data = Data("BOFHVEC2".utf8)
        let dimension = rows.first?.count ?? 0
        for value in [
            UInt32(rows.count), UInt32(dimension), 1, UInt32(components.count),
        ] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        withUnsafeBytes(of: floor.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        let meanValues = mean.isEmpty ? [Float](repeating: 0, count: dimension) : mean
        for value in meanValues {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        for component in components {
            for value in component {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        // The rows are whitened here exactly as `pack_index_assets.py` whitens
        // them, because that is what the file format means. Storing raw rows
        // next to a non-identity transform would describe a file the packer
        // never produces, and the test would be checking a fiction.
        for row in rows {
            var transformed = zip(row, meanValues).map(-)
            for component in components where component.count == transformed.count {
                let projection = zip(transformed, component).map(*).reduce(0, +)
                for index in transformed.indices {
                    transformed[index] -= projection * component[index]
                }
            }
            let norm = transformed.reduce(0) { $0 + $1 * $1 }.squareRoot()
            for value in transformed {
                let scaled = norm > 0 ? value / norm * 127 : 0
                data.append(UInt8(bitPattern: Int8(clamping: Int(scaled.rounded()))))
            }
        }
        return data
    }

    static func metadata(_ lines: [String]) -> Data {
        let encoded = lines.map { Array($0.utf8) }
        var offsets: [UInt32] = []
        var cursor: UInt32 = 0
        for line in encoded {
            offsets.append(cursor)
            cursor += UInt32(line.count)
        }
        offsets.append(cursor)

        var data = Data("BOFHMET1".utf8)
        let textOffset = UInt32(16 + 4 * offsets.count)
        for value in [UInt32(lines.count), textOffset] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        for offset in offsets {
            withUnsafeBytes(of: offset.littleEndian) { data.append(contentsOf: $0) }
        }
        for line in encoded { data.append(contentsOf: line) }
        return data
    }

    static func record(
        accession: String, pdb: String, chain: String, resolution: String,
        method: String = "x-ray diffraction", structures: Int = 1, title: String,
        sequence: String
    ) -> String {
        [
            accession, pdb, chain, resolution, method,
            String(sequence.count), String(structures), title, sequence,
        ].joined(separator: "\t")
    }

    static func segments(
        _ rows: [SegmentRow]
    ) -> Data {
        let names = Set(rows.map(\.accession)).sorted()
        var nameBytes = Data()
        var spans: [String: (UInt32, UInt16)] = [:]
        for name in names {
            spans[name] = (UInt32(nameBytes.count), UInt16(name.utf8.count))
            nameBytes.append(contentsOf: Array(name.utf8))
        }

        var accessionRecords = Data()
        var segmentRecords = Data()
        var first: UInt32 = 0
        for name in names {
            let group = rows.filter { $0.accession == name }
            for row in group {
                func fixed(_ text: String) -> [UInt8] {
                    var bytes = Array(text.utf8.prefix(4))
                    while bytes.count < 4 { bytes.append(0) }
                    return bytes
                }
                segmentRecords.append(contentsOf: fixed(row.pdb))
                segmentRecords.append(contentsOf: fixed(row.chain))
                for value in [
                    Int32(row.seqres.lowerBound), Int32(row.seqres.upperBound),
                    Int32(row.uniprot), Int32(row.author),
                ] {
                    withUnsafeBytes(of: value.littleEndian) {
                        segmentRecords.append(contentsOf: $0)
                    }
                }
                segmentRecords.append(row.arithmetic ? 1 : 0)
                segmentRecords.append(contentsOf: [0, 0, 0])
            }
            let (offset, length) = spans[name] ?? (0, 0)
            withUnsafeBytes(of: offset.littleEndian) { accessionRecords.append(contentsOf: $0) }
            withUnsafeBytes(of: length.littleEndian) { accessionRecords.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt16(0).littleEndian) { accessionRecords.append(contentsOf: $0) }
            withUnsafeBytes(of: first.littleEndian) { accessionRecords.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(group.count).littleEndian) {
                accessionRecords.append(contentsOf: $0)
            }
            first += UInt32(group.count)
        }

        var data = Data("BOFSIFT1".utf8)
        let namesOffset = UInt32(24 + 16 * names.count)
        let segmentsOffset = namesOffset + UInt32(nameBytes.count)
        for value in [
            UInt32(names.count), first, namesOffset, segmentsOffset,
        ] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(accessionRecords)
        data.append(nameBytes)
        data.append(segmentRecords)
        return data
    }

    /// Write a fixture to a UNIQUE path.
    ///
    /// Fixed names looked tidier and were wrong: swift-testing runs tests in
    /// parallel, so two suites writing `m.bin` raced and one read the file
    /// mid-write, failing with "metadata file is not BOFHMET1". The header check
    /// did its job; the fixture was the bug.
    static func write(_ data: Data, named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "boffin-index-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

@Suite("Homolog index format")
struct HomologIndexFormatTests {

    private func build() throws -> HomologIndex {
        let rows: [[Float]] = [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0.9, 0.1, 0, 0],
            [-1, 0, 0, 0],
        ]
        let lines = [
            Fixture.record(
                accession: "P00001", pdb: "1AAA", chain: "A", resolution: "1.50",
                title: "first", sequence: "ACDEFGHIKL"),
            Fixture.record(
                accession: "P00002", pdb: "2BBB", chain: "B", resolution: "",
                method: "solution nmr", title: "second", sequence: "MNPQRSTVWY"),
            Fixture.record(
                accession: "P00003", pdb: "3CCC", chain: "C", resolution: "2.10",
                structures: 12, title: "third", sequence: "ACDEFGHIKM"),
            Fixture.record(
                accession: "P00004", pdb: "4DDD", chain: "D", resolution: "3.00",
                title: "opposite", sequence: "WWWWWWWWWW"),
        ]
        return try HomologIndex(
            vectors: Fixture.write(Fixture.vectors(rows), named: "v.bin"),
            metadata: Fixture.write(Fixture.metadata(lines), named: "m.bin"))
    }

    @Test("Header is read and the two files are checked against each other")
    func header() throws {
        let index = try build()
        #expect(index.count == 4)
        #expect(index.dimension == 4)
    }

    @Test("Nearest neighbours come back in similarity order")
    func ranking() throws {
        let index = try build()
        let hits = try index.search([1, 0, 0, 0], limit: 3, minimumSimilarity: 0)
        #expect(hits.map(\.accession) == ["P00001", "P00003", "P00002"])
        // Quantisation to int8 costs about 1/127 of full scale, so an exact
        // match reads as very slightly under 1 rather than exactly 1.
        #expect(abs(hits[0].similarity - 1.0) < 0.01)
        #expect(abs(hits[1].similarity - 0.9939) < 0.01)
    }

    @Test("Metadata fields land in the right properties")
    func metadata() throws {
        let index = try build()
        let hits = try index.search([1, 0, 0, 0], limit: 4, minimumSimilarity: -1)
        let hit = try #require(hits.first { $0.accession == "P00003" })
        #expect(hit.pdb == "3CCC")
        #expect(hit.chain == "C")
        #expect(hit.resolution == 2.10)
        #expect(hit.structureCount == 12)
        #expect(hit.title == "third")
        #expect(hit.sequence == "ACDEFGHIKM")
        #expect(hit.residueCount == 10)
    }

    @Test("A method that reports no resolution gives nil, not zero")
    func absentResolution() throws {
        let index = try build()
        let hit = try #require(
            try index.search([0, 1, 0, 0], limit: 1, minimumSimilarity: 0).first)
        #expect(hit.accession == "P00002")
        // Zero would sort as the best possible structure in any downstream
        // ranking, which is the wrong way round for "not applicable".
        #expect(hit.resolution == nil)
        #expect(hit.method == "solution nmr")
    }

    @Test("The similarity floor removes hits rather than ranking them low")
    func floor() throws {
        let index = try build()
        let hits = try index.search([1, 0, 0, 0], limit: 10, minimumSimilarity: 0.5)
        #expect(hits.count == 2)
        #expect(!hits.contains { $0.accession == "P00004" })
    }

    @Test("A query of the wrong width is refused, not truncated")
    func dimensionMismatch() throws {
        let index = try build()
        #expect(throws: HomologIndexError.self) {
            _ = try index.search([1, 0, 0], limit: 1)
        }
    }

    @Test("The stored whitening transform is applied to the query")
    func whitening() throws {
        // Two entries that differ only in the first component, and a stored
        // mean that removes the shared part. Without the transform a query of
        // [10, 1, 0, 0] is close to both; with it, the shared offset is gone and
        // only the difference decides.
        let rows: [[Float]] = [[1, 1, 0, 0], [-1, 1, 0, 0]]
        let index = try HomologIndex(
            vectors: Fixture.write(
                Fixture.vectors(rows, mean: [0, 1, 0, 0]), named: "vw.bin"),
            metadata: Fixture.write(
                Fixture.metadata([
                    Fixture.record(
                        accession: "P00001", pdb: "1AAA", chain: "A", resolution: "1.0",
                        title: "plus", sequence: "AA"),
                    Fixture.record(
                        accession: "P00002", pdb: "2BBB", chain: "B", resolution: "1.0",
                        title: "minus", sequence: "CC"),
                ]), named: "mw.bin"))

        // After centring, the stored rows are [1,0,0,0] and [-1,0,0,0].
        // A query of [5, 1, 0, 0] centres to [5, 0, 0, 0], which matches the
        // first exactly and opposes the second.
        let hits = try index.search([5, 1, 0, 0], limit: 2, minimumSimilarity: -1)
        #expect(hits.first?.accession == "P00001")
        #expect(abs((hits.first?.similarity ?? 0) - 1.0) < 0.01)
        #expect(hits.last?.accession == "P00002")
        #expect((hits.last?.similarity ?? 0) < -0.9)
    }

    @Test("A stored principal direction is projected out of the query")
    func componentRemoval() throws {
        // The first axis carries the dominant direction; removing it leaves the
        // second to decide. Without the projection the first entry would win on
        // the shared axis alone.
        let rows: [[Float]] = [[1, 0, 0, 0], [0, 1, 0, 0]]
        let index = try HomologIndex(
            vectors: Fixture.write(
                Fixture.vectors(rows, components: [[1, 0, 0, 0]]), named: "vc.bin"),
            metadata: Fixture.write(
                Fixture.metadata([
                    Fixture.record(
                        accession: "P00001", pdb: "1AAA", chain: "A", resolution: "1.0",
                        title: "axis", sequence: "AA"),
                    Fixture.record(
                        accession: "P00002", pdb: "2BBB", chain: "B", resolution: "1.0",
                        title: "other", sequence: "CC"),
                ]), named: "mc.bin"))

        let hits = try index.search([9, 1, 0, 0], limit: 2, minimumSimilarity: -1)
        #expect(hits.first?.accession == "P00002", "the dominant axis was not removed")
    }

    @Test("Vector and metadata files from different builds refuse to load")
    func mismatchedFiles() throws {
        let vectors = try Fixture.write(
            Fixture.vectors([[1, 0], [0, 1], [1, 1]]), named: "v3.bin")
        let metadata = try Fixture.write(
            Fixture.metadata([
                Fixture.record(
                    accession: "P00001", pdb: "1AAA", chain: "A", resolution: "1.0",
                    title: "only", sequence: "AA")
            ]), named: "m1.bin")
        #expect(throws: HomologIndexError.self) {
            _ = try HomologIndex(vectors: vectors, metadata: metadata)
        }
    }
}

@Suite("SIFTS segment mapping")
struct SIFTSStoreTests {

    /// A deliberately awkward case, and all of it is real behaviour:
    /// author numbering starting at -4 for an expression tag, a disordered loop
    /// splitting the chain into two segments, and a non-arithmetic segment.
    private func build() throws -> SIFTSStore {
        let data = Fixture.segments([
            SegmentRow(
                accession: "P00001", pdb: "1AAA", chain: "A", seqres: 1...20,
                uniprot: 1, author: -4, arithmetic: true),
            SegmentRow(
                accession: "P00001", pdb: "1AAA", chain: "A", seqres: 31...50,
                uniprot: 31, author: 26, arithmetic: true),
            SegmentRow(
                accession: "P00001", pdb: "2BBB", chain: "B", seqres: 1...50,
                uniprot: 1, author: 1, arithmetic: true),
            SegmentRow(
                accession: "P00002", pdb: "3CCC", chain: "C", seqres: 1...10,
                uniprot: 100, author: 0, arithmetic: false),
        ])
        return try SIFTSStore(url: Fixture.write(data, named: "s.bin"))
    }

    @Test("Author numbering is offset, not assumed to start at one")
    func offset() throws {
        let store = try build()
        let segments = store.segments(for: "P00001")
        #expect(segments.count == 3)
        let first = try #require(segments.first { $0.pdb == "1AAA" && $0.seqresStart == 1 })
        #expect(first.authorNumber(forSeqres: 1) == -4)
        #expect(first.authorNumber(forSeqres: 20) == 15)
        #expect(first.uniprotNumber(forSeqres: 20) == 20)
    }

    @Test("A residue in a disordered gap has no number rather than a guessed one")
    func gap() throws {
        let store = try build()
        let segments = store.segments(for: "P00001").filter { $0.pdb == "1AAA" }
        // Residue 25 falls between the two observed segments. Interpolating
        // would produce 20, which is a real author number belonging to a
        // different residue.
        #expect(segments.allSatisfy { $0.authorNumber(forSeqres: 25) == nil })
        #expect(
            store.authorNumber(
                forUniProt: 25, pdb: "1AAA", chain: "A", accession: "P00001") == nil)
        #expect(
            store.authorNumber(
                forUniProt: 31, pdb: "1AAA", chain: "A", accession: "P00001") == 26)
    }

    @Test("A non-arithmetic segment yields no author number at all")
    func insertionCoded() throws {
        let store = try build()
        let segment = try #require(store.segments(for: "P00002").first)
        #expect(segment.isArithmetic == false)
        #expect(segment.authorNumber(forSeqres: 5) == nil)
        #expect(segment.authorRange == nil)
        // UniProt numbering is still derivable: it is the AUTHOR numbering that
        // carries the insertion codes.
        #expect(segment.uniprotNumber(forSeqres: 5) == 104)
    }

    @Test("Constructs group by chain and merge overlapping spans")
    func constructs() throws {
        let store = try build()
        let constructs = store.constructs(for: "P00001")
        #expect(constructs.count == 2)
        // 2BBB observed 50 residues in one run; 1AAA observed 40 across two.
        #expect(constructs[0].pdb == "2BBB")
        #expect(constructs[0].observedCount == 50)
        #expect(constructs[0].disorderedCount == 0)
        #expect(constructs[1].pdb == "1AAA")
        #expect(constructs[1].observedCount == 40)
        #expect(constructs[1].spans.count == 2)
        #expect(constructs[1].disorderedCount == 10)
    }

    @Test("An unknown accession returns nothing and does not crash the search")
    func missing() throws {
        let store = try build()
        #expect(store.segments(for: "Q99999").isEmpty)
        #expect(store.segments(for: "A").isEmpty)
        #expect(store.constructs(for: "P99999").isEmpty)
    }
}

@Suite("Homolog alignment and residue mapping")
struct HomologAlignmentTests {

    private func residues(_ text: String) -> [AminoAcid] {
        text.compactMap { AminoAcid(rawValue: $0) }
    }

    private func hit(sequence: String) -> HomologHit {
        HomologHit(
            accession: "P00001", pdb: "1AAA", chain: "A", resolution: 1.5,
            method: "x-ray diffraction", residueCount: sequence.count,
            structureCount: 1, title: "test", sequence: sequence, similarity: 0.9)
    }

    @Test("A query residue maps through the alignment onto the author number")
    func mapped() {
        let reference = "ACDEFGHIKLMNPQRSTVWY"
        let alignment = HomologAlignment(
            hit: hit(sequence: reference),
            query: residues(reference),
            reference: residues(reference),
            segments: [
                SIFTSSegment(
                    pdb: "1AAA", chain: "A", seqresStart: 1, seqresEnd: 20,
                    uniprotStart: 1, authorStart: 101, isArithmetic: true)
            ])
        #expect(alignment.identity == 1.0)
        #expect(alignment.coverage == 1.0)
        #expect(alignment.mapping(forQueryResidue: 0).authorNumber == 101)
        #expect(alignment.mapping(forQueryResidue: 19).authorNumber == 120)
    }

    @Test("Each way of failing to map is reported as itself")
    func failures() {
        // The query carries a five-residue insertion the reference does not
        // have, and the reference's last five residues were not observed.
        let reference = "ACDEFGHIKLMNPQRSTVWY"
        let query = "ACDEFWWWWWGHIKLMNPQRSTVWY"
        let alignment = HomologAlignment(
            hit: hit(sequence: reference),
            query: residues(query),
            reference: residues(reference),
            segments: [
                SIFTSSegment(
                    pdb: "1AAA", chain: "A", seqresStart: 1, seqresEnd: 15,
                    uniprotStart: 1, authorStart: 1, isArithmetic: true)
            ])

        #expect(alignment.mapping(forQueryResidue: 0).authorNumber == 1)
        // The inserted tryptophans align to nothing in the reference.
        #expect(alignment.mapping(forQueryResidue: 6) == .unmapped(.notAligned))
        // The C-terminal residues align but SIFTS says they were not resolved.
        #expect(alignment.mapping(forQueryResidue: 24) == .unmapped(.notObserved))

        // Identity is denominated on the REFERENCE, so a query carrying an
        // insertion still matches every reference residue and reads 100%.
        // That is the correct answer to "how much of the reference did this
        // reproduce" and the wrong answer to "how alike are these two", which
        // is why COVERAGE is reported next to it and never omitted: 20 of the
        // query's 25 residues aligned.
        #expect(alignment.identity == 1.0)
        #expect(abs(alignment.coverage - 0.8) < 1e-9)
    }

    @Test("A non-arithmetic segment reports insertion coding, not absence")
    func insertionCoded() {
        let reference = "ACDEFGHIKL"
        let alignment = HomologAlignment(
            hit: hit(sequence: reference),
            query: residues(reference),
            reference: residues(reference),
            segments: [
                SIFTSSegment(
                    pdb: "1AAA", chain: "A", seqresStart: 1, seqresEnd: 10,
                    uniprotStart: 1, authorStart: 0, isArithmetic: false)
            ])
        #expect(alignment.mapping(forQueryResidue: 3) == .unmapped(.insertionCoded))
    }

    @Test("Segments belonging to another chain are ignored")
    func otherChain() {
        let reference = "ACDEFGHIKL"
        let alignment = HomologAlignment(
            hit: hit(sequence: reference),
            query: residues(reference),
            reference: residues(reference),
            segments: [
                SIFTSSegment(
                    pdb: "1AAA", chain: "B", seqresStart: 1, seqresEnd: 10,
                    uniprotStart: 1, authorStart: 500, isArithmetic: true)
            ])
        #expect(alignment.mapping(forQueryResidue: 0) == .unmapped(.notObserved))
    }

    @Test("The mapping stacks on the shared ruler like every other annotation")
    func track() {
        let reference = "ACDEFGHIKL"
        let alignment = HomologAlignment(
            hit: hit(sequence: reference),
            query: residues(reference),
            reference: residues(reference),
            segments: [
                SIFTSSegment(
                    pdb: "1AAA", chain: "A", seqresStart: 1, seqresEnd: 10,
                    uniprotStart: 1, authorStart: 7, isArithmetic: true)
            ])
        let track = alignment.track(residueCount: 10)
        #expect(track.values.alignedCount == 10)
        guard case .categorical(let labels) = track.values else {
            Issue.record("expected a categorical track")
            return
        }
        #expect(labels.first == "7")
        #expect(labels.last == "16")
    }
}
