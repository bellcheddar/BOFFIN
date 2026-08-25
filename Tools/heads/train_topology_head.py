#!/usr/bin/env python3
"""Train the transmembrane and signal-peptide head.

    Tools/coreml/.venv/bin/python Tools/heads/train_topology_head.py

Reads `Datasets/embeddings/topology.npz`, writes `Models/heads/topology.pt`.

Per-residue accuracy is the wrong headline
------------------------------------------
Most residues of most proteins are outside the membrane, so a head that predicts
"outside" everywhere scores well over 80% and is useless. The numbers reported
here are therefore per-class, plus SPAN-level agreement, because what the
Boundary tab needs is not "is residue 212 in the membrane" but "where does this
helix start and end", and a construct cut three residues inside a TM helix is
just as dead as one cut in the middle of it.

Two evaluations, not one
------------------------
Swiss-Prot TRANSMEM features are a mixture of experimental determination and
curated inference, and only about 18% carry experimental evidence. Grading only
against everything measures agreement with the curators' inference as much as
with the membrane. So the test split is scored twice: over all entries, and over
the subset whose spans are experimentally evidenced. Where those disagree, the
experimental number is the one to believe.

Split by entry, never by residue: residues of one protein are not independent.
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
DATA = ROOT / "Datasets/embeddings"
TOPOLOGY = ROOT / "Datasets/topology"
MODELS = ROOT / "Models/heads"

EMBED_WIDTH = 480
LABEL_NAMES = ["outside", "transmembrane", "signal"]
MASKED = -1


class TopologyHead(nn.Module):
    """Dilated 1D convolutions, one dilation deeper than the other heads.

    Secondary structure needs to see a helix turn; a transmembrane span needs to
    be told apart from a buried hydrophobic core, and that judgement depends on
    what is on either side of it. Kernel 5 at dilations 1, 2, 4 and 8 sees 57
    residues, comfortably more than a 20-residue helix plus its flanks.
    """

    def __init__(self, classes: int = 3, width: int = 128, dropout: float = 0.2):
        super().__init__()
        self.project = nn.Conv1d(EMBED_WIDTH, width, kernel_size=1)
        self.blocks = nn.ModuleList([
            nn.Conv1d(width, width, kernel_size=5, padding=d * 2, dilation=d)
            for d in (1, 2, 4, 8)
        ])
        self.norms = nn.ModuleList([nn.BatchNorm1d(width) for _ in range(4)])
        self.dropout = nn.Dropout(dropout)
        self.output = nn.Conv1d(width, classes, kernel_size=1)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        h = F.gelu(self.project(x))
        for block, norm in zip(self.blocks, self.norms):
            h = h + self.dropout(F.gelu(norm(block(h))))
        return self.output(h)


def spans_from(labels: np.ndarray, value: int) -> list[tuple[int, int]]:
    """Contiguous runs of one label, as zero-based inclusive ranges."""
    runs, start = [], None
    for index, label in enumerate(labels):
        if label == value and start is None:
            start = index
        elif label != value and start is not None:
            runs.append((start, index - 1))
            start = None
    if start is not None:
        runs.append((start, len(labels) - 1))
    return runs


def span_agreement(
    true: np.ndarray, predicted: np.ndarray, value: int, tolerance: int = 5
) -> tuple[int, int, int]:
    """Matched, expected and predicted span counts for one label.

    A predicted span matches a true one when both boundaries land within
    `tolerance` residues. Five is the tolerance the transmembrane literature
    uses, and it is generous for construct design: a cut five residues inside a
    helix is still a cut inside the helix.
    """
    expected = spans_from(true, value)
    found = spans_from(predicted, value)
    used = set()
    matched = 0
    for start, end in expected:
        for index, (s, e) in enumerate(found):
            if index in used:
                continue
            if abs(s - start) <= tolerance and abs(e - end) <= tolerance:
                used.add(index)
                matched += 1
                break
    return matched, len(expected), len(found)


def evaluate(head, bundle, boundaries, indices, device, batch_size, tolerance=5):
    head.eval()
    confusion = np.zeros((len(LABEL_NAMES), len(LABEL_NAMES)), dtype=np.int64)
    spanMatched = spanExpected = spanPredicted = 0
    correctCount = 0

    with torch.no_grad():
        for offset in range(0, len(indices), batch_size):
            chunk = indices[offset : offset + batch_size]
            for index in chunk:
                start, end = boundaries[index]
                x = torch.from_numpy(
                    bundle["hidden"][start:end].astype(np.float32)
                ).T.unsqueeze(0).to(device)
                logits = head(x)[0].argmax(0).cpu().numpy()
                truth = bundle["label"][start:end]

                keep = truth >= 0
                for t, p in zip(truth[keep], logits[keep]):
                    confusion[t, p] += 1

                matched, expected, predicted = span_agreement(
                    truth, logits, 1, tolerance)
                spanMatched += matched
                spanExpected += expected
                spanPredicted += predicted
                if matched == expected == predicted:
                    correctCount += 1

    return confusion, spanMatched, spanExpected, spanPredicted, correctCount


def report(name, confusion, matched, expected, predicted, exactChains, chains):
    print(f"\n--- {name} ---")
    total = confusion.sum()
    print(f"  per-residue accuracy : {np.trace(confusion) / max(total, 1):.4f}")
    for index, label in enumerate(LABEL_NAMES):
        support = confusion[index].sum()
        recall = confusion[index, index] / max(support, 1)
        precision = confusion[index, index] / max(confusion[:, index].sum(), 1)
        f1 = 2 * precision * recall / max(precision + recall, 1e-9)
        print(f"  {label:<15} recall {recall:.3f}  precision {precision:.3f}  "
              f"F1 {f1:.3f}  (n={support:,})")
    print(f"  TM span recall       : {matched / max(expected, 1):.4f} "
          f"({matched:,} of {expected:,})")
    print(f"  TM span precision    : {matched / max(predicted, 1):.4f} "
          f"({matched:,} of {predicted:,})")
    print(f"  chains with EVERY span right: {exactChains / max(chains, 1):.4f} "
          f"({exactChains:,} of {chains:,})")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--epochs", type=int, default=14)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument("--width", type=int, default=128)
    parser.add_argument("--device", default="cpu", choices=["cpu", "mps"])
    args = parser.parse_args()

    path = DATA / "topology.npz"
    if not path.exists():
        print(f"missing {path}: run embed_topology.py first")
        return 1

    # Materialised, not lazily indexed: see embed_topology.py's closing note.
    raw = np.load(path, allow_pickle=True)
    bundle = {
        "hidden": raw["hidden"],
        "label": raw["label"],
    }
    boundaries = raw["boundaries"]
    accessions = list(raw["accessions"])
    entries = json.loads((TOPOLOGY / "train.json").read_text())
    print(f"{len(boundaries):,} chains, {len(bundle['label']):,} residues")

    rng = np.random.default_rng(0)
    order = rng.permutation(len(boundaries))
    trainEnd = int(len(order) * 0.85)
    trainIndices, testIndices = order[:trainEnd], order[trainEnd:]
    print(f"  train {len(trainIndices):,} chains, test {len(testIndices):,}")

    # The subset of test chains whose TRANSMEM spans are experimentally
    # evidenced, scored separately: see the module docstring.
    byAccession = {e["accession"]: e for e in entries}
    experimental = np.array([
        index for index in testIndices
        if any(s[2] == "experimental"
               for s in byAccession.get(accessions[index], {}).get("transmem", []))
    ])
    print(f"  of those, {len(experimental):,} have experimental TRANSMEM evidence")

    device = torch.device(args.device)
    head = TopologyHead(width=args.width).to(device)
    parameters = sum(p.numel() for p in head.parameters())
    print(f"head parameters: {parameters:,} ({parameters * 2 / 1e6:.2f} MB at fp16)")

    # Class weights from the training split. Transmembrane residues are a small
    # minority and an unweighted loss simply learns to say "outside".
    counts = np.bincount(
        bundle["label"][bundle["label"] >= 0], minlength=len(LABEL_NAMES))
    weights = torch.tensor(
        (counts.sum() / np.maximum(counts, 1)) ** 0.5, dtype=torch.float32).to(device)
    weights /= weights.mean()
    print("class weights:", {n: round(float(w), 2) for n, w in zip(LABEL_NAMES, weights)})

    optimiser = torch.optim.AdamW(head.parameters(), lr=args.learning_rate, weight_decay=0.01)
    schedule = torch.optim.lr_scheduler.CosineAnnealingLR(optimiser, T_max=args.epochs)

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
                    bundle["hidden"][start:end].astype(np.float32)
                ).T.unsqueeze(0).to(device)
                y = torch.from_numpy(bundle["label"][start:end]).unsqueeze(0).to(device)
                loss = loss + F.cross_entropy(
                    head(x), y, weight=weights, ignore_index=MASKED)
            loss = loss / len(chunk)
            loss.backward()
            optimiser.step()
            running += float(loss)
            seen += 1
        schedule.step()
        print(f"  epoch {epoch:>3}: loss {running / max(seen, 1):.4f}")

    confusion, matched, expected, predicted, exact = evaluate(
        head, bundle, boundaries, testIndices, device, args.batch_size)
    report("held-out test, all entries", confusion, matched, expected, predicted,
           exact, len(testIndices))

    if len(experimental):
        confusion2, matched2, expected2, predicted2, exact2 = evaluate(
            head, bundle, boundaries, experimental, device, args.batch_size)
        report("held-out test, EXPERIMENTAL evidence only", confusion2, matched2,
               expected2, predicted2, exact2, len(experimental))

    MODELS.mkdir(parents=True, exist_ok=True)
    torch.save(head.state_dict(), MODELS / "topology.pt")
    (MODELS / "topology_metrics.json").write_text(json.dumps({
        "labels": LABEL_NAMES,
        "width": args.width,
        "span_recall": matched / max(expected, 1),
        "span_precision": matched / max(predicted, 1),
        "chains_fully_correct": exact / max(len(testIndices), 1),
        "test_chains": int(len(testIndices)),
        "experimental_chains": int(len(experimental)),
    }, indent=2) + "\n")
    print(f"\nwrote {(MODELS / 'topology.pt').relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
