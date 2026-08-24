#!/usr/bin/env python3
"""Parity gate: does the Core ML model agree with PyTorch?

    Tools/coreml/.venv/bin/python Tools/coreml/validate_parity.py \
        --model esm2_t12_35M_UR50D

Gates (build plan section 4.2, revised 2026-08-24):
    relative error on hidden states      < 1%     (max abs error / max |signal|)
    cosine similarity on hidden states   > 0.999
    Spearman rho on the delta-LLR matrix > 0.99

Why the hidden-state gate is relative rather than absolute
----------------------------------------------------------
The plan originally specified `max absolute error < 1e-2`. That gate cannot be
met by any model that runs on the Neural Engine, and the reason is hardware, not
a defect: **the ANE is fp16**. Measured on this backbone, fp32 achieves a max
absolute error of 0.0017 and **0% ANE residency**, with all 682 executable
operations falling back to the CPU. fp16 achieves 0.031 absolute error and 98.8%
residency. Choosing the absolute gate means choosing a model that cannot run on
the hardware the entire app is premised on.

The replacement is scale-aware. fp16's 0.031 is 0.61% of the signal's own range,
a cosine similarity of 0.99997 and a delta-LLR rank correlation of 0.999975: the
embeddings are, for every purpose the app puts them to, the same embeddings. A
relative gate also stays meaningful for a larger backbone whose activations have
a different range, which a hard-coded 1e-2 would not.

Why every bucket is checked, not just one
-----------------------------------------
The failure this gate exists to catch is not "the model is broken", which is
obvious. It is "the model is right at the length it was traced and wrong at
every other length", which is invisible. fair-esm caches its rotary position
tables keyed on sequence length, so a naive trace bakes in tables sized for one
bucket; the conversion succeeds, the default bucket is perfect, and every other
bucket is quietly wrong. So each declared bucket is validated independently, and
a padded sequence is checked specifically, because padding is the other branch a
trace can silently freeze.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from scipy.stats import spearmanr

ROOT = Path(__file__).resolve().parents[2]
MODELS_DIR = ROOT / "Models"

BUCKETS = [128, 256, 384, 512, 768, 1024]

RELATIVE_TOLERANCE = 0.01
COSINE_FLOOR = 0.999
SPEARMAN_FLOOR = 0.99

UBIQUITIN = "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDYNIQKESTLHLVLRLRGG"
CANONICAL = "ACDEFGHIKLMNPQRSTVWY"


def build_tokens(alphabet, sequence: str, bucket: int) -> torch.Tensor:
    tokens = torch.full((1, bucket), alphabet.padding_idx, dtype=torch.int64)
    tokens[0, 0] = alphabet.cls_idx
    residues = [alphabet.get_idx(c) for c in sequence]
    tokens[0, 1 : 1 + len(residues)] = torch.tensor(residues)
    tokens[0, 1 + len(residues)] = alphabet.eos_idx
    return tokens


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="esm2_t12_35M_UR50D")
    args = parser.parse_args()

    sys.path.insert(0, str(Path(__file__).parent))
    from convert_backbone import ESMBackbone, load_model, make_traceable

    package = MODELS_DIR / f"{args.model}.mlpackage"
    if not package.exists():
        print(f"missing {package}: run convert_backbone.py first", file=sys.stderr)
        return 1

    print(f"loading PyTorch reference {args.model} ...")
    model, alphabet = load_model(args.model)
    make_traceable(model, max(BUCKETS))
    reference = ESMBackbone(model, model.num_layers).eval()

    print("loading Core ML model (CPU_AND_NE) ...")
    mlmodel = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_AND_NE)

    failures: list[str] = []

    print("\n--- hidden state parity, every declared bucket ---")
    print(f"{'bucket':>7}  {'max abs':>9}  {'relative':>9}  {'cosine':>10}  {'verdict':>8}")
    for bucket in BUCKETS:
        # Fill a decent fraction of the bucket so padding is exercised too.
        length = min(len(UBIQUITIN), bucket - 2)
        tokens = build_tokens(alphabet, UBIQUITIN[:length], bucket)

        with torch.no_grad():
            torch_hidden, _ = reference(tokens)
        torch_hidden = torch_hidden.numpy().astype(np.float32)

        prediction = mlmodel.predict({"tokens": tokens.numpy().astype(np.int32)})
        coreml_hidden = np.asarray(prediction["hidden_states"], dtype=np.float32)

        # Compare only the real positions: padding is masked, so whatever the
        # model emits there is not a claim about anything.
        real = 1 + length + 1
        expected = torch_hidden[:, :real, :]
        actual = coreml_hidden[:, :real, :]
        maximum = float(np.abs(expected - actual).max())
        # Relative to the signal's own range: an absolute tolerance is only
        # meaningful if you already know how large the activations are.
        scale = float(np.abs(expected).max())
        relative = maximum / scale if scale > 0 else float("inf")
        cosine = float(
            expected.ravel() @ actual.ravel()
            / (np.linalg.norm(expected) * np.linalg.norm(actual)))

        ok = relative < RELATIVE_TOLERANCE and cosine > COSINE_FLOOR
        if not ok:
            failures.append(
                f"bucket {bucket}: relative error {relative:.4%} "
                f"(limit {RELATIVE_TOLERANCE:.0%}), cosine {cosine:.6f} "
                f"(floor {COSINE_FLOOR})")
        print(f"{bucket:>7}  {maximum:>9.5f}  {relative:>9.4%}  {cosine:>10.7f}  "
              f"{'PASS' if ok else 'FAIL':>8}")

    print("\n--- delta-LLR rank correlation (the number the Fitness tab shows) ---")
    bucket = 128
    length = min(len(UBIQUITIN), bucket - 2)
    positions = list(range(1, length + 1))
    canonical_ids = [alphabet.get_idx(c) for c in CANONICAL]

    def llr_matrix(logits: np.ndarray, tokens: np.ndarray) -> np.ndarray:
        """Delta-LLR for every canonical substitution at every position."""
        matrix = np.zeros((len(positions), len(CANONICAL)), dtype=np.float64)
        for row, position in enumerate(positions):
            column = logits[0, position, :].astype(np.float64)
            column = column - np.log(np.exp(column - column.max()).sum()) - column.max()
            wild_type = int(tokens[0, position])
            for col, token_id in enumerate(canonical_ids):
                matrix[row, col] = column[token_id] - column[wild_type]
        return matrix

    tokens = build_tokens(alphabet, UBIQUITIN[:length], bucket)
    with torch.no_grad():
        _, torch_logits = reference(tokens)
    torch_llr = llr_matrix(torch_logits.numpy().astype(np.float32), tokens.numpy())

    prediction = mlmodel.predict({"tokens": tokens.numpy().astype(np.int32)})
    coreml_llr = llr_matrix(
        np.asarray(prediction["logits"], dtype=np.float32), tokens.numpy())

    rho, _ = spearmanr(torch_llr.ravel(), coreml_llr.ravel())
    ok = rho > SPEARMAN_FLOOR
    if not ok:
        failures.append(f"delta-LLR Spearman rho {rho:.5f} <= {SPEARMAN_FLOOR}")
    print(f"  Spearman rho = {rho:.6f}   {'PASS' if ok else 'FAIL'}")
    print(f"  max abs delta-LLR difference = {np.abs(torch_llr - coreml_llr).max():.6f}")

    print("\n--- padding is genuinely masked ---")
    # The same residues in two different buckets must give the same answer for
    # the real positions. If the trace froze the no-padding branch, they will
    # not, and nothing else in this script would notice.
    short = build_tokens(alphabet, UBIQUITIN[:60], 128)
    long = build_tokens(alphabet, UBIQUITIN[:60], 512)
    short_hidden = np.asarray(
        mlmodel.predict({"tokens": short.numpy().astype(np.int32)})["hidden_states"],
        dtype=np.float32)
    long_hidden = np.asarray(
        mlmodel.predict({"tokens": long.numpy().astype(np.int32)})["hidden_states"],
        dtype=np.float32)
    real = 62
    padding_difference = float(
        np.abs(short_hidden[:, :real, :] - long_hidden[:, :real, :]).max())
    padding_scale = float(np.abs(short_hidden[:, :real, :]).max())
    padding_relative = padding_difference / padding_scale if padding_scale > 0 else float("inf")
    ok = padding_relative < RELATIVE_TOLERANCE
    if not ok:
        failures.append(
            f"same residues differ by {padding_relative:.4%} between buckets: "
            "padding is not being masked, or the rotary tables are frozen at one length")
    print(f"  bucket 128 vs 512, same residues: max abs {padding_difference:.6f}, "
          f"relative {padding_relative:.4%}   {'PASS' if ok else 'FAIL'}")

    print()
    if failures:
        print("PARITY GATE FAILED")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("PARITY GATE PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
