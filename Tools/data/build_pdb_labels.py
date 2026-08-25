#!/usr/bin/env python3
"""Build secondary-structure and disorder labels from the PDB itself.

    Tools/coreml/.venv/bin/python Tools/data/build_pdb_labels.py

Writes `Datasets/pdblabels/train.json`.

Why not NetSurfP's datasets
---------------------------
The secondary-structure and disorder heads are trained on CB513, TS115 and
CASP12 as distributed by DTU, whose download pages **state no terms at all**.
`Docs/ATTRIBUTIONS.md` has recorded that as unverified since Phase 3, and it
blocks release rather than development, which means it blocks release.

Those labels are themselves derived from the PDB, which is **CC0**, verified at
`rcsb.org/pages/policies`. So the labels can be derived here instead of
redistributed from there, which is the same move that unblocked the
transmembrane head and the residue numbering.

What each label is, and what it is not
--------------------------------------
**Disorder** is a residue present in SEQRES and absent from the coordinates. That
is the definition NetSurfP uses and it is not a euphemism: the residue was in the
crystal and could not be placed. Read from `_pdbx_poly_seq_scheme`, where the
marker is `pdb_mon_id` being absent. It is NOT `pdb_seq_num` being absent, which
is populated for every residue of the construct whether it was seen or not.

**Secondary structure** here is THREE state, from `_struct_conf` and
`_struct_sheet_range`, which are the assignments deposited with the entry. Eight
state needs DSSP run over the coordinates, which is a hydrogen-bond calculation
this script does not do. So this replaces the Q3 labels and not the Q8 ones, and
the difference is stated rather than absorbed.

Selection
---------
X-ray only, because "not observed" means something specific in a crystal and
means nothing in a predicted model or an NMR ensemble. Resolution 2.5 A or
better, one chain per UniProt accession, so the set is not forty lysozymes.
"""

from __future__ import annotations

import argparse
import gzip
import json
import random
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INDEX = ROOT / "Datasets/pdb/index_entries.json"
CACHE = ROOT / "Datasets/pdblabels/cache"
OUT = ROOT / "Datasets/pdblabels"

USER_AGENT = "boffin-label-builder (research use; marc@marcdeller.com)"

# Three-state, in the order the head emits.
HELIX, STRAND, COIL = 0, 1, 2


def fetch(pdb: str) -> str | None:
    """The gzipped TEXT mmCIF, not BinaryCIF.

    BinaryCIF is the right choice for the app, where parse speed matters and
    there is already a decoder. Here it would mean writing a second decoder, in
    a second language, for three categories, and keeping the two in step. The
    text file is larger over the wire and is read once.
    """
    cached = CACHE / f"{pdb.lower()}.cif.gz"
    if cached.exists():
        return gzip.decompress(cached.read_bytes()).decode("utf-8", "replace")
    url = f"https://files.rcsb.org/download/{pdb.upper()}.cif.gz"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            data = response.read()
    except (urllib.error.URLError, OSError):
        return None
    CACHE.mkdir(parents=True, exist_ok=True)
    cached.write_bytes(data)
    return gzip.decompress(data).decode("utf-8", "replace")


def loops(text: str, wanted: set[str]) -> dict[str, list[dict[str, str]]]:
    """Parse the named `loop_` categories out of an mmCIF file.

    Deliberately small. It handles the loop form, quoted values and the `.`/`?`
    placeholders, which is everything the three categories here use, and it
    refuses to guess at anything else: a category written in the single-row
    key-value form simply does not appear in the result rather than being half
    read.
    """
    result: dict[str, list[dict[str, str]]] = {}
    lines = text.split("\n")
    index = 0
    while index < len(lines):
        if lines[index].strip() != "loop_":
            index += 1
            continue
        index += 1
        columns: list[str] = []
        while index < len(lines) and lines[index].startswith("_"):
            columns.append(lines[index].strip())
            index += 1
        if not columns:
            continue
        category = columns[0].split(".")[0]
        names = [column.split(".", 1)[1] for column in columns]
        if category not in wanted:
            while index < len(lines) and not lines[index].startswith(("loop_", "#", "_")):
                index += 1
            continue

        rows: list[dict[str, str]] = []
        while index < len(lines):
            line = lines[index]
            if line.startswith("#") or line.strip() == "loop_" or line.startswith("_"):
                break
            index += 1
            if not line.strip():
                continue
            values = split_row(line)
            if len(values) != len(names):
                continue
            rows.append(dict(zip(names, values)))
        result[category] = rows
    return result


def split_row(line: str) -> list[str]:
    """Split an mmCIF row, respecting single and double quotes."""
    values: list[str] = []
    current = ""
    quote = ""
    for character in line.strip():
        if quote:
            if character == quote:
                quote = ""
                values.append(current)
                current = ""
            else:
                current += character
        elif character in "'\"":
            quote = character
        elif character.isspace():
            if current:
                values.append(current)
                current = ""
        else:
            current += character
    if current:
        values.append(current)
    return values


