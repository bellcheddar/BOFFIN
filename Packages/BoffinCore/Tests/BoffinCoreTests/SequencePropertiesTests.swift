//  SequencePropertiesTests.swift
//  BoffinCoreTests
//
//  Every expectation here comes from a published definition or from an
//  independent reference implementation, never from running BOFFIN and
//  recording what it happened to produce. A test written the latter way pins
//  the bug in place and calls it correct.
//
//  Cross-check reference: Biopython 1.88 `Bio.SeqUtils.ProtParam`, which uses
//  the same published constants but implements the algorithms separately.
//  Where BOFFIN deliberately differs from it, the test says why.

import Foundation
import Testing

@testable import BoffinCore

/// Ubiquitin, the Phase 0 baseline fixture (PDB 1UBQ, UniProt P0CG48 residues
/// 1 to 76). Small, well behaved and widely tabulated, so its properties are
/// easy to check against any external tool.
private let ubiquitin =
    "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDYNIQKESTLHLVLRLRGG"

private func acids(_ letters: String) -> [AminoAcid] {
    letters.compactMap { AminoAcid(rawValue: $0) }
}

private func properties(_ letters: String, scale: PKaScale = .bjellqvist) -> SequenceProperties {
    SequenceProperties(
        ProteinSequence(name: "t", letters: letters, source: .fixture(name: "unit")),
        pKaScale: scale)
}

@Suite("Constant tables")
struct AminoAcidTableTests {

    @Test("Every canonical residue has a mass, a hydropathy and a full DIWV row")
    func tablesAreComplete() {
        for acid in AminoAcid.canonical {
            #expect(
                AminoAcidTables.averageResidueMass[acid] != nil, "mass missing for \(acid.code)")
            #expect(
                AminoAcidTables.kyteDoolittleHydropathy[acid] != nil,
                "hydropathy missing for \(acid.code)")
            let row = AminoAcidTables.dipeptideInstability[acid]
            #expect(row != nil, "DIWV row missing for \(acid.code)")
            #expect(row?.count == 20, "DIWV row for \(acid.code) is not 20 wide")
        }
    }

    @Test("The DIWV table is the full 400 entries")
    func dipeptideTableIsComplete() {
        // Guruprasad's table is 20 x 20. A short row means the generator
        // silently dropped values, which would bias the instability index
        // towards stability without any error.
        let total = AminoAcidTables.dipeptideInstability.values.reduce(0) { $0 + $1.count }
        #expect(total == 400)
    }

    @Test("Residue masses are free amino acid masses minus one water")
    func residueMassesAreResidueNotFreeMasses() {
        // Glycine free is 75.0666; as a residue it must be 57.0515.
        // Getting this wrong adds 18 Da per residue, which is 1.4 kDa on
        // ubiquitin: wrong enough to matter, small enough to look plausible.
        let glycine = AminoAcidTables.averageResidueMass[.glycine]
        #expect(abs((glycine ?? 0) - 57.05132) < 0.001)
    }

    @Test("Kyte-Doolittle extremes match the published index")
    func hydropathyExtremesArePublished() {
        // Ile is the most hydrophobic at +4.5, Arg the most hydrophilic at -4.5.
        #expect(AminoAcidTables.kyteDoolittleHydropathy[.isoleucine] == 4.5)
        #expect(AminoAcidTables.kyteDoolittleHydropathy[.arginine] == -4.5)
        #expect(AminoAcidTables.kyteDoolittleHydropathy[.valine] == 4.2)
    }

    @Test("Extinction coefficients are the Pace 1995 values")
    func extinctionConstantsArePublished() {
        #expect(AminoAcidTables.extinctionTryptophan == 5500)
        #expect(AminoAcidTables.extinctionTyrosine == 1490)
        #expect(AminoAcidTables.extinctionCystine == 125)
    }
}

@Suite("Molecular weight")
struct MolecularWeightTests {

    @Test("Ubiquitin weighs 8564.74 Da")
    func ubiquitinWeight() {
        // Independently reproduced by Biopython 1.88 (8564.7357) and matching
        // the widely published ~8.6 kDa for ubiquitin.
        #expect(abs(properties(ubiquitin).molecularWeight - 8564.7357) < 0.01)
    }

    @Test("A single glycine weighs one residue plus one water")
    func singleResidueWeight() {
        // 57.05132 + 18.01524 = 75.06656, which is free glycine. Hand-checkable.
        #expect(abs(properties("G").molecularWeight - 75.0666) < 0.001)
    }

    @Test("An empty selection weighs nothing, not one water")
    func emptySelectionWeighsNothing() {
        #expect(properties("").molecularWeight == 0)
    }

    @Test("A short peptide matches the reference implementation")
    func shortPeptideWeight() {
        #expect(abs(properties("MKWY").molecularWeight - 626.7667) < 0.01)
    }
}

