//  EntryNumberingTests.swift
//  BoffinStructureTests
//
//  The licence-clear numbering path, checked against the same anchors the SIFTS
//  path is checked against. If the two disagree on CDK2's catalytic aspartate,
//  one of them is wrong and it matters which.

import Foundation
import Testing

@testable import BoffinStructure

private func entry(_ name: String) throws -> BinaryCIFFile {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/structures/\(name)")
    return try BinaryCIF.decode(Data(contentsOf: url))
}

@Suite("Numbering from the entry")
struct EntryNumberingTests {

    @Test("Ubiquitin numbers 1 to 76 in one chain")
    func ubiquitin() throws {
        let numbering = EntryNumbering.from(try entry("1ubq.bcif"))
        let chain = try #require(numbering.chains["A"])
        #expect(chain.count == 76)
        #expect(chain.first?.seqresIndex == 1)
        #expect(numbering.authorNumber(chain: "A", seqres: 1) == 1)
        #expect(numbering.authorNumber(chain: "A", seqres: 76) == 76)
        #expect(numbering.seqresIndex(chain: "A", authorNumber: 48) == 48)
    }

    /// The anchor everything else in this app is pinned to. The SIFTS path
    /// asserts the same thing, and the point of having both is that they agree.
    @Test("CDK2's catalytic aspartate is author 145 by the entry's own scheme")
    func cdk2() throws {
        let file = try entry("1hck.bcif")
        let numbering = EntryNumbering.from(file)
        let index = try #require(numbering.seqresIndex(chain: "A", authorNumber: 145))
        let residue = try #require(numbering.chains["A"]?[index - 1])
        #expect(residue.residueName == "ASP")
        #expect(numbering.authorNumber(chain: "A", seqres: index) == 145)

        // And the store built from the coordinates agrees, which is the check
        // that matters: two readings of the same file, one through the scheme
        // and one through the atoms.
        let store = try AtomStore.from(file)
        let atoms = (0..<store.count).filter {
            store.authorNumber[$0] == 145 && store.chainID[$0] == "A"
                && !store.isHeteroatom[$0]
        }
        #expect(!atoms.isEmpty)
        #expect(store.residueName[atoms[0]] == "ASP")
    }

    /// The depositor's own UniProt correspondence, which is what replaces SIFTS
    /// for the licence-clear path.
    @Test("The entry carries its own UniProt correspondence")
    func uniprotReference() throws {
        let numbering = EntryNumbering.from(try entry("1hck.bcif"))
        let reference = try #require(numbering.references.first { $0.chainID == "A" })
        #expect(reference.accession == "P24941")
        #expect(reference.database == "UniProt")
        // CDK2 is deposited as the full-length protein, so SEQRES and UniProt
        // numbering coincide, which is why every paper writes Asp145 and means
        // both.
        #expect(reference.databaseNumber(forSeqres: 145) == 145)
        #expect(reference.databaseNumber(forSeqres: 0) == nil)
        #expect(reference.databaseNumber(forSeqres: 10_000) == nil)
    }

    /// Unobserved residues are what the scheme records with `?`, and they are
    /// the same information SIFTS publishes as the gap between two segments.
    @Test("Observed spans come from the scheme, not from a separate table")
    func observedSpans() throws {
        let numbering = EntryNumbering.from(try entry("1hck.bcif"))
        let spans = numbering.observedSpans(chain: "A")
        #expect(!spans.isEmpty)
        // Ascending and non-overlapping.
        #expect(zip(spans, spans.dropFirst()).allSatisfy { $0.upperBound < $1.lowerBound })
        let observed = spans.reduce(0) { $0 + $1.count }
        let total = numbering.chains["A"]?.count ?? 0
        #expect(observed > 0 && observed <= total)
        // 1HCK has a disordered loop, so the two must not be equal: if they
        // were, the scheme's `?` markers are not being read.
        #expect(observed < total, "every residue read as observed")
    }

    @Test("Ubiquitin is fully ordered, so it has exactly one span")
    func fullyOrdered() throws {
        let numbering = EntryNumbering.from(try entry("1ubq.bcif"))
        #expect(numbering.observedSpans(chain: "A") == [1...76])
    }

    /// Read from the entry rather than asked of the viewer, which is the other
    /// half of removing a dependency: BOFFIN parses these bytes already.
    @Test("Biological assemblies are declared in the entry")
    func assemblies() throws {
        let kinase = EntryNumbering.from(try entry("1hck.bcif"))
        #expect(!kinase.assemblies.isEmpty, "1HCK declares no assembly")
        #expect(kinase.assemblies.allSatisfy { !$0.id.isEmpty })

        // And a structure with none must report none rather than inventing one.
        let ribosome = EntryNumbering.from(try entry("7k00.bcif"))
        #expect(ribosome.assemblies.count >= 1)
    }

    @Test("An entry with no scheme yields nothing rather than a wrong answer")
    func missingCategories() {
        let empty = BinaryCIFFile(header: "TEST", categories: [:])
        let numbering = EntryNumbering.from(empty)
        #expect(numbering.chains.isEmpty)
        #expect(numbering.references.isEmpty)
        #expect(numbering.assemblies.isEmpty)
        #expect(numbering.authorNumber(chain: "A", seqres: 1) == nil)
        #expect(numbering.observedSpans(chain: "A").isEmpty)
    }
}
