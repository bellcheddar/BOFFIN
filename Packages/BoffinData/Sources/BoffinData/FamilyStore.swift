//  FamilyStore.swift
//  BoffinData
//
//  The bundled family numbering tables, and the mapping of a pasted sequence
//  onto them.
//
//  Step 5 of the build plan's Family flow: "map". A homolog hit lands on real
//  numbering rather than on sequence indices, which is the difference between a
//  toy and a tool. Getting it wrong is invisible, so every mapped number here
//  travels with the alignment identity that produced it, and a weak alignment
//  is refused rather than reported with a caveat nobody reads.

import BoffinCore
import Foundation

/// A residue's position in a family's canonical numbering.
public struct CanonicalNumber: Sendable, Hashable {
    /// Index in the user's sequence, zero-based.
    public let residue: Int
    /// The scheme's label, as that scheme writes it (`3x50`, `I.1`).
    public let label: String
    /// Structural segment, where the scheme names one (`TM3`, `hinge`).
    public let segment: String?

    public init(residue: Int, label: String, segment: String?) {
        self.residue = residue
        self.label = label
        self.segment = segment
    }
}

/// The result of mapping a sequence onto a curated reference.
public struct NumberingResult: Sendable, Hashable {
    /// Which reference entry the numbering came from.
    public let reference: String
    /// Fraction of aligned positions that are identical.
    public let identity: Double
    public let numbers: [CanonicalNumber]

    /// Below this, a mapped numbering is not evidence.
    ///
    /// 0.35 is a deliberately conservative floor. Kinases and class A GPCRs are
    /// each a family with recognisable cores, so a genuine member aligns to its
    /// closest relative well above this; anything under it is more likely to be
    /// a different protein that shares a fold. The alternative, reporting a
    /// number with a quiet caveat, does not work: the number gets copied and
    /// the caveat does not travel with it.
    public static let minimumIdentity = 0.35
}

public enum FamilyStoreError: Error, Sendable {
    case tablesUnavailable(String)
    /// The sequence does not carry the family's canonical motifs, so numbering
    /// it against that family's references would be numbering the wrong thing.
    case notInFamily(String)
    case noReferenceMatched(bestIdentity: Double)
}

/// Curated numbering for the families BOFFIN annotates.
public struct FamilyStore: Sendable {

    private struct GPCRResidue: Decodable {
        let position: Int
        let residue: String
        let segment: String?
        let ballesterosWeinstein: String
        let gpcrdb: String

        enum CodingKeys: String, CodingKey {
            case position, residue, segment, gpcrdb
            case ballesterosWeinstein = "ballesteros_weinstein"
        }
    }

    private struct KinaseEntry: Decodable {
        let uniprot: String?
        let family: String?
        let group: String?
        let fullName: String?
        let pocket: String

        enum CodingKeys: String, CodingKey {
            case uniprot, family, group, pocket
            case fullName = "full_name"
        }
    }

    private let receptors: [String: [GPCRResidue]]
    private let kinases: [String: KinaseEntry]

    /// Load from the package bundle.
    ///
    /// `Bundle.module` is internal to the package, so it cannot appear in a
    /// public default argument. The no-argument initialiser uses it and the
    /// explicit one lets a host application point elsewhere.
    public init() throws {
        try self.init(bundle: .module)
    }

