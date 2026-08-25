#!/usr/bin/env python3
"""Embed the PDB index with the ESM-2 backbone.

    Tools/coreml/.venv/bin/python Tools/heads/embed_pdb_index.py

Reads `Datasets/pdb/index_entries.json` and writes `Datasets/pdb/vectors.npy`,
one mean-pooled vector per accession, in the same order as the entries file.

The tiling here REPRODUCES `SequenceTiler` in BoffinML deliberately
--------------------------------------------------------------------
A pooled embedding of a tiled sequence is not the same number as a pooled
embedding of the same sequence in one pass: each residue sees only its tile's
context. So if the index embedded short proteins in one pass and the app tiled a
long query, the cosine between them would be comparing two different statistics
and the mismatch would show up as a slightly-wrong ranking, which is the kind of
error nobody notices.

Both sides therefore use: capacity 1022 residues per tile, 128 residues of
overlap, overlapping positions AVERAGED, then a mean over all residues. If
`ShapeBucket.tileOverlap` or the bucket list changes in Swift, this file has to
change with it and the index has to be rebuilt. There is a test in BoffinData
that pins the constants on the Swift side so the divergence is at least loud.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "Datasets/pdb"

# Must match ShapeBucket.tokens1024 minus the two special tokens, and
# ShapeBucket.tileOverlap.
TILE_CAPACITY = 1022
TILE_OVERLAP = 128


def tile_ranges(length: int) -> list[tuple[int, int]]:
    """Reproduce `SequenceTiler.plan`."""
    if length <= TILE_CAPACITY:
        return [(0, length)]
    stride = TILE_CAPACITY - TILE_OVERLAP
    ranges, start = [], 0
    while start < length:
        end = min(start + TILE_CAPACITY, length)
        ranges.append((start, end))
        if end == length:
            break
        start += stride
    return ranges


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=0, help="embed only the first N, for timing")
    parser.add_argument("--tokens-per-batch", type=int, default=16384)
    args = parser.parse_args()

    entries = json.loads((DATA / "index_entries.json").read_text())
    if args.limit:
        entries = entries[: args.limit]
    print(f"{len(entries):,} entries, {sum(len(e['sequence']) for e in entries) / 1e6:.1f} M residues")

    import esm

    model, alphabet = esm.pretrained.esm2_t12_35M_UR50D()
    model.eval()
    converter = alphabet.get_batch_converter()
    layer = model.num_layers

    # Two paths, because only one of them has an overlap to get right.
    #
    # A sequence that fits in one tile has no overlap, so batching those by
    # length and pooling each independently is exact. A sequence that needs
    # tiling has residues represented twice, and SequenceTiler AVERAGES the two
    # representations rather than counting both. Summing over tiles would
    # instead double-weight the overlap: for a 2,000-residue protein that is 128
    # of 2,000 residues carrying twice their share, which is small, plausible,
    # and exactly the sort of quiet discrepancy that makes an index rank
    # slightly wrongly for the rest of its life.
    #
    # So tiled sequences are handled one at a time, with their tiles in a single
    # batch and the stitching done exactly. There are only a few thousand of
    # them, so the cost of not batching across sequences is small.
    short = [(row, e["sequence"]) for row, e in enumerate(entries)
             if len(e["sequence"]) <= TILE_CAPACITY]
    long = [(row, e["sequence"]) for row, e in enumerate(entries)
            if len(e["sequence"]) > TILE_CAPACITY]
    totalTiles = len(short) + sum(len(tile_ranges(len(s))) for _, s in long)
    print(f"{len(short):,} single-tile and {len(long):,} tiled sequences, "
          f"{totalTiles:,} tiles")

    width = model.embed_dim
    vectors = np.zeros((len(entries), width), dtype=np.float32)
    filled = np.zeros(len(entries), dtype=bool)

    work = sorted(short, key=lambda w: len(w[1]))

    started = time.time()
    done = 0

    def run(pieces: list[str]) -> np.ndarray:
        _, _, tokens = converter([(f"t{i}", p) for i, p in enumerate(pieces)])
        with torch.no_grad():
            out = model(tokens, repr_layers=[layer], return_contacts=False)
        return out["representations"][layer].numpy()

    def progress():
        rate = done / max(time.time() - started, 1e-9)
        left = (totalTiles - done) / max(rate, 1e-9)
        print(f"\r  {done:,}/{totalTiles:,} tiles  {rate:.1f}/s  "
              f"{left / 60:.0f} min left  ", end="", flush=True)

    def flush(batch):
        nonlocal done
        if not batch:
            return
        hidden = run([piece for _, piece in batch])
        for i, (row, piece) in enumerate(batch):
            vectors[row] = hidden[i, 1 : 1 + len(piece), :].mean(axis=0)
            filled[row] = True
            done += 1
        if done % 2000 < len(batch):
            progress()

    batch = []
    for item in work:
        batch.append(item)
        widest = max(len(w[1]) for w in batch)
        if widest * len(batch) >= args.tokens_per_batch:
            flush(batch)
            batch = []
    flush(batch)

    for row, sequence in long:
        ranges = tile_ranges(len(sequence))
        hidden = run([sequence[a:b] for a, b in ranges])
        sums = np.zeros((len(sequence), width), dtype=np.float64)
        counts = np.zeros(len(sequence), dtype=np.float64)
        for i, (a, b) in enumerate(ranges):
            sums[a:b] += hidden[i, 1 : 1 + (b - a), :]
            counts[a:b] += 1
        assert counts.all(), "a residue was covered by no tile"
        vectors[row] = (sums / counts[:, None]).mean(axis=0)
        filled[row] = True
        done += len(ranges)
        if done % 200 < len(ranges):
            progress()
    print()

    assert filled.all(), f"{(~filled).sum()} entries received no vector"
    np.save(DATA / "vectors.npy", vectors)
    elapsed = time.time() - started
    print(f"wrote Datasets/pdb/vectors.npy {vectors.shape} in {elapsed / 60:.1f} min")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
