# Attributions and licence audit

Every dependency, data source and model in BOFFIN is recorded here before it is
used. For a scientific tool by a named scientist, correct attribution is a
professional obligation as much as a legal one. This file is surfaced in the
app through an in-app Acknowledgements screen.

**Status key:** *verified* means the licence was read at the source on the date
shown. *assumed* means it is taken from the build plan and has not yet been
checked, and must not be relied on.

---

## Verified in Phase 0 (2026-08-24)

### PLIP: GNU GPL v2 (verified)

Source: <https://github.com/pharmai/plip>. The README states "PLIP is published
under the GNU GPLv2", and the repository licence badge reads GPL-2.0.

**Consequence: PLIP is never linked, vendored, ported or copied into BOFFIN.**
GPL v2 is incompatible with a closed-source App Store application. The
`InteractionProfiler` in `BoffinStructure` is a clean-room Swift implementation
of published geometric criteria, which are standard structural chemistry and
are not themselves proprietary. Cite PLIP's papers for the criteria; take no
code.

Whoever implements the profiler must not read PLIP source while doing so. Work
from the published criteria and the PLIP documentation instead.

### Mol*: MIT (verified)

Source: <https://github.com/molstar/molstar>. MIT licence.

Vendored as a UMD build into `Packages/BoffinViewer/Sources/BoffinViewer/Resources/`
in Phase 7, with the pinned version, commit hash and full licence text recorded
in a `VENDOR.md` alongside it. No CDN reference anywhere: CI fails the build if
one appears.

### ESM-2: MIT (verified)

Source: <https://github.com/facebookresearch/esm>. Source code is MIT. The
pretrained weights are distributed under the same repository terms.

Note that the ESM Metagenomic Atlas *data* is separately licensed CC BY 4.0.
BOFFIN uses the ESM-2 weights, not the Atlas, so that clause does not currently
apply. It would if Atlas structures were ever bundled.

Cite: Lin et al., *Evolutionary-scale prediction of atomic-level protein
structure with a language model*, Science 379:1123 (2023).

---

## To verify before the phase that first uses them

| Source | Expected terms | First needed | Status |
|---|---|---|---|
| RCSB PDB data | CC0 | Phase 0 (fixtures) | assumed, attribute regardless |
| UniProt | CC BY 4.0 | Phase 0 (fixtures) | assumed |
| Pfam / InterPro | CC0 | Phase 5 | assumed |
| KLIFS | check current terms | Phase 5 | **unverified: confirm redistribution of derived numbering tables** |
| GPCRdb | CC BY 4.0 | Phase 5 | assumed, attribution required |
| AlphaFold DB | CC BY 4.0 | Phase 7 | assumed, predicted models must be labelled as such |
| DisProt, CB513, TOPCONS, DeepTMHMM | various | Phase 3 | **unverified, and gated on open question 1** |

KLIFS is the one to check early: it is the only entry where redistribution of
derived tables inside a shipped app is genuinely in question, and it gates
Phase 5.

---

## Fixture data (Phase 0)

Structures and sequences under `Fixtures/` are from RCSB PDB and UniProt.
Provenance, download date and SHA-256 checksums are in `Fixtures/MANIFEST.md`.

- RCSB PDB: Berman et al., *The Protein Data Bank*, Nucleic Acids Res 28:235 (2000).
- UniProt: The UniProt Consortium, Nucleic Acids Res 51:D523 (2023).

---

## Constant tables (Phase 1, 2026-08-24)

`BoffinCore`'s amino acid tables are **generated**, not transcribed, by
`Tools/data/generate_amino_acid_tables.py`. Source URLs, download date and
SHA-256 of every input are recorded in `Tools/data/MANIFEST.md`.

These are published scientific constants (facts from the papers below), used
here via convenient machine-readable transcriptions rather than as code. No
third-party code is linked or shipped.

| Table | Paper | Transcription source | Licence of that source |
|---|---|---|---|
| Kyte-Doolittle hydropathy | Kyte J, Doolittle RF. J Mol Biol 157:105-132 (1982) | Biopython `Bio/SeqUtils/ProtParamData.py` | Biopython License Agreement or BSD 3-Clause |
| DIWV dipeptide instability (400 entries) | Guruprasad K, Reddy BVB, Pandit MW. Protein Eng 4:155-161 (1990) | Biopython `Bio/SeqUtils/ProtParamData.py` | as above |
| Bjellqvist pKa scale | Bjellqvist B et al. Electrophoresis 14:1023-1031 (1993) | Biopython `Bio/SeqUtils/IsoelectricPoint.py` | as above |
| Average residue masses | IUPAC-IUB standard atomic weights | Biopython `Bio/Data/IUPACData.py` | as above |
| EMBOSS pKa scale | EMBOSS `iep` | EMBOSS `emboss/data/Epk.dat` | GPL (data file only, no code taken) |
| Extinction coefficients at 280 nm | Pace CN et al. Protein Sci 4:2411-2423 (1995) | written directly into the generator | n/a |

Biopython 1.88 is additionally used **outside the app**, as an independent
reference implementation for generating expected values in the Phase 1 test
suite. It is not a dependency of BOFFIN and is not shipped.

Note on the EMBOSS entry: EMBOSS itself is GPL. Only the numeric pKa values
from a data file are used, which are the published constants of the `iep`
method rather than expressive code, and no EMBOSS code is linked or ported.
The same discipline applied to PLIP applies here.

---

## Adding a dependency

Rule 9 of `CLAUDE.md`: every new dependency needs a licence check recorded
here, before it is added. Record the source URL, the licence as read at that
URL, the date, and any consequence for how BOFFIN may use it.