@Suite("GRAVY")
struct GravyTests {

    @Test("Ubiquitin GRAVY is -0.489")
    func ubiquitinGravy() {
        #expect(abs(properties(ubiquitin).gravy - (-0.489474)) < 0.0001)
    }

    @Test("A homopolymer's GRAVY is that residue's hydropathy")
    func homopolymerGravy() {
        // The mean of N identical values is that value: the simplest possible
        // check that the divisor is the residue count and not something else.
        #expect(abs(properties("IIIII").gravy - 4.5) < 1e-12)
        #expect(abs(properties("RRRRR").gravy - (-4.5)) < 1e-12)
    }

    @Test("GRAVY is a mean, so it does not scale with length")
    func gravyIsLengthIndependent() {
        #expect(abs(properties("AG").gravy - properties("AGAGAG").gravy) < 1e-12)
    }
}

@Suite("Extinction coefficient at 280 nm")
struct ExtinctionTests {

    @Test("Ubiquitin has one Tyr, no Trp and no Cys, so epsilon is 1490")
    func ubiquitinExtinction() {
        let result = properties(ubiquitin)
        #expect(result.extinctionCoefficientReduced == 1490)
        // No cysteines, so the cystine variant cannot differ.
        #expect(result.extinctionCoefficientCystine == 1490)
    }

    @Test("Trp and Tyr contribute their published coefficients")
    func trpAndTyrContribute() {
        // 5500 + 1490 = 6990, hand-computable from the Pace formula.
        #expect(properties("MKWY").extinctionCoefficientReduced == 6990)
    }

    @Test("A lone cysteine contributes nothing: half a disulfide is not a chromophore")
    func oddCysteineDoesNotContribute() {
        let result = properties("WC")
        #expect(result.extinctionCoefficientReduced == 5500)
        #expect(result.extinctionCoefficientCystine == 5500)
    }

    @Test("Two cysteines make one cystine, worth 125")
    func cysteinePairMakesOneCystine() {
        let result = properties("WCC")
        #expect(result.extinctionCoefficientCystine == 5500 + 125)
    }

    @Test("Five cysteines make two cystines, not two and a half")
    func cystinesCountInWholePairs() {
        #expect(properties("CCCCC").extinctionCoefficientCystine == 250)
    }

    @Test("A protein with no aromatics has no absorbance at 280 nm")
    func noAromaticsMeansNoAbsorbance() {
        // Worth stating: such a protein cannot be quantified by A280 at all,
        // which is exactly the sort of thing the Boundary tab must not hide.
        #expect(properties("AAAAGGGG").extinctionCoefficientReduced == 0)
    }

    @Test("The 0.1 percent absorbance is epsilon over molecular weight")
    func absorbanceIsEpsilonOverWeight() {
        let result = properties(ubiquitin)
        let expected = result.extinctionCoefficientReduced / result.molecularWeight
        #expect(abs((result.absorbance01PercentReduced ?? 0) - expected) < 1e-12)
    }
}

@Suite("Instability index")
struct InstabilityTests {

    @Test("Ubiquitin's instability index is 36.06, below the stability threshold")
    func ubiquitinInstability() {
        let result = properties(ubiquitin)
        #expect(abs(result.instabilityIndex - 36.055263) < 0.0001)
        #expect(result.isPredictedStable)
    }

    @Test("The stability threshold is Guruprasad's 40")
    func thresholdIsPublished() {
        #expect(SequenceProperties.instabilityThreshold == 40)
    }

    @Test("A poly-acidic peptide reads as unstable")
    func acidicPeptideIsUnstable() {
        let result = properties("DDDEEE")
        #expect(abs(result.instabilityIndex - 117.0) < 0.0001)
        #expect(!result.isPredictedStable)
    }

    @Test("A single residue has no dipeptides and therefore no index")
    func singleResidueHasNoIndex() {
        #expect(properties("M").instabilityIndex == 0)
    }

    @Test("The index sums consecutive dipeptides, not all pairs")
    func indexUsesConsecutiveDipeptides() {
        // "MKWY" has three dipeptides (MK, KW, WY), not six pairs. Biopython
        // gives 7.5 for it; summing all pairs would give a different number.
        #expect(abs(properties("MKWY").instabilityIndex - 7.5) < 0.0001)
    }
}

@Suite("Isoelectric point")
struct IsoelectricPointTests {

    @Test("Ubiquitin's pI is 6.56 on the Bjellqvist scale")
    func ubiquitinIsoelectricPoint() {
        // Matches Biopython 1.88 (6.5616) and ExPASy's published value for
        // ubiquitin. This sequence sits well inside every implementation's
        // working range, so agreement here is meaningful.
        #expect(abs(properties(ubiquitin).isoelectricPoint - 6.5616) < 0.001)
    }

