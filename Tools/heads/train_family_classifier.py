#!/usr/bin/env python3
"""Train the family classifier over pooled ESM-2 embeddings.

    Tools/coreml/.venv/bin/python Tools/heads/train_family_classifier.py

Writes Models/heads/family.pt and family_labels.json.

Invariant 1's third fan-out: the mean-pooled embedding drives family
classification and homolog search, from the same forward pass that produced the
per-residue tracks and the masked-token logits.

Calibration, not just accuracy
------------------------------
The build plan's risk register names family classifier over-confidence as a
medium risk, and the mitigation as calibrated confidence with an explicit
low-confidence state. A softmax over 100 classes is not a probability: networks
trained with cross-entropy are systematically over-confident, so a 0.95 output
does not mean 95% of such calls are right.

Temperature scaling is fitted on a held-out split and the temperature is stored
with the weights, so the number the app shows has been checked against how often
the model is actually right. Expected calibration error is reported before and
after, because "we calibrated it" is not a measurement.
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
DATA = ROOT / "Datasets/pfam"
MODELS = ROOT / "Models/heads"
EMBED_WIDTH = 480


class FamilyHead(nn.Module):
    """A shallow MLP over the pooled embedding.

    Shallow on purpose. The backbone has already done the representation
    learning; a deep head on a frozen embedding mostly memorises the training
    families, and the whole point of this head is that it generalises to a
    protein the user pasted.
    """

    def __init__(self, classes: int, width: int = 512, dropout: float = 0.3):
        super().__init__()
        self.body = nn.Sequential(
            nn.Linear(EMBED_WIDTH, width),
            nn.GELU(),
            nn.Dropout(dropout),
            nn.Linear(width, width // 2),
            nn.GELU(),
            nn.Dropout(dropout),
        )
        self.output = nn.Linear(width // 2, classes)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.output(self.body(x))


def expected_calibration_error(probabilities, labels, bins: int = 15) -> float:
    """Expected calibration error: mean gap between confidence and accuracy.

    Predictions are bucketed by confidence; in each bucket the model's average
    confidence is compared with how often it was actually right. A perfectly
    calibrated model has zero gap. This is the number that says whether a
    displayed confidence means anything.
    """
    confidence = probabilities.max(axis=1)
    predicted = probabilities.argmax(axis=1)
    correct = (predicted == labels).astype(np.float64)

    edges = np.linspace(0, 1, bins + 1)
    error = 0.0
    for low, high in zip(edges[:-1], edges[1:]):
        mask = (confidence > low) & (confidence <= high)
        if not mask.any():
            continue
        error += mask.mean() * abs(correct[mask].mean() - confidence[mask].mean())
    return float(error)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--epochs", type=int, default=40)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    args = parser.parse_args()

    embeddings_path = DATA / "embeddings.npz"
    if not embeddings_path.exists():
        print(f"missing {embeddings_path}: run embed_pfam.py first")
        return 1

    bundle = np.load(embeddings_path, allow_pickle=True)
    X = bundle["embeddings"].astype(np.float32)
    y = bundle["label"].astype(np.int64)
    labels = list(bundle["families"])
    print(f"{len(X):,} sequences, {len(labels)} families, {X.shape[1]}-d embeddings")

    rng = np.random.default_rng(0)
    order = rng.permutation(len(X))
    X, y = X[order], y[order]

    # Three splits, not two. The calibration temperature must be fitted on data
    # the head did not train on, and reported on data the temperature was not
    # fitted on, or the calibration error is measured on its own training set.
    n = len(X)
    trainEnd = int(n * 0.80)
    calibrateEnd = int(n * 0.90)
    splits = {
        "train": (X[:trainEnd], y[:trainEnd]),
        "calibrate": (X[trainEnd:calibrateEnd], y[trainEnd:calibrateEnd]),
        "test": (X[calibrateEnd:], y[calibrateEnd:]),
    }
    for name, (a, _) in splits.items():
        print(f"  {name}: {len(a):,}")

    device = torch.device("cpu")
    head = FamilyHead(classes=len(labels)).to(device)
    parameters = sum(p.numel() for p in head.parameters())
    print(f"head parameters: {parameters:,} ({parameters * 2 / 1e6:.2f} MB at fp16)")

    optimiser = torch.optim.AdamW(head.parameters(), lr=args.learning_rate, weight_decay=0.01)
    schedule = torch.optim.lr_scheduler.CosineAnnealingLR(optimiser, T_max=args.epochs)

    trainX = torch.from_numpy(splits["train"][0])
    trainY = torch.from_numpy(splits["train"][1])

    for epoch in range(1, args.epochs + 1):
        head.train()
        permutation = torch.randperm(len(trainX))
        running = 0.0
        batches = 0
        for start in range(0, len(trainX), args.batch_size):
            index = permutation[start : start + args.batch_size]
            optimiser.zero_grad()
            loss = F.cross_entropy(head(trainX[index]), trainY[index])
            loss.backward()
            optimiser.step()
            running += loss.item()
            batches += 1
        schedule.step()

        if epoch % 5 == 0 or epoch == args.epochs:
            head.eval()
            with torch.no_grad():
                logits = head(torch.from_numpy(splits["test"][0]))
                accuracy = (logits.argmax(1).numpy() == splits["test"][1]).mean()
            print(f"  epoch {epoch:>3}: loss {running / batches:.4f}  test top-1 {accuracy:.4f}")

    # Temperature scaling on the calibration split.
    head.eval()
    with torch.no_grad():
        calibrationLogits = head(torch.from_numpy(splits["calibrate"][0]))
    calibrationLabels = torch.from_numpy(splits["calibrate"][1])

    logTemperature = torch.zeros(1, requires_grad=True)
    temperatureOptimiser = torch.optim.LBFGS([logTemperature], lr=0.1, max_iter=100)

    def closure():
        temperatureOptimiser.zero_grad()
        loss = F.cross_entropy(
            calibrationLogits / logTemperature.exp(), calibrationLabels)
        loss.backward()
        return loss

    temperatureOptimiser.step(closure)
    fitted = float(logTemperature.exp().item())

    # Apply the temperature ONLY if it improves calibration, and decide that on
    # the calibration split rather than on test: choosing by test score is
    # fitting to the set the number is then reported on.
    #
    # Measured here, this head was already well calibrated (ECE 0.007) and
    # scaling made it slightly worse. Temperature scaling is a correction for
    # over-confidence, not a ritual, and applying it unconditionally would have
    # degraded a number the risk register specifically cares about.
    with torch.no_grad():
        calibrationProbabilities = F.softmax(calibrationLogits, dim=1).numpy()
        scaledProbabilities = F.softmax(calibrationLogits / fitted, dim=1).numpy()
    calibrationTruth = splits["calibrate"][1]
    eceRaw = expected_calibration_error(calibrationProbabilities, calibrationTruth)
    eceScaled = expected_calibration_error(scaledProbabilities, calibrationTruth)
    temperature = fitted if eceScaled < eceRaw else 1.0
    print(f"\n  temperature fitted {fitted:.4f}; calibration-split ECE "
          f"{eceRaw:.4f} raw against {eceScaled:.4f} scaled -> "
          f"{'applying' if temperature != 1.0 else 'NOT applying, the head is already calibrated'}")

    with torch.no_grad():
        testLogits = head(torch.from_numpy(splits["test"][0]))
        before = F.softmax(testLogits, dim=1).numpy()
        after = F.softmax(testLogits / temperature, dim=1).numpy()
    testLabels = splits["test"][1]

    top1 = float((testLogits.argmax(1).numpy() == testLabels).mean())
    top5 = float(
        np.mean([
            label in row
            for label, row in zip(testLabels, testLogits.topk(5, dim=1).indices.numpy())
        ]))
    eceBefore = expected_calibration_error(before, testLabels)
    eceAfter = expected_calibration_error(after, testLabels)

    print(f"\n--- held-out test ({len(testLabels):,} sequences, {len(labels)} families) ---")
    print(f"  top-1 accuracy : {top1:.4f}")
    print(f"  top-5 accuracy : {top5:.4f}")
    print(f"  temperature    : {temperature:.4f}")
    print(f"  calibration err: {eceBefore:.4f} before, {eceAfter:.4f} after")
    print(f"  random baseline: {1 / len(labels):.4f}")

    # Class centroids and the in-distribution similarity range, for the
    # out-of-distribution warning.
    #
    # This classifier is CLOSED SET: it can only answer with one of these
    # families, so a protein whose family is not among them is assigned the
    # nearest one, with high confidence. Measured: ubiquitin (Pfam PF00240, not
    # in the set) is called PF00076 at 79.7%. Confidence cannot detect that,
    # because the model genuinely is confident.
    #
    # Cosine similarity to the nearest class centroid is a partial signal and is
    # honestly a weak one: correctly-classified CDK2 sits at 0.829 while
    # misclassified ubiquitin sits at 0.864, so it does not separate the two.
    # It is stored anyway, with the in-distribution 5th percentile, so the app
    # can say "this sits outside the range the model was trained on" instead of
    # implying the family list is exhaustive.
    centroids = np.stack([
        X[y == index].mean(axis=0) for index in range(len(labels))
    ]).astype(np.float32)
    centroids /= np.linalg.norm(centroids, axis=1, keepdims=True)

    normalised = X / np.linalg.norm(X, axis=1, keepdims=True)
    nearest = (normalised @ centroids.T).max(axis=1)
    similarityFloor = float(np.percentile(nearest, 5))
    print(f"  in-distribution similarity: mean {nearest.mean():.3f}, "
          f"5th percentile {similarityFloor:.3f}")

    MODELS.mkdir(parents=True, exist_ok=True)
    np.save(MODELS / "family_centroids.npy", centroids)
    torch.save(head.state_dict(), MODELS / "family.pt")
    (MODELS / "family_labels.json").write_text(json.dumps({
        "families": labels,
        "temperature": temperature,
        "top1": top1,
        "top5": top5,
        "calibration_error": eceAfter,
        "embed_width": EMBED_WIDTH,
        "similarity_floor": similarityFloor,
        "closed_set": True,
    }, indent=2) + "\n")
    print(f"\nwrote {(MODELS / 'family.pt').relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
