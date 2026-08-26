//  SelectionLanguageTests.swift
//  BoffinStructureTests
//
//  The parser's own error reporting, which is what a person reads when a
//  selection does not compile.

import Foundation
import Testing

@testable import BoffinStructure

@Suite("Selection error messages")
struct SelectionErrorMessageTests {

    @Test("Every failure names the text that caused it")
    func messagesNameTheOffendingText() {
        // A message saying only "invalid selection" leaves the reader comparing
        // their expression against a syntax they do not have. Naming the token
        // is the difference between fixing a typo and guessing.
        #expect(SelectionError.unknownKeyword("resn5").message.contains("resn5"))
        #expect(SelectionError.badNumber("five").message.contains("five"))
        #expect(SelectionError.trailing(")").message.contains(")"))
        #expect(SelectionError.unexpected(token: "and", at: 3).message.contains("and"))
        #expect(
            SelectionError.unexpectedEnd(expected: "a selection").message
                .contains("a selection"))
        #expect(!SelectionError.unclosedParenthesis.message.isEmpty)
    }

    @Test("Positions are reported from one, the way a person counts")
    func positionsAreOneBased() {
        // The parser counts from zero. A person reading "position 0" of their
        // own typing has to translate, and translating an off-by-one under
        // mild irritation is how the wrong character gets deleted.
        #expect(SelectionError.unexpected(token: "and", at: 0).message.contains("position 1"))
    }

    @Test("A real parse failure produces a real message")
    func parserProducesMessages() {
        // Not a hand-built error: one thrown by the parser, so the two cannot
        // drift apart.
        do {
            _ = try SelectionParser.parse("chain A and wibble B")
            Issue.record("that should not have parsed")
        } catch let error as SelectionError {
            #expect(error.message.contains("wibble"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}

@Suite("Negative residue numbering")
struct NegativeResidueNumberTests {

    private func range(_ expression: String) throws -> [ClosedRange<Int>] {
        guard case .residueNumbers(let ranges) = try SelectionParser.parse(expression) else {
            Issue.record("\(expression) did not parse as residue numbers")
            return []
        }
        return ranges
    }

    @Test("An expression tag numbered below one is selectable")
    func negativeSingleAndRange() throws {
        // The PDB numbers an expression tag backwards from the mature protein's
        // first residue, so a cleaved His-tag is typically -20 to -1. The
        // tokeniser treats `50-120` as one token specifically so the minus in
        // that numbering is not read as a range separator.
        #expect(try range("resi -5") == [(-5)...(-5)])
        #expect(try range("resi 0") == [0...0])

        // Both ends negative. This is the case the single-token treatment
        // exists for and the one it used to fail: the body was split on every
        // minus, giving three parts and "not a number", and there was no way at
        // all to write a range that ends below zero.
        #expect(try range("resi -20--1") == [(-20)...(-1)])
    }

    @Test("A range spanning zero works from either side")
    func rangesAcrossZero() throws {
        // A construct with a tag and a mature sequence is numbered through
        // zero, so this is the ordinary way to ask for the whole thing.
        #expect(try range("resi -5-10") == [(-5)...10])
        #expect(try range("resi 50--10") == [(-10)...50], "a range ending negative")
    }

    @Test("Ordinary ranges are unaffected")
    func positiveRangesUnchanged() throws {
        // The behaviour every other selection depends on.
        #expect(try range("resi 50-120") == [50...120])
        #expect(try range("resi 7") == [7...7])
        #expect(try range("resi 1+5+9") == [1...1, 5...5, 9...9])
        #expect(try range("resi -3+7") == [(-3)...(-3), 7...7])
    }

    @Test("Nonsense is still refused")
    func malformedIsRejected() {
        // The fix must not have turned the parser permissive: an unparseable
        // number has to name itself rather than selecting everything or
        // nothing, because an over-broad selection makes a figure that is wrong
        // in a way nobody can see.
        for expression in ["resi 5-", "resi --", "resi 1-2-3", "resi abc"] {
            #expect(throws: SelectionError.self) {
                _ = try SelectionParser.parse(expression)
            }
        }
    }
}
