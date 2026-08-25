#!/usr/bin/env python3
"""Build the homolog search index and the SIFTS residue-mapping table.

    Tools/coreml/.venv/bin/python Tools/data/build_pdb_index.py

Reads the bulk files downloaded into `Datasets/pdb/` and writes
`Datasets/pdb/index_entries.json` (one representative PDB chain per UniProt
accession) and `Datasets/pdb/segments.json` (SIFTS observed segments for those
accessions).

Why one entry per UniProt accession
-----------------------------------
The obvious unit is the RCSB sequence cluster, and it is the wrong one here.
Clustering at 30% identity puts lysozyme mutants, apo and holo forms and every
crystal form of the same protein into one bucket, which is right for a
redundancy filter and wrong for the two things this index feeds:

* Homolog search wants to answer "what proteins resemble this one", and two
  entries that are the same protein are one answer, not two.
* The Boundary tab wants crystallisation precedent: every construct anyone
  successfully crystallised for that protein. That is a per-accession list, and
  collapsing crystal forms would delete exactly the evidence it needs.

So the index carries one vector per accession, and the segment table carries
every observed construct for it. Chains with no UniProt mapping are deduplicated
by exact sequence instead, which is the only identity available for them.

How the representative is chosen, and why coverage comes before resolution
--------------------------------------------------------------------------
Ranking on resolution alone is wrong, and wrong in a way that looks reasonable
until you check a specific protein. The best-resolution chain for the beta-2
adrenergic receptor (P07550) is 1GQ4_A: a NINETY-RESIDUE C-terminal peptide
bound to NHERF, at 1.9 A. The actual receptor, 2RH1, is 2.4 A and loses. A
fragment almost always out-resolves the protein it came from, so
best-resolution-wins systematically selects fragments.

That is not a cosmetic problem. The index stores ONE EMBEDDING PER ACCESSION,
computed from the representative's sequence, so with 1GQ4_A as representative
the index would hold a vector for a disordered tail and a homolog search for a
GPCR would never surface ADRB2 at all.

So chains are ranked by UniProt COVERAGE first, taken from the SIFTS mapping
segments, and only among those within 90% of the best coverage is method and
then resolution allowed to decide. That reads as "the best structure of the
whole protein", not "the best structure of any piece of it".
"""

from __future__ import annotations

import argparse
import gzip
import json
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "Datasets/pdb"

# The backbone's hard ceiling is 1024 tokens including <cls> and <eos>, and the
# first version of this script stopped there. That was wrong, and wrong in a way
# that removes exactly the proteins a structural biologist searches for: EGFR is
# 1,210 residues, so it was absent from the index entirely, along with 3,533
# other entries.
#
# BOFFIN already tiles a long QUERY with 128 residues of overlap and mean-pools
# the stitched result, so refusing to tile the INDEX would compare a tiled
# statistic against an untiled one. Tiling both, identically, is the consistent
# choice, and `embed_pdb_index.py` reproduces `SequenceTiler` exactly.
#
# The remaining cap is a compute budget rather than a model limit: the tail
# above 2,500 residues is a few hundred entries costing several tiles each.
MAX_LENGTH = 2500
MIN_LENGTH = 30

# Methods ranked by how well "observed residue range" is defined for them.
# NMR reports every residue of the construct whether ordered or not, so its
# observed range says nothing about crystallisability; it is kept but ranked
# last so it is never preferred as a representative when diffraction exists.
METHOD_RANK = {
    "x-ray diffraction": 0,
    "electron microscopy": 1,
    "electron crystallography": 1,
    "neutron diffraction": 1,
    "fiber diffraction": 2,
    "powder diffraction": 2,
    "solution scattering": 3,
    "solution nmr": 4,
    "solid-state nmr": 4,
}


def parse_entries(path: Path) -> dict[str, dict]:
    """`entries.idx`: IDCODE, HEADER, DATE, COMPOUND, SOURCE, AUTHORS, RESOLUTION, EXPERIMENT."""
    entries: dict[str, dict] = {}
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 8 or len(parts[0]) != 4:
                continue
            code = parts[0].strip().upper()
            if not code.isalnum():
                continue
            try:
                resolution = float(parts[6])
            except ValueError:
                resolution = None
            # A resolution of 0 means "not applicable" (NMR), not a perfect map.
            if resolution is not None and resolution <= 0:
                resolution = None
            entries[code] = {
                "resolution": resolution,
                "method": parts[7].strip().lower(),
                "header": parts[1].strip(),
                "compound": parts[3].strip(),
                "source": parts[4].strip(),
            }
    return entries


