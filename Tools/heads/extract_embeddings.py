#!/usr/bin/env python3
"""Embed the NetSurfP datasets with the ESM-2 backbone, once.

    Tools/coreml/.venv/bin/python Tools/heads/extract_embeddings.py --split train

Writes `Datasets/embeddings/<split>.npz` holding, per residue:
    embeddings  float16 (N, 480)   the frozen backbone representation
    q8          uint8   (N,)       secondary structure class, order GHIBESTC
    ordered     uint8   (N,)       1 = ordered, 0 = disordered
    rsa         float32 (N,)       relative solvent accessibility, isolated
    chain       int32   (N,)       which protein each residue came from

Embedding once and training many heads against the cached result is the whole
point of invariant 1: the backbone pass is the expensive step, so it is paid
once rather than per head and per epoch.

Verified before use, not assumed
--------------------------------
The NetSurfP `.npz` carries 68 columns with no schema in the file. The layout
below was derived empirically and then checked against ground truth: chain
154l-A reconstructs to **100% identity** with the RCSB sequence for 154L over
all 185 residues, which pins both the column offsets and the alphabetical
residue ordering. Getting either wrong would train every head on labels
belonging to different residues, and would not error.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[2]
DATASETS = ROOT / "Datasets"
OUT = DATASETS / "embeddings"

# Verified layout of the 68 feature columns.
AA_ONE_HOT = slice(0, 20)
SEQUENCE_MASK = 50
ORDERED_MASK = 51  # 1 = ordered, 0 = disordered
EVALUATION_MASK = 52
RSA_ISOLATED = 55
Q8_ONE_HOT = slice(57, 65)  # order: G H I B E S T C

# Verified against RCSB entry 154L.
ALPHABET = "ACDEFGHIKLMNPQRSTVWY"

# Q8 to Q3, the standard collapse. G/H/I are helix, B/E are strand, S/T/C coil.
Q8_NAMES = "GHIBESTC"
Q8_TO_Q3 = {"G": "H", "H": "H", "I": "H", "B": "E", "E": "E", "S": "C", "T": "C", "C": "C"}

SPLITS = {
    "train": "netsurfp_train.npz",
    "cb513": "netsurfp_cb513.npz",
    "ts115": "netsurfp_ts115.npz",
    "casp12": "netsurfp_casp12.npz",
}


def decode(path: Path):
    """Yield (identifier, sequence, labels) for every chain in a NetSurfP file."""
    bundle = np.load(path, allow_pickle=True)
    data, identifiers = bundle["data"], bundle["pdbids"]

    for index in range(len(data)):
        protein = data[index]
        mask = protein[:, SEQUENCE_MASK] > 0.5
        if not mask.any():
            continue
        residues = protein[mask]

        one_hot = residues[:, AA_ONE_HOT]
        assigned = one_hot.sum(axis=1) > 0.5
        letters = np.array(list(ALPHABET))[one_hot.argmax(axis=1)]
        # About 0.1% of residues carry a label but no amino acid. They become X
        # rather than being dropped: dropping them would shift every downstream
        # residue against its label.
        letters[~assigned] = "X"

        yield (
            str(identifiers[index]),
            "".join(letters),
            {
                "q8": residues[:, Q8_ONE_HOT].argmax(axis=1).astype(np.uint8),
                "ordered": (residues[:, ORDERED_MASK] > 0.5).astype(np.uint8),
                "rsa": residues[:, RSA_ISOLATED].astype(np.float32),
                "evaluation": (residues[:, EVALUATION_MASK] > 0.5).astype(np.uint8),
            },
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--split", required=True, choices=sorted(SPLITS))
    parser.add_argument("--model", default="esm2_t12_35M_UR50D")
    parser.add_argument("--batch-residues", type=int, default=8192,
                        help="approximate residues per forward pass")
    parser.add_argument("--limit", type=int, default=0, help="debug: first N chains only")
    parser.add_argument("--device", default="cpu", choices=["cpu", "mps"])
    args = parser.parse_args()

    source = DATASETS / SPLITS[args.split]
    if not source.exists():
        print(f"missing {source}: run Tools/data/fetch_head_datasets.py first")
        return 1

    import esm

    print(f"loading {args.model} ...")
    model, alphabet = getattr(esm.pretrained, args.model)()
    model.eval()
    device = torch.device(args.device)
    model = model.to(device)
    converter = alphabet.get_batch_converter()
    layer = model.num_layers

    chains = list(decode(source))
    if args.limit:
        chains = chains[: args.limit]
    total_residues = sum(len(sequence) for _, sequence, _ in chains)
    print(f"{args.split}: {len(chains)} chains, {total_residues:,} residues")

    # Sort by length before batching. Padding a 20-residue chain out to 874
    # wastes almost the whole batch, and on MPS every distinct padded width also
    # triggers a fresh kernel compilation.
    chains.sort(key=lambda c: len(c[1]))

    embeddings: list[np.ndarray] = []
    labels = {key: [] for key in ("q8", "ordered", "rsa", "evaluation")}
    chain_index: list[np.ndarray] = []

    batch: list[tuple[str, str, dict]] = []
    processed = 0

    def flush(batch):
        nonlocal processed
        if not batch:
            return
        longest = max(len(sequence) for _, sequence, _ in batch)
        _, _, tokens = converter([(name, sequence) for name, sequence, _ in batch])
        tokens = tokens.to(device)
        with torch.no_grad():
            out = model(tokens, repr_layers=[layer], return_contacts=False)
        hidden = out["representations"][layer].cpu().numpy()

        for row, (name, sequence, label) in enumerate(batch):
            # Slice past <cls>, and stop at the true length: everything after is
            # <eos> and padding, which describe nothing.
            vectors = hidden[row, 1 : 1 + len(sequence), :]
            assert vectors.shape[0] == len(sequence), (
                f"{name}: {vectors.shape[0]} vectors for {len(sequence)} residues")
            embeddings.append(vectors.astype(np.float16))
            for key in labels:
                labels[key].append(label[key])
            chain_index.append(np.full(len(sequence), processed, dtype=np.int32))
            processed += 1
        print(f"\r  {processed}/{len(chains)} chains (width {longest})", end="", flush=True)

    for chain in chains:
        batch.append(chain)
        widest = max(len(sequence) for _, sequence, _ in batch)
        if widest * len(batch) >= args.batch_residues:
            flush(batch)
            batch = []
    flush(batch)
    print()

    OUT.mkdir(parents=True, exist_ok=True)
    destination = OUT / f"{args.split}.npz"
    np.savez_compressed(
        destination,
        embeddings=np.concatenate(embeddings),
        chain=np.concatenate(chain_index),
        **{key: np.concatenate(value) for key, value in labels.items()},
    )
    size = destination.stat().st_size / 1e6
    print(f"wrote {destination.relative_to(ROOT)}  ({size:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
