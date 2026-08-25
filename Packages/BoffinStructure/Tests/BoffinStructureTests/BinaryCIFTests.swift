//  BinaryCIFTests.swift
//  BoffinStructureTests
//
//  Decoding is checked against the fixture structures and against facts about
//  them that are in the literature, not against the decoder's own output. A
//  chain of encodings undone in the wrong order produces arrays of exactly the
//  right length full of plausible coordinates, so "it parsed" proves nothing.

import Foundation
import Testing

@testable import BoffinStructure

private var fixtures: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/structures")
}

private func load(_ name: String) throws -> BinaryCIFFile {
    try BinaryCIF.decode(Data(contentsOf: fixtures.appending(path: name)))
}

@Suite("BinaryCIF")
struct BinaryCIFTests {

    @Test("Ubiquitin decodes to the entry it says it is")
    func header() throws {
        let file = try load("1ubq.bcif")
        #expect(file.header == "1UBQ")
        #expect(file["_entry"]?["id"]?.string(0) == "1UBQ")
    }

    /// 1UBQ is 602 protein atoms plus 58 waters, and its 76 residues are the
    /// sequence every other part of this app is checked against.
    @Test("The atom site table has the right shape")
    func atomSite() throws {
        let file = try load("1ubq.bcif")
        let atoms = try #require(file["_atom_site"])
        #expect(atoms.rowCount == 660)
        #expect(atoms["Cartn_x"] != nil)
        #expect(atoms["label_atom_id"] != nil)
        #expect(atoms["auth_seq_id"] != nil)
    }

    /// The first ATOM record of 1UBQ, which is in the file and in every copy of
    /// it anyone has ever downloaded: N of Met1 at 27.340, 24.430, 2.614.
    @Test("The first atom has the coordinates the file has always had")
    func firstAtom() throws {
        let file = try load("1ubq.bcif")
        let atoms = try #require(file["_atom_site"])
        #expect(atoms["group_PDB"]?.string(0) == "ATOM")
        #expect(atoms["label_atom_id"]?.string(0) == "N")
        #expect(atoms["label_comp_id"]?.string(0) == "MET")
        #expect(atoms["auth_seq_id"]?.int(0) == 1)
        let x = try #require(atoms["Cartn_x"]?.double(0))
        let y = try #require(atoms["Cartn_y"]?.double(0))
        let z = try #require(atoms["Cartn_z"]?.double(0))
        #expect(abs(x - 27.340) < 0.001, "x was \(x)")
        #expect(abs(y - 24.430) < 0.001, "y was \(y)")
        #expect(abs(z - 2.614) < 0.001, "z was \(z)")
    }

    /// Coordinates are delta-encoded and integer-packed. If the packing is
    /// undone by stopping at the first extreme value, the errors accumulate
    /// down the column rather than appearing at the top, so the LAST atom is
    /// the one that catches it.
    @Test("The last atom is right too, which the first alone does not prove")
    func lastAtom() throws {
        let file = try load("1ubq.bcif")
        let atoms = try #require(file["_atom_site"])
        let last = atoms.rowCount - 1
        #expect(atoms["group_PDB"]?.string(last) == "HETATM")
        #expect(atoms["label_comp_id"]?.string(last) == "HOH")
        let x = try #require(atoms["Cartn_x"]?.double(last))
        #expect(x > -100 && x < 100, "x was \(x), which is not in the box")
        // Every coordinate in the file is within the crystal, so a decoding
        // slip shows up as an outlier rather than as a single wrong atom.
        for row in 0..<atoms.rowCount {
            let value = atoms["Cartn_x"]?.double(row) ?? 0
            #expect(value > -200 && value < 200, "atom \(row) has x = \(value)")
        }
    }

    @Test("B-factors and occupancies come back in their real ranges")
    func bFactors() throws {
        let file = try load("1ubq.bcif")
        let atoms = try #require(file["_atom_site"])
        for row in 0..<atoms.rowCount {
            let b = atoms["B_iso_or_equiv"]?.double(row) ?? 0
            let occupancy = atoms["occupancy"]?.double(row) ?? 0
            #expect(b >= 0 && b < 200, "row \(row) has B = \(b)")
            #expect(occupancy > 0 && occupancy <= 1.001, "row \(row) has occupancy \(occupancy)")
        }
    }

    /// A kinase, a GPCR and a ribosome: different sizes, different encodings
    /// chosen by the writer, and the large one is where integer packing
    /// actually has something to pack.
    @Test(
        "Every fixture decodes with a plausible atom count",
        arguments: [
            ("1hck.bcif", 2500, 3500),
            ("2rh1.bcif", 3000, 6000),
            ("6eqe.bcif", 2000, 5000),
            ("1xq8.bcif", 500, 2500),
            ("7k00.bcif", 100_000, 160_000),
        ])
    func everyFixture(name: String, lower: Int, upper: Int) throws {
        let file = try load(name)
        let atoms = try #require(file["_atom_site"])
        #expect(
            atoms.rowCount > lower && atoms.rowCount < upper,
            "\(name) has \(atoms.rowCount) atoms")
        // The coordinates must be finite and inside a plausible box, which a
        // mis-ordered encoding chain reliably violates.
        for row in stride(from: 0, to: atoms.rowCount, by: max(atoms.rowCount / 500, 1)) {
            let x = atoms["Cartn_x"]?.double(row) ?? .nan
            #expect(x.isFinite && abs(x) < 2000, "\(name) atom \(row) has x = \(x)")
        }
    }

    @Test("An absent value is nil, not an empty string that parses as zero")
    func masking() throws {
        let file = try load("1ubq.bcif")
        let atoms = try #require(file["_atom_site"])
        // Alternate location is absent for every atom of 1UBQ, and must read as
        // absent rather than as the empty string.
        let altloc = try #require(atoms["label_alt_id"])
        #expect(altloc.string(0) == nil)
    }

    @Test("A file that is not BinaryCIF is refused rather than half decoded")
    func refusesRubbish() {
        #expect(throws: (any Error).self) {
            _ = try BinaryCIF.decode(Data([0x00, 0x01, 0x02, 0x03]))
        }
        #expect(throws: (any Error).self) {
            _ = try BinaryCIF.decode(Data())
        }
    }
}

