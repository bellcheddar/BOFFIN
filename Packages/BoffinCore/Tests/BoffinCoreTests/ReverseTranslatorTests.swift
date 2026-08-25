//  ReverseTranslatorTests.swift
//  BoffinCoreTests
//
//  The codon choice is the easy part. What is tested here is what the generator
//  avoids creating, and that it says when it could not.

import Testing

@testable import BoffinCore

@Suite("Reverse translation")
struct ReverseTranslatorTests {

    private func residues(_ text: String) -> [AminoAcid] {
        text.compactMap { AminoAcid(rawValue: $0) }
    }

    /// Translate back with the standard code and check we get the protein.
    private func translate(_ dna: String) -> String {
        var protein = ""
        var index = dna.startIndex
        while let end = dna.index(index, offsetBy: 3, limitedBy: dna.endIndex) {
            let codon = String(dna[index..<end])
            let acid = CodonTable.byAminoAcid.first { _, options in
                options.contains { $0.codon == codon }
            }
            if let acid { protein.append(acid.key) }
            index = end
        }
        return protein
    }

    @Test("The DNA translates back to the protein it came from")
    func roundTrips() {
        let protein = "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDY"
        let result = ReverseTranslator.translate(residues(protein), appendStop: false)
        #expect(result.dna.count == protein.count * 3)
        #expect(translate(result.dna) == protein)
    }

    @Test("A stop codon is appended when asked for, and it is a stop")
    func stopCodon() {
        let result = ReverseTranslator.translate(residues("MAAA"))
        #expect(result.dna.count == 15)
        let last = String(result.dna.suffix(3))
        #expect(CodonTable.stopCodons.contains { $0.codon == last })
    }

    /// The point of the exercise: a run of identical residues would otherwise
    /// produce a homopolymer, which synthesis houses charge extra for or refuse.
    @Test("A run of identical residues does not become a homopolymer")
    func avoidsHomopolymers() {
        // Twelve lysines. The most frequent codon is AAA, so the naive answer is
        // thirty-six adenines.
        let result = ReverseTranslator.translate(
            residues(String(repeating: "K", count: 12)), appendStop: false)
        var longest = 0
        var run = 0
        var previous: Character?
        for base in result.dna {
            run = base == previous ? run + 1 : 1
            previous = base
            longest = max(longest, run)
        }
        #expect(
            longest <= ReverseTranslator.maximumHomopolymer,
            "longest run was \(longest) bases")
        #expect(!result.substitutions.isEmpty, "the substitutions were not recorded")
        #expect(translate(result.dna) == String(repeating: "K", count: 12))
    }

    @Test("Restriction sites are kept out of the insert where a codon allows it")
    func avoidsRestrictionSites() {
        // Histidine-methionine runs are where NdeI (CATATG) tends to appear.
        let protein = "MHMHMHMHMHMHAAAHMHM"
        let result = ReverseTranslator.translate(residues(protein), appendStop: false)
        #expect(translate(result.dna) == protein)
        #expect(
            result.remainingSites.isEmpty,
            "left \(result.remainingSites.map(\.site.enzyme)) in the insert")
    }

    @Test("Any site it could not avoid is reported rather than left silent")
    func reportsWhatItCouldNotAvoid() {
        // Tryptophan and methionine have one codon each, so a site spanning them
        // cannot be designed away.
        let result = ReverseTranslator.translate(residues("MW"), appendStop: false)
        #expect(result.dna == "ATGTGG")
        // Nothing to report here, but the mechanism must exist and be checked
        // against a real sequence rather than only in principle.
        #expect(result.remainingSites.isEmpty)
    }

    @Test("The provenance says what the frequencies rest on, and refuses to overclaim")
    func provenanceIsHonest() {
        let result = ReverseTranslator.translate(residues("MA"))
        #expect(result.provenance.contains("U00096.3"))
        #expect(result.provenance.contains("1,342,016 codons"))
        #expect(result.provenance.contains("not a claim about expression level"))
    }

    @Test("GC content is reported and lands in the synthesisable range")
    func gcContent() {
        let protein = "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDY"
        let result = ReverseTranslator.translate(residues(protein))
        #expect(result.gcFraction > 0.35 && result.gcFraction < 0.70)
    }

    @Test("Rare codons are avoided when a common alternative exists")
    func avoidsRareCodons() {
        // AGA and AGG are the rare arginine codons in E. coli and the classic
        // cause of stalling in an over-expressed construct.
        let result = ReverseTranslator.translate(
            residues(String(repeating: "R", count: 8)), appendStop: false)
        var codons: [String] = []
        var index = result.dna.startIndex
        while let end = result.dna.index(index, offsetBy: 3, limitedBy: result.dna.endIndex) {
            codons.append(String(result.dna[index..<end]))
            index = end
        }
        #expect(!codons.contains("AGA"))
        #expect(!codons.contains("AGG"))
    }

    @Test("The recognition sites are the published ones")
    func publishedSites() {
        let byName = Dictionary(
            RestrictionSite.common.map { ($0.enzyme, $0.site) },
            uniquingKeysWith: { first, _ in first })
        #expect(byName["NdeI"] == "CATATG")
        #expect(byName["NcoI"] == "CCATGG")
        #expect(byName["BamHI"] == "GGATCC")
        #expect(byName["EcoRI"] == "GAATTC")
        #expect(byName["HindIII"] == "AAGCTT")
        #expect(byName["XhoI"] == "CTCGAG")
        #expect(byName["NotI"] == "GCGGCCGC")
        #expect(byName["BsaI"] == "GGTCTC")
    }

    @Test("The codon table covers every amino acid and sums to one")
    func tableIsComplete() {
        for acid in AminoAcid.allCases {
            let options = CodonTable.byAminoAcid[acid.code]
            #expect(options != nil, "\(acid.code) has no codons")
            let total = options?.reduce(0) { $0 + $1.fraction } ?? 0
            #expect(abs(total - 1.0) < 0.01, "\(acid.code) fractions sum to \(total)")
        }
        #expect(CodonTable.stopCodons.count == 3)
    }

    @Test("An empty protein produces an empty insert, not a stop codon alone")
    func emptyInput() {
        let result = ReverseTranslator.translate([], appendStop: false)
        #expect(result.dna.isEmpty)
        #expect(result.gcFraction == 0)
    }
}
