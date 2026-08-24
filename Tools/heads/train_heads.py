#!/usr/bin/env python3
"""Train the Order tab's analysis heads on frozen ESM-2 embeddings.

    Tools/coreml/.venv/bin/python Tools/heads/train_heads.py

Heads are deliberately small 1D convolutional stacks, per build plan section
4.1. Two constraints drive that shape and neither is negotiable:

* **Neural Engine residency.** Phase 2 measured 98.8% for the backbone. A
  recurrent head (which is what DeepTMHMM and NetSurfP-3.0 both use) would fall
  off the ANE and forfeit it. Convolutions and pointwise layers do not.
* **Size.** Each head must be a few hundred kilobytes so heads can be updated
  without reshipping the 67 MB backbone.

Convolutions rather than a per-residue MLP because secondary structure is a
local property: whether a residue is in a helix depends on its neighbours, and
a head that sees one residue at a time cannot know. The receptive field is the
head's only source of context, since the backbone is frozen.

Reported metrics are the published ones for these benchmarks (Q3 and Q8
accuracy on CB513/TS115/CASP12, MCC for disorder), so the numbers can be
compared with the literature rather than only with each other.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

ROOT = Path(__file__).resolve().parents[2]
EMBEDDINGS = ROOT / "Datasets/embeddings"
MODELS = ROOT / "Models/heads"

Q8_NAMES = "GHIBESTC"
# G/H/I -> helix, B/E -> strand, S/T/C -> coil. The standard collapse.
Q8_TO_Q3 = np.array([0, 0, 0, 1, 1, 2, 2, 2], dtype=np.int64)
Q3_NAMES = "HEC"

EMBED_WIDTH = 480


class ConvHead(nn.Module):
    """A small dilated 1D convolutional stack over frozen embeddings.

    Dilation widens the receptive field without adding depth or parameters:
    kernel 5 at dilations 1, 2 and 4 sees 25 residues, which comfortably spans a
    helix turn or a strand pairing, for a head that is still a few hundred KB.
    """

    def __init__(self, classes: int, width: int = 128, dropout: float = 0.2):
        super().__init__()
        self.project = nn.Conv1d(EMBED_WIDTH, width, kernel_size=1)
        self.block1 = nn.Conv1d(width, width, kernel_size=5, padding=2, dilation=1)
        self.block2 = nn.Conv1d(width, width, kernel_size=5, padding=4, dilation=2)
        self.block3 = nn.Conv1d(width, width, kernel_size=5, padding=8, dilation=4)
        self.norm1 = nn.BatchNorm1d(width)
        self.norm2 = nn.BatchNorm1d(width)
        self.norm3 = nn.BatchNorm1d(width)
        self.dropout = nn.Dropout(dropout)
        self.output = nn.Conv1d(width, classes, kernel_size=1)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: (batch, EMBED_WIDTH, length)
        h = F.gelu(self.project(x))
        h = h + self.dropout(F.gelu(self.norm1(self.block1(h))))
        h = h + self.dropout(F.gelu(self.norm2(self.block2(h))))
        h = h + self.dropout(F.gelu(self.norm3(self.block3(h))))
        return self.output(h)


def load_split(name: str):
    """Load a split fully into memory.

    `np.load` on a compressed .npz returns a LAZY handle, and every indexing
    operation decompresses the whole array again. Slicing it per chain inside
    the training loop cost 6.8 seconds per access here, which is roughly 20
    hours per epoch of pure zlib for a job whose actual arithmetic takes
    minutes. Materialise once.
    """
    path = EMBEDDINGS / f"{name}.npz"
    if not path.exists():
        raise SystemExit(f"missing {path}: run extract_embeddings.py --split {name}")

    handle = np.load(path)
    print(f"  loading {name} into memory ...", end="", flush=True)
    bundle = {key: handle[key] for key in handle.files}
    size = sum(a.nbytes for a in bundle.values()) / 1e9
    print(f" {size:.2f} GB")

    chain = bundle["chain"]
    boundaries = np.searchsorted(chain, np.arange(chain[-1] + 2))
    return bundle, boundaries


def batches(bundle, boundaries, indices, batch_size, device, shuffle=False):
    """Yield padded (embeddings, labels, mask) batches, grouped by length."""
    order = list(indices)
    lengths = {i: boundaries[i + 1] - boundaries[i] for i in order}
    order.sort(key=lambda i: lengths[i])
    if shuffle:
        # Shuffle in length-sorted blocks: keeps padding low while still
        # varying batch composition between epochs.
        blocks = [order[i : i + batch_size] for i in range(0, len(order), batch_size)]
        rng = np.random.default_rng(0)
        rng.shuffle(blocks)
        order = [i for block in blocks for i in block]

    for start in range(0, len(order), batch_size):
        group = order[start : start + batch_size]
        longest = max(lengths[i] for i in group)
        x = np.zeros((len(group), longest, EMBED_WIDTH), dtype=np.float32)
        q8 = np.full((len(group), longest), -100, dtype=np.int64)
        ordered = np.full((len(group), longest), -100, dtype=np.int64)
        mask = np.zeros((len(group), longest), dtype=bool)

        for row, index in enumerate(group):
            lo, hi = boundaries[index], boundaries[index + 1]
            n = hi - lo
            x[row, :n] = bundle["embeddings"][lo:hi].astype(np.float32)
            q8[row, :n] = bundle["q8"][lo:hi]
            ordered[row, :n] = bundle["ordered"][lo:hi]
            mask[row, :n] = True

        yield (
            torch.from_numpy(x).permute(0, 2, 1).to(device),
            torch.from_numpy(q8).to(device),
            torch.from_numpy(ordered).to(device),
            torch.from_numpy(mask).to(device),
        )


def tune_threshold(disorder_head, bundle, boundaries, indices, device, batch_size):
    """Pick the decision threshold that maximises MCC on VALIDATION data.

    MCC is threshold-sensitive and argmax is an arbitrary operating point,
    especially with a class weight of 14.5 pulling the logits around. Measured
    here: argmax gave 0.527 on TS115 where a swept threshold reached 0.631.

    Tuned on validation and applied blind to the test sets. Sweeping on the test
    set itself, which is the tempting shortcut, produces an upper bound that
    cannot be reproduced on new data.
    """
    disorder_head.eval()
    probabilities, truth = [], []
    with torch.no_grad():
        for x, _, ordered, mask in batches(
            bundle, boundaries, indices, batch_size, device
        ):
            p = F.softmax(disorder_head(x), dim=1)[:, 0]
            probabilities.append(p[mask].cpu().numpy())
            truth.append((ordered[mask] == 0).cpu().numpy())

    p = np.concatenate(probabilities)
    y = np.concatenate(truth)

    best_threshold, best_mcc = 0.5, -1.0
    for candidate in np.arange(0.05, 0.96, 0.025):
        predicted = p > candidate
        tp = int((predicted & y).sum())
        tn = int((~predicted & ~y).sum())
        fp = int((predicted & ~y).sum())
        fn = int((~predicted & y).sum())
        denominator = np.sqrt(float(tp + fp) * (tp + fn) * (tn + fp) * (tn + fn))
        mcc = ((tp * tn - fp * fn) / denominator) if denominator > 0 else 0.0
        if mcc > best_mcc:
            best_mcc, best_threshold = mcc, float(candidate)
    return best_threshold


def evaluate(
    ss_head, disorder_head, bundle, boundaries, indices, device, batch_size,
    threshold: float = 0.5,
):
    ss_head.eval()
    disorder_head.eval()
    q8_correct = q3_correct = total = 0
    tp = tn = fp = fn = 0

    with torch.no_grad():
        for x, q8, ordered, mask in batches(
            bundle, boundaries, indices, batch_size, device
        ):
            predicted_q8 = ss_head(x).argmax(dim=1)
            valid = mask
            q8_correct += ((predicted_q8 == q8) & valid).sum().item()
            total += valid.sum().item()

            q3_map = torch.from_numpy(Q8_TO_Q3).to(device)
            q3_correct += (
                (q3_map[predicted_q8.clamp(min=0)] == q3_map[q8.clamp(min=0)]) & valid
            ).sum().item()

            # Disorder: positive class is DISORDERED, which is the rare one, so
            # accuracy would be meaningless and MCC is reported instead.
            disorder_probability = F.softmax(disorder_head(x), dim=1)[:, 0]
            is_disordered = (ordered == 0) & valid
            said_disordered = (disorder_probability > threshold) & valid
            tp += (is_disordered & said_disordered).sum().item()
            fn += (is_disordered & ~said_disordered).sum().item()
            fp += (~is_disordered & said_disordered & valid).sum().item()
            tn += (~is_disordered & ~said_disordered & valid).sum().item()

    denominator = np.sqrt(float(tp + fp) * (tp + fn) * (tn + fp) * (tn + fn))
    mcc = ((tp * tn - fp * fn) / denominator) if denominator > 0 else 0.0
    return {
        "q8_accuracy": q8_correct / total if total else 0.0,
        "q3_accuracy": q3_correct / total if total else 0.0,
        "disorder_mcc": mcc,
        "disorder_positives": tp + fn,
        "residues": total,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--epochs", type=int, default=12)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument("--width", type=int, default=128)
    parser.add_argument("--device", default="cpu", choices=["cpu", "mps"])
    parser.add_argument("--validation-fraction", type=float, default=0.05)
    args = parser.parse_args()

    device = torch.device(args.device)
    torch.manual_seed(0)

    train_bundle, train_boundaries = load_split("train")
    chains = int(train_bundle["chain"][-1]) + 1
    rng = np.random.default_rng(0)
    shuffled = rng.permutation(chains)
    split = int(chains * (1 - args.validation_fraction))
    train_indices, validation_indices = shuffled[:split], shuffled[split:]
    print(f"train: {len(train_indices)} chains, validation: {len(validation_indices)}")

    ss_head = ConvHead(classes=8, width=args.width).to(device)
    disorder_head = ConvHead(classes=2, width=args.width).to(device)

    parameters = list(ss_head.parameters()) + list(disorder_head.parameters())
    total_parameters = sum(p.numel() for p in parameters)
    print(f"head parameters: {total_parameters:,} "
          f"({total_parameters * 2 / 1e6:.2f} MB at fp16, both heads)")

    optimiser = torch.optim.AdamW(parameters, lr=args.learning_rate, weight_decay=0.01)
    schedule = torch.optim.lr_scheduler.CosineAnnealingLR(optimiser, T_max=args.epochs)

    # Disorder is heavily imbalanced. Without a class weight the head learns to
    # answer "ordered" everywhere, which scores well on accuracy and has an MCC
    # of zero: a confident, useless predictor.
    ordered_counts = np.bincount(train_bundle["ordered"], minlength=2)
    disorder_weight = torch.tensor(
        [ordered_counts[1] / max(ordered_counts[0], 1), 1.0], dtype=torch.float32
    ).to(device)
    print(f"disorder class balance: {ordered_counts[0]:,} disordered, "
          f"{ordered_counts[1]:,} ordered (weight {disorder_weight[0]:.1f})")

    # Each head is checkpointed on the metric that head is FOR. Selecting both
    # on Q3 (as the first version did) saves the disorder head at whichever
    # epoch happened to be best for secondary structure, which is unrelated to
    # whether it is best at finding disorder: here its MCC peaked at epoch 9 and
    # drifted afterwards, and the saved weights were chosen without reference to
    # that.
    best = {"secondary_structure": -1.0, "disorder": -1.0}
    for epoch in range(1, args.epochs + 1):
        ss_head.train()
        disorder_head.train()
        running = count = 0
        for x, q8, ordered, mask in batches(
            train_bundle, train_boundaries, train_indices,
            args.batch_size, device, shuffle=True
        ):
            optimiser.zero_grad()
            ss_loss = F.cross_entropy(ss_head(x), q8, ignore_index=-100)
            disorder_loss = F.cross_entropy(
                disorder_head(x), ordered, ignore_index=-100, weight=disorder_weight)
            loss = ss_loss + disorder_loss
            loss.backward()
            torch.nn.utils.clip_grad_norm_(parameters, 1.0)
            optimiser.step()
            running += loss.item()
            count += 1
            print(f"\r  epoch {epoch}: {count} batches, loss {running / count:.4f}",
                  end="", flush=True)
        schedule.step()
        print()

        metrics = evaluate(
            ss_head, disorder_head, train_bundle, train_boundaries,
            validation_indices, device, args.batch_size)
        print(f"    validation  Q3 {metrics['q3_accuracy']:.4f}  "
              f"Q8 {metrics['q8_accuracy']:.4f}  disorder MCC {metrics['disorder_mcc']:.4f}")

        MODELS.mkdir(parents=True, exist_ok=True)
        saved = []
        if metrics["q3_accuracy"] > best["secondary_structure"]:
            best["secondary_structure"] = metrics["q3_accuracy"]
            torch.save(ss_head.state_dict(), MODELS / "secondary_structure.pt")
            saved.append(f"SS (Q3 {metrics['q3_accuracy']:.4f})")
        if metrics["disorder_mcc"] > best["disorder"]:
            best["disorder"] = metrics["disorder_mcc"]
            torch.save(disorder_head.state_dict(), MODELS / "disorder.pt")
            # The decision threshold is tuned on VALIDATION and stored with the
            # weights. Tuning it on the test set, which is the tempting version,
            # reports an upper bound rather than a result.
            threshold = tune_threshold(
                disorder_head, train_bundle, train_boundaries,
                validation_indices, device, args.batch_size)
            best["disorder_threshold"] = threshold
            saved.append(
                f"disorder (MCC {metrics['disorder_mcc']:.4f}, threshold {threshold:.3f})")
        if saved:
            print(f"    (saved: {', '.join(saved)})")

        (MODELS / "config.json").write_text(json.dumps({
            "embed_width": EMBED_WIDTH,
            "head_width": args.width,
            "q8_names": Q8_NAMES,
            "q3_names": Q3_NAMES,
            "backbone": "esm2_t12_35M_UR50D",
            "best_q3": best["secondary_structure"],
            "best_disorder_mcc": best["disorder"],
            "disorder_threshold": best.get("disorder_threshold", 0.5),
        }, indent=2) + "\n")

    # Reload the saved checkpoints. The first version benchmarked whatever was
    # in memory after the last epoch, which is NOT what was written to disk, so
    # the published numbers described weights nobody could load.
    ss_head.load_state_dict(torch.load(MODELS / "secondary_structure.pt", map_location=device))
    disorder_head.load_state_dict(torch.load(MODELS / "disorder.pt", map_location=device))
    threshold = best.get("disorder_threshold", 0.5)
    print(f"\n--- held-out benchmarks (saved checkpoints, "
          f"disorder threshold {threshold:.3f} tuned on validation) ---")
    results = {}
    for split in ("cb513", "ts115", "casp12"):
        path = EMBEDDINGS / f"{split}.npz"
        if not path.exists():
            print(f"  {split}: not extracted, skipped")
            continue
        bundle, boundaries = load_split(split)
        count = int(bundle["chain"][-1]) + 1
        metrics = evaluate(
            ss_head, disorder_head, bundle, boundaries,
            range(count), device, args.batch_size, threshold=threshold)
        results[split] = metrics
        print(f"  {split:>7}: Q3 {metrics['q3_accuracy']:.4f}  "
              f"Q8 {metrics['q8_accuracy']:.4f}  "
              f"disorder MCC {metrics['disorder_mcc']:.4f}  "
              f"({metrics['residues']:,} residues)")

    (MODELS / "benchmarks.json").write_text(json.dumps(results, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