def parse_seqres(path: Path) -> dict[tuple[str, str], str]:
    """`pdb_seqres.txt.gz`: `>101m_A mol:protein length:154  MYOGLOBIN`."""
    sequences: dict[tuple[str, str], str] = {}
    key = None
    with gzip.open(path, "rt", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if line.startswith(">"):
                header = line[1:].split()
                key = None
                if len(header) >= 2 and header[1] == "mol:protein":
                    code, _, chain = header[0].partition("_")
                    key = (code.upper(), chain)
                continue
            if key is not None:
                sequences[key] = line.strip().upper()
                key = None
    return sequences


def parse_sifts(path: Path) -> list[tuple]:
    """SIFTS TSV: PDB, CHAIN, SP_PRIMARY, RES_BEG, RES_END, PDB_BEG, PDB_END, SP_BEG, SP_END."""
    rows = []
    with gzip.open(path, "rt", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if line.startswith("#") or line.startswith("PDB"):
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 9:
                continue
            rows.append(tuple(p.strip() for p in parts[:9]))
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--max-entries", type=int, default=0,
                        help="cap the index; 0 means no cap")
    parser.add_argument("--segments-only", action="store_true",
                        help="reuse the existing index_entries.json and rebuild "
                             "only segments.json; the index row order is what the "
                             "embedding vectors are aligned to, so it must not "
                             "change once they have been computed")
    args = parser.parse_args()

    if args.segments_only:
        index = json.loads((DATA / "index_entries.json").read_text())
        print(f"reusing index of {len(index):,} accessions")
        return write_segments(index)

    print("reading entries.idx")
    entries = parse_entries(DATA / "entries.idx")
    print(f"  {len(entries):,} PDB entries")
    # A truncated download is the failure mode this guards. `curl --max-time`
    # leaves the partial file on disk and a `|| echo` in the fetch loop swallows
    # its non-zero exit, so the file looks fetched. It happened here: 19,151 of
    # 258,224 entries, which does not raise an error because every missing
    # entry simply falls to the default rank, silently turning the choice of
    # representative into "alphabetically first PDB ID". Coverage is asserted,
    # not assumed.
    if len(entries) < 200_000:
        print(f"\nentries.idx holds only {len(entries):,} entries, which is far short of "
              f"the PDB. It is almost certainly a truncated download; re-fetch it.")
        return 1

    print("reading pdb_seqres.txt.gz")
    sequences = parse_seqres(DATA / "pdb_seqres.txt.gz")
    print(f"  {len(sequences):,} protein chains")

    print("reading pdb_chain_uniprot.tsv.gz")
    mapping = parse_sifts(DATA / "pdb_chain_uniprot.tsv.gz")
    print(f"  {len(mapping):,} chain-to-UniProt segments")

    # Coverage is the union of UniProt ranges a chain maps onto, not their sum:
    # a chain can map to the same accession in several segments and they can
    # overlap, so summing double-counts.
    ranges: dict[str, dict[tuple[str, str], list[tuple[int, int]]]] = defaultdict(
        lambda: defaultdict(list))
    for pdb, chain, accession, _, _, _, _, spBeg, spEnd in mapping:
        try:
            start, end = int(spBeg), int(spEnd)
        except ValueError:
            continue
        if end >= start:
            ranges[accession][(pdb.upper(), chain)].append((start, end))
    print(f"  {len(ranges):,} distinct UniProt accessions")

    def covered(spans: list[tuple[int, int]]) -> int:
        total = 0
        cursor = -1
        for start, end in sorted(spans):
            start = max(start, cursor + 1)
            if end >= start:
                total += end - start + 1
                cursor = end
        return total

    def rank(pdb: str, chain: str):
        meta = entries.get(pdb, {})
        method = meta.get("method", "")
        resolution = meta.get("resolution")
        sequence = sequences.get((pdb, chain), "")
        return (
            METHOD_RANK.get(method, 5),
            resolution if resolution is not None else 99.0,
            -len(sequence),
            pdb,
            chain,
        )

    index = []
    skippedNoSequence = 0
    skippedLength = 0
    for accession, chains in ranges.items():
        usable = {pc: covered(spans) for pc, spans in chains.items() if pc in sequences}
        if not usable:
            skippedNoSequence += 1
            continue
        # Coverage first, resolution only as a tie-break among chains that cover
        # comparably much. See the module docstring for why this order matters.
        best = max(usable.values())
        contenders = [pc for pc, c in usable.items() if c >= best * 0.9]
        pdb, chain = min(contenders, key=lambda pc: rank(*pc))
        sequence = sequences[(pdb, chain)]
        if not (MIN_LENGTH <= len(sequence) <= MAX_LENGTH):
            skippedLength += 1
            continue
        meta = entries.get(pdb, {})
        index.append({
            "accession": accession,
            "pdb": pdb,
            "chain": chain,
            "sequence": sequence,
            "resolution": meta.get("resolution"),
            "method": meta.get("method", ""),
            "title": meta.get("compound") or meta.get("header", ""),
            "source": meta.get("source", ""),
            "coverage": usable[(pdb, chain)],
            "structures": len({p for (p, _) in chains}),
        })

    unranked = sum(1 for e in index if e["pdb"] not in entries)
    if unranked:
        print(f"\n{unranked:,} representatives have no entries.idx metadata, so their "
              f"method and resolution ranking was a default rather than a measurement.")
        if unranked > len(index) * 0.02:
            print("That is more than 2% of the index; refusing to write it.")
            return 1

    index.sort(key=lambda e: e["accession"])
    if args.max_entries:
        index = index[: args.max_entries]

    print(f"\nindex: {len(index):,} accessions")
    print(f"  skipped {skippedNoSequence:,} with no protein SEQRES "
          f"(nucleic-acid or obsolete chains)")
    print(f"  skipped {skippedLength:,} outside {MIN_LENGTH} to {MAX_LENGTH} residues")

    (DATA / "index_entries.json").write_text(json.dumps(index) + "\n")
    print(f"wrote Datasets/pdb/index_entries.json "
          f"({(DATA / 'index_entries.json').stat().st_size / 1e6:.1f} MB)")
    return write_segments(index)


def write_segments(index: list[dict]) -> int:
    """SIFTS observed segments, in all three coordinate systems at once.

    A segment anchors the same run of residues in SEQRES numbering (RES_BEG),
    UniProt numbering (SP_BEG) and PDB author numbering (PDB_BEG). Keeping all
    three is what lets BOFFIN go from a pasted sequence to an author residue
    number in one hop: align the query to the entry's SEQRES, then read the
    author number off the segment. Keeping only two would force a second hop
    through UniProt, and every hop is somewhere for an off-by-one to hide.
    """
    wanted = {e["accession"] for e in index}
    print("\nreading uniprot_segments_observed.tsv.gz")
    observed = parse_sifts(DATA / "uniprot_segments_observed.tsv.gz")
    print(f"  {len(observed):,} observed segments")

    # Insertion codes make a segment non-arithmetic: PDB author numbering inside
    # it is no longer start + offset. SIFTS does not flag these, so they are
    # counted here and marked, and the Swift side refuses to interpolate through
    # one rather than returning a number that is plausible and wrong.
    segments: dict[str, list] = defaultdict(list)
    insertionCoded = 0
    inconsistent = 0
    for pdb, chain, accession, resBeg, resEnd, pdbBeg, pdbEnd, spBeg, spEnd in observed:
        if accession not in wanted:
            continue
        try:
            spStart, spStop = int(spBeg), int(spEnd)
            seqresStart, seqresStop = int(resBeg), int(resEnd)
        except ValueError:
            continue
        arithmetic = True
        try:
            authorStart, authorStop = int(pdbBeg), int(pdbEnd)
        except ValueError:
            # An insertion code (`27A`) means author numbering inside the
            # segment is no longer start + offset, so the segment cannot be
            # interpolated through. It is kept, because it still says which
            # residues were observed, and marked so the mapper refuses to
            # produce a number for it.
            insertionCoded += 1
            arithmetic = False
            authorStart = authorStop = 0

        # All three coordinate systems must advance by the same amount across a
        # segment. Where they do not, SIFTS is describing something the affine
        # model does not capture, and asserting it here is cheaper than
        # discovering it as a residue number that is off by three.
        spans = {spStop - spStart, seqresStop - seqresStart}
        if arithmetic:
            spans.add(authorStop - authorStart)
        if len(spans) != 1:
            inconsistent += 1
            arithmetic = False

        segments[accession].append({
            "pdb": pdb.upper(), "chain": chain,
            "seqres_start": seqresStart, "seqres_end": seqresStop,
            "uniprot_start": spStart, "uniprot_end": spStop,
            "author_start": authorStart,
            "arithmetic": arithmetic,
        })

    total = sum(len(v) for v in segments.values())
    unusable = sum(1 for v in segments.values() for s in v if not s["arithmetic"])
    print(f"  kept {total:,} segments for indexed accessions")
    print(f"  {insertionCoded:,} carry insertion codes in the author numbering")
    print(f"  {inconsistent:,} have coordinate systems that advance by different "
          f"amounts across the segment")
    print(f"  {unusable:,} are therefore NOT arithmetic "
          f"({unusable / max(total, 1):.2%}); the mapper refuses those rather "
          f"than interpolating")

    DATA.mkdir(parents=True, exist_ok=True)
    (DATA / "segments.json").write_text(json.dumps(segments) + "\n")
    size = (DATA / "segments.json").stat().st_size / 1e6
    print(f"wrote Datasets/pdb/segments.json ({size:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
