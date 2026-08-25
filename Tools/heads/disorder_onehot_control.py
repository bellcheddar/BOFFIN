#!/usr/bin/env python3
"""Is the embedding helping, or is the head too small?

    Tools/coreml/.venv/bin/python Tools/heads/disorder_onehot_control.py

The comparison this project has been making
-------------------------------------------
BOFFIN's disorder head measures MCC 0.426 on CB513 against a published "one-hot"
baseline of 0.502, and the conclusion drawn, on screen and in the roadmap, is
that the language model is contributing nothing there.

**That comparison conflates two differences.** The published baseline is
NetSurfP's own architecture fed one-hot amino acids. BOFFIN's number is a small
dilated convolutional head fed frozen 480-dimensional ESM-2 embeddings. Two
things differ at once, the input representation and the model, so a gap between
them cannot be attributed to either.

The missing arm
---------------
Train the SAME head, with the same seed and the same schedule, on one-hot amino
acids instead of embeddings. That isolates the representation:

- If one-hot scores far BELOW 0.426, the embeddings are contributing after all,
  and the deficit against NetSurfP is about architecture and training budget
  rather than about the language model. The on-screen claim would then be
  wrong, and in the direction that understates the app.
- If one-hot scores AT or ABOVE 0.426, the embeddings genuinely add nothing on
  this benchmark, the claim stands, and it stands on evidence rather than on a
  cross-architecture comparison.

Either answer is worth having. The current position rests on comparing against
somebody else's model, and this project's own rule is that a plausible-looking
comparison which is silently wrong is worse than no comparison, because it will
be believed.

The one-hot columns are the first 20 of the NetSurfP feature block, a layout
already verified against RCSB entry 154L in `extract_embeddings.py`.
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
from extract_embeddings import AA_ONE_HOT, ORDERED_MASK, SEQUENCE_MASK  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
RAW = ROOT / "Datasets"
OUT = ROOT / "Docs"
SPLITS = {
    "train": "netsurfp_train.npz",
    "cb513": "netsurfp_cb513.npz",
    "ts115": "netsurfp_ts115.npz",
    "casp12": "netsurfp_casp12.npz",
}
ONE_HOT_FLOOR = {"cb513": 0.502, "ts115": 0.594, "casp12": 0.573}


def load_onehot(name: str):
    """Flatten a NetSurfP split into per-residue one-hot rows plus chain ids.

    The same flattening `extract_embeddings.py` performs, so the chains, the
    residue order and the ordered/disordered labels line up exactly with the
    cached embeddings. Anything else would compare two different benchmarks and
    call the difference an effect.
    """
    handle = np.load(RAW / SPLITS[name])
    data = handle["data"]

    rows, ordered, chain = [], [], []
    for index in range(data.shape[0]):
        residues = data[index]
        present = residues[:, SEQUENCE_MASK] > 0.5
        if not present.any():
            continue
        block = residues[present]
        rows.append(block[:, AA_ONE_HOT].astype(np.float32))
        ordered.append((block[:, ORDERED_MASK] > 0.5).astype(np.uint8))
        chain.append(np.full(len(block), index, dtype=np.int32))

    return {
        "features": np.concatenate(rows),
        "ordered": np.concatenate(ordered),
        "chain": np.concatenate(chain),
    }


class OneHotHead(nn.Module):
    """`ConvHead`, with its input projection resized for 20 channels.

    Everything after the projection is identical: the same three dilated blocks
    at the same width, the same normalisation, the same dropout, the same
    output. Only the first 1x1 convolution changes shape, because the input has
    20 channels instead of 480.

    That is the whole design. If the trunk differed at all, a difference in
    score would again be attributable to two things.
    """

    def __init__(self, width: int = 128, dropout: float = 0.2):
        super().__init__()
        self.trunk = train_heads.ConvHead(classes=2, width=width, dropout=dropout)
        self.trunk.project = nn.Conv1d(20, width, kernel_size=1)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.trunk(x)


def batches(bundle, boundaries, indices, batch_size, shuffle, rng=None):
    order = list(indices)
    lengths = {i: boundaries[i + 1] - boundaries[i] for i in order}
    order.sort(key=lambda i: lengths[i])
    if shuffle:
        blocks = [order[i : i + batch_size] for i in range(0, len(order), batch_size)]
        (rng or np.random.default_rng(0)).shuffle(blocks)
        order = [i for block in blocks for i in block]

    width = bundle["features"].shape[1]
    for start in range(0, len(order), batch_size):
        group = order[start : start + batch_size]
        longest = max(lengths[i] for i in group)
        x = np.zeros((len(group), longest, width), dtype=np.float32)
        ordered = np.full((len(group), longest), -100, dtype=np.int64)
        mask = np.zeros((len(group), longest), dtype=bool)
        for row, index in enumerate(group):
            lo, hi = boundaries[index], boundaries[index + 1]
            n = hi - lo
            x[row, :n] = bundle["features"][lo:hi]
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
    bundle = load_onehot(name)
    chain = bundle["chain"]
    boundaries = np.searchsorted(chain, np.arange(chain[-1] + 2))

    said = np.zeros(len(bundle["ordered"]), dtype=bool)
    head.eval()
    with torch.no_grad():
        for index in range(len(boundaries) - 1):
            lo, hi = int(boundaries[index]), int(boundaries[index + 1])
            if hi <= lo:
                continue
            block = torch.from_numpy(bundle["features"][lo:hi]).T.unsqueeze(0)
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
    return {"mcc": point, "ci_low": float(low), "ci_high": float(high)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--epochs", type=int, default=6)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--weight", type=float, default=14.5)
    parser.add_argument("--draws", type=int, default=2000)
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()

    print("  loading one-hot training data ...", flush=True)
    bundle = load_onehot("train")
    chain = bundle["chain"]
    boundaries = np.searchsorted(chain, np.arange(chain[-1] + 2))
    total = len(boundaries) - 2

    rng = np.random.default_rng(args.seed)
    order = rng.permutation(total)
    cut = int(len(order) * 0.9)
    train_indices, validation_indices = order[:cut], order[cut:]
    print(f"  {len(train_indices):,} training chains, "
          f"{len(validation_indices):,} for threshold tuning\n")

    torch.manual_seed(args.seed)
    head = OneHotHead()
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
        print(f"    epoch {epoch:>2}: loss {running / max(count, 1):.4f}", flush=True)

    threshold = tune_threshold(
        head, bundle, boundaries, validation_indices, args.batch_size)
    print(f"    threshold {threshold:.2f}\n")

    # The embedding arm's numbers, from the paired experiment that used the same
    # architecture, schedule and seed. Quoted rather than recomputed so the two
    # are comparable by construction.
    embedding = {"cb513": 0.426, "ts115": 0.643, "casp12": 0.515}

    summary = {}
    print("--- same head, one-hot input against frozen ESM-2 embeddings ---")
    for name in ["cb513", "ts115", "casp12"]:
        measured = evaluate(head, name, threshold, args.draws, np.random.default_rng(1))
        gain = embedding[name] - measured["mcc"]
        print(f"  {name}: one-hot {measured['mcc']:.3f} "
              f"[{measured['ci_low']:.3f}, {measured['ci_high']:.3f}]  "
              f"embeddings {embedding[name]:.3f}  "
              f"(embedding gain {gain:+.3f})  "
              f"NetSurfP one-hot {ONE_HOT_FLOOR[name]:.3f}")
        summary[name] = {
            "our_onehot_mcc": measured["mcc"],
            "our_onehot_ci": [measured["ci_low"], measured["ci_high"]],
            "our_embedding_mcc": embedding[name],
            "embedding_gain": gain,
            "netsurfp_onehot": ONE_HOT_FLOOR[name],
        }

    OUT.mkdir(exist_ok=True)
    (OUT / "disorder_onehot_control.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"\nwrote {(OUT / 'disorder_onehot_control.json').relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
