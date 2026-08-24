//  AminoAcid.swift
//  BoffinCore
//
//  The canonical residue alphabet. Codes follow IUPAC-IUB one-letter
//  nomenclature. Non-canonical residues are preserved rather than silently
//  coerced, because a parser that quietly turns selenomethionine into
//  methionine loses information the user may care about.

/// A residue identity in the one-letter alphabet.
public enum AminoAcid: Character, CaseIterable, Sendable, Hashable {
    case alanine = "A"
    case cysteine = "C"
    case asparticAcid = "D"
    case glutamicAcid = "E"
    case phenylalanine = "F"
    case glycine = "G"
    case histidine = "H"
    case isoleucine = "I"
    case lysine = "K"
    case leucine = "L"
    case methionine = "M"
    case asparagine = "N"
    case proline = "P"
    case glutamine = "Q"
    case arginine = "R"
    case serine = "S"
    case threonine = "T"
    case valine = "V"
    case tryptophan = "W"
    case tyrosine = "Y"

    /// The twenty canonical amino acids, in alphabetical one-letter order.
    ///
    /// This ordering is the row order of the delta-LLR matrix and of every
    /// substitution table in the app: fix it here so the two never disagree.
    public static let canonical: [AminoAcid] = allCases

    public var code: Character { rawValue }
}

/// A position in a sequence: either a canonical residue or something else that
/// was present in the source and deliberately not discarded.
public enum ResidueIdentity: Sendable, Hashable {
    /// One of the twenty canonical amino acids.
    case canonical(AminoAcid)
    /// A code that is valid in the source format but not one of the canonical
    /// twenty: `X` (unknown), `B`, `Z`, `J` (ambiguous), `U` (selenocysteine),
    /// `O` (pyrrolysine), or a gap character.
    case nonCanonical(Character)

    public var code: Character {
        switch self {
        case .canonical(let acid): acid.code
        case .nonCanonical(let character): character
        }
    }

    /// Whether this position can be scored by the model. Non-canonical
    /// positions are excluded from delta-LLR scanning rather than guessed at.
    public var isScorable: Bool {
        if case .canonical = self { return true }
        return false
    }

    public init(code: Character) {
        let upper = Character(code.uppercased())
        if let acid = AminoAcid(rawValue: upper) {
            self = .canonical(acid)
        } else {
            self = .nonCanonical(upper)
        }
    }
}

// MARK: - Codable

// `Character` is not Codable, so both types round-trip through their
// one-letter code as a String. This also keeps the on-disk and CloudKit
// representations human-readable, which matters when debugging a cached
// analysis by hand.

extension AminoAcid: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard text.count == 1, let acid = AminoAcid(rawValue: Character(text)) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected one canonical amino acid code, found \(text)"))
        }
        self = acid
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(rawValue))
    }
}

extension ResidueIdentity: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard text.count == 1 else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a single residue code, found \(text)"))
        }
        self = ResidueIdentity(code: Character(text))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(code))
    }
}
