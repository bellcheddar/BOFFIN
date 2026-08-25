#!/usr/bin/env python3
"""Train the disorder and three-state secondary-structure heads on CC0 labels.

    Tools/coreml/.venv/bin/python Tools/heads/train_pdblabels_heads.py

Reads `Datasets/embeddings/pdblabels.npz`, writes `Models/heads/disorder_cc0.pt`
and `Models/heads/secondary_structure_q3_cc0.pt`.

Why these exist beside the heads that already work
--------------------------------------------------
The shipped disorder and secondary-structure heads are trained on NetSurfP's
distributions of CB513, TS115 and CASP12, whose download pages state no terms.
That has blocked release since Phase 3. These are trained on labels derived from
the PDB, which is CC0, so they can actually ship.

The comparison is the point, and it is not a formality: if the CC0 heads are
markedly worse then the honest choice is to ship worse heads or to ship nothing,
and either way the numbers have to be on the table. They are measured on a
held-out split of the SAME source, so they are not directly comparable to the
published CB513 figures, and the report says so rather than putting them in one
column.

What this replaces and what it does not
---------------------------------------
Disorder: replaced entirely. "Present in SEQRES and absent from the coordinates"
is the same definition NetSurfP uses.

Secondary structure: replaced at THREE states only. `_struct_conf` and
`_struct_sheet_range` are the assignments deposited with the entry; eight-state
needs DSSP run over the coordinates, which is a hydrogen-bond calculation
nothing here does. The Q8 head remains NetSurfP-derived and remains blocked.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "Datasets/embeddings"
MODELS = ROOT / "Models/heads"
MASKED = -1


def report(name: str, confusion: np.ndarray, names: list[str]) -> dict:
    total = confusion.sum()
    accuracy = np.trace(confusion) / max(total, 1)
    print(f"\n--- {name} ---")
    print(f"  accuracy {accuracy:.4f}  ({total:,} residues)")
    perClass = {}
    for index, label in enumerate(names):
        support = confusion[index].sum()
        recall = confusion[index, index] / max(support, 1)
        precision = confusion[index, index] / max(confusion[:, index].sum(), 1)
        f1 = 2 * precision * recall / max(precision + recall, 1e-9)
        print(f"  {label:<12} recall {recall:.3f}  precision {precision:.3f}  "
              f"F1 {f1:.3f}  (n={support:,})")
        perClass[label] = {"recall": float(recall), "precision": float(precision)}

    # Matthews correlation for the two-class case, which is the number the
    # disorder literature quotes and the one accuracy flatters most: disorder is
    # about 6% of residues, so predicting "ordered" everywhere scores 0.94.
    matthews = None
    if len(names) == 2:
        tn, fp, fn, tp = confusion[0, 0], confusion[0, 1], confusion[1, 0], confusion[1, 1]
        denominator = np.sqrt(
            float(tp + fp) * float(tp + fn) * float(tn + fp) * float(tn + fn))
        matthews = float((tp * tn - fp * fn) / denominator) if denominator > 0 else 0.0
        print(f"  Matthews correlation {matthews:.4f}")
        print(f"  (predicting the majority class everywhere scores "
              f"{confusion[0].sum() / max(total,1):.4f} accuracy and 0 MCC)")
    return {"accuracy": float(accuracy), "per_class": perClass, "mcc": matthews}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--epochs", type=int, default=12)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument("--width", type=int, default=128)
    args = parser.parse_args()

    path = DATA / "pdblabels.npz"
    if not path.exists():
        print(f"missing {path}: run embed_pdblabels.py first")
        return 1

    import sys

    sys.path.insert(0, str(ROOT / "Tools/heads"))
    from train_heads import ConvHead

    raw = np.load(path, allow_pickle=True)
    hidden = raw["hidden"]
    boundaries = raw["boundaries"]
    accessions = list(raw["accessions"])
    print(f"{len(boundaries):,} chains, {len(hidden):,} residues")

    # Split by ACCESSION, not by chain. Two chains of the same protein in
    # different entries are the same sequence, and splitting by chain puts a
    # protein in both halves: the test score then measures memorisation.
    unique = sorted(set(accessions))
    rng = np.random.default_rng(0)
    order = rng.permutation(len(unique))
    trainAccessions = {unique[i] for i in order[: int(len(unique) * 0.85)]}
    trainIndices = [i for i, a in enumerate(accessions) if a in trainAccessions]
    testIndices = [i for i, a in enumerate(accessions) if a not in trainAccessions]
    print(f"  {len(unique):,} distinct accessions; "
          f"train {len(trainIndices):,} chains, test {len(testIndices):,}")

    device = torch.device("cpu")
    metrics = {}

    for task, names in (
        ("disorder", ["ordered", "disordered"]),
        ("structure", ["helix", "strand", "coil"]),
    ):
        labels = raw[task]
        head = ConvHead(classes=len(names), width=args.width).to(device)
        counts = np.bincount(labels[labels >= 0], minlength=len(names))
        weights = torch.tensor(
            (counts.sum() / np.maximum(counts, 1)) ** 0.5, dtype=torch.float32)
        weights /= weights.mean()
        print(f"\n{task}: class weights "
              f"{ {n: round(float(w), 2) for n, w in zip(names, weights)} }")

        optimiser = torch.optim.AdamW(
            head.parameters(), lr=args.learning_rate, weight_decay=0.01)
        schedule = torch.optim.lr_scheduler.CosineAnnealingLR(
            optimiser, T_max=args.epochs)

        for epoch in range(1, args.epochs + 1):
            head.train()
            shuffled = rng.permutation(trainIndices)
            running, seen = 0.0, 0
            for offset in range(0, len(shuffled), args.batch_size):
                chunk = shuffled[offset : offset + args.batch_size]
                optimiser.zero_grad()
                loss = torch.zeros((), device=device)
                for index in chunk:
                    start, end = boundaries[index]
                    x = torch.from_numpy(
                        hidden[start:end].astype(np.float32)).T.unsqueeze(0)
                    y = torch.from_numpy(labels[start:end]).unsqueeze(0)
                    loss = loss + F.cross_entropy(
                        head(x), y, weight=weights, ignore_index=MASKED)
                (loss / len(chunk)).backward()
                optimiser.step()
                running += float(loss) / len(chunk)
                seen += 1
            schedule.step()
            if epoch % 3 == 0 or epoch == args.epochs:
                print(f"  epoch {epoch:>3}: loss {running / max(seen,1):.4f}")

        head.eval()
        confusion = np.zeros((len(names), len(names)), dtype=np.int64)
        with torch.no_grad():
            for index in testIndices:
                start, end = boundaries[index]
                x = torch.from_numpy(
                    hidden[start:end].astype(np.float32)).T.unsqueeze(0)
                predicted = head(x)[0].argmax(0).numpy()
                truth = labels[start:end]
                keep = truth >= 0
                for t, p in zip(truth[keep], predicted[keep]):
                    confusion[t, p] += 1

        metrics[task] = report(f"{task}, held out by accession", confusion, names)
        MODELS.mkdir(parents=True, exist_ok=True)
        name = "disorder_cc0" if task == "disorder" else "secondary_structure_q3_cc0"
        torch.save(head.state_dict(), MODELS / f"{name}.pt")
        print(f"  wrote Models/heads/{name}.pt")

    (MODELS / "cc0_metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
