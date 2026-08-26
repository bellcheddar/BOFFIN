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

/// The 85 KLIFS pocket positions, with the structural region each belongs to.
///
/// Bundled rather than derived. The region boundaries are quoted differently in
/// different papers, and a hand-typed set of them would put the gatekeeper
/// annotation on the wrong residue in a way that looks entirely convincing.
/// `Tools/data/fetch_family_tables.py` reads the labels KLIFS itself serves and
/// asserts they are identical across four unrelated structures.
public struct KLIFSRegions: Sendable {
    /// KLIFS labels in pocket order: `I.1`, `g.l.4`, `GK.45`, `xDFG.81`.
    public let labels: [String]
    /// Where the table came from and when it was checked.
    public let provenance: String

    /// The region name for a one-based KLIFS position.
    public func region(at position: Int) -> String? {
        guard position >= 1, position <= labels.count else { return nil }
        return String(labels[position - 1].split(separator: ".").dropLast().joined(separator: "."))
    }

    /// One-based KLIFS positions belonging to a named region.
    public func positions(in region: String) -> [Int] {
        labels.indices.compactMap { self.region(at: $0 + 1) == region ? $0 + 1 : nil }
    }

    /// The gatekeeper, KLIFS position 45.
    public static let gatekeeperPosition = 45
    /// The hinge, KLIFS positions 46 to 48.
    public static let hingePositions = 46...48
    /// `xDFG`: the DFG motif and the residue before it, positions 80 to 83.
    ///
    /// KLIFS labels four positions, not three. The `x` is the residue preceding
    /// the aspartate, which is why "the DFG is KLIFS 81 to 83" is right about
    /// the motif and wrong about the label.
    public static let xDFGPositions = 80...83
}

/// A named landmark in the kinase pocket, with the residues it landed on.
///
/// The build plan's Phase 5 acceptance asks for the DFG, HRD, gatekeeper and
/// hinge to "annotate at the correct KLIFS positions". A ruler labelled `GK.45`
/// satisfies the letter of that and not the point: the reader has to know that
/// 45 is the gatekeeper. These carry the name.
public struct PocketAnchor: Sendable, Hashable, Identifiable {
    /// What a medicinal chemist calls it.
    public let name: String
    /// KLIFS's own label for the first position, `GK.45`.
    public let label: String
    /// One-based positions in the user's sequence.
    public let positions: [Int]
    /// The residues found there, in order.
    public let residues: String

    public var id: String { label }

