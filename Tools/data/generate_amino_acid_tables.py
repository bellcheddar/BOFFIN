#!/usr/bin/env python3
"""Generate BoffinCore's amino acid constant tables from public sources.

Run:  python3 Tools/data/generate_amino_acid_tables.py

Writes:
  Packages/BoffinCore/Sources/BoffinCore/Generated/AminoAcidTables.swift
  Tools/data/MANIFEST.md   (source URLs, download date, SHA-256 of each source)

Why this is generated rather than typed
---------------------------------------
The instability index needs a 400-entry dipeptide table (Guruprasad 1990). Hand
transcribing 400 numbers is precisely the failure the working agreement warns
about: a plausible-looking but silently wrong table that will be believed
because the code around it looks careful. Generating the Swift from a fetched,
checksummed source removes transcription as a failure mode entirely.

The values are scientific constants from published papers, not code. The
sources are used as convenient machine-readable transcriptions of those papers,
and each is cited in Docs/ATTRIBUTIONS.md alongside the paper it came from.

This script is NOT run at build time. Re-run it only to refresh the tables, and
commit the regenerated Swift alongside an updated manifest.
"""

from __future__ import annotations

import ast
import datetime
import hashlib
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT_SWIFT = (
    ROOT
    / "Packages/BoffinCore/Sources/BoffinCore/Generated/AminoAcidTables.swift"
)
OUT_MANIFEST = ROOT / "Tools/data/MANIFEST.md"

CANONICAL = "ACDEFGHIKLMNPQRSTVWY"

# One-letter code to the Swift enum case name in AminoAcid.swift. Emitting the
# case directly keeps the generated file free of force unwraps, which the
# project's swift-format configuration forbids (NeverForceUnwrap).
CASE_NAME = {
    "A": "alanine", "C": "cysteine", "D": "asparticAcid", "E": "glutamicAcid",
    "F": "phenylalanine", "G": "glycine", "H": "histidine", "I": "isoleucine",
    "K": "lysine", "L": "leucine", "M": "methionine", "N": "asparagine",
    "P": "proline", "Q": "glutamine", "R": "arginine", "S": "serine",
    "T": "threonine", "V": "valine", "W": "tryptophan", "Y": "tyrosine",
}

# Average mass of water, used to convert free amino acid masses to residue
# masses and to add the terminal H and OH back onto the assembled chain.
WATER_AVERAGE_MASS = 18.01524

SOURCES = {
    "IUPACData.py": (
        "https://raw.githubusercontent.com/biopython/biopython/master/"
        "Bio/Data/IUPACData.py"
    ),
    "ProtParamData.py": (
        "https://raw.githubusercontent.com/biopython/biopython/master/"
        "Bio/SeqUtils/ProtParamData.py"
    ),
    "IsoelectricPoint.py": (
        "https://raw.githubusercontent.com/biopython/biopython/master/"
        "Bio/SeqUtils/IsoelectricPoint.py"
    ),
    "Epk.dat": (
        "https://raw.githubusercontent.com/kimrutherford/EMBOSS/master/"
        "emboss/data/Epk.dat"
    ),
}


