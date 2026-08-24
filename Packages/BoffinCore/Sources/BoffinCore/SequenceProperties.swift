//  SequenceProperties.swift
//  BoffinCore
//
//  Analytical properties computed directly from composition: no model, no
//  network, no ambiguity. These are the numbers a bench scientist checks before
//  ordering a gene, so every one of them cites the definition it implements and
//  is tested against a published reference value.
//
//  Non-canonical residues (X, B, Z, J, U, O and gaps) are excluded from every
//  calculation and counted, rather than being guessed at or silently dropped.
//  `nonCanonicalCount` is surfaced so the UI can say the result is partial.

import Foundation

/// Analytical properties of a sequence or a selection within one.
public struct SequenceProperties: Sendable, Hashable {

    /// Number of canonical residues the properties were computed over.
    public let residueCount: Int

    /// Non-canonical positions excluded from every calculation.
    ///
    /// Non-zero means the numbers describe a subset of what the user selected,
    /// and the UI must say so. A molecular weight that quietly ignores three
    /// selenocysteines is a wrong molecular weight.
    public let nonCanonicalCount: Int

    /// Average (not monoisotopic) molecular weight in daltons.
    public let molecularWeight: Double

    /// Isoelectric point, and the scale that produced it.
    public let isoelectricPoint: Double
    public let pKaScale: PKaScale

    /// Molar extinction coefficient at 280 nm, M^-1 cm^-1, assuming all
    /// cysteines are reduced (no disulfides).
    public let extinctionCoefficientReduced: Double

    /// Molar extinction coefficient at 280 nm assuming every cysteine pair
    /// forms a cystine. Equals the reduced value when there are fewer than two
    /// cysteines.
    public let extinctionCoefficientCystine: Double

    /// Absorbance of a 1 g/L solution at 280 nm (the "0.1 %" figure), reduced
    /// and cystine variants. `nil` when the molecular weight is zero.
    public let absorbance01PercentReduced: Double?
    public let absorbance01PercentCystine: Double?

    /// Grand average of hydropathy: mean Kyte-Doolittle value per residue.
    public let gravy: Double

    /// Guruprasad instability index. Above 40 predicts an unstable protein.
    public let instabilityIndex: Double

    /// Residue composition, canonical residues only.
    public let composition: [AminoAcid: Int]

    /// Whether the instability index predicts a stable protein.
    ///
    /// The 40 threshold is Guruprasad's, not a BOFFIN invention.
    public var isPredictedStable: Bool { instabilityIndex < Self.instabilityThreshold }

    /// Guruprasad's stability cutoff.
    public static let instabilityThreshold = 40.0
}

extension SequenceProperties {

    /// Compute properties for a whole sequence.
    public init(_ sequence: ProteinSequence, pKaScale: PKaScale = .bjellqvist) {
        self.init(residues: sequence.residues, pKaScale: pKaScale)
    }

    /// Compute properties over an arbitrary selection of residues.
    ///
    /// Takes residues rather than a range so the Order tab can report over a
    /// discontinuous selection without first materialising a new sequence.
    public init(residues: [Residue], pKaScale: PKaScale = .bjellqvist) {
        let canonical: [AminoAcid] = residues.compactMap { residue in
            if case .canonical(let acid) = residue.identity { return acid }
            return nil
        }

        self.residueCount = canonical.count
        self.nonCanonicalCount = residues.count - canonical.count
        self.pKaScale = pKaScale

        var composition: [AminoAcid: Int] = [:]
        for acid in canonical { composition[acid, default: 0] += 1 }
        self.composition = composition

        self.molecularWeight = Self.molecularWeight(of: canonical)
        self.isoelectricPoint = Self.isoelectricPoint(of: canonical, scale: pKaScale)
        self.gravy = Self.gravy(of: canonical)
        self.instabilityIndex = Self.instabilityIndex(of: canonical)

        let (reduced, cystine) = Self.extinctionCoefficients(composition: composition)
        self.extinctionCoefficientReduced = reduced
        self.extinctionCoefficientCystine = cystine

        if molecularWeight > 0 {
            self.absorbance01PercentReduced = reduced / molecularWeight
            self.absorbance01PercentCystine = cystine / molecularWeight
        } else {
            self.absorbance01PercentReduced = nil
            self.absorbance01PercentCystine = nil
        }
    }
}

// MARK: - The calculations

extension SequenceProperties {

    /// Average molecular weight: the sum of residue masses plus one water for
    /// the terminal H and OH.
    ///
    /// An empty chain weighs nothing rather than one water: a selection of no
    /// residues has no mass, and reporting 18 Da for it would be nonsense.
    static func molecularWeight(of residues: [AminoAcid]) -> Double {
        guard !residues.isEmpty else { return 0 }
        let sum = residues.reduce(0.0) { total, acid in
            total + (AminoAcidTables.averageResidueMass[acid] ?? 0)
        }
        return sum + AminoAcidTables.waterAverageMass
    }

