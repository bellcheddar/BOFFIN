# PDB homolog index and SIFTS tables

Built by `Tools/data/build_pdb_index.py` from bulk files this directory holds,
embedded by `Tools/heads/embed_pdb_index.py`, packed by
`Tools/data/pack_index_assets.py`, and checked by `Tools/data/validate_index.py`.

Last built: **2026-08-25**

## Sources

| File | Source | Terms |
|---|---|---|
| `pdb_seqres.txt.gz` | `files.rcsb.org/pub/pdb/derived_data/` | **CC0 1.0**, verified at `rcsb.org/pages/policies` |
| `entries.idx` | `files.rcsb.org/pub/pdb/derived_data/index/` | **CC0 1.0**, same statement |
| `pdb_chain_uniprot.tsv.gz` | SIFTS, `ftp.ebi.ac.uk/pub/databases/msd/sifts/` | **no licence stated**, see `Docs/ATTRIBUTIONS.md` |
| `uniprot_segments_observed.tsv.gz` | SIFTS, same | **no licence stated** |

## What the index is, and what it is not

One entry per **UniProt accession**, not per RCSB sequence cluster and not per
PDB chain. The reasoning is in the `build_pdb_index.py` docstring; the short
version is that homolog search wants distinct proteins, and the Boundary tab
wants every construct ever deposited for one protein, and both of those are
per-accession questions.

Known limitations, stated rather than discovered later:

- **The unit is the UniProt entry, not the domain.** Polyubiquitin-C (P0CG48) is
  a 685-residue polyprotein of nine tandem ubiquitin repeats, so its index entry
  is a vector for the polyprotein. Mean pooling makes that close to a single
  repeat's vector, but the *title and length shown* are the polyprotein's.
- **1,854 accessions are excluded** for being under 30 or over 2,500 residues.
  The lower bound removes peptides whose pooled embedding is dominated by their
  termini; the upper is a compute budget.
- **Chains with no UniProt mapping are absent entirely.** That includes designed
  proteins, most peptides and anything not yet cross-referenced.

## Reproducing

```bash
cd Datasets/pdb
curl -O https://files.rcsb.org/pub/pdb/derived_data/pdb_seqres.txt.gz
curl -O https://files.rcsb.org/pub/pdb/derived_data/index/entries.idx
curl -O https://ftp.ebi.ac.uk/pub/databases/msd/sifts/flatfiles/tsv/pdb_chain_uniprot.tsv.gz
curl -O https://ftp.ebi.ac.uk/pub/databases/msd/sifts/flatfiles/tsv/uniprot_segments_observed.tsv.gz
```

**Check the byte counts against `Content-Length`.** `entries.idx` is 57 MB and a
truncated download of it does not fail loudly: it silently removes the method and
resolution metadata for most of the PDB, which turns the choice of representative
chain into "alphabetically first PDB ID" without erroring. That happened on the
first build here (19,151 of 258,224 entries). `build_pdb_index.py` now refuses to
run on a short file.

Then:

```bash
Tools/coreml/.venv/bin/python Tools/data/build_pdb_index.py
Tools/coreml/.venv/bin/python Tools/heads/embed_pdb_index.py
Tools/coreml/.venv/bin/python Tools/data/validate_index.py
Tools/coreml/.venv/bin/python Tools/data/pack_index_assets.py
```

The row order of `index_entries.json` is what `vectors.npy` is aligned to. Never
rebuild the index without rebuilding the vectors: use `--segments-only` to touch
the segment table alone.
