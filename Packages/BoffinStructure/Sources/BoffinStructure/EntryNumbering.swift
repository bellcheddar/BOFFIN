//  EntryNumbering.swift
//  BoffinStructure
//
//  Residue numbering and UniProt correspondence read from the PDB ENTRY itself.
//
//  Why this exists when there is already a SIFTS store
//  ---------------------------------------------------
//  SIFTS states no licence. `Docs/ATTRIBUTIONS.md` records that, and the obvious
//  workaround is to take the same mapping from RCSB, whose data is CC0. It does
//  not work: RCSB labels its alignment `provenance_source: SIFTS`, and RCSB's
//  policy excludes data originating from an integrated external resource from
//  its own licence. The mapping is EBI's work however you fetch it.
//
//  The way out is not a different supplier, it is a different source. Three
//  categories inside every mmCIF entry carry what BOFFIN actually needs, and the
//  PDB archive is CC0, verified at `rcsb.org/pages/policies`:
//
//    _pdbx_poly_seq_scheme   SEQRES index to author number, with insertion codes
//                            and a marker for residues that were not observed
//    _struct_ref_seq         the depositor's own UniProt correspondence
//    _pdbx_struct_assembly   the biological assemblies the entry declares
//
//  What is lost is real and should be stated: `_struct_ref_seq` is the
//  DEPOSITOR'S alignment, and SIFTS is EBI's curated correction of exactly that.
//  For a straightforward entry they agree; for a chimera, an engineered mutant
//  or a badly annotated old entry, SIFTS is better. So this is the licence-clear
//  path and not the more accurate one, and the type says which it is.

import Foundation

/// One residue of one chain, as the entry itself numbers it.
public struct SchemeResidue: Sendable, Hashable {
    /// One-based index into SEQRES.
    public let seqresIndex: Int
    /// PDB author residue number, absent when the entry gives none.
    public let authorNumber: Int?
    /// Author insertion code, empty when there is none.
    public let insertionCode: String
    /// Three-letter component code.
    public let residueName: String
    /// Whether the residue appears in the coordinates.
    ///
    /// Read from `pdb_mon_id`, NOT from the author number. The obvious reading
    /// is that an unobserved residue has no author number, and it is wrong:
    /// `_pdbx_poly_seq_scheme.pdb_seq_num` is populated for every residue of the
    /// construct whether it was seen or not, and the marker for "not observed"
    /// is `pdb_mon_id` being absent. Reading the number instead reported all 298
    /// residues of CDK2 as observed, which would have made the Boundary tab's
    /// crystallisation precedent meaningless: every construct would appear to
    /// have ordered completely.
    public let isObserved: Bool
}

/// The depositor's correspondence between one chain and a sequence database.
public struct EntryReference: Sendable, Hashable {
    public let chainID: String
    public let database: String
    public let accession: String
    /// One-based SEQRES range covered.
    public let seqresRange: ClosedRange<Int>
    /// The matching range in the database sequence.
    public let databaseRange: ClosedRange<Int>

    /// Database residue number for a SEQRES index, or `nil` outside the range.
    ///
    /// Affine within the aligned region, which is what the category asserts.
    public func databaseNumber(forSeqres index: Int) -> Int? {
        guard seqresRange ~= index else { return nil }
        guard databaseRange.count == seqresRange.count else { return nil }
        return databaseRange.lowerBound + (index - seqresRange.lowerBound)
    }
}

/// A declared biological assembly.
public struct EntryAssembly: Sendable, Hashable, Identifiable {
    public let id: String
    public let details: String
    /// Number of polymer chains in the assembly, when the entry says.
    public let chainCount: Int?
}

/// Everything the entry says about its own numbering.
public struct EntryNumbering: Sendable {
    /// Residues by author chain identifier, in SEQRES order.
    public let chains: [String: [SchemeResidue]]
    public let references: [EntryReference]
    public let assemblies: [EntryAssembly]

