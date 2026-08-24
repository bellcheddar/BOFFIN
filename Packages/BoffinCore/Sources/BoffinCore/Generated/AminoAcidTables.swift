//  AminoAcidTables.swift
//  BoffinCore
//
//  GENERATED FILE. Do not edit by hand.
//  Regenerate with: python3 Tools/data/generate_amino_acid_tables.py
//  Generated 2026-08-24. Source checksums in Tools/data/MANIFEST.md.
//
//  These are published scientific constants. Each table cites the paper
//  it comes from: see Docs/ATTRIBUTIONS.md for the full provenance.

/// Constant tables backing the analytical properties in `SequenceProperties`.
public enum AminoAcidTables {

    /// Average mass of water, in daltons.
    ///
    /// Added once to the sum of residue masses: a peptide chain is the
    /// residues plus a terminal H and OH.
    public static let waterAverageMass = 18.01524

    /// Average (not monoisotopic) residue masses, in daltons.
    ///
    /// Derived as the free amino acid mass minus one water. Average masses
    /// are what ExPASy ProtParam reports and what a molecular weight quoted
    /// on a construct card should be: monoisotopic masses belong to mass
    /// spectrometry and are a different number for the same protein.
    public static let averageResidueMass: [AminoAcid: Double] = [
        .alanine: 71.07796,
        .cysteine: 103.14296,
        .asparticAcid: 115.08746,
        .glutamicAcid: 129.11406,
        .phenylalanine: 147.17386,
        .glycine: 57.05136,
        .histidine: 137.13936,
        .isoleucine: 113.15766,
        .lysine: 128.17236,
        .leucine: 113.15766,
        .methionine: 131.19606,
        .asparagine: 114.10266,
        .proline: 97.11526,
        .glutamine: 128.12926,
        .arginine: 156.18576,
        .serine: 87.07736,
        .threonine: 101.10396,
        .valine: 99.13106,
        .tryptophan: 186.20996,
        .tyrosine: 163.17326,
    ]

    /// Kyte and Doolittle hydropathy index.
    ///
    /// Kyte J, Doolittle RF. A simple method for displaying the hydropathic
    /// character of a protein. J Mol Biol 157:105-132 (1982).
    public static let kyteDoolittleHydropathy: [AminoAcid: Double] = [
        .alanine: 1.8,
        .cysteine: 2.5,
        .asparticAcid: -3.5,
        .glutamicAcid: -3.5,
        .phenylalanine: 2.8,
        .glycine: -0.4,
        .histidine: -3.2,
        .isoleucine: 4.5,
        .lysine: -3.9,
        .leucine: 3.8,
        .methionine: 1.9,
        .asparagine: -3.5,
        .proline: -1.6,
        .glutamine: -3.5,
        .arginine: -4.5,
        .serine: -0.8,
        .threonine: -0.7,
        .valine: 4.2,
        .tryptophan: -0.9,
        .tyrosine: -1.3,
    ]

    /// Molar extinction coefficients at 280 nm, in M^-1 cm^-1.
    ///
    /// Pace CN, Vajdos F, Fee L, Grimsley G, Gray T. How to measure and
    /// predict the molar absorption coefficient of a protein.
    /// Protein Sci 4:2411-2423 (1995).
    ///
    /// Cystine (a disulfide-bonded pair) absorbs; free cysteine does not,
    /// which is why the two reported variants differ.
    public static let extinctionTryptophan = 5500.0
    public static let extinctionTyrosine = 1490.0
    public static let extinctionCystine = 125.0