@Suite("MessagePack")
struct MessagePackTests {

    @Test("The fixed-width integer formats round-trip")
    func integers() throws {
        #expect(try MessagePack.decode(Data([0x7F])).intValue == 127)
        #expect(try MessagePack.decode(Data([0xFF])).intValue == -1)
        #expect(try MessagePack.decode(Data([0xCC, 0xFF])).intValue == 255)
        #expect(try MessagePack.decode(Data([0xCD, 0x01, 0x00])).intValue == 256)
        #expect(try MessagePack.decode(Data([0xD0, 0x80])).intValue == -128)
        #expect(try MessagePack.decode(Data([0xD1, 0xFF, 0x00])).intValue == -256)
    }

    @Test("Strings, arrays and maps nest")
    func containers() throws {
        // {"a": [1, 2]}
        let data = Data([0x81, 0xA1, 0x61, 0x92, 0x01, 0x02])
        let value = try MessagePack.decode(data)
        #expect(value["a"]?.arrayValue?.count == 2)
        #expect(value["a"]?.arrayValue?[1].intValue == 2)
    }

    @Test("A truncated document throws rather than returning a short array")
    func truncation() {
        #expect(throws: MessagePackError.self) {
            // Announces two elements and supplies one.
            _ = try MessagePack.decode(Data([0x92, 0x01]))
        }
    }

    @Test("An unsupported format is refused by name")
    func unsupported() {
        #expect(throws: MessagePackError.self) {
            // 0xC7 is ext 8, which BinaryCIF never uses.
            _ = try MessagePack.decode(Data([0xC7, 0x00, 0x00]))
        }
    }
}

@Suite("Atom store, from real files")
struct AtomStoreFromFileTests {

    @Test("Ubiquitin loads with its author numbering intact")
    func ubiquitin() throws {
        let store = try AtomStore.from(try load("1ubq.bcif"))
        #expect(store.count == 660)
        #expect(store.chains == ["A"])
        #expect(store.authorNumber.first == 1)
        // Ubiquitin is residues 1 to 76, and the last protein residue is G76.
        let protein = (0..<store.count).filter { !store.isHeteroatom[$0] }
        #expect(store.authorNumber[protein.last!] == 76)
        #expect(store.residueName[protein.last!] == "GLY")
    }

    /// The distinction that matters: `label_seq_id` counts from one along the
    /// entity, `auth_seq_id` is the number a paper quotes. CDK2's catalytic
    /// aspartate is Asp145 in every publication about it.
    @Test("CDK2's catalytic aspartate is at author number 145")
    func authorNumbering() throws {
        let store = try AtomStore.from(try load("1hck.bcif"))
        let indices = (0..<store.count).filter {
            store.authorNumber[$0] == 145 && store.chainID[$0] == "A"
                && !store.isHeteroatom[$0]
        }
        #expect(!indices.isEmpty, "no residue 145 in chain A")
        #expect(store.residueName[indices[0]] == "ASP")
        #expect(store.atomName.contains("CA"))
    }

    /// Model selection, which matters for NMR: an ensemble holds twenty
    /// superimposed copies, and loading all of them at once renders as a single
    /// very badly resolved structure rather than as an obvious error.
    ///
    /// The alpha synuclein fixture turns out to hold ONE model, so it tests the
    /// other half of the contract: asking for a model that is not there returns
    /// nothing, rather than quietly falling back to the first. A fallback would
    /// make a wrong model number invisible.
    @Test("Model selection takes one model and refuses to substitute another")
    func modelSelection() throws {
        let file = try load("1xq8.bcif")
        let all = try #require(file["_atom_site"])
        let first = try AtomStore.from(file)
        #expect(first.models == [1])
        #expect(first.count == all.rowCount, "this fixture should be a single model")

        let missing = try AtomStore.from(file, model: 7)
        #expect(missing.isEmpty, "a model that is absent came back with atoms")
    }

    @Test("The ribosome loads, which is the size the guardrail exists for")
    func largeAssembly() throws {
        let store = try AtomStore.from(try load("7k00.bcif"))
        #expect(store.count > 100_000)
        #expect(store.chains.count > 20)
        let bounds = try #require(store.bounds)
        // A ribosome is roughly 250 A across, so a bounding box of a few
        // angstroms or of thousands would both mean the coordinates are wrong.
        let span = bounds.maximum - bounds.minimum
        #expect(span.x > 100 && span.x < 1000, "box spans \(span)")
    }

    @Test("An empty store has no bounds rather than a degenerate one")
    func emptyStore() {
        let store = AtomStore()
        #expect(store.isEmpty)
        #expect(store.bounds == nil)
        #expect(store.chains.isEmpty)
    }
}