def fetch(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "boffin-table-generator"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode("utf-8")


def literal_after(text: str, name: str) -> object:
    """Extract the Python literal assigned to `name` at module level."""
    module = ast.parse(text)
    for node in module.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == name:
                    return ast.literal_eval(node.value)
    raise KeyError(f"{name} not found")


def parse_emboss_pka(text: str) -> dict[str, float]:
    """Parse the ORIGINAL EMBOSS block of Epk.dat.

    The file also carries an alternative Wikipedia-sourced block further down.
    Only the first block is the EMBOSS scale, so parsing stops at the second
    header rather than letting later values silently overwrite earlier ones.
    """
    values: dict[str, float] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            if "Wikipedia" in stripped:
                break
            continue
        if not stripped:
            continue
        parts = stripped.split()
        if len(parts) != 2:
            continue
        key, raw = parts
        try:
            values[key] = float(raw)
        except ValueError:
            continue
    return values


def swift_double(value: float) -> str:
    text = repr(float(value))
    return text if ("." in text or "e" in text) else text + ".0"


def main() -> int:
    downloaded: dict[str, str] = {}
    digests: dict[str, str] = {}
    for name, url in SOURCES.items():
        try:
            body = fetch(url)
        except Exception as error:  # noqa: BLE001
            print(f"failed to fetch {name}: {error}", file=sys.stderr)
            return 1
        downloaded[name] = body
        digests[name] = hashlib.sha256(body.encode("utf-8")).hexdigest()
        print(f"fetched {name} ({len(body)} bytes)")

    free_weights = literal_after(downloaded["IUPACData.py"], "protein_weights")
    kyte_doolittle = literal_after(downloaded["ProtParamData.py"], "kd")
    diwv = literal_after(downloaded["ProtParamData.py"], "DIWV")

    isoelectric = downloaded["IsoelectricPoint.py"]
    positive_pks = literal_after(isoelectric, "positive_pKs")
    negative_pks = literal_after(isoelectric, "negative_pKs")
    pk_cterminal = literal_after(isoelectric, "pKcterminal")
    pk_nterminal = literal_after(isoelectric, "pKnterminal")

    emboss = parse_emboss_pka(downloaded["Epk.dat"])

    missing = [aa for aa in CANONICAL if aa not in free_weights]
    if missing:
        print(f"missing residue masses: {missing}", file=sys.stderr)
        return 1
    for first in CANONICAL:
        for second in CANONICAL:
            if second not in diwv.get(first, {}):
                print(f"missing DIWV[{first}][{second}]", file=sys.stderr)
                return 1

    today = datetime.date.today().isoformat()

    lines: list[str] = []
    add = lines.append

    add("//  AminoAcidTables.swift")
    add("//  BoffinCore")
    add("//")
    add("//  GENERATED FILE. Do not edit by hand.")
    add("//  Regenerate with: python3 Tools/data/generate_amino_acid_tables.py")
    add(f"//  Generated {today}. Source checksums in Tools/data/MANIFEST.md.")
    add("//")
    add("//  These are published scientific constants. Each table cites the paper")
    add("//  it comes from: see Docs/ATTRIBUTIONS.md for the full provenance.")
    add("")
    add("/// Constant tables backing the analytical properties in `SequenceProperties`.")
    add("public enum AminoAcidTables {")
    add("")
    add("    /// Average mass of water, in daltons.")
    add("    ///")
    add("    /// Added once to the sum of residue masses: a peptide chain is the")
    add("    /// residues plus a terminal H and OH.")
    add(f"    public static let waterAverageMass = {swift_double(WATER_AVERAGE_MASS)}")
    add("")
    add("    /// Average (not monoisotopic) residue masses, in daltons.")
    add("    ///")
    add("    /// Derived as the free amino acid mass minus one water. Average masses")
    add("    /// are what ExPASy ProtParam reports and what a molecular weight quoted")
    add("    /// on a construct card should be: monoisotopic masses belong to mass")
    add("    /// spectrometry and are a different number for the same protein.")
    add("    public static let averageResidueMass: [AminoAcid: Double] = [")
    for aa in CANONICAL:
        residue = free_weights[aa] - WATER_AVERAGE_MASS
        add(f"        .{CASE_NAME[aa]}: {swift_double(round(residue, 6))},")
    add("    ]")
    add("")
    add("    /// Kyte and Doolittle hydropathy index.")
    add("    ///")
    add("    /// Kyte J, Doolittle RF. A simple method for displaying the hydropathic")
    add("    /// character of a protein. J Mol Biol 157:105-132 (1982).")
    add("    public static let kyteDoolittleHydropathy: [AminoAcid: Double] = [")
    for aa in CANONICAL:
        add(f"        .{CASE_NAME[aa]}: {swift_double(kyte_doolittle[aa])},")
    add("    ]")
    add("")
    add("    /// Molar extinction coefficients at 280 nm, in M^-1 cm^-1.")
    add("    ///")
    add("    /// Pace CN, Vajdos F, Fee L, Grimsley G, Gray T. How to measure and")
    add("    /// predict the molar absorption coefficient of a protein.")
    add("    /// Protein Sci 4:2411-2423 (1995).")
    add("    ///")
    add("    /// Cystine (a disulfide-bonded pair) absorbs; free cysteine does not,")
    add("    /// which is why the two reported variants differ.")
    add("    public static let extinctionTryptophan = 5500.0")
    add("    public static let extinctionTyrosine = 1490.0")
    add("    public static let extinctionCystine = 125.0")
    add("")
    add("    /// Dipeptide instability weight values (DIWV).")
    add("    ///")
    add("    /// Guruprasad K, Reddy BVB, Pandit MW. Correlation between stability of")
    add("    /// a protein and its dipeptide composition. Protein Eng 4:155-161 (1990).")
    add("    ///")
    add("    /// Indexed [first][second] for the dipeptide first-second. 400 entries,")
    add("    /// generated rather than transcribed.")
    add("    public static let dipeptideInstability: [AminoAcid: [AminoAcid: Double]] = [")
    for first in CANONICAL:
        pairs = ", ".join(
            f".{CASE_NAME[second]}: {swift_double(diwv[first][second])}"
            for second in CANONICAL
        )
        add(f"        .{CASE_NAME[first]}: [{pairs}],")
    add("    ]")
    add("")
    add("    // MARK: - pKa scales")
    add("")
    add("    /// Bjellqvist pKa values, as used by ExPASy Compute pI/Mw and ProtParam.")
    add("    ///")
    add("    /// Bjellqvist B et al. Reference points for comparisons of two-dimensional")
    add("    /// maps of proteins from different human cell types defined in a pH scale")
    add("    /// where isoelectric points correlate with polypeptide compositions.")
    add("    /// Electrophoresis 14:1023-1031 (1993), and Electrophoresis 15:529-539 (1994).")
    add("    ///")
    add("    /// This scale gives the N-terminal amine a pKa that depends on which")
    add("    /// residue is first, and the C-terminal carboxyl one that depends on which")
    add("    /// is last. Ignoring those overrides shifts pI for short peptides.")
    add("    public static let bjellqvistScale = PKaScale.Values(")
    add(f"        nTerminus: {swift_double(positive_pks['Nterm'])},")
    add(f"        cTerminus: {swift_double(negative_pks['Cterm'])},")
    add("        nTerminusOverrides: [")
    for aa in sorted(pk_nterminal):
        add(f"            .{CASE_NAME[aa]}: {swift_double(pk_nterminal[aa])},")
    add("        ],")
    add("        cTerminusOverrides: [")
    for aa in sorted(pk_cterminal):
        add(f"            .{CASE_NAME[aa]}: {swift_double(pk_cterminal[aa])},")
    add("        ],")
    add("        basicSideChains: [")
    for aa in sorted(k for k in positive_pks if k != "Nterm"):
        add(f"            .{CASE_NAME[aa]}: {swift_double(positive_pks[aa])},")
    add("        ],")
    add("        acidicSideChains: [")
    for aa in sorted(k for k in negative_pks if k != "Cterm"):
        add(f"            .{CASE_NAME[aa]}: {swift_double(negative_pks[aa])},")
    add("        ])")
    add("")
    add("    /// EMBOSS pKa values, as used by the EMBOSS `iep` program.")
    add("    ///")
    add("    /// From the ORIGINAL EMBOSS block of `emboss/data/Epk.dat`. The same file")
    add("    /// carries an alternative Wikipedia-sourced block further down, which is")
    add("    /// deliberately not used: mixing the two would produce a scale that is")
    add("    /// neither.")
    add("    ///")
    add("    /// This scale has no residue-specific terminal overrides.")
    add("    public static let embossScale = PKaScale.Values(")
    add(f"        nTerminus: {swift_double(emboss['Amino'])},")
    add(f"        cTerminus: {swift_double(emboss['Carboxyl'])},")
    add("        nTerminusOverrides: [:],")
    add("        cTerminusOverrides: [:],")
    add("        basicSideChains: [")
    for aa in ("H", "K", "R"):
        add(f"            .{CASE_NAME[aa]}: {swift_double(emboss[aa])},")
    add("        ],")
    add("        acidicSideChains: [")
    for aa in ("C", "D", "E", "Y"):
        add(f"            .{CASE_NAME[aa]}: {swift_double(emboss[aa])},")
    add("        ])")
    add("}")
    add("")

    OUT_SWIFT.parent.mkdir(parents=True, exist_ok=True)
    OUT_SWIFT.write_text("\n".join(lines) + "\n")
    print(f"wrote {OUT_SWIFT.relative_to(ROOT)} ({len(lines)} lines)")

    manifest = [
        "# Generated data manifest",
        "",
        "Constant tables in `BoffinCore` are generated, not transcribed. Regenerate",
        "with `python3 Tools/data/generate_amino_acid_tables.py` and commit the",
        "result together with this manifest.",
        "",
        f"Last generated: **{today}**",
        "",
        "| Source | URL | SHA-256 |",
        "|---|---|---|",
    ]
    for name, url in SOURCES.items():
        manifest.append(f"| `{name}` | <{url}> | `{digests[name]}` |")
    manifest += [
        "",
        "## What is taken from each",
        "",
        "| Source | Table | Underlying paper |",
        "|---|---|---|",
        "| `IUPACData.py` | Average free amino acid masses | IUPAC-IUB standard atomic weights |",
        "| `ProtParamData.py` | Kyte-Doolittle hydropathy | Kyte & Doolittle, J Mol Biol 157:105 (1982) |",
        "| `ProtParamData.py` | DIWV dipeptide instability, 400 entries | Guruprasad et al., Protein Eng 4:155 (1990) |",
        "| `IsoelectricPoint.py` | Bjellqvist pKa scale | Bjellqvist et al., Electrophoresis 14:1023 (1993) |",
        "| `Epk.dat` | EMBOSS pKa scale | EMBOSS `iep` |",
        "",
        "These are published scientific constants, used here as machine-readable",
        "transcriptions of the papers cited above rather than as code. Licensing of",
        "the sources is recorded in `Docs/ATTRIBUTIONS.md`.",
        "",
        "Extinction coefficients at 280 nm (Trp 5500, Tyr 1490, cystine 125) are from",
        "Pace et al., Protein Sci 4:2411 (1995) and are written directly into the",
        "generator: three numbers do not need a download to be trustworthy.",
        "",
    ]
    OUT_MANIFEST.write_text("\n".join(manifest) + "\n")
    print(f"wrote {OUT_MANIFEST.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
