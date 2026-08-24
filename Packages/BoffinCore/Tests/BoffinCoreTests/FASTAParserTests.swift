//  FASTAParserTests.swift
//  BoffinCoreTests
//
//  The malformed cases are read from the committed fixture files rather than
//  from string literals here. A literal in a test drifts from the file it is
//  meant to represent, and then the suite passes while the real input still
//  breaks. These are the same bytes the app will be handed.

import Foundation
import Testing

@testable import BoffinCore

/// Locate the repository's `Fixtures/` directory relative to this source file,
/// so the tests read the committed fixtures without needing them bundled as
/// SPM resources (which would duplicate them into the build).
private var fixturesDirectory: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // BoffinCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // BoffinCore
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("Fixtures")
}

private func fixture(_ relativePath: String) throws -> String {
    let url = fixturesDirectory.appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite("FASTA parsing, well-formed input")
struct FASTAWellFormedTests {

    @Test("The ubiquitin fixture parses to a single 76-residue sequence")
    func ubiquitinFixtureParses() throws {
        let result = try FASTAParser.parse(try fixture("sequences/1UBQ.fasta"))
        #expect(result.sequences.count == 1)
        #expect(result.sequences.first?.count == 76)
        #expect(result.sequences.first?.letters.hasPrefix("MQIFVKTLTGK") == true)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("A UniProt header yields the accession as provenance")
    func uniProtHeaderGivesAccession() throws {
        let result = try FASTAParser.parse(try fixture("sequences/P0CG48_UBC_HUMAN.fasta"))
        guard let sequence = result.sequences.first else {
            Issue.record("no sequence parsed")
            return
        }
        #expect(sequence.source == .uniProt(accession: "P0CG48"))
    }

    @Test("Provenance distinguishes a UniProt entry from an anonymous paste")
    func provenanceIsRecorded() throws {
        // The Family and Boundary tabs treat a known accession differently from
        // a pasted string, so this must not collapse to one case.
        let pasted = try FASTAParser.parse("MKVLA")
        #expect(pasted.sequences.first?.source == .pasted)

        let named = try FASTAParser.parse(">my construct\nMKVLA", fileName: "constructs.fasta")
        #expect(named.sequences.first?.source == .fasta(fileName: "constructs.fasta"))
    }

    @Test("Multiple records all parse")
    func multipleRecordsParse() throws {
        let result = try FASTAParser.parse(">one\nMKVL\n>two\nAGHY\n>three\nWWWW")
        #expect(result.sequences.count == 3)
        #expect(result.sequences.map(\.letters) == ["MKVL", "AGHY", "WWWW"])
    }

    @Test("Residues wrapped across lines are joined")
    func wrappedResiduesAreJoined() throws {
        let result = try FASTAParser.parse(">wrapped\nMKVL\nAGHY\nWWWW")
        #expect(result.sequences.first?.letters == "MKVLAGHYWWWW")
    }
}

@Suite("FASTA parsing, malformed input")
struct FASTAMalformedTests {

    @Test("An empty file throws rather than producing an empty sequence")
    func emptyFileThrows() throws {
        let text = try fixture("malformed/empty.fasta")
        #expect(throws: FASTAParseError.empty) { try FASTAParser.parse(text) }
    }

    @Test("A header with no residues is reported, not silently accepted")
    func headerOnlyIsReported() throws {
        let text = try fixture("malformed/truncated-header-only.fasta")
        #expect(throws: FASTAParseError.noSequencesFound) { try FASTAParser.parse(text) }
    }

    @Test("A sequence truncated mid-line still parses to what is there")
    func truncatedMidLineParses() throws {
        let result = try FASTAParser.parse(try fixture("malformed/truncated-midline.fasta"))
        // No trailing newline: the last line must not be dropped.
        #expect(result.sequences.first?.count == 40)
        #expect(result.sequences.first?.letters.hasSuffix("PPDQ") == true)
    }

    @Test("An empty record among good ones is skipped with a diagnostic")
    func emptyRecordIsSkippedAndReported() throws {
        let result = try FASTAParser.parse(try fixture("malformed/empty-record.fasta"))
        #expect(result.sequences.count == 2)
        let emptyReports = result.diagnostics.filter {
            if case .emptyRecord = $0.kind { return true }
            return false
        }
        #expect(emptyReports.count == 1)
    }

    @Test("Non-canonical codes are kept and reported, never coerced")
    func nonCanonicalAreKeptAndReported() throws {
        let result = try FASTAParser.parse(try fixture("malformed/non-canonical-codes.fasta"))
        guard let sequence = result.sequences.first else {
            Issue.record("no sequence parsed")
            return
        }
        // MXBZJUOKVLA: seven canonical, four not... the point is that the
        // letters survive unchanged. Coercing U to M would be a silent lie.
        #expect(sequence.letters == "MXBZJUOKVLA")
        let reported = result.diagnostics.contains {
            if case .nonCanonicalResidues = $0.kind { return true }
            return false
        }
        #expect(reported)
    }

    @Test("Alignment paste is cleaned of numbering, whitespace and gaps")
    func alignmentPasteIsCleaned() throws {
        let result = try FASTAParser.parse(try fixture("malformed/pasted-alignment.fasta"))
        guard let sequence = result.sequences.first else {
            Issue.record("no sequence parsed")
            return
        }
        // Source is "   1 mqifv ktltg\n  11 ktitl-evep.s": block numbers and
        // spaces stripped, two gap characters removed, case normalised.
        #expect(sequence.letters == "MQIFVKTLTGKTITLEVEPS")
        let gapReport = result.diagnostics.compactMap { diagnostic -> Int? in
            if case .gapsRemoved(let count) = diagnostic.kind { return count }
            return nil
        }
        #expect(gapReport == [2])
    }

    @Test("A bare sequence with no header is accepted and flagged")
    func bareSequenceIsAccepted() throws {
        let result = try FASTAParser.parse(try fixture("malformed/bare-sequence.txt"))
        #expect(result.sequences.count == 1)
        #expect(result.sequences.first?.count == 76)
        let flagged = result.diagnostics.contains {
            if case .noHeader = $0.kind { return true }
            return false
        }
        #expect(flagged)
    }

    @Test("CRLF line endings do not become residues")
    func crlfIsNormalised() throws {
        let result = try FASTAParser.parse(try fixture("malformed/crlf.fasta"))
        guard let sequence = result.sequences.first else {
            Issue.record("no sequence parsed")
            return
        }
        // A stray carriage return would appear as a non-canonical residue at
        // every line break, quietly lengthening the sequence.
        #expect(sequence.letters == "MQIFVKTLTGKTITLEVEPSDT")
        // Computed outside the macro: #expect's expansion cannot see through
        // a key-path allSatisfy and reports a spurious rethrows error.
        let allScorable = sequence.residues.allSatisfy(\.identity.isScorable)
        #expect(allScorable)
    }

    @Test("Whitespace-only input throws empty, not noSequencesFound")
    func whitespaceOnlyThrowsEmpty() {
        #expect(throws: FASTAParseError.empty) { try FASTAParser.parse("   \n\n  \t \n") }
    }
}

@Suite("FASTA headers")
struct FASTAHeaderTests {

    @Test("A Swiss-Prot header is decomposed")
    func swissProtHeader() {
        let header = FASTAHeader("sp|P0CG48|UBC_HUMAN Polyubiquitin-C OS=Homo sapiens OX=9606")
        #expect(header.uniProtAccession == "P0CG48")
        #expect(header.displayName == "UBC_HUMAN Polyubiquitin-C")
    }

    @Test("A TrEMBL header is recognised too")
    func tremblHeader() {
        let header = FASTAHeader("tr|A0A0K8P6T7|PETH_PISS1 PET hydrolase OS=Piscinibacter")
        #expect(header.uniProtAccession == "A0A0K8P6T7")
    }

    @Test("An RCSB entry header yields entry and chain")
    func rcsbHeader() {
        let header = FASTAHeader("1UBQ_1|Chain A|UBIQUITIN|Homo sapiens (9606)")
        #expect(header.pdbEntry?.id == "1UBQ")
        #expect(header.pdbEntry?.chain == "A")
    }

    @Test("An RCSB header with several chains keeps them all")
    func rcsbMultipleChains() {
        let header = FASTAHeader("6EQE_1|Chains A, B|PETase|Piscinibacter sakaiensis")
        #expect(header.pdbEntry?.chain == "A, B")
    }

    @Test("An unrecognised header is kept verbatim rather than mangled")
    func unrecognisedHeaderIsVerbatim() {
        let header = FASTAHeader("my favourite construct v3")
        #expect(header.uniProtAccession == nil)
        #expect(header.pdbEntry == nil)
        #expect(header.displayName == "my favourite construct v3")
    }

    @Test("A pipe-containing header that is not UniProt is not misread as one")
    func nonUniProtPipesAreNotMisread() {
        // "gnl|db|id" style headers must not yield "db" as an accession.
        let header = FASTAHeader("gnl|mydb|thing1 some description")
        #expect(header.uniProtAccession == nil)
    }
}
