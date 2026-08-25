#!/usr/bin/env python3
"""Is the disorder head too small, and would a bigger one ship?

    Tools/coreml/.venv/bin/python Tools/heads/disorder_capacity_sweep.py

Why capacity, and why now
-------------------------
Two experiments point the same way.

`disorder_rsa_experiment.py` added solvent accessibility as an auxiliary task
and found nothing: CB513 moved 0.426 to 0.428, paired interval [-0.007, +0.013].
Bounded, not merely undetected.

`disorder_onehot_control.py` trained the same head on one-hot amino acids and
got 0.380 against 0.426 with embeddings, while NetSurfP's own one-hot baseline
is 0.502. So the embeddings ARE contributing (+0.046), and the gap to NetSurfP
is 0.122 of architecture and training budget, with nothing to do with the input.

Both results say the deficit lives in the head. This measures whether making it
bigger closes any of it.

What is varied
--------------
Width, and receptive field. Depth is worth testing separately from width for
this task specifically: disordered regions are long, often tens of residues, and
the shipped head's three dilated blocks see 25 residues. A fourth block at
dilation 8 sees 49. If disorder is a statement about a neighbourhood larger than
the head can see, no amount of width fixes it.

    w128     the shipped head: three blocks, dilations 1, 2, 4, width 128
    w256     the same shape, twice as wide
    d4       three blocks plus a fourth at dilation 8, width 128
    w256d4   both

Everything else is held: same seed, bit-identical initialisation where the
shapes allow, same chains, same batches in the same order, same class weight,
thresholds tuned on the same validation chains and applied blind.

The constraint nobody should forget
-----------------------------------
This head ships inside an app and runs on the Neural Engine. A configuration
that wins by two points and quadruples the asset is not obviously a win, so the
parameter count and the estimated fp16 size are reported beside every score.
A result that cannot ship is a research note, not an improvement.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

sys.path.insert(0, str(Path(__file__).resolve().parent))
import train_heads  # noqa: E402
from train_heads import EMBED_WIDTH  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "Datasets/embeddings"
OUT = ROOT / "Docs"
ONE_HOT_FLOOR = {"cb513": 0.502, "ts115": 0.594, "casp12": 0.573}


class SweepHead(nn.Module):
    """The shipped head's shape, with width and depth as parameters.

    At `width=128, dilations=(1, 2, 4)` this is `ConvHead` exactly: same
    projection, same residual blocks, same normalisation, same dropout, same
    output. That matters, because the baseline arm of this sweep has to be the
    shipped model and not something that resembles it.
    """

    def __init__(
        self, classes: int = 2, width: int = 128, dropout: float = 0.2,
        dilations: tuple[int, ...] = (1, 2, 4)
    ):
        super().__init__()
        self.project = nn.Conv1d(EMBED_WIDTH, width, kernel_size=1)
        self.blocks = nn.ModuleList([
            nn.Conv1d(width, width, kernel_size=5, padding=2 * d, dilation=d)
            for d in dilations
        ])
        self.norms = nn.ModuleList([nn.BatchNorm1d(width) for _ in dilations])
        self.dropout = nn.Dropout(dropout)
        self.output = nn.Conv1d(width, classes, kernel_size=1)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        h = F.gelu(self.project(x))
        for block, norm in zip(self.blocks, self.norms):
            h = h + self.dropout(F.gelu(norm(block(h))))
        return self.output(h)

    @property
    def receptive_field(self) -> int:
        """Residues the output at one position can see.

        Each kernel-5 block at dilation d adds 4*d. Reported because it is the
        quantity that matters for a long-range property, and because a number
        in a table is harder to hand-wave than "deeper".
        """
        return 1 + sum(4 * block.dilation[0] for block in self.blocks)


CONFIGURATIONS = {
    "w128": {"width": 128, "dilations": (1, 2, 4)},
    "w256": {"width": 256, "dilations": (1, 2, 4)},
    "d4": {"width": 128, "dilations": (1, 2, 4, 8)},
    "w256d4": {"width": 256, "dilations": (1, 2, 4, 8)},
}


def batches(bundle, boundaries, indices, batch_size, shuffle, rng=None):
    order = list(indices)
    lengths = {i: boundaries[i + 1] - boundaries[i] for i in order}
    order.sort(key=lambda i: lengths[i])
    if shuffle:
        blocks = [order[i : i + batch_size] for i in range(0, len(order), batch_size)]
        (rng or np.random.default_rng(0)).shuffle(blocks)
        order = [i for block in blocks for i in block]

    for start in range(0, len(order), batch_size):
        group = order[start : start + batch_size]
        longest = max(lengths[i] for i in group)
        x = np.zeros((len(group), longest, EMBED_WIDTH), dtype=np.float32)
        ordered = np.full((len(group), longest), -100, dtype=np.int64)
        mask = np.zeros((len(group), longest), dtype=bool)
        for row, index in enumerate(group):
            lo, hi = boundaries[index], boundaries[index + 1]
            n = hi - lo
            x[row, :n] = bundle["embeddings"][lo:hi].astype(np.float32)
            ordered[row, :n] = bundle["ordered"][lo:hi]
            mask[row, :n] = True
        yield (
            torch.from_numpy(x).permute(0, 2, 1),
            torch.from_numpy(ordered),
            torch.from_numpy(mask),
        )


def mcc_from_counts(tp: int, tn: int, fp: int, fn: int) -> float:
    denominator = np.sqrt(float(tp + fp) * (tp + fn) * (tn + fp) * (tn + fn))
    return float((tp * tn - fp * fn) / denominator) if denominator > 0 else 0.0


def tune_threshold(head, bundle, boundaries, indices, batch_size) -> float:
    head.eval()
    probabilities, truth = [], []
    with torch.no_grad():
        for x, ordered, mask in batches(bundle, boundaries, indices, batch_size, False):
            p = F.softmax(head(x), dim=1)[:, 0]
            probabilities.append(p[mask].numpy())
            truth.append((ordered[mask] == 0).numpy())
    p = np.concatenate(probabilities)
    y = np.concatenate(truth)
    best, best_mcc = 0.5, -1.0
    for candidate in np.arange(0.05, 1.0, 0.01):
        said = p > candidate
        score = mcc_from_counts(
            int((said & y).sum()), int((~said & ~y).sum()),
            int((said & ~y).sum()), int((~said & y).sum()))
        if score > best_mcc:
            best_mcc, best = score, float(candidate)
    return best


def evaluate(head, name: str, threshold: float, draws: int, rng) -> dict:
    handle = np.load(DATA / f"{name}.npz")
    bundle = {key: handle[key] for key in handle.files}
    chain = bundle["chain"]
    boundaries = np.searchsorted(chain, np.arange(chain[-1] + 2))

    said = np.zeros(len(bundle["ordered"]), dtype=bool)
    head.eval()
    with torch.no_grad():
        for index in range(len(boundaries) - 1):
            lo, hi = int(boundaries[index]), int(boundaries[index + 1])
            if hi <= lo:
                continue
            block = torch.from_numpy(
                bundle["embeddings"][lo:hi].astype(np.float32)).T.unsqueeze(0)
            probability = F.softmax(head(block), dim=1)[0, 0].numpy()
            said[lo:hi] = probability > threshold

    truth = bundle["ordered"] == 0
    point = mcc_from_counts(
        int((said & truth).sum()), int((~said & ~truth).sum()),
        int((said & ~truth).sum()), int((~said & truth).sum()))

    chains = np.unique(chain)
    by_chain = {c: np.where(chain == c)[0] for c in chains}
    scores = np.empty(draws)
    for draw in range(draws):
        picked = rng.choice(chains, size=len(chains), replace=True)
        index = np.concatenate([by_chain[c] for c in picked])
        s, t = said[index], truth[index]
        scores[draw] = mcc_from_counts(
            int((s & t).sum()), int((~s & ~t).sum()),
            int((s & ~t).sum()), int((~s & t).sum()))
    low, high = np.percentile(scores, [2.5, 97.5])
    return {
        "mcc": point, "ci_low": float(low), "ci_high": float(high), "scores": scores}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--epochs", type=int, default=6)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--weight", type=float, default=14.5)
    parser.add_argument("--draws", type=int, default=2000)
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()

    bundle, boundaries = train_heads.load_split("train")
    total = len(boundaries) - 2
    rng = np.random.default_rng(args.seed)
    order = rng.permutation(total)
    cut = int(len(order) * 0.9)
    train_indices, validation_indices = order[:cut], order[cut:]
    print(f"  {len(train_indices):,} training chains, "
          f"{len(validation_indices):,} for threshold tuning\n")

    results = {}
    for name, configuration in CONFIGURATIONS.items():
        torch.manual_seed(args.seed)
        head = SweepHead(**configuration)
        parameters = sum(p.numel() for p in head.parameters())
        print(f"  --- {name}: {parameters:,} parameters, "
              f"{parameters * 2 / 1e6:.2f} MB at fp16, "
              f"receptive field {head.receptive_field} residues ---", flush=True)

        optimiser = torch.optim.AdamW(head.parameters(), lr=1e-3, weight_decay=0.01)
        schedule = torch.optim.lr_scheduler.CosineAnnealingLR(optimiser, T_max=args.epochs)
        class_weight = torch.tensor([args.weight, 1.0])

        for epoch in range(1, args.epochs + 1):
            head.train()
            running = count = 0.0
            for x, ordered, _ in batches(
                bundle, boundaries, train_indices, args.batch_size, True,
                np.random.default_rng(0)
            ):
                optimiser.zero_grad()
                loss = F.cross_entropy(
                    head(x), ordered, weight=class_weight, ignore_index=-100)
                loss.backward()
                optimiser.step()
                running += float(loss.item())
                count += 1
            schedule.step()
            if epoch == args.epochs:
                print(f"    epoch {epoch}: loss {running / max(count, 1):.4f}", flush=True)

        threshold = tune_threshold(
            head, bundle, boundaries, validation_indices, args.batch_size)
        entry = {
            "parameters": parameters,
            "megabytes_fp16": parameters * 2 / 1e6,
            "receptive_field": head.receptive_field,
            "threshold": threshold,
        }
        for split in ["cb513", "ts115", "casp12"]:
            measured = evaluate(head, split, threshold, args.draws, np.random.default_rng(1))
            entry[split] = measured
            print(f"    {split}: MCC {measured['mcc']:.3f} "
                  f"[{measured['ci_low']:.3f}, {measured['ci_high']:.3f}]", flush=True)
        results[name] = entry
        print(flush=True)

    print("--- against the shipped w128, paired over the same chain draws ---")
    summary = {}
    baseline = results["w128"]
    for name, entry in results.items():
        row = {
            "parameters": entry["parameters"],
            "megabytes_fp16": entry["megabytes_fp16"],
            "receptive_field": entry["receptive_field"],
        }
        for split in ["cb513", "ts115", "casp12"]:
            paired = entry[split]["scores"] - baseline[split]["scores"]
            low, high = np.percentile(paired, [2.5, 97.5])
            verdict = (
                "helps" if low > 0 else "hurts" if high < 0 else "no effect detectable")
            row[split] = {
                "mcc": entry[split]["mcc"],
                "delta": entry[split]["mcc"] - baseline[split]["mcc"],
                "paired_ci": [float(low), float(high)],
                "verdict": verdict,
            }
        summary[name] = row
        cb = row["cb513"]
        print(f"  {name:>7}: CB513 {cb['mcc']:.3f} "
              f"({cb['delta']:+.3f}, paired [{cb['paired_ci'][0]:+.3f}, "
              f"{cb['paired_ci'][1]:+.3f}]) {cb['verdict']}   "
              f"{row['megabytes_fp16']:.2f} MB")

    OUT.mkdir(exist_ok=True)
    (OUT / "disorder_capacity_results.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"\nwrote {(OUT / 'disorder_capacity_results.json').relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