    @Test("Net charge is zero at the isoelectric point, by definition")
    func netChargeIsZeroAtPI() {
        // The definitional check: whatever the solver returns must actually be
        // the pH where the charge crosses zero.
        for sequence in [ubiquitin, "MKWY", "DDDEEE", "KKKRRR", "H"] {
            let residues = acids(sequence)
            let pI = SequenceProperties.isoelectricPoint(of: residues)
            let charge = SequenceProperties.netCharge(of: residues, atPH: pI)
            #expect(abs(charge) < 1e-6, "charge at pI was \(charge) for \(sequence)")
        }
    }

    @Test("Net charge falls monotonically as pH rises")
    func chargeIsMonotonic() {
        let residues = acids(ubiquitin)
        var previous = Double.greatestFiniteMagnitude
        for step in 0...140 {
            let charge = SequenceProperties.netCharge(of: residues, atPH: Double(step) / 10)
            #expect(charge <= previous, "charge rose between pH steps")
            previous = charge
        }
    }

    @Test("A strongly acidic peptide has a pI below 4, not clamped at 4.05")
    func acidicPeptideIsNotClampedAtLowerBound() {
        // Biopython brackets its bisection to [4.05, 12] and returns the bound
        // when a sequence falls outside, so it reports exactly 4.05 for this
        // peptide. That is the edge of an assumption, not an isoelectric point,
        // and it looks entirely plausible in a results panel. BOFFIN brackets
        // the real 0 to 14 domain and gets 3.49.
        let pI = properties("DDDEEE").isoelectricPoint
        #expect(abs(pI - 3.4919) < 0.001)
        #expect(pI < 4.05)
    }

    @Test("A strongly basic peptide has a pI above 12, not clamped at 12.00")
    func basicPeptideIsNotClampedAtUpperBound() {
        // The same failure at the other end: Biopython returns exactly 12.00.
        let pI = properties("KKKRRR").isoelectricPoint
        #expect(abs(pI - 12.3106) < 0.001)
        #expect(pI > 12.0)
    }

    @Test("The two pKa scales disagree, and the difference is reported not hidden")
    func scalesDisagree() {
        // If these ever returned the same number, one scale would not be wired
        // up. The point of offering both is that they differ.
        let bjellqvist = properties(ubiquitin, scale: .bjellqvist).isoelectricPoint
        let emboss = properties(ubiquitin, scale: .emboss).isoelectricPoint
        #expect(abs(bjellqvist - emboss) > 0.01)
    }

    @Test("Each result carries the scale that produced it")
    func resultRecordsItsScale() {
        #expect(properties(ubiquitin, scale: .emboss).pKaScale == .emboss)
        #expect(properties(ubiquitin, scale: .bjellqvist).pKaScale == .bjellqvist)
    }

    @Test("The Bjellqvist N-terminal override is applied")
    func terminalOverridesAreApplied() {
        // Bjellqvist gives an N-terminal Ala a pKa of 7.59 rather than the
        // default 7.5. On a short peptide, where the termini dominate, ignoring
        // the override moves pI measurably.
        let values = PKaScale.bjellqvist.values
        #expect(values.nTerminusPKa(startingWith: .alanine) == 7.59)
        #expect(values.nTerminusPKa(startingWith: .glycine) == values.nTerminus)
        #expect(values.cTerminusPKa(endingWith: .asparticAcid) == 4.55)
    }

    @Test("EMBOSS has no terminal overrides")
    func embossHasNoOverrides() {
        let values = PKaScale.emboss.values
        #expect(values.nTerminusOverrides.isEmpty)
        #expect(values.cTerminusOverrides.isEmpty)
        #expect(values.nTerminusPKa(startingWith: .alanine) == values.nTerminus)
    }
}

@Suite("Non-canonical handling")
struct NonCanonicalPropertyTests {

    @Test("Non-canonical residues are excluded and counted, not guessed at")
    func nonCanonicalAreExcludedAndCounted() {
        let result = properties("MKXWY")
        #expect(result.residueCount == 4)
        #expect(result.nonCanonicalCount == 1)
        // The weight must equal MKWY exactly: X contributed nothing.
        #expect(abs(result.molecularWeight - properties("MKWY").molecularWeight) < 1e-9)
    }

    @Test("A sequence of only non-canonical residues yields zeroed properties")
    func allNonCanonicalYieldsZeroes() {
        let result = properties("XXXX")
        #expect(result.residueCount == 0)
        #expect(result.nonCanonicalCount == 4)
        #expect(result.molecularWeight == 0)
        #expect(result.absorbance01PercentReduced == nil)
    }

    @Test("Composition counts canonical residues only")
    func compositionCountsCanonicalOnly() {
        let result = properties("MMMXU")
        #expect(result.composition[.methionine] == 3)
        #expect(result.composition.values.reduce(0, +) == 3)
    }
}
