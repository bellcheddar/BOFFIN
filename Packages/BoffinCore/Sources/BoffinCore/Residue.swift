//  Residue.swift
//  BoffinCore

/// A single position in a sequence.
///
/// `index` is zero-based and is the array coordinate used by every
/// `ResidueTrack`. `authorNumber` is the number as written by the depositor of
/// a structure (which may be negative, non-contiguous, or carry an insertion
/// code) and is `nil` for a sequence that did not come from a structure.
/// Conflating the two is the classic source of off-by-one errors in structural
/// bioinformatics, so they are separate fields and never interchangeable.
public struct Residue: Sendable, Hashable, Identifiable {
    public let index: Int
    public let identity: ResidueIdentity
    public let authorNumber: Int?
    public let insertionCode: Character?

    public var id: Int { index }
    public var code: Character { identity.code }

    public init(
        index: Int,
        identity: ResidueIdentity,
        authorNumber: Int? = nil,
        insertionCode: Character? = nil
    ) {
        self.index = index
        self.identity = identity
        self.authorNumber = authorNumber
        self.insertionCode = insertionCode
    }
}

// MARK: - Codable

extension Residue: Codable {
    private enum CodingKeys: String, CodingKey {
        case index, identity, authorNumber, insertionCode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.index = try container.decode(Int.self, forKey: .index)
        self.identity = try container.decode(ResidueIdentity.self, forKey: .identity)
        self.authorNumber = try container.decodeIfPresent(Int.self, forKey: .authorNumber)
        // `Character` is not Codable: insertion codes round-trip as a String.
        self.insertionCode =
            try container
            .decodeIfPresent(String.self, forKey: .insertionCode)
            .flatMap(\.first)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(identity, forKey: .identity)
        try container.encodeIfPresent(authorNumber, forKey: .authorNumber)
        try container.encodeIfPresent(insertionCode.map(String.init), forKey: .insertionCode)
    }
}
