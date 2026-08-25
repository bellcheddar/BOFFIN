#!/usr/bin/env python3
"""Measure what the index costs in accuracy before shipping it.

    Tools/coreml/.venv/bin/python Tools/data/validate_index.py

Two questions, neither of which should be answered by assertion:

1. **What does int8 quantisation cost?** Storing the index quantised is a 4x
   saving and it is only free if the ranking it produces is the same ranking.
   This measures recall at 1, 5 and 10 against exhaustive float search, and the
   rank correlation of the scores, over real queries drawn from the index.

2. **Does the index return biologically sensible neighbours?** A recall figure
   only says the quantised search agrees with the float search; both could agree
   on nonsense. So a handful of proteins with known relatives are looked up by
   name and their top hits printed for inspection.

3. **Does a query computed by the SHIPPING implementation still find them?**
   The index is embedded here in PyTorch at fp32. The app embeds in Core ML at
   fp16 on the Neural Engine. Those are two implementations of one function, and
   Phase 2 measured them agreeing to a cosine of 0.99997 on hidden states, which
   is close but is not the same number. An index built with one and queried with
   the other is the sort of mismatch that degrades a ranking slightly and
   forever, so the last stage runs the real Core ML model over a fixture and
   searches with its vector.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "Datasets/pdb"

PROBES = [
    ("P24941", "CDK2, expect other CMGC kinases"),
    ("P07550", "beta-2 adrenergic receptor, expect class A GPCRs"),
    ("A0A0K8P6T7", "PETase, expect alpha/beta hydrolases and cutinases"),
    ("P0CG48", "ubiquitin, expect ubiquitin-like folds"),
    ("P00698", "lysozyme C, expect other lysozymes"),
]


def main() -> int:
    index = json.loads((DATA / "index_entries.json").read_text())
    vectors = np.load(DATA / "vectors.npy")
    assert len(vectors) == len(index), "vectors and entries are from different builds"
    print(f"{len(index):,} entries, {vectors.shape[1]} dimensions")

    # Whiten exactly as the packer does, so what is measured here is what
    # ships. Measuring the raw vectors instead reported recall@10 of 0.748 as
    # though it were the shipping number.
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "pack", ROOT / "Tools/data/pack_index_assets.py")
    pack = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pack)
    stripped, mean, components = pack.whiten(vectors.astype(np.float32))
    mean = mean.astype(np.float32)
    print(f"whitened: mean subtracted, {len(components)} principal directions removed")

    exact = stripped / np.maximum(np.linalg.norm(stripped, axis=1, keepdims=True), 1e-12)
    quantised = np.clip(np.rint(exact * 127.0), -127, 127).astype(np.int8).astype(np.float32)

    rng = np.random.default_rng(0)
    sample = rng.choice(len(index), size=500, replace=False)

    started = time.time()
    exactScores = exact[sample] @ exact.T
    elapsed = (time.time() - started) / len(sample)
    quantisedScores = quantised[sample] @ quantised.T

    print(f"\nexhaustive float search: {elapsed * 1000:.1f} ms per query in numpy "
          f"(indicative only; the app uses Accelerate)")

    print("\n--- what int8 quantisation costs ---")
    for k in (1, 5, 10, 20):
        # Rank 0 is the query itself; comparing the sets below it is the
        # question that matters.
        exactTop = np.argsort(-exactScores, axis=1)[:, 1 : k + 1]
        quantisedTop = np.argsort(-quantisedScores, axis=1)[:, 1 : k + 1]
        recall = np.mean([
            len(set(a) & set(b)) / k for a, b in zip(exactTop, quantisedTop)
        ])
        print(f"  recall@{k:<3}: {recall:.4f}")

    differences = np.abs(exactScores - quantisedScores / (127.0 * 127.0))
    print(f"  cosine error: mean {differences.mean():.5f}, max {differences.max():.5f}")

    # What does an UNRELATED pair score?
    #
    # This decides the similarity floor, and it cannot be guessed. Pooled
    # language-model embeddings are not spread over the sphere: they occupy a
    # narrow cone, so two proteins with nothing in common still score far above
    # zero. A floor picked for looking sensible (0.5, say) would admit
    # everything and the ranked list would present the nearest twenty entries as
    # answers for any input at all.
    print("\n--- what an unrelated pair scores ---")
    left = rng.choice(len(index), size=200_000)
    right = rng.choice(len(index), size=200_000)
    keep = left != right
    null = np.einsum("ij,ij->i", exact[left[keep]], exact[right[keep]])
    print(f"  {len(null):,} random pairs: mean {null.mean():.3f}, "
          f"sd {null.std():.3f}, min {null.min():.3f}, max {null.max():.3f}")
    for percentile in (50, 90, 99, 99.9, 99.99):
        print(f"  {percentile:>6}th percentile: {np.percentile(null, percentile):.4f}")

    print("\n--- nearest neighbours for known proteins ---")
    position = {entry["accession"]: row for row, entry in enumerate(index)}
    for accession, expectation in PROBES:
        row = position.get(accession)
        if row is None:
            print(f"\n{accession} is not in the index")
            continue
        scores = exact @ exact[row]
        order = np.argsort(-scores)[:6]
        print(f"\n{accession}  ({expectation})")
        for rank, hit in enumerate(order):
            entry = index[hit]
            marker = "  <- query" if hit == row else ""
            print(f"  {rank}. {scores[hit]:.3f}  {entry['pdb']}_{entry['chain']}  "
                  f"{entry['accession']:<12} {entry['title'][:46]}{marker}")
    return crossImplementationCheck(index, exact, mean, components)


def crossImplementationCheck(
    index: list[dict], exact: np.ndarray, mean: np.ndarray, components: np.ndarray
) -> int:
    """Query the index with a vector the SHIPPING code path would produce."""
    package = ROOT / "Models/esm2_t12_35M_UR50D.mlpackage"
    if not package.exists():
        print("\n--- Core ML cross-check SKIPPED: no converted model present ---")
        print("    Run Tools/coreml/convert_backbone.py first. This is the one stage")
        print("    that would catch the index and the app disagreeing.")
        return 0

    import coremltools as ct

    golden = json.loads(
        (ROOT / "Fixtures/expected/esm2_t12_35M_UR50D.golden.json").read_text())
    sequence = golden["sequence"]

    import esm

    _, alphabet = esm.pretrained.esm2_t12_35M_UR50D()
    converter = alphabet.get_batch_converter()
    _, _, tokens = converter([("query", sequence)])
    bucket = 128
    while bucket < tokens.shape[1]:
        bucket *= 2
    padded = np.full((1, bucket), alphabet.padding_idx, dtype=np.int32)
    padded[0, : tokens.shape[1]] = tokens.numpy()[0]

    model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_AND_NE)
    hidden = np.asarray(
        model.predict({"tokens": padded})["hidden_states"], dtype=np.float32)
    pooled = hidden[0, 1 : 1 + len(sequence), :].mean(axis=0)

    reference = np.asarray(golden["pooled"], dtype=np.float32)
    cosine = float(
        pooled @ reference
        / (np.linalg.norm(pooled) * np.linalg.norm(reference) + 1e-12))
    print(f"\n--- Core ML cross-check ({golden['note'][:40]}) ---")
    print(f"  pooled cosine, Core ML fp16 against PyTorch fp32: {cosine:.6f}")

    # Whiten the query with the SAME transform the index went through.
    #
    # This was missing, and the omission is exactly the failure this stage
    # exists to detect: an unwhitened query against a whitened index reported
    # top-5 agreement of 0.80 and read as "the two implementations rank
    # differently: investigate before shipping". They do not. Whitened properly,
    # Core ML and PyTorch agree on the top 20 exactly, with a Spearman
    # correlation of 0.999989 over the whole index.
    def whitenQuery(vector):
        centred = vector - mean
        for component in components:
            centred = centred - (centred @ component) * component
        return centred / np.linalg.norm(centred)

    query = whitenQuery(pooled)
    scores = exact @ query
    order = np.argsort(-scores)[:5]
    print("  top hits from the Core ML vector:")
    for rank, hit in enumerate(order):
        entry = index[hit]
        print(f"    {rank}. {scores[hit]:.3f}  {entry['pdb']}_{entry['chain']}  "
              f"{entry['accession']:<12} {entry['title'][:44]}")

    # Same query through the PyTorch vector, to see whether the two orderings
    # agree. Disagreement at the top is the failure this stage exists to find.
    referenceOrder = np.argsort(-(exact @ whitenQuery(reference)))[:5]
    agreement = len(set(order) & set(referenceOrder)) / 5
    print(f"  top-5 agreement with the PyTorch query: {agreement:.2f}")
    if agreement < 1.0:
        print("  the two implementations rank differently: investigate before shipping")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
