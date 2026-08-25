#!/usr/bin/env python3
"""How certain is "the disorder head is below the no-language-model floor"?

    Tools/coreml/.venv/bin/python Tools/heads/disorder_uncertainty.py

The app tells users that on sequences with no close relative in the PDB, the
disorder head is currently WORSE than not using a language model at all. That is
a strong claim, and it rests on one number: MCC 0.500 on CASP12 against a
published one-hot baseline of 0.573.

CASP12 has **21 chains**.

Worse, the 7,256 residues in it are not 7,256 independent observations.
Disorder is contiguous: a disordered forty-residue tail is one event, not forty.
Treating residues as independent is exactly the mistake that makes a small
benchmark look decisive, and this project has been caught by the correlated-unit
version of it before.

So the resampling unit here is the CHAIN. Draw 21 chains with replacement,
recompute MCC over whatever residues those chains contain, and repeat. The
spread of that distribution is what the benchmark can actually support.

This does not try to improve the head. It asks whether the number the app is
quoting means what the app says it means, which has to be answered first: if the
interval is wide enough to contain the floor, then "below the floor" is not an
established fact and chasing it would be optimising against noise.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import train_heads  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "Datasets/embeddings"
MODELS = ROOT / "Models/heads"

# The published no-language-model baselines these are measured against, from
# the NetSurfP-3.0 paper's Table 1. The "one-hot" row uses no language model and
# is the floor: below it, the embeddings are contributing nothing.
ONE_HOT_FLOOR = {"cb513": 0.502, "ts115": 0.594, "casp12": 0.573}


def mcc_from_counts(tp: int, tn: int, fp: int, fn: int) -> float:
    denominator = np.sqrt(float(tp + fp) * (tp + fn) * (tn + fp) * (tn + fn))
    return float((tp * tn - fp * fn) / denominator) if denominator > 0 else 0.0


def load_head(path: Path) -> torch.nn.Module:
    """Load the trained disorder head.

    Imported from the trainer rather than reconstructed. The first version of
    this script rebuilt it as a stack of Linear layers from the state dict's
    shapes, which loaded without complaint and scored MCC 0.000 on all three
    benchmarks: the head is CONVOLUTIONAL and operates over a chain, so a
    per-residue MLP made of its weights is a different function entirely.
    A reconstruction that runs is not a reconstruction that is right.
    """
    head = train_heads.ConvHead(classes=2)
    head.load_state_dict(torch.load(path, map_location="cpu", weights_only=True))
    head.eval()
    return head


def predictions(bundle, boundaries, head: torch.nn.Module, threshold: float) -> tuple:
    """Per-residue predictions, chain by chain.

    Chain by chain because the head is convolutional: batching chains together
    means padding, and padding a dilated convolution changes the values at the
    ends of every real chain. Slower and correct.

    The valid mask is the trainer's: every residue of every chain. The cached
    `evaluation` column is NOT used, because `train_heads.evaluate` does not use
    it either, and a different mask here would produce a different denominator
    and an interval around a number the app never quoted. The first version did
    exactly that and reported 564 disordered residues on CB513 where the
    published benchmark records 3,529.
    """
    embeddings = bundle["embeddings"]
    ordered = bundle["ordered"]
    chain = bundle["chain"]

    said = np.zeros(len(ordered), dtype=bool)
    with torch.no_grad():
        for index in range(len(boundaries) - 1):
            start, stop = int(boundaries[index]), int(boundaries[index + 1])
            if stop <= start:
                continue
            block = torch.from_numpy(
                embeddings[start:stop].astype(np.float32)).T.unsqueeze(0)
            probability = F.softmax(head(block), dim=1)[0, 0].numpy()
            said[start:stop] = probability > threshold

    truth = ordered == 0
    valid = np.ones(len(ordered), dtype=bool)
    return said, truth, valid, chain


def bootstrap(
    said: np.ndarray, truth: np.ndarray, valid: np.ndarray, chain: np.ndarray,
    draws: int, rng: np.random.Generator
) -> np.ndarray:
    """Resample CHAINS with replacement and recompute MCC each time."""
    chains = np.unique(chain)
    by_chain = {c: np.where((chain == c) & valid)[0] for c in chains}

    scores = np.empty(draws)
    for draw in range(draws):
        picked = rng.choice(chains, size=len(chains), replace=True)
        index = np.concatenate([by_chain[c] for c in picked])
        s, t = said[index], truth[index]
        tp = int((s & t).sum())
        fp = int((s & ~t).sum())
        fn = int((~s & t).sum())
        tn = int((~s & ~t).sum())
        scores[draw] = mcc_from_counts(tp, tn, fp, fn)
    return scores


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--draws", type=int, default=2000)
    # The SHIPPED threshold, read from the head's own configuration rather than
    # defaulted to 0.5. The trainer tunes it (0.90 here), and bootstrapping at
    # 0.5 puts an interval around an operating point the app never uses: the
    # first run of this script did exactly that and reported CB513 at 0.357
    # where the recorded benchmark is 0.431.
    default_threshold = 0.5
    try:
        default_threshold = float(
            json.loads((MODELS / "config.json").read_text())["disorder_threshold"])
    except (OSError, KeyError, ValueError):
        pass
    parser.add_argument("--threshold", type=float, default=default_threshold)
    parser.add_argument(
        "--head", default=str(MODELS / "disorder.pt"),
        help="the trained disorder head")
    args = parser.parse_args()

    head_path = Path(args.head)
    if not head_path.exists():
        candidates = sorted(MODELS.glob("disorder*.pt"))
        if not candidates:
            print(f"no disorder head found at {head_path} or in {MODELS}")
            return 1
        head_path = candidates[0]
        print(f"using {head_path.name}")

    summary = {}
    rng = np.random.default_rng(0)

    for name in ["cb513", "ts115", "casp12"]:
        path = DATA / f"{name}.npz"
        if not path.exists():
            print(f"skipping {name}: no cached embeddings")
            continue
        handle = np.load(path)
        bundle = {key: handle[key] for key in handle.files}
        chain_index = bundle["chain"]
        boundaries = np.searchsorted(chain_index, np.arange(chain_index[-1] + 2))
        head = load_head(head_path)

        said, truth, valid, chain = predictions(
            bundle, boundaries, head, args.threshold)
        chains = len(np.unique(chain))
        positives = int((truth & valid).sum())

        tp = int((said & truth & valid).sum())
        fp = int((said & ~truth & valid).sum())
        fn = int((~said & truth & valid).sum())
        tn = int((~said & ~truth & valid).sum())
        point = mcc_from_counts(tp, tn, fp, fn)

        scores = bootstrap(said, truth, valid, chain, args.draws, rng)
        low, high = np.percentile(scores, [2.5, 97.5])
        floor = ONE_HOT_FLOOR[name]
        # The question the app's claim depends on: how often does a resampled
        # benchmark put this head BELOW the no-language-model floor?
        below = float((scores < floor).mean())

        verdict = (
            "below the floor" if high < floor
            else "above the floor" if low > floor
            else "INDISTINGUISHABLE from the floor")
        print(f"\n--- {name}: {chains} chains, {positives:,} disordered residues ---")
        print(f"  MCC {point:.3f}, 95% interval [{low:.3f}, {high:.3f}] by chain bootstrap")
        print(f"  one-hot floor {floor:.3f}: {verdict}")
        print(f"  resamples landing below the floor: {below:.1%}")

        summary[name] = {
            "chains": chains,
            "disordered_residues": positives,
            "mcc": point,
            "ci_low": float(low),
            "ci_high": float(high),
            "one_hot_floor": floor,
            "fraction_below_floor": below,
            "verdict": verdict,
        }

    (ROOT / "Docs/disorder_uncertainty.json").write_text(
        json.dumps(summary, indent=2) + "\n")
    print("\nwrote Docs/disorder_uncertainty.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
