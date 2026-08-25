//  ConstructCardTests.swift
//  BoffinCoreTests
//
//  A card is the artefact that gets forwarded, so what matters is that nothing
//  on it can be read as a measurement when it is a convention, and that the
//  reasons a protease was excluded travel with it.

import Testing

@testable import BoffinCore

@Suite("Construct card")
struct ConstructCardTests {

    private func residues(_ text: String) -> [AminoAcid] {
        text.compactMap { AminoAcid(rawValue: $0) }
    }

    private func card(
        letters: String =
            "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDYNIQKESTLHLVLRLRGG",
        tagPlan: TagPlan? = nil,
        constraints: [ConstructConstraint] = [],
        scale: PKaScale = .bjellqvist
    ) -> ConstructCard {
        let acids = residues(letters)
        return ConstructCard(
            proteinName: "test protein",
            range: 21...96,
            residues: acids,
            rationale: ["Removes 20 predicted disordered residues."],
            tagPlan: tagPlan,
            linker: .flexible,
            properties: SequenceProperties(
                residues: acids.enumerated().map {
                    Residue(index: $0.offset, identity: .canonical($0.element))
                },
                pKaScale: scale),
            pKaScale: scale,
            precedentCount: 3,
            constraints: constraints)
    }

    @Test("The card carries the boundaries in one-based numbering")
    func boundaries() {
        let text = card().text()
        #expect(text.contains("residues 21 to 96"))
        #expect(text.contains("76 residues"))
    }

    /// The scale travels WITH the numbers, so a card cannot print one
    /// provenance line above another scale's figures. It used to be a parameter
    /// to `text`, which made exactly that mismatch a one-character mistake.
    @Test("Properties are reported with the scale that actually produced them")
    func propertiesCarryTheirScale() {
        let bjellqvist = card(scale: .bjellqvist).text()
        let emboss = card(scale: .emboss).text()
        #expect(bjellqvist.contains(PKaScale.bjellqvist.provenance))
        #expect(emboss.contains(PKaScale.emboss.provenance))
        // The two scales disagree by 0.2 to 0.5 pH units, so the isoelectric
        // point must differ as well as the provenance line.
        #expect(bjellqvist != emboss)
        #expect(
            card(scale: .bjellqvist).properties.isoelectricPoint
                != card(scale: .emboss).properties.isoelectricPoint)
    }

    @Test("A refused protease and its reason are on the card, not only in the app")
    func refusalsTravel() {
        let plan = TagPlanner.plan(
            construct: residues("AAA" + "ENLYFQG" + "AAAAAAAAAA"),
            hasSignalPeptide: false, startsDisordered: false, endsDisordered: false)
        let text = card(tagPlan: plan).text()
        #expect(text.contains("NOT TEV"))
        #expect(text.contains("ENLYFQG"))
        #expect(text.contains("would cut the protein as well as the tag"))
    }

    @Test("The linker is presented as a convention, not a result")
    func linkerIsLabelledAsAConvention() {
        let plan = TagPlanner.plan(
            construct: residues("AAAAAAAAAA"), hasSignalPeptide: false,
            startsDisordered: false, endsDisordered: false)
        let text = card(tagPlan: plan).text()
        #expect(text.contains("GGGGSGGGGS"))
        #expect(text.contains("Length is a choice rather than a prediction"))
    }

    @Test("Enforced regions are listed, with the signal peptide marked removed")
    func constraintsAreListed() {
        let text = card(constraints: [
            ConstructConstraint(kind: .motif, range: 30...36, label: "HRD"),
            ConstructConstraint(kind: .signalPeptide, range: 0...21, label: "signal peptide"),
        ]).text()
        #expect(text.contains("HRD: 31 to 37"))
        #expect(text.contains("signal peptide: 1 to 22 (removed)"))
    }

    @Test("The FASTA record is valid and wrapped at sixty")
    func fastaIsWrapped() {
        let text = card().text()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let headerIndex = try? #require(lines.firstIndex { $0.hasPrefix(">") })
        let header = lines[headerIndex!]
        #expect(header.contains("test protein construct 21-96"))
        // Two lines of sequence: 60 then 16.
        #expect(lines[headerIndex! + 1].count == 60)
        #expect(lines[headerIndex! + 2].count == 16)
    }

    @Test("The card says it is a proposal")
    func researchUseOnly() {
        let text = card().text()
        #expect(text.contains("Research use only"))
        #expect(text.contains("not a result"))
    }

    @Test("Chunking handles the edges")
    func chunking() {
        #expect("".chunked(60).isEmpty)
        #expect("ABC".chunked(60) == ["ABC"])
        #expect("ABCDEF".chunked(3) == ["ABC", "DEF"])
        #expect("ABCDEFG".chunked(3) == ["ABC", "DEF", "G"])
        #expect("ABC".chunked(0) == ["ABC"])
    }

    @Test("The DNA and everything worked around for it appear on the card")
    func dnaSection() {
        let acids = residues("MHMHMHMHMHKKKKKKKKKKKK")
        let dna = ReverseTranslator.translate(acids)
        let withDNA = ConstructCard(
            proteinName: "test", range: 1...22, residues: acids,
            rationale: [], tagPlan: nil, linker: nil,
            properties: SequenceProperties(
                residues: acids.enumerated().map {
                    Residue(index: $0.offset, identity: .canonical($0.element))
                }, pKaScale: .bjellqvist),
            pKaScale: .bjellqvist, precedentCount: 0, constraints: [], dna: dna)
        let text = withDNA.text()
        #expect(text.contains("Insert DNA"))
        #expect(text.contains("GC content"))
        #expect(text.contains("U00096.3"))
        // The lysine run forces codon substitutions, and the card must say so
        // rather than presenting the result as straightforwardly optimal.
        #expect(text.contains("not the most frequent choice"))
    }
}
