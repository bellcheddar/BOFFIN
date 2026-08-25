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
