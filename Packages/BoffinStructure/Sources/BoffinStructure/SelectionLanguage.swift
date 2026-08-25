//  SelectionLanguage.swift
//  BoffinStructure
//
//  A PyMOL-like selection language: tokeniser, recursive-descent parser, and an
//  evaluator over `AtomStore`.
//
//  Why a real parser and not pattern matching
//  ------------------------------------------
//  The temptation with a selection string is to look for keywords and split on
//  spaces, and it survives exactly as long as nobody writes a nested expression.
//  `byres (polymer within 5 of organic)` is the acceptance case in the build
//  plan and it has an operator that takes a whole sub-expression as its right
//  operand, inside a call that takes one as its only argument. Precedence,
//  grouping and unary operators are what a parser is for.
//
//  Selecting the wrong atoms is worse than failing to select
//  ---------------------------------------------------------
//  A selection is used to colour, measure and cut. A silently over-broad one
//  produces a figure that is wrong in a way nobody can see, so an unknown
//  keyword is an error naming the keyword, never an empty set and never
//  everything.

import Foundation

public enum SelectionError: Error, Sendable, Equatable {
    case unexpectedEnd(expected: String)
    case unexpected(token: String, at: Int)
    case unknownKeyword(String)
    case badNumber(String)
    case unclosedParenthesis
    case trailing(String)

    /// The failure, phrased for the person who typed it.
    ///
    /// Lives here rather than in the view, because every one of these messages
    /// is a statement about the grammar and the grammar is defined here. A view
    /// that switches over the cases itself is a second, slowly diverging
    /// account of what the parser accepts.
    ///
    /// Each names the offending text. An unknown keyword that says only
    /// "invalid selection" leaves the reader comparing their expression against
    /// a syntax they do not have, which is how an over-broad selection ends up
    /// accepted instead of fixed.
    public var message: String {
        switch self {
        case .unexpectedEnd(let expected):
            "The expression ends too early: \(expected) was expected."
        case .unexpected(let token, let position):
            "\"\(token)\" does not belong at position \(position + 1)."
        case .unknownKeyword(let keyword):
            "\"\(keyword)\" is not a selection keyword."
        case .badNumber(let text):
            "\"\(text)\" is not a number."
        case .unclosedParenthesis:
            "A bracket is opened and never closed."
        case .trailing(let text):
            "\"\(text)\" is left over at the end."
        }
    }
}

/// The parsed form of a selection.
public indirect enum Selection: Sendable, Hashable {
    case all
    case none
    /// `chain A`, `chain A+B`
    case chain([String])
    /// `resi 50-120`, `resi 50+60`
    case residueNumbers([ClosedRange<Int>])
    /// `resn ALA+GLY`
    case residueNames([String])
    /// `name CA+CB`
    case atomNames([String])
    /// `elem C+N`
    case elements([String])
    /// `alt A+B`: atoms carrying one of these alternate location codes.
    ///
    /// `alt ''` selects atoms with NO altloc, which is the majority of any
    /// structure and is the form PyMOL uses. Without it there would be no way
    /// to express "the unambiguous part", which is the more common question.
    case alternateLocations([String])
    /// `polymer`, `organic`, `solvent`, `hydro`, `backbone`, `sidechain`
    case category(Category)
    /// `b > 50`, `q < 0.5`
    case numericProperty(Property, Comparison, Double)
    case not(Selection)
    case and(Selection, Selection)
    case or(Selection, Selection)
    /// `X within 5 of Y`
    case within(Double, Selection, Selection)
    /// `byres X`: expand to every atom of any residue the selection touches.
    case byResidue(Selection)

    public enum Category: String, Sendable, Hashable, CaseIterable {
        case polymer
        case organic
        case solvent
        case hydrogen = "hydro"
        case backbone
        case sidechain
        case metal
    }

    public enum Property: String, Sendable, Hashable {
        case bFactor = "b"
        case occupancy = "q"
    }

    public enum Comparison: String, Sendable, Hashable {
        case less = "<"
        case greater = ">"
        case lessOrEqual = "<="
        case greaterOrEqual = ">="
        case equal = "="

        func holds(_ left: Double, _ right: Double) -> Bool {
            switch self {
            case .less: left < right
            case .greater: left > right
            case .lessOrEqual: left <= right
            case .greaterOrEqual: left >= right
            case .equal: abs(left - right) < 1e-9
            }
        }
    }
}

