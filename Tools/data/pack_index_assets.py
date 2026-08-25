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

Quantisation
------------
Vectors are L2-normalised and stored as int8. Normalising first is what makes
one shared scale correct: after normalisation every component is in [-1, 1], so
the scale is 127 for every row and cosine similarity becomes a plain dot
product. `validate_index.py` measures what the quantisation costs in recall
rather than assuming it is negligible.
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


def pack_vectors(vectors: np.ndarray) -> bytes:
    normalised = vectors / np.maximum(
        np.linalg.norm(vectors, axis=1, keepdims=True), 1e-12)
    quantised = np.clip(np.rint(normalised * 127.0), -127, 127).astype(np.int8)
    header = b"BOFHVEC1" + struct.pack(
        "<IIII", quantised.shape[0], quantised.shape[1], 1, 0)
    return header + quantised.tobytes()


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