    /// Author residue number for a one-based SEQRES index.
    public func authorNumber(chain: String, seqres index: Int) -> Int? {
        guard let residues = chains[chain], index >= 1, index <= residues.count else {
            return nil
        }
        // Indexed by position rather than searched: the category is written in
        // SEQRES order and a linear search would be quadratic over a ribosome.
        let residue = residues[index - 1]
        return residue.seqresIndex == index
            ? residue.authorNumber
            : residues.first { $0.seqresIndex == index }?.authorNumber
    }

    /// SEQRES index for an author residue number.
    public func seqresIndex(chain: String, authorNumber number: Int) -> Int? {
        chains[chain]?.first { $0.authorNumber == number }?.seqresIndex
    }

    /// Observed SEQRES spans for a chain, which is what a construct actually
    /// yielded.
    public func observedSpans(chain: String) -> [ClosedRange<Int>] {
        guard let residues = chains[chain] else { return [] }
        var spans: [ClosedRange<Int>] = []
        var start: Int?
        for residue in residues {
            if residue.isObserved {
                if start == nil { start = residue.seqresIndex }
            } else if let began = start {
                spans.append(began...(residue.seqresIndex - 1))
                start = nil
            }
        }
        if let began = start, let last = residues.last {
            spans.append(began...last.seqresIndex)
        }
        return spans
    }

    /// Read from a decoded entry.
    public static func from(_ file: BinaryCIFFile) -> EntryNumbering {
        var chains: [String: [SchemeResidue]] = [:]
        if let scheme = file["_pdbx_poly_seq_scheme"] {
            for row in 0..<scheme.rowCount {
                guard
                    let chain = scheme["pdb_strand_id"]?.string(row)
                        ?? scheme["asym_id"]?.string(row),
                    let index = scheme["seq_id"]?.int(row)
                else { continue }
                chains[chain, default: []].append(
                    SchemeResidue(
                        seqresIndex: index,
                        authorNumber: scheme["pdb_seq_num"]?.int(row),
                        insertionCode: scheme["pdb_ins_code"]?.string(row) ?? "",
                        residueName: scheme["mon_id"]?.string(row) ?? "",
                        isObserved: (scheme["pdb_mon_id"]?.string(row)
                            ?? scheme["auth_mon_id"]?.string(row)) != nil))
            }
        }

        var references: [EntryReference] = []
        if let reference = file["_struct_ref_seq"] {
            for row in 0..<reference.rowCount {
                guard let chain = reference["pdbx_strand_id"]?.string(row),
                    let accession = reference["pdbx_db_accession"]?.string(row),
                    let seqStart = reference["seq_align_beg"]?.int(row),
                    let seqEnd = reference["seq_align_end"]?.int(row),
                    let dbStart = reference["db_align_beg"]?.int(row),
                    let dbEnd = reference["db_align_end"]?.int(row),
                    seqEnd >= seqStart, dbEnd >= dbStart
                else { continue }
                // A chain identifier here can be a comma-separated list.
                for identifier in chain.split(separator: ",") {
                    references.append(
                        EntryReference(
                            chainID: identifier.trimmingCharacters(in: .whitespaces),
                            database: "UniProt",
                            accession: accession,
                            seqresRange: seqStart...seqEnd,
                            databaseRange: dbStart...dbEnd))
                }
            }
        }

        var assemblies: [EntryAssembly] = []
        if let assembly = file["_pdbx_struct_assembly"] {
            for row in 0..<assembly.rowCount {
                guard let identifier = assembly["id"]?.string(row) else { continue }
                assemblies.append(
                    EntryAssembly(
                        id: identifier,
                        details: assembly["details"]?.string(row) ?? "",
                        chainCount: assembly["oligomeric_count"]?.int(row)))
            }
        }

        return EntryNumbering(
            chains: chains, references: references, assemblies: assemblies)
    }
}