// MARK: - Tokeniser

struct SelectionToken: Equatable {
    enum Kind: Equatable {
        case word(String)
        case number(Double)
        case openParen
        case closeParen
        case comparison(String)
    }
    let kind: Kind
    let position: Int
    /// The characters as written.
    ///
    /// Kept alongside the kind because `resi 50` lexes to a NUMBER and the range
    /// parser needs the digits: rendering 50 back out of a Double gives "50.0",
    /// which is not an integer and produced `badNumber("50.0")` on the most
    /// ordinary selection anybody could type.
    let lexeme: String

    var text: String { lexeme }
}

enum SelectionLexer {
    static func tokenise(_ text: String) -> [SelectionToken] {
        var tokens: [SelectionToken] = []
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            if character == "(" {
                tokens.append(
                    SelectionToken(kind: .openParen, position: index, lexeme: "("))
                index += 1
                continue
            }
            if character == ")" {
                tokens.append(
                    SelectionToken(kind: .closeParen, position: index, lexeme: ")"))
                index += 1
                continue
            }
            if character == "<" || character == ">" || character == "=" {
                var operatorText = String(character)
                if index + 1 < characters.count, characters[index + 1] == "=" {
                    operatorText.append("=")
                    index += 1
                }
                tokens.append(
                    SelectionToken(
                        kind: .comparison(operatorText), position: index,
                        lexeme: operatorText))
                index += 1
                continue
            }

            // A word runs to the next delimiter. `+` and `-` stay INSIDE it, so
            // `50-120` and `A+B` are single tokens: splitting them here would
            // make `resi 50-120` three tokens and a range indistinguishable from
            // a subtraction nobody wrote.
            let start = index
            var word = ""
            while index < characters.count {
                let next = characters[index]
                if next.isWhitespace || next == "(" || next == ")" || next == "<"
                    || next == ">" || next == "="
                {
                    break
                }
                word.append(next)
                index += 1
            }

            if let value = Double(word), !word.contains("+"), word.filter({ $0 == "-" }).count <= 1,
                !(word.dropFirst().contains("-"))
            {
                tokens.append(
                    SelectionToken(kind: .number(value), position: start, lexeme: word))
            } else {
                tokens.append(
                    SelectionToken(kind: .word(word), position: start, lexeme: word))
            }
        }
        return tokens
    }
}

// MARK: - Parser

public enum SelectionParser {

    /// Parse a selection expression.
    ///
    /// - Parameter text: the expression.
    /// - Returns: the parsed selection.
    /// - Throws: ``SelectionError`` naming what went wrong and where.
    public static func parse(_ text: String) throws -> Selection {
        var parser = Parser(tokens: SelectionLexer.tokenise(text))
        let selection = try parser.expression()
        if let extra = parser.peek() {
            throw SelectionError.trailing(extra.text)
        }
        return selection
    }

    struct Parser {
        let tokens: [SelectionToken]
        var index = 0

        func peek() -> SelectionToken? {
            index < tokens.count ? tokens[index] : nil
        }

        mutating func advance() -> SelectionToken? {
            defer { index += 1 }
            return peek()
        }

        mutating func match(word: String) -> Bool {
            if case .word(let value)? = peek()?.kind, value.lowercased() == word {
                index += 1
                return true
            }
            return false
        }

        /// `or` binds loosest, as in PyMOL.
        mutating func expression() throws -> Selection {
            var left = try conjunction()
            while match(word: "or") {
                left = .or(left, try conjunction())
            }
            return left
        }

