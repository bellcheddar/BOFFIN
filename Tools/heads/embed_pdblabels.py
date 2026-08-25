#!/usr/bin/env python3
"""Embed the CC0 PDB label set.

    Tools/coreml/.venv/bin/python Tools/heads/embed_pdblabels.py

Writes `Datasets/embeddings/pdblabels.npz`: one row per residue with the hidden
state, a disorder label, a three-state secondary-structure label and the chain
boundaries.

The labels come from the PDB entries themselves rather than from NetSurfP's
distributions, whose terms are unstated. See `Tools/data/build_pdb_labels.py`.

Two label sets in one file
--------------------------
Disorder (`0` ordered, `1` disordered) and three-state secondary structure
(`0` helix, `1` strand, `2` coil). Both come from the same entry and the same
chain, so embedding once and training twice is not a shortcut: it is the same
residues with two annotations.

The split is by ENTRY, not by residue
--------------------------------------
Residues from one protein are not independent, so a residue-level split leaks
almost perfectly: the model sees most of a TM helix in training and is asked
about the rest of it at test. Chains are assigned whole.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "Datasets/pdblabels"
OUT = ROOT / "Datasets/embeddings"

DISORDER_NAMES = ["ordered", "disordered"]
STRUCTURE_NAMES = ["helix", "strand", "coil"]
MASKED = -1





def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--batch-residues", type=int, default=16384)
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()

    entries = json.loads((DATA / "train.json").read_text())

    if args.limit:
        entries = entries[: args.limit]
    total = sum(len(e["sequence"]) for e in entries)
    print(f"{len(entries):,} entries, {total / 1e6:.2f} M residues")

    import esm

    model, alphabet = esm.pretrained.esm2_t12_35M_UR50D()
    model.eval()
    converter = alphabet.get_batch_converter()
    layer = model.num_layers
    width = model.embed_dim

    order = sorted(range(len(entries)), key=lambda i: len(entries[i]["sequence"]))

    hidden = np.zeros((total, width), dtype=np.float16)
    disorder = np.full(total, MASKED, dtype=np.int64)
    structure = np.full(total, MASKED, dtype=np.int64)
    boundaries = np.zeros((len(entries), 2), dtype=np.int64)

    cursor = 0
    for index, entry in enumerate(entries):
        length = len(entry["sequence"])
        boundaries[index] = (cursor, cursor + length)
        disorder[cursor : cursor + length] = entry["disorder"]
        structure[cursor : cursor + length] = entry["structure"]
        cursor += length
    assert cursor == total

    done = 0

    def flush(batch):
        nonlocal done
        if not batch:
            return
        _, _, tokens = converter(
            [(f"e{i}", entries[i]["sequence"]) for i in batch])
        with torch.no_grad():
            out = model(tokens, repr_layers=[layer], return_contacts=False)
        states = out["representations"][layer].numpy()
        for position, index in enumerate(batch):
            start, end = boundaries[index]
            hidden[start:end] = states[position, 1 : 1 + (end - start), :].astype(np.float16)
            done += 1
        print(f"\r  {done:,}/{len(entries):,}", end="", flush=True)

    batch: list[int] = []
    for index in order:
        batch.append(index)
        widest = max(len(entries[i]["sequence"]) for i in batch)
        if widest * len(batch) >= args.batch_residues:
            flush(batch)
            batch = []
    flush(batch)
    print()

    for names, values in ((DISORDER_NAMES, disorder), (STRUCTURE_NAMES, structure)):
        counts = np.bincount(values[values >= 0], minlength=len(names))
        print("label balance:")
        for name, count in zip(names, counts):
            print(f"  {name:<12} {count:>10,}  {count / max(counts.sum(),1):.3%}")

    OUT.mkdir(parents=True, exist_ok=True)
    destination = OUT / "pdblabels.npz"
    np.savez(
        destination, hidden=hidden, disorder=disorder, structure=structure,
        boundaries=boundaries,
        chains=np.array([f"{e['pdb']}_{e['chain']}" for e in entries]),
        accessions=np.array([e["accession"] for e in entries]))
    print(f"wrote {destination.relative_to(ROOT)} "
          f"({destination.stat().st_size / 1e6:.0f} MB)")
    # Uncompressed on purpose: np.load on a compressed .npz is lazy and every
    # slice re-decompresses the whole array, which cost roughly 20 hours an
    # epoch the first time it happened here.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
