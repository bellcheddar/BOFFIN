//  SequenceTests.swift
//  BoffinCoreTests

import Foundation
import Testing

@testable import BoffinCore

@Suite("Sequence construction")
struct SequenceTests {

    @Test("The canonical alphabet is exactly twenty residues")
    func canonicalAlphabetSize() {
        #expect(AminoAcid.canonical.count == 20)
    }

    @Test("Canonical row order is stable and alphabetical")
    func canonicalOrderIsStable() {
        // The delta-LLR matrix row order depends on this. If it ever changes,
        // every cached matrix and exported CSV silently transposes meaning.
        #expect(String(AminoAcid.canonical.map(\.code)) == "ACDEFGHIKLMNPQRSTVWY")
    }

    @Test("Whitespace and block numbering are stripped from pasted input")
    func pastedInputIsCleaned() {
        let sequence = ProteinSequence(
            name: "pasted", letters: "  1 MKVL\n  5 AGHY \n", source: .pasted)
        #expect(sequence.letters == "MKVLAGHY")
        #expect(sequence.count == 8)
    }

    @Test("Indices are zero-based and contiguous")
    func indicesAreContiguous() {
        let sequence = ProteinSequence(name: "t", letters: "MKVL", source: .pasted)
        #expect(sequence.residues.map(\.index) == [0, 1, 2, 3])
    }

    @Test("Non-canonical residues are preserved, not coerced")
    func nonCanonicalIsPreserved() {
        // Selenomethionine (U) and unknown (X) must survive parsing: a parser
        // that turns U into M loses information the user may care about.
        let sequence = ProteinSequence(name: "t", letters: "MUXM", source: .pasted)
        #expect(sequence.letters == "MUXM")
        #expect(sequence.residues[1].identity == .nonCanonical("U"))
        #expect(sequence.residues[2].identity == .nonCanonical("X"))
    }

    @Test("Only canonical residues are scorable")
    func onlyCanonicalIsScorable() {
        let sequence = ProteinSequence(name: "t", letters: "MUXM", source: .pasted)
        #expect(sequence.residues.map(\.identity.isScorable) == [true, false, false, true])
    }

    @Test("Lower-case input is normalised to upper case")
    func lowerCaseIsNormalised() {
        let sequence = ProteinSequence(name: "t", letters: "mkvl", source: .pasted)
        #expect(sequence.letters == "MKVL")
    }

    @Test("A residue round-trips through JSON, insertion code included")
    func residueRoundTripsThroughJSON() throws {
        let residue = Residue(
            index: 7,
            identity: .canonical(.histidine),
            authorNumber: 52,
            insertionCode: "A")
        let data = try JSONEncoder().encode(residue)
        let decoded = try JSONDecoder().decode(Residue.self, from: data)
        #expect(decoded == residue)
    }

    @Test("Author numbering is kept separate from array index")
    func authorNumberingIsSeparate() {
        // Author numbers may be negative, non-contiguous or carry insertion
        // codes. Conflating them with the array index is the classic
        // off-by-one in structural bioinformatics.
        let residue = Residue(index: 0, identity: .canonical(.methionine), authorNumber: -3)
        #expect(residue.index == 0)
        #expect(residue.authorNumber == -3)
    }
}