        mutating func conjunction() throws -> Selection {
            var left = try unary()
            while true {
                if match(word: "and") {
                    left = .and(left, try unary())
                } else if match(word: "within") {
                    // `X within 5 of Y`. The distance and the `of` are both
                    // required: `within 5 Y` is a different language.
                    guard case .number(let distance)? = advance()?.kind else {
                        throw SelectionError.unexpectedEnd(expected: "a distance")
                    }
                    guard match(word: "of") else {
                        throw SelectionError.unexpectedEnd(expected: "of")
                    }
                    left = .within(distance, left, try unary())
                } else {
                    return left
                }
            }
        }

        mutating func unary() throws -> Selection {
            if match(word: "not") { return .not(try unary()) }
            if match(word: "byres") { return .byResidue(try unary()) }
            return try primary()
        }

        mutating func primary() throws -> Selection {
            guard let token = peek() else {
                throw SelectionError.unexpectedEnd(expected: "a selection")
            }

            switch token.kind {
            case .openParen:
                index += 1
                let inner = try expression()
                guard case .closeParen? = peek()?.kind else {
                    throw SelectionError.unclosedParenthesis
                }
                index += 1
                return inner

            case .closeParen:
                throw SelectionError.unexpected(token: ")", at: token.position)

            case .number(let value):
                throw SelectionError.unexpected(token: String(value), at: token.position)

            case .comparison(let text):
                throw SelectionError.unexpected(token: text, at: token.position)

            case .word(let raw):
                index += 1
                let keyword = raw.lowercased()

                if let category = Selection.Category(rawValue: keyword) {
                    return .category(category)
                }
                if keyword == "all" || keyword == "*" { return .all }
                if keyword == "none" { return .none }

                if let property = Selection.Property(rawValue: keyword) {
                    guard case .comparison(let symbol)? = advance()?.kind,
                        let comparison = Selection.Comparison(rawValue: symbol)
                    else {
                        throw SelectionError.unexpectedEnd(
                            expected: "a comparison after \(keyword)")
                    }
                    guard case .number(let value)? = advance()?.kind else {
                        throw SelectionError.unexpectedEnd(expected: "a number")
                    }
                    return .numericProperty(property, comparison, value)
                }

                switch keyword {
                case "chain", "c.":
                    return .chain(try list())
                case "resn", "r.":
                    return .residueNames(try list().map { $0.uppercased() })
                case "name", "n.":
                    return .atomNames(try list().map { $0.uppercased() })
                case "elem", "element", "e.":
                    return .elements(try list().map { $0.uppercased() })
                case "alt":
                    // Not uppercased. Altloc codes are case sensitive in the
                    // PDB format, and a file may legitimately use both 'a' and
                    // 'A' for different conformations.
                    return .alternateLocations(try list().map { $0 == "''" ? "" : $0 })
                case "resi", "resid", "i.":
                    return .residueNumbers(try ranges())
                default:
                    throw SelectionError.unknownKeyword(raw)
                }
            }
        }

        /// `A`, or `A+B+C`.
        mutating func list() throws -> [String] {
            guard let token = advance() else {
                throw SelectionError.unexpectedEnd(expected: "a value")
            }
            return token.text.split(separator: "+").map(String.init)
        }

        /// `50`, `50-120`, `50+60-70`.
        mutating func ranges() throws -> [ClosedRange<Int>] {
            guard let token = advance() else {
                throw SelectionError.unexpectedEnd(expected: "a residue number")
            }
            var result: [ClosedRange<Int>] = []
            for piece in token.text.split(separator: "+") {
                // A leading minus is a negative residue number, which the PDB
                // uses for expression tags; a minus in the middle is a range.
                let body = piece.dropFirst(piece.hasPrefix("-") ? 1 : 0)
                let parts = body.split(separator: "-", omittingEmptySubsequences: false)
                let sign = piece.hasPrefix("-") ? -1 : 1
                if parts.count == 1 {
                    guard let value = Int(parts[0]) else {
                        throw SelectionError.badNumber(String(piece))
                    }
                    result.append((sign * value)...(sign * value))
                } else if parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]) {
                    let start = sign * low
                    result.append(min(start, high)...max(start, high))
                } else {
                    throw SelectionError.badNumber(String(piece))
                }
            }
            return result
        }
    }
}
