#!/usr/bin/env python3
"""Pack the homolog index and SIFTS tables into the binary assets the app reads.

    Tools/coreml/.venv/bin/python Tools/data/pack_index_assets.py

Writes `Assets/homolog_vectors.bin`, `Assets/homolog_meta.bin` and
`Assets/sifts_segments.bin`.

Why binary and not JSON
-----------------------
The JSON intermediates are 43 MB and 225 MB. Decoding those at launch would
cost seconds and peak at several times their size in memory, on a device where
the whole point is that the analysis is instant. The binary forms are
memory-mapped: the vectors are read as one contiguous block, and metadata and
segments are touched only for the handful of entries a search actually returns.

Whitening, and why the index would have been quietly broken without it
----------------------------------------------------------------------
Pooled language-model embeddings are ANISOTROPIC: they occupy a narrow cone
rather than the sphere. Measured on this index, two proteins picked at random
score a cosine of **0.848 on average**, and the 99.9th percentile of random
pairs is **0.980**. Real homologues score 0.97 to 0.99. So the raw number is
almost meaningless as something to show a user, and worse, everything useful
lives in a sliver of the range.

That sliver is what int8 quantisation destroys. Measured: storing the raw
normalised vectors as int8 gives **recall@10 of 0.748** against exhaustive float
search. A quarter of the true nearest neighbours are simply lost, silently, and
the hits that remain still look plausible because the neighbours of a protein
are mostly its own family.

The fix is the standard anisotropy correction (Mu and Viswanath, "All-but-the-
top", ICLR 2018): subtract the mean vector, then remove the dominant principal
directions. Measured here:

    raw              recall@10 0.748   null mean 0.848   null p99.9 0.980
    centred          recall@10 0.944   null mean 0.001   null p99.9 0.819
    centred, -4 PCs  recall@10 0.966   null mean 0.000   null p99.9 0.640

The mean and the components are stored in the vector file, because the app must
apply exactly the same transform to a query. They are 5 by 480 floats, which is
9.6 KB against a 34.8 MB index.

Quantisation
------------
After whitening, vectors are L2-normalised and stored as int8. Normalising makes
one shared scale correct: every component is in [-1, 1], so the scale is 127 for
every row and cosine similarity becomes a plain dot product.
"""

from __future__ import annotations

import json
import struct
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "Datasets/pdb"
OUT = ROOT / "Assets"

TITLE_LIMIT = 90


# How many principal directions to remove. Four is where the measured recall
# stops improving: 2 gives 0.963, 4 gives 0.966, 8 gives 0.962. Removing more
# starts discarding signal along with the anisotropy.
COMPONENTS = 4