    /// Dipeptide instability weight values (DIWV).
    ///
    /// Guruprasad K, Reddy BVB, Pandit MW. Correlation between stability of
    /// a protein and its dipeptide composition. Protein Eng 4:155-161 (1990).
    ///
    /// Indexed [first][second] for the dipeptide first-second. 400 entries,
    /// generated rather than transcribed.
    public static let dipeptideInstability: [AminoAcid: [AminoAcid: Double]] = [
        .alanine: [
            .alanine: 1.0, .cysteine: 44.94, .asparticAcid: -7.49, .glutamicAcid: 1.0,
            .phenylalanine: 1.0, .glycine: 1.0, .histidine: -7.49, .isoleucine: 1.0, .lysine: 1.0,
            .leucine: 1.0, .methionine: 1.0, .asparagine: 1.0, .proline: 20.26, .glutamine: 1.0,
            .arginine: 1.0, .serine: 1.0, .threonine: 1.0, .valine: 1.0, .tryptophan: 1.0,
            .tyrosine: 1.0,
        ],
        .cysteine: [
            .alanine: 1.0, .cysteine: 1.0, .asparticAcid: 20.26, .glutamicAcid: 1.0,
            .phenylalanine: 1.0, .glycine: 1.0, .histidine: 33.6, .isoleucine: 1.0, .lysine: 1.0,
            .leucine: 20.26, .methionine: 33.6, .asparagine: 1.0, .proline: 20.26,
            .glutamine: -6.54, .arginine: 1.0, .serine: 1.0, .threonine: 33.6, .valine: -6.54,
            .tryptophan: 24.68, .tyrosine: 1.0,
        ],
        .asparticAcid: [
            .alanine: 1.0, .cysteine: 1.0, .asparticAcid: 1.0, .glutamicAcid: 1.0,
            .phenylalanine: -6.54, .glycine: 1.0, .histidine: 1.0, .isoleucine: 1.0, .lysine: -7.49,
            .leucine: 1.0, .methionine: 1.0, .asparagine: 1.0, .proline: 1.0, .glutamine: 1.0,
            .arginine: -6.54, .serine: 20.26, .threonine: -14.03, .valine: 1.0, .tryptophan: 1.0,
            .tyrosine: 1.0,
        ],
        .glutamicAcid: [
            .alanine: 1.0, .cysteine: 44.94, .asparticAcid: 20.26, .glutamicAcid: 33.6,
            .phenylalanine: 1.0, .glycine: 1.0, .histidine: -6.54, .isoleucine: 20.26, .lysine: 1.0,
            .leucine: 1.0, .methionine: 1.0, .asparagine: 1.0, .proline: 20.26, .glutamine: 20.26,
            .arginine: 1.0, .serine: 20.26, .threonine: 1.0, .valine: 1.0, .tryptophan: -14.03,
            .tyrosine: 1.0,
        ],
        .phenylalanine: [
            .alanine: 1.0, .cysteine: 1.0, .asparticAcid: 13.34, .glutamicAcid: 1.0,
            .phenylalanine: 1.0, .glycine: 1.0, .histidine: 1.0, .isoleucine: 1.0, .lysine: -14.03,
            .leucine: 1.0, .methionine: 1.0, .asparagine: 1.0, .proline: 20.26, .glutamine: 1.0,
            .arginine: 1.0, .serine: 1.0, .threonine: 1.0, .valine: 1.0, .tryptophan: 1.0,
            .tyrosine: 33.601,
        ],
        .glycine: [
            .alanine: -7.49, .cysteine: 1.0, .asparticAcid: 1.0, .glutamicAcid: -6.54,
            .phenylalanine: 1.0, .glycine: 13.34, .histidine: 1.0, .isoleucine: -7.49,
            .lysine: -7.49, .leucine: 1.0, .methionine: 1.0, .asparagine: -7.49, .proline: 1.0,
            .glutamine: 1.0, .arginine: 1.0, .serine: 1.0, .threonine: -7.49, .valine: 1.0,
            .tryptophan: 13.34, .tyrosine: -7.49,
        ],
        .histidine: [
            .alanine: 1.0, .cysteine: 1.0, .asparticAcid: 1.0, .glutamicAcid: 1.0,
            .phenylalanine: -9.37, .glycine: -9.37, .histidine: 1.0, .isoleucine: 44.94,
            .lysine: 24.68, .leucine: 1.0, .methionine: 1.0, .asparagine: 24.68, .proline: -1.88,
            .glutamine: 1.0, .arginine: 1.0, .serine: 1.0, .threonine: -6.54, .valine: 1.0,
            .tryptophan: -1.88, .tyrosine: 44.94,
        ],
        .isoleucine: [
            .alanine: 1.0, .cysteine: 1.0, .asparticAcid: 1.0, .glutamicAcid: 44.94,
            .phenylalanine: 1.0, .glycine: 1.0, .histidine: 13.34, .isoleucine: 1.0, .lysine: -7.49,
            .leucine: 20.26, .methionine: 1.0, .asparagine: 1.0, .proline: -1.88, .glutamine: 1.0,
            .arginine: 1.0, .serine: 1.0, .threonine: 1.0, .valine: -7.49, .tryptophan: 1.0,
            .tyrosine: 1.0,
        ],
        .lysine: [
            .alanine: 1.0, .cysteine: 1.0, .asparticAcid: 1.0, .glutamicAcid: 1.0,
            .phenylalanine: 1.0, .glycine: -7.49, .histidine: 1.0, .isoleucine: -7.49, .lysine: 1.0,
            .leucine: -7.49, .methionine: 33.6, .asparagine: 1.0, .proline: -6.54,
            .glutamine: 24.64, .arginine: 33.6, .serine: 1.0, .threonine: 1.0, .valine: -7.49,
            .tryptophan: 1.0, .tyrosine: 1.0,
        ],
        .leucine: [
            .alanine: 1.0, .cysteine: 1.0, .asparticAcid: 1.0, .glutamicAcid: 1.0,
            .phenylalanine: 1.0, .glycine: 1.0, .histidine: 1.0, .isoleucine: 1.0, .lysine: -7.49,
            .leucine: 1.0, .methionine: 1.0, .asparagine: 1.0, .proline: 20.26, .glutamine: 33.6,
            .arginine: 20.26, .serine: 1.0, .threonine: 1.0, .valine: 1.0, .tryptophan: 24.68,
            .tyrosine: 1.0,
        ],
        .methionine: [
            .alanine: 13.34, .cysteine: 1.0, .asparticAcid: 1.0, .glutamicAcid: 1.0,
            .phenylalanine: 1.0, .glycine: 1.0, .histidine: 58.28, .isoleucine: 1.0, .lysine: 1.0,
            .leucine: 1.0, .methionine: -1.88, .asparagine: 1.0, .proline: 44.94, .glutamine: -6.54,
            .arginine: -6.54, .serine: 44.94, .threonine: -1.88, .valine: 1.0, .tryptophan: 1.0,
            .tyrosine: 24.68,
        ],
        .asparagine: [
            .alanine: 1.0, .cysteine: -1.88, .asparticAcid: 1.0, .glutamicAcid: 1.0,
            .phenylalanine: -14.03, .glycine: -14.03, .histidine: 1.0, .isoleucine: 44.94,
            .lysine: 24.68, .leucine: 1.0, .methionine: 1.0, .asparagine: 1.0, .proline: -1.88,
            .glutamine: -6.54, .arginine: 1.0, .serine: 1.0, .threonine: -7.49, .valine: 1.0,
            .tryptophan: -9.37, .tyrosine: 1.0,
        ],
        .proline: [
            .alanine: 20.26, .cysteine: -6.54, .asparticAcid: -6.54, .glutamicAcid: 18.38,
            .phenylalanine: 20.26, .glycine: 1.0, .histidine: 1.0, .isoleucine: 1.0, .lysine: 1.0,
            .leucine: 1.0, .methionine: -6.54, .asparagine: 1.0, .proline: 20.26, .glutamine: 20.26,
            .arginine: -6.54, .serine: 20.26, .threonine: 1.0, .valine: 20.26, .tryptophan: -1.88,
            .tyrosine: 1.0,
        ],
        .glutamine: [
            .alanine: 1.0, .cysteine: -6.54, .asparticAcid: 20.26, .glutamicAcid: 20.26,
            .phenylalanine: -6.54, .glycine: 1.0, .histidine: 1.0, .isoleucine: 1.0, .lysine: 1.0,
            .leucine: 1.0, .methionine: 1.0, .asparagine: 1.0, .proline: 20.26, .glutamine: 20.26,
            .arginine: 1.0, .serine: 44.94, .threonine: 1.0, .valine: -6.54, .tryptophan: 1.0,
            .tyrosine: -6.54,
        ],
        .arginine: [
            .alanine: 1.0, .cysteine: 1.0, .asparticAcid: 1.0, .glutamicAcid: 1.0,
            .phenylalanine: 1.0, .glycine: -7.49, .histidine: 20.26, .isoleucine: 1.0, .lysine: 1.0,
            .leucine: 1.0, .methionine: 1.0, .asparagine: 13.34, .proline: 20.26, .glutamine: 20.26,
            .arginine: 58.28, .serine: 44.94, .threonine: 1.0, .valine: 1.0, .tryptophan: 58.28,
            .tyrosine: -6.54,
        ],
        .serine: [
            .alanine: 1.0, .cysteine: 33.6, .asparticAcid: 1.0, .glutamicAcid: 20.26,
            .phenylalanine: 1.0, .glycine: 1.0, .histidine: 1.0, .isoleucine: 1.0, .lysine: 1.0,
            .leucine: 1.0, .methionine: 1.0, .asparagine: 1.0, .proline: 44.94, .glutamine: 20.26,
            .arginine: 20.26, .serine: 20.26, .threonine: 1.0, .valine: 1.0, .tryptophan: 1.0,
            .tyrosine: 1.0,
        ],
        .threonine: [
            .alanine: 1.0, .cysteine: 1.0, .asparticAcid: 1.0, .glutamicAcid: 20.26,
            .phenylalanine: 13.34, .glycine: -7.49, .histidine: 1.0, .isoleucine: 1.0, .lysine: 1.0,
            .leucine: 1.0, .methionine: 1.0, .asparagine: -14.03, .proline: 1.0, .glutamine: -6.54,
            .arginine: 1.0, .serine: 1.0, .threonine: 1.0, .valine: 1.0, .tryptophan: -14.03,
            .tyrosine: 1.0,
        ],
        .valine: [
            .alanine: 1.0, .cysteine: 1.0, .asparticAcid: -14.03, .glutamicAcid: 1.0,
            .phenylalanine: 1.0, .glycine: -7.49, .histidine: 1.0, .isoleucine: 1.0, .lysine: -1.88,
            .leucine: 1.0, .methionine: 1.0, .asparagine: 1.0, .proline: 20.26, .glutamine: 1.0,
            .arginine: 1.0, .serine: 1.0, .threonine: -7.49, .valine: 1.0, .tryptophan: 1.0,
            .tyrosine: -6.54,
        ],
        .tryptophan: [
            .alanine: -14.03, .cysteine: 1.0, .asparticAcid: 1.0, .glutamicAcid: 1.0,
            .phenylalanine: 1.0, .glycine: -9.37, .histidine: 24.68, .isoleucine: 1.0, .lysine: 1.0,
            .leucine: 13.34, .methionine: 24.68, .asparagine: 13.34, .proline: 1.0, .glutamine: 1.0,
            .arginine: 1.0, .serine: 1.0, .threonine: -14.03, .valine: -7.49, .tryptophan: 1.0,
            .tyrosine: 1.0,
        ],
        .tyrosine: [
            .alanine: 24.68, .cysteine: 1.0, .asparticAcid: 24.68, .glutamicAcid: -6.54,
            .phenylalanine: 1.0, .glycine: -7.49, .histidine: 13.34, .isoleucine: 1.0, .lysine: 1.0,
            .leucine: 1.0, .methionine: 44.94, .asparagine: 1.0, .proline: 13.34, .glutamine: 1.0,
            .arginine: -15.91, .serine: 1.0, .threonine: -7.49, .valine: 1.0, .tryptophan: -9.37,
            .tyrosine: 13.34,
        ],
    ]

