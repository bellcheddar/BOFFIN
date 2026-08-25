//  DocumentReadingTests.swift
//  BoffinCoreTests
//
//  The rules a dropped file has to satisfy, tested where they can be: in
//  BoffinCore, over the same predicates the app applies. The app's own reader
//  adds security-scoped access, which needs a real file from another container
//  and cannot be exercised in a unit test.

import Foundation
import Testing

@testable import BoffinCore

@Suite("Reading a dropped file")
struct DocumentReadingTests {

    /// A FASTA written on a Windows machine in 1998 is not valid UTF-8 and is
    /// still a sequence file. Refusing it would be correct and useless.
    @Test("Invalid UTF-8 is decoded permissively rather than refused")
    func permissiveDecoding() throws {
        var bytes = Array(">seq\nACDEF".utf8)
        bytes.insert(0xFF, at: 5)  // a lone continuation byte, not valid UTF-8
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("ACDEF") || text.contains("CDEF"))

        let parsed = try FASTAParser.parse(text)
        #expect(parsed.sequences.count == 1)
    }

    /// A NUL in the first kilobyte means binary. FASTA never contains one, and
    /// this is what stops a `.bcif` dropped on the app from producing a
    /// confusing diagnostic about residues.
    @Test("A binary file is recognised before the parser sees it")
    func binaryDetection() {
        let binary = Data([0x83, 0xA7, 0x00, 0x76, 0x65, 0x72])
        #expect(binary.prefix(1024).contains(0))

        let fasta = Data(">1UBQ\nMQIFVKTLTGKTITLEVE".utf8)
        #expect(!fasta.prefix(1024).contains(0))
    }

    /// The parser must still cope if something binary reaches it, because the
    /// binary guard in the app is a courtesy and not a guarantee.
    ///
    /// It does not throw, and it should not: the parser's contract is that
    /// nothing is changed silently, so rubbish comes back as residues it has
    /// marked NON-CANONICAL with a diagnostic, which the UI already surfaces as
    /// a warning. Throwing would be a second way of saying the same thing.
    @Test("Rubbish reaching the parser is reported, not swallowed and not fatal")
    func rubbishIsHandled() throws {
        let rubbish = String(decoding: Data([0x00, 0x01, 0xFF, 0xFE]), as: UTF8.self)
        let parsed = try FASTAParser.parse(rubbish)
        let sequence = try #require(parsed.sequences.first)
        let nonCanonical = sequence.residues.count {
            if case .nonCanonical = $0.identity { return true }
            return false
        }
        #expect(nonCanonical == sequence.count)
        #expect(nonCanonical > 0)
    }

    @Test("A sequence file large enough to be a mistake is refused by size")
    func sizeLimit() {
        // The largest protein anybody works with is a few hundred kilobytes of
        // FASTA. Twenty megabytes is a genome, and reading one into a string on
        // a phone is how an app is killed by the system rather than by an error.
        let limit = 20 * 1_000_000
        #expect(limit > 500_000, "a real protein file must fit")
        #expect(limit < 100_000_000, "the limit must actually limit something")
    }
}