    public init(bundle: Bundle) throws {
        func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
            guard let url = bundle.url(forResource: name, withExtension: "json") else {
                throw FamilyStoreError.tablesUnavailable("\(name).json missing from the bundle")
            }
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        }
        self.receptors = try load("gpcrdb_numbering", as: [String: [GPCRResidue]].self)
        self.kinases = try load("klifs_pockets", as: [String: KinaseEntry].self)
    }

    public var receptorCount: Int { receptors.count }
    public var kinaseCount: Int { kinases.count }

    // MARK: - GPCRdb

    /// Map a sequence onto GPCRdb generic numbering.
    ///
    /// The reference is whichever bundled receptor aligns best, because a
    /// receptor is numbered against its own family rather than against one
    /// arbitrary member. Both GPCRdb and Ballesteros-Weinstein labels are kept:
    /// they differ exactly where a helix has a bulge or constriction, which is
    /// the entire reason GPCRdb exists, so collapsing them to one would discard
    /// the information the scheme was created to carry.
    public func gpcrdbNumbering(for sequence: ProteinSequence) throws -> NumberingResult {
        // Family membership is decided by the MOTIFS, not by alignment score.
        // Alignment identity answers "how close is the nearest reference", which
        // is not the same question: ubiquitin scored 0.35 against a kinase
        // pocket and beta-2 adrenergic receptor scored 0.48 against PLK2, both
        // purely on chance overlap. The motif detector already answers family
        // membership and its negative controls pass, so numbering is a
        // refinement of that call rather than an independent guess.
        guard !FamilyMotifs.classAGPCR(in: sequence).isEmpty else {
            throw FamilyStoreError.notInFamily("no class A GPCR micro-switches found")
        }
        let query = canonical(sequence)
        guard !query.isEmpty else { throw FamilyStoreError.noReferenceMatched(bestIdentity: 0) }

        var best: (name: String, identity: Double, numbers: [CanonicalNumber])?

        for (name, residues) in receptors {
            let referenceLetters = residues.compactMap {
                AminoAcid(rawValue: Character($0.residue))
            }
            guard referenceLetters.count == residues.count else { continue }

            let alignment = SequenceAlignment.align(query: query, reference: referenceLetters)
            let identity = alignment.identity(query: query, reference: referenceLetters)
            guard identity > (best?.identity ?? 0) else { continue }

            let map = alignment.queryIndexByReference()
            let numbers = residues.enumerated().compactMap { index, residue -> CanonicalNumber? in
                guard let queryIndex = map[index] else { return nil }
                // GPCRdb writes `3x50`. The API returns `3.50x50`, which
                // splits into Ballesteros-Weinstein `3.50` and the GPCRdb
                // suffix `50`; the helix number has to be carried across from
                // the first, or the label reads as a bare `50`.
                let helix = residue.ballesterosWeinstein.split(separator: ".").first
                let gpcrdbLabel =
                    helix.map { "\($0)x\(residue.gpcrdb)" } ?? residue.gpcrdb
                return CanonicalNumber(
                    residue: queryIndex,
                    label: "\(gpcrdbLabel) (BW \(residue.ballesterosWeinstein))",
                    segment: residue.segment)
            }
            best = (name, identity, numbers)
        }

        guard let best, best.identity >= NumberingResult.minimumIdentity else {
            throw FamilyStoreError.noReferenceMatched(bestIdentity: best?.identity ?? 0)
        }
        return NumberingResult(
            reference: best.name, identity: best.identity, numbers: best.numbers)
    }

    // MARK: - KLIFS

    /// Map a sequence onto the 85-position KLIFS pocket numbering.
    ///
    /// The pocket is discontinuous in sequence, so it is aligned rather than
    /// searched for. Gap characters in the reference pocket are skipped: a gap
    /// is a position the reference kinase does not have, and inventing a
    /// residue for it would shift every position after it.
    public func klifsNumbering(for sequence: ProteinSequence) throws -> NumberingResult {
        guard !FamilyMotifs.proteinKinase(in: sequence).isEmpty else {
            throw FamilyStoreError.notInFamily("no protein kinase catalytic motifs found")
        }
        let query = canonical(sequence)
        guard !query.isEmpty else { throw FamilyStoreError.noReferenceMatched(bestIdentity: 0) }

        var best: (name: String, identity: Double, numbers: [CanonicalNumber])?

        for (name, entry) in kinases {
            // Track which KLIFS position each reference residue came from, so
            // the labels survive the gaps being dropped.
            var referenceLetters: [AminoAcid] = []
            var klifsPositions: [Int] = []
            for (offset, character) in entry.pocket.enumerated() {
                guard let acid = AminoAcid(rawValue: character) else { continue }
                referenceLetters.append(acid)
                klifsPositions.append(offset + 1)
            }
            guard !referenceLetters.isEmpty else { continue }

            let alignment = SequenceAlignment.align(query: query, reference: referenceLetters)
            let identity = alignment.identity(query: query, reference: referenceLetters)
            guard identity > (best?.identity ?? 0) else { continue }

            let map = alignment.queryIndexByReference()
            let numbers = klifsPositions.enumerated().compactMap {
                index, position -> CanonicalNumber? in
                guard let queryIndex = map[index] else { return nil }
                return CanonicalNumber(
                    residue: queryIndex, label: "KLIFS \(position)", segment: nil)
            }
            best = (name, identity, numbers)
        }

        guard let best, best.identity >= NumberingResult.minimumIdentity else {
            throw FamilyStoreError.noReferenceMatched(bestIdentity: best?.identity ?? 0)
        }
        return NumberingResult(
            reference: best.name, identity: best.identity, numbers: best.numbers)
    }

    // MARK: - Tracks

    /// Numbering as a categorical track on the shared ruler.
    public static func track(
        _ result: NumberingResult, residueCount: Int, title: String
    )
        -> AnyResidueTrack?
    {
        guard !result.numbers.isEmpty else { return nil }
        var labels = [String?](repeating: nil, count: residueCount)
        for number in result.numbers where number.residue < residueCount {
            labels[number.residue] = number.segment ?? number.label
        }
        return AnyResidueTrack(
            id: TrackID("numbering"),
            title: "\(title): \(result.reference), \(Int(result.identity * 100))% identity",
            kind: .categorical,
            values: .categorical(labels),
            colourScheme: .categorical)
    }

    private func canonical(_ sequence: ProteinSequence) -> [AminoAcid] {
        sequence.residues.compactMap {
            if case .canonical(let acid) = $0.identity { return acid }
            return nil
        }
    }
}
