#!/usr/bin/env python3
"""Can the family classifier tell when it is being shown something it has never seen?

    Tools/coreml/.venv/bin/python Tools/heads/openset_experiment.py

The problem, stated in the README and on screen in the app: the classifier is
CLOSED SET. It knows 100 families and must answer with one of them, so a protein
from a family it was never trained on is assigned the nearest one, confidently.
Measured: ubiquitin (PF00240, not in the set) is called PF00076 at 79.7%.

Confidence cannot detect that, because the model genuinely is confident.
Distance to the nearest class centroid was tried and is honestly weak:
correctly-classified CDK2 sits at 0.829 while misclassified ubiquitin sits at
0.864, so it does not separate the two.

That measurement was on ONE protein. Two proteins are an anecdote, and the
question deserves an experiment.

The experiment
--------------
Hold out whole FAMILIES, not sequences. Train on the rest. Then ask, of every
held-out sequence, whether any score would have rejected it, and of every
in-distribution test sequence, whether that same score would have wrongly
rejected it.

Holding out whole families is the entire point. A sequence-level split leaves
the held-out sequences' families in the training set, so the model has seen
their fold, their motifs and their neighbours, and "unknown" would mean nothing.

Scored by AUROC for known against unknown, which asks the only question that
matters: does the score rank unseen proteins above seen ones? 0.5 is chance.

Repeated over several random family splits, because 20 held-out families is a
small sample and one split can flatter or damn a method by which families
happened to fall in it.

Candidate scores
----------------
1. **Maximum softmax probability.** The naive baseline, and the one the app
   currently shows. Expected to be weak: cross-entropy training makes networks
   confident everywhere, including where they should not be.
2. **Maximum logit.** Softmax normalises away the overall magnitude of the
   response, which is exactly the part that might carry "none of these fit".
3. **Energy**, -logsumexp(logits). The principled version of the same idea
   (Liu et al., NeurIPS 2020), and a strictly better-behaved statistic than the
   maximum alone.
4. **Cosine to the nearest class centroid.** What was tried before, included so
   the comparison is like for like rather than remembered.
5. **Mahalanobis distance** to the nearest class, in the embedding space with a
   shared covariance (Lee et al., NeurIPS 2018). Uses the geometry of the
   embedding rather than the classifier's opinion of it.

Nothing here is a new idea. The contribution is measuring them on THIS
embedding, at THIS size, rather than assuming a published result transfers.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "Datasets/pfam"
OUT = ROOT / "Docs"

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from train_family_classifier import FamilyHead  # noqa: E402


def auroc(known: np.ndarray, unknown: np.ndarray) -> float:
    """Probability that a random unknown scores above a random known.

    Computed by rank rather than by sweeping thresholds: the rank form is exact,
    has no bin-width parameter to tune, and handles ties correctly, which
    matters because several of these scores saturate.
    """
    scores = np.concatenate([known, unknown])
    labels = np.concatenate([np.zeros(len(known)), np.ones(len(unknown))])
    order = np.argsort(scores, kind="mergesort")
    ranks = np.empty(len(scores), dtype=np.float64)
    ranks[order] = np.arange(1, len(scores) + 1)

    # Average ranks within tied groups, or a saturated score reports a spurious
    # separation created entirely by the sort's arbitrary order.
    sorted_scores = scores[order]
    start = 0
    for index in range(1, len(sorted_scores) + 1):
        if index == len(sorted_scores) or sorted_scores[index] != sorted_scores[start]:
            if index - start > 1:
                ranks[order[start:index]] = ranks[order[start:index]].mean()
            start = index

    positives = labels == 1
    n_pos = positives.sum()
    n_neg = len(labels) - n_pos
    if n_pos == 0 or n_neg == 0:
        return float("nan")
    return float((ranks[positives].sum() - n_pos * (n_pos + 1) / 2) / (n_pos * n_neg))


def mahalanobis_scores(
    train_x: np.ndarray, train_y: np.ndarray, classes: int, query: np.ndarray
) -> np.ndarray:
    """Distance to the nearest class mean under a shared covariance.

    Shared rather than per-class: with ~65 sequences per family and 480
    dimensions, a per-class covariance is wildly underdetermined and its inverse
    is noise. The shared estimate pools every class and is the form the original
    paper uses for exactly this reason.
    """
    means = np.stack([train_x[train_y == k].mean(axis=0) for k in range(classes)])
    centred = train_x - means[train_y]
    covariance = np.cov(centred, rowvar=False)
    # Ridge before inverting. The covariance of 6,500 points in 480 dimensions
    # is full rank in principle and badly conditioned in practice, and an
    # unregularised inverse turns that into large arbitrary numbers.
    covariance += np.eye(covariance.shape[0]) * 1e-3
    precision = np.linalg.pinv(covariance)

    # Whiten once with the matrix square root of the precision, after which the
    # Mahalanobis distance is an ordinary squared Euclidean distance. That turns
    # an n x k x d^2 einsum into two n x d matrix products and a distance
    # matrix, which is the difference between minutes and seconds here.
    eigenvalues, eigenvectors = np.linalg.eigh(precision)
    eigenvalues = np.clip(eigenvalues, 0, None)
    whitener = eigenvectors @ np.diag(np.sqrt(eigenvalues)) @ eigenvectors.T

    whitened_query = query @ whitener
    whitened_means = means @ whitener
    squared = (
        (whitened_query ** 2).sum(axis=1)[:, None]
        - 2 * whitened_query @ whitened_means.T
        + (whitened_means ** 2).sum(axis=1)[None, :])
    return squared.min(axis=1)


def run_split(
    X: np.ndarray, y: np.ndarray, families: list[str], rng: np.random.Generator,
    held_out: int, epochs: int
) -> dict[str, float]:
    classes = sorted(set(y.tolist()))
    unknown_families = set(rng.choice(classes, size=held_out, replace=False).tolist())
    known_families = [k for k in classes if k not in unknown_families]
    remap = {old: new for new, old in enumerate(known_families)}

    known_mask = np.array([label not in unknown_families for label in y])
    known_x, known_y = X[known_mask], np.array([remap[label] for label in y[known_mask]])
    unknown_x = X[~known_mask]

    # Split the KNOWN families into train and test by sequence. The test
    # sequences are in-distribution: the score must not reject them.
    order = rng.permutation(len(known_x))
    known_x, known_y = known_x[order], known_y[order]
    cut = int(len(known_x) * 0.85)
    train_x, train_y = known_x[:cut], known_y[:cut]
    test_x = known_x[cut:]

    head = FamilyHead(classes=len(known_families))
    optimiser = torch.optim.AdamW(head.parameters(), lr=1e-3, weight_decay=0.01)
    tx = torch.from_numpy(train_x.astype(np.float32))
    ty = torch.from_numpy(train_y)

    head.train()
    for _ in range(epochs):
        permutation = torch.randperm(len(tx))
        for start in range(0, len(tx), 128):
            index = permutation[start : start + 128]
            optimiser.zero_grad()
            F.cross_entropy(head(tx[index]), ty[index]).backward()
            optimiser.step()

    head.eval()
    with torch.no_grad():
        known_logits = head(torch.from_numpy(test_x.astype(np.float32)))
        unknown_logits = head(torch.from_numpy(unknown_x.astype(np.float32)))

    def as_numpy(t: torch.Tensor) -> np.ndarray:
        return t.detach().numpy().astype(np.float64)

    results: dict[str, float] = {}

    # Every score is oriented so that HIGHER means "more likely unknown", so the
    # AUROCs are directly comparable and a value below 0.5 means the score is
    # pointing the wrong way rather than merely being useless.
    results["max softmax"] = auroc(
        -as_numpy(F.softmax(known_logits, dim=1).max(dim=1).values),
        -as_numpy(F.softmax(unknown_logits, dim=1).max(dim=1).values))
    results["max logit"] = auroc(
        -as_numpy(known_logits.max(dim=1).values),
        -as_numpy(unknown_logits.max(dim=1).values))
    results["energy"] = auroc(
        -as_numpy(torch.logsumexp(known_logits, dim=1)),
        -as_numpy(torch.logsumexp(unknown_logits, dim=1)))

    centroids = np.stack([train_x[train_y == k].mean(axis=0) for k in range(len(known_families))])
    centroids /= np.linalg.norm(centroids, axis=1, keepdims=True)

    def nearest_cosine(batch: np.ndarray) -> np.ndarray:
        normalised = batch / np.linalg.norm(batch, axis=1, keepdims=True)
        return (normalised @ centroids.T).max(axis=1)

    results["centroid cosine"] = auroc(
        -nearest_cosine(test_x.astype(np.float64)),
        -nearest_cosine(unknown_x.astype(np.float64)))

    # Computed ONCE and reused below. The quadratic form is n x k x 480^2, so
    # for 1,500 points against 80 classes it is tens of billions of operations
    # and doing it twice per split turned a two-minute experiment into one that
    # had to be backgrounded.
    maha_known = mahalanobis_scores(
        train_x.astype(np.float64), train_y, len(known_families), test_x.astype(np.float64))
    maha_unknown = mahalanobis_scores(
        train_x.astype(np.float64), train_y, len(known_families), unknown_x.astype(np.float64))
    results["mahalanobis"] = auroc(maha_known, maha_unknown)

    # AUROC says the score RANKS unknowns above knowns. It does not say a
    # usable threshold exists, and a shipped feature needs a threshold. So the
    # operating point is reported too: holding the false-rejection rate on
    # in-distribution proteins at 5%, what fraction of genuinely unseen
    # families is caught?
    #
    # 5% is chosen from the cost of the two mistakes. Wrongly warning about a
    # protein the model does know costs a moment's doubt; silently naming a
    # family for a protein from outside the set is the failure this whole
    # experiment exists to prevent.
    def detection_rate(known_scores: np.ndarray, unknown_scores: np.ndarray) -> float:
        threshold = np.quantile(known_scores, 0.95)
        return float((unknown_scores > threshold).mean())

    results["_maha_detection_at_95"] = detection_rate(maha_known, maha_unknown)

    softmax_known = -as_numpy(F.softmax(known_logits, dim=1).max(dim=1).values)
    softmax_unknown = -as_numpy(F.softmax(unknown_logits, dim=1).max(dim=1).values)
    results["_softmax_detection_at_95"] = detection_rate(softmax_known, softmax_unknown)

    results["_known"] = float(len(test_x))
    results["_unknown"] = float(len(unknown_x))
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--held-out", type=int, default=20, help="families treated as unseen")
    parser.add_argument("--splits", type=int, default=5)
    parser.add_argument("--epochs", type=int, default=40)
    args = parser.parse_args()

    bundle = np.load(DATA / "embeddings.npz", allow_pickle=True)
    X = bundle["embeddings"].astype(np.float32)
    y = bundle["label"].astype(np.int64)
    families = list(bundle["families"])
    print(f"{len(X):,} sequences, {len(families)} families, {X.shape[1]}-d")
    print(f"holding out {args.held_out} whole families per split, {args.splits} splits\n")

    per_method: dict[str, list[float]] = {}
    operating: dict[str, list[float]] = {}
    for split in range(args.splits):
        rng = np.random.default_rng(split)
        result = run_split(X, y, families, rng, args.held_out, args.epochs)
        counts = f"{int(result['_known'])} known, {int(result['_unknown'])} unknown"
        print(f"  split {split}: {counts}")
        for name, value in result.items():
            if name.startswith("_detection") or name.endswith("_detection_at_95"):
                operating.setdefault(name, []).append(value)
            if name.startswith("_"):
                continue
            per_method.setdefault(name, []).append(value)
            print(f"    {name:>16}: AUROC {value:.3f}")
        print()

    print("--- detection at a 5% false-rejection rate ---")
    print("  what fraction of unseen families is caught, while wrongly")
    print("  warning about 5% of proteins the model does know:")
    for key, label in [
        ("_maha_detection_at_95", "mahalanobis"),
        ("_softmax_detection_at_95", "max softmax"),
    ]:
        values = operating.get(key, [])
        if values:
            print(f"    {label:>16}: {np.mean(values):.3f} +/- {np.std(values):.3f}")
    print()

    print("--- summary, mean AUROC across splits (0.5 is chance) ---")
    summary = {}
    for name, values in sorted(per_method.items(), key=lambda kv: -np.mean(kv[1])):
        mean = float(np.mean(values))
        spread = float(np.std(values))
        summary[name] = {"mean": mean, "std": spread, "splits": values}
        print(f"  {name:>16}: {mean:.3f} +/- {spread:.3f}")

    for key, values in operating.items():
        summary[key.lstrip("_")] = {
            "mean": float(np.mean(values)), "std": float(np.std(values)), "splits": values}

    OUT.mkdir(exist_ok=True)
    (OUT / "openset_results.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"\nwrote {(OUT / 'openset_results.json').relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
