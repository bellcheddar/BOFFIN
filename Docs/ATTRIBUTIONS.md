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

## DSSP, and why nothing of it is here either

`BoffinStructure/SecondaryStructure.swift` assigns eight-state secondary
structure from coordinates. It is written from Kabsch and Sander's published
description, not from any DSSP implementation: no source has been read, which is
the same footing as the interaction profiler.

Cite: Kabsch and Sander, *Dictionary of protein secondary structure: pattern
recognition of hydrogen-bonded and geometrical features*, Biopolymers 22:2577
(1983).

This exists to unblock a licence. The Q8 head is trained on NetSurfP's
distribution of CB513, whose terms are unstated; those labels are DSSP
assignments over PDB structures, and the PDB is CC0. Computing the labels rather
than redistributing somebody else's is the same move that unblocked the
transmembrane head and the residue numbering.

---

## PLIP, and why nothing of it is here

The interaction profiler in `BoffinStructure/InteractionProfiler.swift` is a
CLEAN-ROOM implementation. **PLIP is GPL v2 and is never linked, ported or
consulted**, which is hard rule 4 and the reason the file exists at all rather
than being a wrapper.

What is reimplemented are the geometric criteria: a distance cutoff between two
carbon atoms is standard structural chemistry from the primary literature and not
anybody's property. The numbers are those tabulated in
`Docs/BOFFIN_BUILD_PLAN.md` section 8.2, which cites them, and they live in a
single `InteractionCriteria` struct so each can be checked against the literature
in one place.

Cite for the criteria: Adasme et al., *PLIP 2021: expanding the scope of the
protein-ligand interaction profiler*, Nucleic Acids Res 49:W530 (2021), as the
source of the tabulated defaults rather than of any code.

---

## Mol\*, vendored 2026-08-25

The structure viewer. **MIT licensed**, verified in the npm registry metadata for
version 5.11.0 and vendored alongside the code as `molstar-LICENSE.txt`. MIT
permits redistribution in a closed-source application with the notice retained,
which is what `Packages/BoffinViewer/VENDOR.md` records along with the checksums.

Cite: Sehnal et al., *Mol\* Viewer: modern web app for 3D visualization and
analysis of large biomolecular structures*, Nucleic Acids Res 49:W431 (2021).

---

## Decision on unstated terms, 2026-08-25

**Marc's call: datasets that state no terms are used, for non-commercial research
purposes.** That covers SIFTS and the DTU distributions of CB513, TS115 and
CASP12. They are no longer treated as release blockers.

The factual position, stated once so it is on the record rather than assumed:
silence is not a permissive licence. Absent a grant, copyright defaults to all
rights reserved, so this is a risk position rather than a permission. Every one
of these sources is a public academic resource distributed for research, which is
the low-risk end of that, and non-commercial use is the narrowest reading of it.

Two things follow, and both are already true of the code:

* **Attribution regardless.** Every source is cited here and surfaced in the
  in-app Acknowledgements screen whether or not a licence requires it.
* **The licence-clear alternatives are kept**, because they turned out to be
  better engineering rather than merely safer. `EntryNumbering` reads numbering
  from the entry itself, and `SecondaryStructureAssigner` computes DSSP from
  coordinates, which means the app can answer geometry questions about a
  structure a user supplies and not only about one somebody has pre-labelled.

**Revisit this before any commercial release**, which is a different decision
with a different risk profile.

---

## To verify before the phase that first uses them

| Source | Expected terms | First needed | Status |
|---|---|---|---|
| RCSB PDB data | CC0 | Phase 0 (fixtures) | **VERIFIED 2026-08-25** |
| SIFTS (EMBL-EBI / PDBe) | expected CC0 | Phase 5 | **checked and NOT stated**, see below |
| UniProt | CC BY 4.0 | Phase 0 (fixtures) | assumed |
| Pfam / InterPro | CC0 | Phase 5 | assumed |
| KLIFS | see below | Phase 5 | **VERIFIED 2026-08-25** |
| GPCRdb | CC BY 4.0 | Phase 5 | **VERIFIED 2026-08-25** |
| AlphaFold DB | CC BY 4.0 | Phase 7 | assumed, predicted models must be labelled as such |
| DisProt, CB513, TOPCONS, DeepTMHMM | various | Phase 3 | **unverified, and gated on open question 1** |