    // MARK: - pKa scales

    /// Bjellqvist pKa values, as used by ExPASy Compute pI/Mw and ProtParam.
    ///
    /// Bjellqvist B et al. Reference points for comparisons of two-dimensional
    /// maps of proteins from different human cell types defined in a pH scale
    /// where isoelectric points correlate with polypeptide compositions.
    /// Electrophoresis 14:1023-1031 (1993), and Electrophoresis 15:529-539 (1994).
    ///
    /// This scale gives the N-terminal amine a pKa that depends on which
    /// residue is first, and the C-terminal carboxyl one that depends on which
    /// is last. Ignoring those overrides shifts pI for short peptides.
    public static let bjellqvistScale = PKaScale.Values(
        nTerminus: 7.5,
        cTerminus: 3.55,
        nTerminusOverrides: [
            .alanine: 7.59,
            .glutamicAcid: 7.7,
            .methionine: 7.0,
            .proline: 8.36,
            .serine: 6.93,
            .threonine: 6.82,
            .valine: 7.44,
        ],
        cTerminusOverrides: [
            .asparticAcid: 4.55,
            .glutamicAcid: 4.75,
        ],
        basicSideChains: [
            .histidine: 5.98,
            .lysine: 10.0,
            .arginine: 12.0,
        ],
        acidicSideChains: [
            .cysteine: 9.0,
            .asparticAcid: 4.05,
            .glutamicAcid: 4.45,
            .tyrosine: 10.0,
        ])

    /// EMBOSS pKa values, as used by the EMBOSS `iep` program.
    ///
    /// From the ORIGINAL EMBOSS block of `emboss/data/Epk.dat`. The same file
    /// carries an alternative Wikipedia-sourced block further down, which is
    /// deliberately not used: mixing the two would produce a scale that is
    /// neither.
    ///
    /// This scale has no residue-specific terminal overrides.
    public static let embossScale = PKaScale.Values(
        nTerminus: 7.5,
        cTerminus: 3.6,
        nTerminusOverrides: [:],
        cTerminusOverrides: [:],
        basicSideChains: [
            .histidine: 6.5,
            .lysine: 10.8,
            .arginine: 12.5,
        ],
        acidicSideChains: [
            .cysteine: 8.5,
            .asparticAcid: 3.9,
            .glutamicAcid: 4.1,
            .tyrosine: 10.1,
        ])
}
