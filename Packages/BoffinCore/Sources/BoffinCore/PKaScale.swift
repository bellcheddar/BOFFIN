//  PKaScale.swift
//  BoffinCore
//
//  Isoelectric point depends on which published pKa scale you use, and the
//  scales disagree by 0.2 to 0.5 pH units on the same sequence. That is a large
//  enough difference to change a buffer choice, so BOFFIN never picks silently:
//  the scale is part of the request and is shown alongside the answer.

/// A published set of pKa values for the ionisable groups in a protein.
public enum PKaScale: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Bjellqvist values, as used by ExPASy Compute pI/Mw and ProtParam.
    /// Choose this to agree with the tool most people cross-check against.
    case bjellqvist

    /// The EMBOSS `iep` values. Common in command-line pipelines. Differs from
    /// Bjellqvist most noticeably for histidine- and cysteine-rich sequences.
    case emboss

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bjellqvist: "Bjellqvist (ExPASy)"
        case .emboss: "EMBOSS"
        }
    }

    /// A one-line note for the UI, so the number is never presented without
    /// saying what produced it.
    public var provenance: String {
        switch self {
        case .bjellqvist:
            "Bjellqvist et al., Electrophoresis 1993. Matches ExPASy ProtParam."
        case .emboss:
            "EMBOSS iep default table."
        }
    }

    public var values: Values {
        switch self {
        case .bjellqvist: AminoAcidTables.bjellqvistScale
        case .emboss: AminoAcidTables.embossScale
        }
    }

    /// The pKa values of every ionisable group in a scale.
    public struct Values: Sendable, Hashable {
        /// pKa of the free alpha-amino group, when the first residue has no
        /// scale-specific override.
        public let nTerminus: Double

        /// pKa of the free alpha-carboxyl group, when the last residue has no
        /// scale-specific override.
        public let cTerminus: Double

        /// Scale-specific N-terminal pKa keyed by the first residue.
        ///
        /// The Bjellqvist scale varies the terminal pKa by which residue sits
        /// there. Ignoring these shifts pI noticeably for short peptides, where
        /// the termini are a large fraction of the ionisable groups.
        public let nTerminusOverrides: [AminoAcid: Double]

        /// Scale-specific C-terminal pKa keyed by the last residue.
        public let cTerminusOverrides: [AminoAcid: Double]

        /// Side chains that carry positive charge when protonated.
        public let basicSideChains: [AminoAcid: Double]

        /// Side chains that carry negative charge when deprotonated.
        public let acidicSideChains: [AminoAcid: Double]

        public init(
            nTerminus: Double,
            cTerminus: Double,
            nTerminusOverrides: [AminoAcid: Double],
            cTerminusOverrides: [AminoAcid: Double],
            basicSideChains: [AminoAcid: Double],
            acidicSideChains: [AminoAcid: Double]
        ) {
            self.nTerminus = nTerminus
            self.cTerminus = cTerminus
            self.nTerminusOverrides = nTerminusOverrides
            self.cTerminusOverrides = cTerminusOverrides
            self.basicSideChains = basicSideChains
            self.acidicSideChains = acidicSideChains
        }

        /// The N-terminal pKa for a chain starting with `residue`.
        public func nTerminusPKa(startingWith residue: AminoAcid?) -> Double {
            guard let residue, let override = nTerminusOverrides[residue] else {
                return nTerminus
            }
            return override
        }

        /// The C-terminal pKa for a chain ending with `residue`.
        public func cTerminusPKa(endingWith residue: AminoAcid?) -> Double {
            guard let residue, let override = cTerminusOverrides[residue] else {
                return cTerminus
            }
            return override
        }
    }
}
