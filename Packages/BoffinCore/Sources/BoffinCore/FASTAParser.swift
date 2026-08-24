//  FASTAParser.swift
//  BoffinCore
//
//  FASTA is a format by convention rather than specification, so real input is
//  routinely ragged: CRLF from a share sheet, block numbering pasted out of an
//  alignment viewer, a header with nothing under it, a bare sequence with no
//  header at all.
//
//  The parser's contract is that it never silently changes the science. It
//  either parses, or it reports precisely what it did. Anything it strips or
//  cannot interpret comes back as a diagnostic the UI can show, because a
//  parser that quietly drops eleven residues produces a construct that does not
//  express, and nobody finds out until the gel.

import Foundation

/// What a parse produced, together with everything the parser had to decide.
public struct FASTAParseResult: Sendable, Hashable {
    public let sequences: [ProteinSequence]

    /// Non-fatal observations. An empty array means the input was clean.
    public let diagnostics: [FASTADiagnostic]

    public init(sequences: [ProteinSequence], diagnostics: [FASTADiagnostic]) {
        self.sequences = sequences
        self.diagnostics = diagnostics
    }
}

/// Something the parser did that the user should know about.
public struct FASTADiagnostic: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// A header with no residues under it.
        case emptyRecord(header: String)
        /// Input had no `>` header, so the whole thing was read as one sequence.
        case noHeader
        /// Alignment gap characters were removed.
        case gapsRemoved(count: Int)
        /// Codes outside the canonical twenty were kept, not coerced.
        case nonCanonicalResidues(codes: [Character], count: Int)
    }

    public let kind: Kind
    public let recordName: String?

    public var id: String { "\(recordName ?? "-"):\(kind)" }

    /// User-facing text. British English, no em dashes.
    public var message: String {
        switch kind {
        case .emptyRecord(let header):
            "The record \"\(header)\" has a header but no residues, so it was skipped."
        case .noHeader:
            "No FASTA header was found, so the whole input was read as one sequence."
        case .gapsRemoved(let count):
            "Removed \(count) alignment gap \(count == 1 ? "character" : "characters")."
        case .nonCanonicalResidues(let codes, let count):
            """
            Kept \(count) non-canonical \(count == 1 ? "residue" : "residues") \
            (\(codes.map(String.init).joined(separator: ", "))). \
            These are excluded from analytical properties and cannot be scored.
            """
        }
    }

    public init(kind: Kind, recordName: String? = nil) {
        self.kind = kind
        self.recordName = recordName
    }
}

public enum FASTAParseError: Error, Sendable, Hashable {
    /// Nothing but whitespace.
    case empty
    /// Headers were present but not one of them had any residues.
    case noSequencesFound
}

public enum FASTAParser {

    /// Characters treated as alignment gaps and removed.
    static let gapCharacters: Set<Character> = ["-", ".", "*", "~"]

    /// Parse FASTA text, which may hold any number of records.
    ///
    /// - Parameters:
    ///   - text: the raw input, with any line ending convention.
    ///   - fileName: recorded as provenance when present, so a sequence read
    ///     from a file is distinguishable from one that was pasted.
    /// - Returns: the parsed sequences together with every non-fatal
    ///   observation the parser made, so nothing is changed silently.
    /// - Throws: ``FASTAParseError/empty`` when the input is only whitespace,
    ///   or ``FASTAParseError/noSequencesFound`` when headers were present but
    ///   none had residues under them.
    public static func parse(
        _ text: String,
        fileName: String? = nil
    ) throws(FASTAParseError) -> FASTAParseResult {

        // Normalise CRLF and lone CR before anything else. A share sheet from
        // Windows or an old Mac otherwise leaves a stray \r on the end of every
        // line, which becomes a non-canonical residue at every line break.
        let normalised =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        guard !normalised.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FASTAParseError.empty
        }

        var diagnostics: [FASTADiagnostic] = []
        var sequences: [ProteinSequence] = []

        let lines = normalised.split(separator: "\n", omittingEmptySubsequences: false)
        let hasAnyHeader = lines.contains { $0.hasPrefix(">") }

        if !hasAnyHeader {
            diagnostics.append(FASTADiagnostic(kind: .noHeader))
            let body = lines.joined()
            let (sequence, recordDiagnostics) = makeSequence(
                header: nil, body: body, fileName: fileName, index: 0)
            if let sequence {
                sequences.append(sequence)
                diagnostics.append(contentsOf: recordDiagnostics)
            }
            guard !sequences.isEmpty else { throw FASTAParseError.noSequencesFound }
            return FASTAParseResult(sequences: sequences, diagnostics: diagnostics)
        }

        var currentHeader: String?
        var currentBody = ""
        var recordIndex = 0

        func flush() {
            defer {
                currentBody = ""
                recordIndex += 1
            }
            guard let header = currentHeader else { return }
            let (sequence, recordDiagnostics) = makeSequence(
                header: header, body: currentBody, fileName: fileName, index: recordIndex)
            if let sequence {
                sequences.append(sequence)
                diagnostics.append(contentsOf: recordDiagnostics)
            } else {
                diagnostics.append(
                    FASTADiagnostic(
                        kind: .emptyRecord(header: header),
                        recordName: FASTAHeader(header).displayName))
            }
        }