### SIFTS: the workaround that does not work, and the way out

The obvious response to an unlicensed dataset is to obtain the same thing from
somebody whose terms are clear. RCSB's data is CC0, verified, and its API
publishes the UniProt correspondence for every entity.

**It does not help.** RCSB labels that alignment `provenance_source: SIFTS`, and
RCSB's own policy excludes data originating from an integrated external resource
from its licence: "the licensing restrictions applied by the data provider must
be followed". The mapping is EBI's work whoever hands it to you. Recorded here so
the route is closed rather than tried again.

**The way out is a different SOURCE, not a different supplier.** Three categories
inside every mmCIF entry carry what BOFFIN actually needs, and the PDB archive is
CC0:

| Category | What it gives |
|---|---|
| `_pdbx_poly_seq_scheme` | SEQRES index to author number, insertion codes, and which residues were observed |
| `_struct_ref_seq` | the depositor's own UniProt correspondence |
| `_pdbx_struct_assembly` | the biological assemblies the entry declares |

`BoffinStructure/EntryNumbering.swift` reads all three, and its tests pin the
same anchors the SIFTS path is pinned to: CDK2's catalytic aspartate is author
145 by the entry's own scheme, and the coordinates agree.

**What is lost is real.** `_struct_ref_seq` is the DEPOSITOR'S alignment, and
SIFTS is EBI's curated correction of exactly that. For a straightforward entry
they agree; for a chimera, an engineered mutant or a badly annotated old entry,
SIFTS is better. This is the licence-clear path, not the more accurate one, and
the source file says so rather than implying they are equivalent.

### SIFTS, checked at source 2026-08-25

`uniprot_segments_observed.tsv.gz` is the residue-level correspondence between
UniProt, PDB SEQRES and PDB author numbering, and BOFFIN ships a compacted form
of it. It has **no licence statement**. The SIFTS documentation carries only an
EMBL-EBI copyright line, `ebi.ac.uk/pdbe/about/licence` does not resolve, and
`ebi.ac.uk/licencing` states a five-year *commitment* to adopt Creative Commons
across EMBL-EBI resources with CC0 preferred: an intention, not a grant.

The inputs are clear (PDB is CC0, verified at `rcsb.org/pages/policies`; UniProt
is CC BY 4.0), but the SIFTS *mapping* is EBI's own curated work and is what is
being redistributed here. Recorded as unstated rather than rounded up to CC0.
**Confirm with PDBe before release.** This blocks shipping, not development, and
is the same posture taken for the DTU head-training datasets.

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

## Family numbering tables (Phase 5, verified 2026-08-25)

### GPCRdb: CC BY 4.0 (verified)

Data is CC BY 4.0; their source code is Apache 2.0. Commercial use is permitted
with attribution, so BOFFIN may bundle the generic numbering tables provided the
attribution below is carried and surfaced in the Acknowledgements screen.

Cite: Kooistra AJ et al. GPCRdb in 2021: integrating GPCR sequence, structure
and function. Nucleic Acids Res 49:D335 (2021).

### KLIFS: stated open, no named licence (verified as stated)

The KLIFS FAQ says plainly: "both for academia and industry all data in KLIFS is
freely available/open". That is a clear permission covering commercial use.

**It is not a named licence**, and that distinction is kept rather than rounded
up to "CC BY" or "open source". If a formal licence is later required for App
Store distribution, this is the entry to revisit, and the KLIFS team should be
asked directly rather than the FAQ being treated as a licence grant.

Cite: Kanev GK et al. KLIFS: an overhaul after the first 5 years of supporting
kinase research. Nucleic Acids Res 49:D562 (2021).

---

## Adding a dependency

Rule 9 of `CLAUDE.md`: every new dependency needs a licence check recorded
here, before it is added. Record the source URL, the licence as read at that
URL, the date, and any consequence for how BOFFIN may use it.
