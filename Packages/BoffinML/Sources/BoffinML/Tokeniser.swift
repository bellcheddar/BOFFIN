//  Tokeniser.swift
//  BoffinML
//
//  The alphabet is loaded from the JSON the conversion pipeline exports, never
//  written out by hand here.
//
//  A tokeniser mismatch is the worst failure mode this app has available: it
//  does not crash, it does not warn, it produces confident embeddings for the
//  wrong sequence. Deriving the mapping from the same artefact that produced the
//  model removes the possibility of the two drifting apart.

import BoffinCore
import Foundation

/// The ESM alphabet, as exported by `Tools/coreml/convert_backbone.py`.
public struct Tokeniser: Sendable, Hashable, Codable {
    public let tokens: [String]
    public let tokenToIndex: [String: Int32]
    public let paddingIndex: Int32
    public let clsIndex: Int32
    public let eosIndex: Int32
    public let maskIndex: Int32
    public let unknownIndex: Int32
    public let prependBOS: Bool
    public let appendEOS: Bool

    private enum CodingKeys: String, CodingKey {
        case tokens
        case tokenToIndex = "token_to_index"
        case paddingIndex = "padding_index"
        case clsIndex = "cls_index"
        case eosIndex = "eos_index"
        case maskIndex = "mask_index"
        case unknownIndex = "unknown_index"
        case prependBOS = "prepend_bos"
        case appendEOS = "append_eos"
    }

    public init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(Tokeniser.self, from: Data(contentsOf: url))
    }

    /// Number of special tokens wrapped around the residues.
    public var specialTokenCount: Int {
        (prependBOS ? 1 : 0) + (appendEOS ? 1 : 0)
    }

    /// Token count for a sequence of `residueCount` residues.
    public func tokenCount(forResidues residueCount: Int) -> Int {
        residueCount + specialTokenCount
    }

    /// The index for a residue, falling back to the unknown token.
    ///
    /// Non-canonical residues map to `<unk>` rather than being dropped: dropping
    /// them would shift every downstream residue by one, which silently
    /// misaligns every track against the sequence.
    public func index(for residue: ResidueIdentity) -> Int32 {
        tokenToIndex[String(residue.code)] ?? unknownIndex
    }

    /// Encode residues into a padded token buffer of exactly `length`.
    ///
    /// - Returns: the tokens, and the range within them that holds real
    ///   residues, so the caller can slice the model output back without
    ///   recomputing the offsets.
    public func encode(
        _ residues: [Residue],
        paddedTo length: Int
    ) -> (tokens: [Int32], residueRange: Range<Int>) {
        precondition(
            tokenCount(forResidues: residues.count) <= length,
            "buffer of \(length) cannot hold \(residues.count) residues plus special tokens")

        var buffer = [Int32](repeating: paddingIndex, count: length)
        var cursor = 0
        if prependBOS {
            buffer[cursor] = clsIndex
            cursor += 1
        }
        let start = cursor
        for residue in residues {
            buffer[cursor] = index(for: residue.identity)
            cursor += 1
        }
        let end = cursor
        if appendEOS {
            buffer[cursor] = eosIndex
        }
        return (buffer, start..<end)
    }
}