        for line in lines {
            if line.hasPrefix(">") {
                flush()
                currentHeader = String(line.dropFirst())
            } else {
                currentBody += line
            }
        }
        flush()

        guard !sequences.isEmpty else { throw FASTAParseError.noSequencesFound }
        return FASTAParseResult(sequences: sequences, diagnostics: diagnostics)
    }

    /// Build one sequence, returning `nil` when the record has no residues.
    private static func makeSequence(
        header: String?,
        body: String,
        fileName: String?,
        index: Int
    ) -> (ProteinSequence?, [FASTADiagnostic]) {

        var diagnostics: [FASTADiagnostic] = []
        let parsedHeader = header.map(FASTAHeader.init)
        let name = parsedHeader?.displayName ?? "Untitled sequence"

        // Strip whitespace and block numbering, then gaps, counting the gaps so
        // the user is told rather than left to wonder why the length changed.
        let withoutLayout = body.filter { !$0.isWhitespace && !$0.isNumber }
        let gapCount = withoutLayout.count { gapCharacters.contains($0) }
        let letters = withoutLayout.filter { !gapCharacters.contains($0) }

        if gapCount > 0 {
            diagnostics.append(
                FASTADiagnostic(kind: .gapsRemoved(count: gapCount), recordName: name))
        }

        guard !letters.isEmpty else { return (nil, diagnostics) }

        let source: SequenceSource
        if let accession = parsedHeader?.uniProtAccession {
            source = .uniProt(accession: accession)
        } else if let entry = parsedHeader?.pdbEntry {
            source = .pdbSeqRes(entryID: entry.id, chainID: entry.chain)
        } else if let fileName {
            source = .fasta(fileName: fileName)
        } else {
            source = .pasted
        }

        let sequence = ProteinSequence(name: name, letters: letters, source: source)

        let nonCanonical = sequence.residues.filter { !$0.identity.isScorable }
        if !nonCanonical.isEmpty {
            let codes = Array(Set(nonCanonical.map(\.code))).sorted()
            diagnostics.append(
                FASTADiagnostic(
                    kind: .nonCanonicalResidues(codes: codes, count: nonCanonical.count),
                    recordName: name))
        }

        return (sequence, diagnostics)
    }
}

/// A parsed FASTA description line.
///
/// Recognises the two header conventions BOFFIN actually receives: UniProt's
/// `db|accession|entryName description` and RCSB's
/// `ENTRY_n|Chain A|description|organism`. Anything else is kept verbatim as
/// the display name rather than being forced into a shape it does not have.
public struct FASTAHeader: Sendable, Hashable {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw.trimmingCharacters(in: .whitespaces)
    }

    private var pipeFields: [String] {
        raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    }

    /// The UniProt accession, when this is a `sp|` or `tr|` header.
    public var uniProtAccession: String? {
        let fields = pipeFields
        guard fields.count >= 3, fields[0] == "sp" || fields[0] == "tr" else { return nil }
        let accession = fields[1].trimmingCharacters(in: .whitespaces)
        return accession.isEmpty ? nil : accession
    }

    /// The PDB entry and chain, when this is an RCSB entry header.
    public var pdbEntry: (id: String, chain: String)? {
        let fields = pipeFields
        guard fields.count >= 2 else { return nil }
        // RCSB writes "1UBQ_1|Chain A|..." or "6EQE_1|Chains A, B|...".
        let head = fields[0].split(separator: "_").first.map(String.init) ?? fields[0]
        guard head.count == 4, head.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        guard fields[1].hasPrefix("Chain") else { return nil }
        let chain =
            fields[1]
            .replacingOccurrences(of: "Chains ", with: "")
            .replacingOccurrences(of: "Chain ", with: "")
            .trimmingCharacters(in: .whitespaces)
        return (head.uppercased(), chain)
    }

    /// A readable name for the sequence list.
    public var displayName: String {
        let fields = pipeFields
        if uniProtAccession != nil, fields.count >= 3 {
            // "sp|P0CG48|UBC_HUMAN Polyubiquitin-C OS=..." reads best as the
            // entry name plus the protein description, without the OS= tail.
            let tail = fields[2]
            let entryName = tail.split(separator: " ").first.map(String.init) ?? tail
            let description = tail.dropFirst(entryName.count).trimmingCharacters(in: .whitespaces)
            let withoutQualifiers =
                description
                .components(separatedBy: " OS=").first ?? description
            return withoutQualifiers.isEmpty
                ? entryName : "\(entryName) \(withoutQualifiers)"
        }
        if let entry = pdbEntry, fields.count >= 3 {
            return "\(entry.id) chain \(entry.chain): \(fields[2])"
        }
        return raw.isEmpty ? "Untitled sequence" : raw
    }
}
