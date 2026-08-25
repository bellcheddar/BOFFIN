#!/usr/bin/env python3
"""Pool-embed the Pfam training sequences with the ESM-2 backbone.

    Tools/coreml/.venv/bin/python Tools/heads/embed_pfam.py

One vector per sequence: the mean over real residues, excluding <cls>, <eos>
and padding. Pooling over those would drag every vector towards whatever the
model does with nothing, which compresses exactly the differences the classifier
needs.
"""
from __future__ import annotations
import json
from pathlib import Path
import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "Datasets/pfam"

def main() -> int:
    entries = json.loads((DATA / "train.json").read_text())
    families = sorted(entries)
    rows = [(f, e["accession"], e["sequence"]) for f in families for e in entries[f]]
    print(f"{len(rows):,} sequences across {len(families)} families")

    import esm
    model, alphabet = esm.pretrained.esm2_t12_35M_UR50D()
    model.eval()
    converter = alphabet.get_batch_converter()
    layer = model.num_layers

    # Length-sorted batching: padding a 60-residue protein out to 1000 wastes
    # almost the whole batch.
    rows.sort(key=lambda r: len(r[2]))

    vectors, labels = [], []
    batch, done = [], 0
    def flush(batch):
        nonlocal done
        if not batch: return
        _, _, tokens = converter([(a, s[:1022]) for _, a, s in batch])
        with torch.no_grad():
            out = model(tokens, repr_layers=[layer], return_contacts=False)
        hidden = out["representations"][layer].numpy()
        for i, (family, _, sequence) in enumerate(batch):
            n = min(len(sequence), 1022)
            vectors.append(hidden[i, 1:1+n, :].mean(axis=0).astype(np.float16))
            labels.append(families.index(family))
            done += 1
        print(f"\r  {done}/{len(rows)}", end="", flush=True)

    for row in rows:
        batch.append(row)
        widest = max(len(r[2][:1022]) for r in batch)
        if widest * len(batch) >= 8192:
            flush(batch); batch = []
    flush(batch)
    print()

    out = DATA / "embeddings.npz"
    np.savez_compressed(out, embeddings=np.stack(vectors),
                        label=np.array(labels, dtype=np.int32),
                        families=np.array(families))
    print(f"wrote {out.relative_to(ROOT)} ({out.stat().st_size/1e6:.1f} MB)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
