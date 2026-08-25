#!/usr/bin/env python3
"""Embed the Swiss-Prot topology set and build per-residue labels.

    Tools/coreml/.venv/bin/python Tools/heads/embed_topology.py

Writes `Datasets/embeddings/topology.npz`: one row per residue, with the hidden
state, the label, a mask and the chain boundaries, in the same layout the
secondary-structure and disorder heads already use.

Three classes, and a masked fourth
----------------------------------
`0` outside the membrane, `1` transmembrane, `2` signal peptide.

INTRAMEMBRANE regions are given `-1` and excluded from the loss rather than
folded into either class. They are genuinely neither: a re-entrant loop dips
into the bilayer without crossing it, so calling it transmembrane teaches the
head that a span can end where the chain turns round, and calling it outside
teaches the opposite. There are few enough of them that either choice would be
invisible in the aggregate and wrong in exactly the cases a construct designer
cares about.

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
DATA = ROOT / "Datasets/topology"
OUT = ROOT / "Datasets/embeddings"

LABEL_NAMES = ["outside", "transmembrane", "signal"]
MASKED = -1


def labels_for(entry: dict) -> np.ndarray:
    """Per-residue labels, zero-based, from one-based inclusive feature spans."""
    length = len(entry["sequence"])
    labels = np.zeros(length, dtype=np.int64)
    for start, end, _ in entry.get("transmem", []):
        labels[start - 1 : end] = 1
    for start, end, _ in entry.get("signal", []):
        labels[start - 1 : end] = 2
    # Applied last so it wins: an intramembrane region overlapping anything else
    # is still a region this head must not be taught to call either way.
    for start, end, _ in entry.get("intramem", []):
        labels[start - 1 : end] = MASKED
    return labels


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--batch-residues", type=int, default=16384)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--membrane", type=int, default=6000)
    parser.add_argument("--secreted", type=int, default=3000)
    parser.add_argument("--soluble", type=int, default=4000)
    args = parser.parse_args()

    entries = json.loads((DATA / "train.json").read_text())

    # Subsample per group rather than taking the first N.
    #
    # The fetched set is 22,366 entries and 10 M residues, which is 9.6 GB of
    # fp16 hidden states on a disk with 99 GB free, and most of that would be
    # spent on soluble negatives the head learns nothing new from after the
    # first few thousand. Taking the first N instead would take them in fetch
    # order, which is membrane-first: a training set of nothing but positives.
    caps = {"membrane": args.membrane, "secreted": args.secreted, "soluble": args.soluble}
    rng = np.random.default_rng(0)
    chosen: list[dict] = []
    for group, cap in caps.items():
        members = [e for e in entries if e.get("group") == group]
        if len(members) > cap:
            members = [members[i] for i in rng.choice(len(members), cap, replace=False)]
        chosen.extend(members)
        print(f"  {group:<10} {len(members):,}")
    entries = chosen
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
    labels = np.full(total, MASKED, dtype=np.int64)
    groups = np.zeros(total, dtype=np.int32)
    boundaries = np.zeros((len(entries), 2), dtype=np.int64)

    cursor = 0
    for index, entry in enumerate(entries):
        length = len(entry["sequence"])
        boundaries[index] = (cursor, cursor + length)
        labels[cursor : cursor + length] = labels_for(entry)
        groups[cursor : cursor + length] = index
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

    counts = np.bincount(labels[labels >= 0], minlength=len(LABEL_NAMES))
    print("label balance:")
    for name, count in zip(LABEL_NAMES, counts):
        print(f"  {name:<15} {count:>10,}  {count / counts.sum():.3%}")
    print(f"  masked (intramembrane) {(labels == MASKED).sum():,}")

    OUT.mkdir(parents=True, exist_ok=True)
    destination = OUT / "topology.npz"
    np.savez(
        destination, hidden=hidden, label=labels, group=groups,
        boundaries=boundaries,
        accessions=np.array([e["accession"] for e in entries]))
    print(f"wrote {destination.relative_to(ROOT)} "
          f"({destination.stat().st_size / 1e6:.0f} MB)")
    # Uncompressed on purpose: np.load on a compressed .npz is lazy and every
    # slice re-decompresses the whole array, which cost roughly 20 hours an
    # epoch the first time it happened here.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