def whiten(vectors: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Centre, remove the dominant directions, and return the transform too."""
    mean = vectors.mean(axis=0)
    centred = vectors - mean
    # `full_matrices=False` on 72,421 by 480 is a thin SVD and takes seconds.
    _, _, rows = np.linalg.svd(centred, full_matrices=False)
    components = rows[:COMPONENTS].astype(np.float32)
    stripped = centred - (centred @ components.T) @ components
    return stripped.astype(np.float32), mean.astype(np.float32), components


def null_percentile(normalised: np.ndarray, percentile: float = 99.9) -> float:
    """What an UNRELATED pair scores, measured rather than guessed.

    The similarity floor below which a hit is not worth showing cannot be picked
    by eye. Before whitening, unrelated proteins in this index scored 0.848 on
    average and a floor of 0.5 would have admitted literally everything. After
    whitening the null sits at 0.000, and this measures where its tail ends so
    the app can refuse hits inside it.
    """
    rng = np.random.default_rng(0)
    left = rng.choice(len(normalised), size=200_000)
    right = rng.choice(len(normalised), size=200_000)
    keep = left != right
    null = np.einsum("ij,ij->i", normalised[left[keep]], normalised[right[keep]])
    return float(np.percentile(null, percentile))


def pack_vectors(vectors: np.ndarray) -> bytes:
    stripped, mean, components = whiten(vectors.astype(np.float32))
    normalised = stripped / np.maximum(
        np.linalg.norm(stripped, axis=1, keepdims=True), 1e-12)
    floor = null_percentile(normalised)
    print(f"  null 99.9th percentile (the similarity floor): {floor:.4f}")
    quantised = np.clip(np.rint(normalised * 127.0), -127, 127).astype(np.int8)
    header = b"BOFHVEC2" + struct.pack(
        "<IIIIf", quantised.shape[0], quantised.shape[1], 1, len(components), floor)
    return (
        header
        + mean.astype("<f4").tobytes()
        + components.astype("<f4").tobytes()
        + quantised.tobytes())


def pack_meta(index: list[dict]) -> bytes:
    lines = []
    for entry in index:
        resolution = entry["resolution"]
        lines.append(
            "\t".join([
                entry["accession"],
                entry["pdb"],
                entry["chain"],
                "" if resolution is None else f"{resolution:.2f}",
                entry["method"],
                str(len(entry["sequence"])),
                str(entry["structures"]),
                entry["title"][:TITLE_LIMIT].replace("\t", " "),
                # The SEQRES sequence, which costs about 20 MB across the index
                # and buys two things worth more than that. It lets the app
                # report a real ALIGNMENT IDENTITY for the handful of hits it
                # shows, rather than leaving a reader to interpret an embedding
                # cosine as a percentage identity, which it is not. And it is
                # what the query is aligned against to reach SIFTS, since SIFTS
                # anchors on SEQRES positions.
                entry["sequence"],
            ]).encode("utf-8"))

    offsets, cursor = [], 0
    for line in lines:
        offsets.append(cursor)
        cursor += len(line)
    offsets.append(cursor)

    textOffset = 16 + 4 * len(offsets)
    header = b"BOFHMET1" + struct.pack("<II", len(lines), textOffset)
    table = b"".join(struct.pack("<I", o) for o in offsets)
    return header + table + b"".join(lines)


def pack_segments(segments: dict[str, list]) -> bytes:
    names = sorted(segments)

    nameBlob, nameSpans, cursor = [], [], 0
    for name in names:
        encoded = name.encode("ascii")
        assert len(encoded) < 65536
        nameBlob.append(encoded)
        nameSpans.append((cursor, len(encoded)))
        cursor += len(encoded)
    nameBytes = b"".join(nameBlob)

    rows, accessionRecords, first = [], [], 0
    for index, name in enumerate(names):
        group = segments[name]
        for segment in group:
            pdb = segment["pdb"].encode("ascii")[:4].ljust(4, b"\0")
            chain = segment["chain"].encode("ascii")
            assert len(chain) <= 4, f"chain id {segment['chain']!r} does not fit"
            rows.append(struct.pack(
                "<4s4siiiiBxxx",
                pdb, chain.ljust(4, b"\0"),
                segment["seqres_start"], segment["seqres_end"],
                segment["uniprot_start"], segment["author_start"],
                1 if segment["arithmetic"] else 0))
        offset, length = nameSpans[index]
        accessionRecords.append(struct.pack("<IHHII", offset, length, 0, first, len(group)))
        first += len(group)

    accessionsOffset = 24
    namesOffset = accessionsOffset + 16 * len(names)
    segmentsOffset = namesOffset + len(nameBytes)
    header = b"BOFSIFT1" + struct.pack(
        "<IIII", len(names), len(rows), namesOffset, segmentsOffset)
    return header + b"".join(accessionRecords) + nameBytes + b"".join(rows)


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    index = json.loads((DATA / "index_entries.json").read_text())

    vectors = np.load(DATA / "vectors.npy")
    assert len(vectors) == len(index), (
        f"{len(vectors):,} vectors against {len(index):,} entries: the index was "
        f"rebuilt after the vectors were computed, so row N of one is not row N "
        f"of the other")

    written = {
        "homolog_vectors.bin": pack_vectors(vectors),
        "homolog_meta.bin": pack_meta(index),
        "sifts_segments.bin": pack_segments(
            json.loads((DATA / "segments.json").read_text())),
    }
    for name, blob in written.items():
        (OUT / name).write_bytes(blob)
        print(f"wrote Assets/{name} ({len(blob) / 1e6:.1f} MB)")
    print(f"total {sum(len(b) for b in written.values()) / 1e6:.1f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