    /// `F80` or `D145 to G147`, the way a paper writes it.
    public var description: String {
        guard let first = positions.first, let last = positions.last else { return "" }
        guard let firstCode = residues.first else { return "" }
        if positions.count == 1 { return "\(firstCode)\(first)" }
        guard let lastCode = residues.last else { return "" }
        return "\(firstCode)\(first) to \(lastCode)\(last)"
    }
}

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

    private struct RegionTable: Decodable {
        let source: String
        let labels: [String]
    }

    private let receptors: [String: [GPCRResidue]]
    private let kinases: [String: KinaseEntry]
    /// The KLIFS position labels, exposed so callers can name a region rather
    /// than quoting a number nobody can interpret.
    public let klifsRegions: KLIFSRegions

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
        let regions = try load("klifs_regions", as: RegionTable.self)
        guard regions.labels.count == 85 else {
            throw FamilyStoreError.tablesUnavailable(
                "klifs_regions.json holds \(regions.labels.count) labels, not 85")
        }
        self.klifsRegions = KLIFSRegions(
            labels: regions.labels, provenance: regions.source)
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
        let (query, originalIndex) = canonical(sequence)
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
                guard let queryIndex = map[index],
                    originalIndex.indices.contains(queryIndex)
                else { return nil }
                // GPCRdb writes `3x50`. The API returns `3.50x50`, which
                // splits into Ballesteros-Weinstein `3.50` and the GPCRdb
                // suffix `50`; the helix number has to be carried across from
                // the first, or the label reads as a bare `50`.
                let helix = residue.ballesterosWeinstein.split(separator: ".").first
                let gpcrdbLabel =
                    helix.map { "\($0)x\(residue.gpcrdb)" } ?? residue.gpcrdb
                return CanonicalNumber(
                    residue: originalIndex[queryIndex],
                    label: "\(gpcrdbLabel) (BW \(residue.ballesterosWeinstein))",
                    segment: residue.segment)
            }
            best = (name, identity, Self.numbersInIntactSegments(numbers))
        }

        guard let best, best.identity >= NumberingResult.minimumIdentity else {
            throw FamilyStoreError.noReferenceMatched(bestIdentity: best?.identity ?? 0)
        }
        return NumberingResult(
            reference: best.name, identity: best.identity, numbers: best.numbers)
    }

    /// Drop the numbers of any segment the alignment did not keep intact.
    ///
    /// Generic numbers are transferred through an alignment, one reference
    /// position at a time, and nothing checked that the result was locally
    /// consistent. A transmembrane helix is structurally rigid and has no
    /// insertions, so consecutive positions within one segment must land on
    /// consecutive residues. Where they do not, the aligner has threaded the
    /// helix through something that is not the receptor.
    ///
    /// 2RH1 is why this exists. It is the entry the beta-2 adrenergic receptor
    /// is usually quoted from and it is a chimera: T4 lysozyme replaces most
    /// of ICL3. Numbering it assigned **5x70 to 5x76 and 6x24 to lysozyme
    /// residues**, with 5x70 at 238, 5x71 at 244 and 5x74 at 279 -- positions
    /// in one helix cannot be six and thirty-three residues apart. A generic
    /// number is what a reader copies out of the app and into a paper, so a
    /// wrong one is worse than none.
    ///
    /// The whole segment goes rather than the offending positions. A helix
    /// numbering that is right for its first half and silently truncated is
    /// not a safer answer, it is the same wrong answer with fewer places to
    /// notice it. A construct that genuinely disrupts TM5 should report no
    /// TM5, and an intact receptor is unaffected because its segments align
    /// contiguously.
    ///
    /// Not applied to KLIFS: that pocket is discontinuous in sequence by
    /// definition, so contiguity is not a property its numbering has. Whether
    /// a kinase fusion construct needs an equivalent guard is untested,
    /// because no fixture here is one.
    static func numbersInIntactSegments(_ numbers: [CanonicalNumber]) -> [CanonicalNumber] {
        var bySegment: [String: [CanonicalNumber]] = [:]
        var unsegmented: [CanonicalNumber] = []
        for number in numbers {
            if let segment = number.segment {
                bySegment[segment, default: []].append(number)
            } else {
                unsegmented.append(number)
            }
        }

        var kept = unsegmented
        for (_, members) in bySegment {
            let indices = members.map(\.residue).sorted()
            // Contiguous, not merely increasing. A residue the query lacks
            // leaves its reference position unmapped and the rest still
            // consecutive, so a deletion is tolerated; an insertion is not.
            let intact = zip(indices, indices.dropFirst()).allSatisfy { $1 == $0 + 1 }
            if intact { kept.append(contentsOf: members) }
        }
        return kept.sorted { $0.residue < $1.residue }
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
        let (query, originalIndex) = canonical(sequence)
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
                guard let queryIndex = map[index],
                    originalIndex.indices.contains(queryIndex)
                else { return nil }
                // KLIFS's own label, which names the region as well as the
                // position: "GK.45" says gatekeeper where "KLIFS 45" says
                // nothing a reader can act on.
                let label =
                    klifsRegions.labels.indices.contains(position - 1)
                    ? klifsRegions.labels[position - 1]
                    : "KLIFS \(position)"
                return CanonicalNumber(
                    residue: originalIndex[queryIndex],
                    label: label,
                    segment: klifsRegions.region(at: position))
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

    /// The named pocket landmarks in a KLIFS numbering result.
    ///
    /// Only landmarks whose positions ALL mapped are returned. A partial hinge
    /// would be worse than none: three residues are quoted as a unit, and a
    /// two-residue hinge silently renumbers the third.
    public func pocketAnchors(
        _ result: NumberingResult, in sequence: ProteinSequence
    ) -> [PocketAnchor] {
        let byLabel = Dictionary(
            result.numbers.map { ($0.label, $0.residue) },
            uniquingKeysWith: { first, _ in first })

        func anchor(_ name: String, _ positions: [Int]) -> PocketAnchor? {
            var indices: [Int] = []
            for position in positions {
                guard klifsRegions.labels.indices.contains(position - 1),
                    let index = byLabel[klifsRegions.labels[position - 1]],
                    sequence.residues.indices.contains(index)
                else { return nil }
                indices.append(index)
            }
            guard let first = positions.first,
                klifsRegions.labels.indices.contains(first - 1)
            else { return nil }
            return PocketAnchor(
                name: name,
                label: klifsRegions.labels[first - 1],
                positions: indices.map { $0 + 1 },
                residues: String(indices.map { sequence.residues[$0].code }))
        }

        return [
            anchor("Beta-3 lysine", [17]),
            anchor("Gatekeeper", [KLIFSRegions.gatekeeperPosition]),
            anchor("Hinge", Array(KLIFSRegions.hingePositions)),
            // The DFG itself, not the four-position xDFG region: the extra x is
            // a KLIFS labelling convention, and quoting four residues as "the
            // DFG" would be wrong in a way a kinase person notices at once.
            anchor("DFG", [81, 82, 83]),
        ].compactMap { $0 }
    }

    /// The canonical residues, and where each one sat in the original sequence.
    ///
    /// Alignment can only run over canonical residues, so a sequence containing
    /// an X or a selenomethionine yields a SHORTER array, and an index into it
    /// is not an index into the sequence. Returning both halves is what stops a
    /// `CanonicalNumber.residue` from silently pointing one residue to the left
    /// of the one it names for every position after the first non-canonical
    /// character. `FamilyStore.track` then writes those labels into the wrong
    /// cells of a ruler that is exactly the right length, which validates
    /// cleanly and draws a convincing picture of the wrong protein.
    private func canonical(
        _ sequence: ProteinSequence
    ) -> (
        residues: [AminoAcid], originalIndex: [Int]
    ) {
        var residues: [AminoAcid] = []
        var originalIndex: [Int] = []
        for (index, residue) in sequence.residues.enumerated() {
            guard case .canonical(let acid) = residue.identity else { continue }
            residues.append(acid)
            originalIndex.append(index)
        }
        return (residues, originalIndex)
    }
}