    /// Grand average of hydropathy (Kyte and Doolittle, 1982): the mean of the
    /// per-residue hydropathy values.
    static func gravy(of residues: [AminoAcid]) -> Double {
        guard !residues.isEmpty else { return 0 }
        let sum = residues.reduce(0.0) { total, acid in
            total + (AminoAcidTables.kyteDoolittleHydropathy[acid] ?? 0)
        }
        return sum / Double(residues.count)
    }

    /// Molar extinction coefficients at 280 nm (Pace et al., 1995).
    ///
    /// Returns both variants because they answer different questions: the
    /// reduced value is what you want for a protein in DTT, the cystine value
    /// for an oxidised, disulfide-bonded one. ProtParam reports both for the
    /// same reason, and quoting only one invites the wrong concentration.
    ///
    /// Cystines are counted as *pairs* of cysteines, so an odd cysteine does
    /// not contribute: half a disulfide is not a chromophore.
    static func extinctionCoefficients(
        composition: [AminoAcid: Int]
    ) -> (reduced: Double, cystine: Double) {
        let tryptophans = Double(composition[.tryptophan] ?? 0)
        let tyrosines = Double(composition[.tyrosine] ?? 0)
        let cystines = Double((composition[.cysteine] ?? 0) / 2)

        let reduced =
            tryptophans * AminoAcidTables.extinctionTryptophan
            + tyrosines * AminoAcidTables.extinctionTyrosine
        return (reduced, reduced + cystines * AminoAcidTables.extinctionCystine)
    }

    /// Instability index (Guruprasad et al., 1990):
    /// `II = (10 / L) * sum of DIWV over consecutive dipeptides`.
    ///
    /// A single residue has no dipeptides and therefore no instability index;
    /// zero is returned rather than a division by zero.
    static func instabilityIndex(of residues: [AminoAcid]) -> Double {
        guard residues.count >= 2 else { return 0 }
        var total = 0.0
        for index in 0..<(residues.count - 1) {
            let first = residues[index]
            let second = residues[index + 1]
            total += AminoAcidTables.dipeptideInstability[first]?[second] ?? 0
        }
        return (10.0 / Double(residues.count)) * total
    }

    /// Net charge of the chain at a given pH, using Henderson-Hasselbalch on
    /// each ionisable group.
    ///
    /// Basic groups (the N-terminus, His, Lys, Arg) are positive when
    /// protonated; acidic groups (the C-terminus, Asp, Glu, Cys, Tyr) are
    /// negative when deprotonated.
    public static func netCharge(
        of residues: [AminoAcid],
        atPH pH: Double,
        scale: PKaScale = .bjellqvist
    ) -> Double {
        guard !residues.isEmpty else { return 0 }
        let values = scale.values

        var composition: [AminoAcid: Int] = [:]
        for acid in residues { composition[acid, default: 0] += 1 }

        var positive =
            1.0 / (pow(10.0, pH - values.nTerminusPKa(startingWith: residues.first)) + 1.0)
        for (acid, pKa) in values.basicSideChains {
            let count = Double(composition[acid] ?? 0)
            guard count > 0 else { continue }
            positive += count / (pow(10.0, pH - pKa) + 1.0)
        }

        var negative = 1.0 / (pow(10.0, values.cTerminusPKa(endingWith: residues.last) - pH) + 1.0)
        for (acid, pKa) in values.acidicSideChains {
            let count = Double(composition[acid] ?? 0)
            guard count > 0 else { continue }
            negative += count / (pow(10.0, pKa - pH) + 1.0)
        }

        return positive - negative
    }

    /// Isoelectric point: the pH at which net charge is zero, found by
    /// bisection.
    ///
    /// The bracket is the full 0 to 14 pH range deliberately. Some reference
    /// implementations bracket to roughly 4.05 to 12 on the argument that no
    /// protein falls outside it, and then return the *bound* for sequences that
    /// do: a poly-aspartate peptide comes back as exactly 4.05, and a
    /// poly-arginine one as exactly 12.00. Those are not isoelectric points,
    /// they are the edges of someone's assumption, and they look entirely
    /// plausible in a results panel. Bracketing the real domain costs a handful
    /// of extra bisection steps and cannot produce that failure.
    public static func isoelectricPoint(
        of residues: [AminoAcid],
        scale: PKaScale = .bjellqvist
    ) -> Double {
        guard !residues.isEmpty else { return 0 }

        var low = 0.0
        var high = 14.0
        // 60 halvings takes a 14-unit bracket well below floating point
        // resolution, so this converges rather than approximating.
        for _ in 0..<60 {
            let middle = (low + high) / 2
            if netCharge(of: residues, atPH: middle, scale: scale) > 0 {
                low = middle
            } else {
                high = middle
            }
        }
        return (low + high) / 2
    }
}