def labels_for(entry: dict, chain: str, decoded) -> dict | None:
    """Per-residue labels for one chain, or None when the entry cannot supply
    them."""
    scheme = decoded.get("_pdbx_poly_seq_scheme")
    if not scheme:
        return None

    def number(value: str) -> int | None:
        try:
            return int(value)
        except (TypeError, ValueError):
            return None

    residues = []
    for row in scheme:
        if row.get("pdb_strand_id") != chain:
            continue
        sequenceIndex = number(row.get("seq_id", ""))
        if sequenceIndex is None:
            continue
        residues.append(
            {
                "seq": sequenceIndex,
                "code": row.get("mon_id", ""),
                # See the module docstring: the marker is pdb_mon_id, not
                # pdb_seq_num.
                "observed": row.get("pdb_mon_id", "?") not in ("?", ".", ""),
                "author": number(row.get("pdb_seq_num", "")),
            }
        )
    if len(residues) < 30:
        return None
    residues.sort(key=lambda r: r["seq"])

    disorder = [0 if r["observed"] else 1 for r in residues]
    # A chain with nothing disordered teaches the head that disorder does not
    # exist; one with nothing ordered is not a structure. Both are dropped.
    fraction = sum(disorder) / len(disorder)
    if fraction == 0 or fraction > 0.6:
        return None

    byAuthor = {r["author"]: index for index, r in enumerate(residues) if r["observed"]}
    structure = [COIL] * len(residues)

    for category, label in (("_struct_conf", HELIX), ("_struct_sheet_range", STRAND)):
        for row in decoded.get(category, []):
            if row.get("beg_auth_asym_id") != chain:
                continue
            start = number(row.get("beg_auth_seq_id", ""))
            end = number(row.get("end_auth_seq_id", ""))
            kind = row.get("conf_type_id", "")
            if category == "_struct_conf" and not kind.upper().startswith("HELX"):
                continue
            if start is None or end is None or end < start:
                continue
            for author in range(start, end + 1):
                index = byAuthor.get(author)
                if index is not None:
                    structure[index] = label

    return {
        "pdb": entry["pdb"],
        "chain": chain,
        "accession": entry["accession"],
        "sequence": "".join(three_to_one(r["code"]) for r in residues),
        "disorder": disorder,
        "structure": structure,
    }


THREE_TO_ONE = {
    "ALA": "A", "ARG": "R", "ASN": "N", "ASP": "D", "CYS": "C", "GLN": "Q",
    "GLU": "E", "GLY": "G", "HIS": "H", "ILE": "I", "LEU": "L", "LYS": "K",
    "MET": "M", "PHE": "F", "PRO": "P", "SER": "S", "THR": "T", "TRP": "W",
    "TYR": "Y", "VAL": "V", "MSE": "M", "SEC": "U", "PYL": "O",
}


def three_to_one(code: str) -> str:
    return THREE_TO_ONE.get((code or "").upper(), "X")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--entries", type=int, default=6000)
    parser.add_argument("--max-resolution", type=float, default=2.5)
    parser.add_argument("--workers", type=int, default=8)
    args = parser.parse_args()

    index = json.loads(INDEX.read_text())
    candidates = [
        entry for entry in index
        if entry.get("method") == "x-ray diffraction"
        and (entry.get("resolution") or 99) <= args.max_resolution
        and 30 <= len(entry["sequence"]) <= 1022
    ]
    random.Random(0).shuffle(candidates)
    candidates = candidates[: args.entries]
    print(f"{len(candidates):,} candidate chains at {args.max_resolution} A or better")

    results = []
    failures = 0

    wanted = {"_pdbx_poly_seq_scheme", "_struct_conf", "_struct_sheet_range"}

    def work(entry):
        text = fetch(entry["pdb"])
        if text is None:
            return None
        try:
            return labels_for(entry, entry["chain"], loops(text, wanted))
        except Exception:
            return None

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for done, labelled in enumerate(pool.map(work, candidates), start=1):
            if labelled is None:
                failures += 1
            else:
                results.append(labelled)
            if done % 100 == 0:
                print(f"\r  {done:,}/{len(candidates):,}  kept {len(results):,}",
                      end="", flush=True)
    print()

    residues = sum(len(r["disorder"]) for r in results)
    disordered = sum(sum(r["disorder"]) for r in results)
    helix = sum(r["structure"].count(HELIX) for r in results)
    strand = sum(r["structure"].count(STRAND) for r in results)
    print(f"{len(results):,} chains, {residues:,} residues ({failures:,} dropped)")
    print(f"  disordered {disordered:,} ({disordered / max(residues,1):.1%})")
    print(f"  helix {helix / max(residues,1):.1%}, strand {strand / max(residues,1):.1%}, "
          f"coil {(residues - helix - strand) / max(residues,1):.1%}")

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "train.json").write_text(json.dumps(results) + "\n")
    print(f"wrote Datasets/pdblabels/train.json "
          f"({(OUT / 'train.json').stat().st_size / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
