#!/usr/bin/env python3
"""Does predicting solvent accessibility alongside disorder help the disorder?

    Tools/coreml/.venv/bin/python Tools/heads/disorder_rsa_experiment.py

The target
----------
CB513, not CASP12. `Tools/heads/disorder_uncertainty.py` bootstrapped the
benchmarks by chain and found the CASP12 deficit is not established: 21 chains,
MCC 0.501 with a 95% interval of [0.337, 0.662] against a floor of 0.573. CB513
is where the deficit is real: 0.430, interval [0.372, 0.492], wholly below its
floor of 0.502, across 513 chains.

Chasing CASP12 would have been optimising against a benchmark that could not
have confirmed the result afterwards.

The idea
--------
NetSurfP predicts relative solvent accessibility jointly with everything else,
and RSA and disorder are the same physical fact seen twice: a residue nobody can
see in a crystal is usually one with nothing packed against it. Sharing a trunk
between the two tasks gives the disorder head a denser training signal than a
rare binary label, which is the standard argument for auxiliary supervision.

The RSA labels are already in the cached embeddings. Nothing needs re-embedding.

The control
-----------
Two heads trained under identical conditions: same seed, same initialisation,
same batches in the same order, same epochs, same class weight, same threshold
tuning on the same validation chains. The ONLY difference is whether the
auxiliary RSA loss is added.

Without that control the comparison says nothing, because a second training run
of the same architecture differs by more than most auxiliary tasks are worth.

Reported with the same chain bootstrap as the measurement that set the target,
because a point estimate that moved by 0.02 on 513 correlated chains is not
evidence of anything.
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
from train_heads import EMBED_WIDTH, batches  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "Datasets/embeddings"
OUT = ROOT / "Docs"
ONE_HOT_FLOOR = {"cb513": 0.502, "ts115": 0.594, "casp12": 0.573}


class JointHead(nn.Module):
    """The shipped disorder head, optionally with an RSA output beside it.

    The trunk is `ConvHead`'s, unchanged, so the control arm is genuinely the
    shipped architecture rather than a reimplementation that happens to look
    like it. `with_rsa` adds one 1x1 convolution: the extra capacity is four
    hundred parameters, which is small enough that an improvement cannot be
    attributed to size.
    """

    def __init__(self, width: int = 128, dropout: float = 0.2, with_rsa: bool = False):
        super().__init__()
        self.trunk = train_heads.ConvHead(classes=2, width=width, dropout=dropout)
        self.with_rsa = with_rsa
        if with_rsa:
            self.rsa = nn.Conv1d(width, 1, kernel_size=1)

    def forward(self, x: torch.Tensor):
        trunk = self.trunk
        h = F.gelu(trunk.project(x))
        h = h + trunk.dropout(F.gelu(trunk.norm1(trunk.block1(h))))
        h = h + trunk.dropout(F.gelu(trunk.norm2(trunk.block2(h))))
        h = h + trunk.dropout(F.gelu(trunk.norm3(trunk.block3(h))))
        disorder = trunk.output(h)
        accessibility = self.rsa(h).squeeze(1) if self.with_rsa else None
        return disorder, accessibility


def rsa_batches(bundle, boundaries, indices, batch_size, device, shuffle=False):
    """The trainer's batches, with RSA carried alongside.

    A parallel generator rather than a change to `batches`, so the shipped
    trainer is untouched by an experiment. Padding is filled with NaN and masked
    out, not with zero: zero is a REAL rsa value meaning fully buried, and
    training the auxiliary task to predict "buried" for every pad would be a
    signal pulling the trunk in a direction nothing asked for.
    """
    order = list(indices)
    lengths = {i: boundaries[i + 1] - boundaries[i] for i in order}
    order.sort(key=lambda i: lengths[i])
    if shuffle:
        blocks = [order[i : i + batch_size] for i in range(0, len(order), batch_size)]
        rng = np.random.default_rng(0)
        rng.shuffle(blocks)
        order = [i for block in blocks for i in block]

    for start in range(0, len(order), batch_size):
        group = order[start : start + batch_size]
        longest = max(lengths[i] for i in group)
        x = np.zeros((len(group), longest, EMBED_WIDTH), dtype=np.float32)
        ordered = np.full((len(group), longest), -100, dtype=np.int64)
        rsa = np.full((len(group), longest), np.nan, dtype=np.float32)
        mask = np.zeros((len(group), longest), dtype=bool)

        for row, index in enumerate(group):
            lo, hi = boundaries[index], boundaries[index + 1]
            n = hi - lo
            x[row, :n] = bundle["embeddings"][lo:hi].astype(np.float32)
            ordered[row, :n] = bundle["ordered"][lo:hi]
            rsa[row, :n] = bundle["rsa"][lo:hi]
            mask[row, :n] = True

        yield (
            torch.from_numpy(x).permute(0, 2, 1).to(device),
            torch.from_numpy(ordered).to(device),
            torch.from_numpy(rsa).to(device),
            torch.from_numpy(mask).to(device),
        )


def train(
    bundle, boundaries, train_indices, *, with_rsa: bool, epochs: int,
    batch_size: int, weight: float, rsa_weight: float, device, seed: int
) -> JointHead:
    # Seeded immediately before construction so both arms start from bit
    # identical weights. Seeding once at the top of the script would leave the
    # second arm initialised from a different point in the stream, and a
    # difference in starting weights is exactly the size of effect being looked
    # for here.
    torch.manual_seed(seed)
    head = JointHead(with_rsa=with_rsa).to(device)
    optimiser = torch.optim.AdamW(head.parameters(), lr=1e-3, weight_decay=0.01)
    schedule = torch.optim.lr_scheduler.CosineAnnealingLR(optimiser, T_max=epochs)
    class_weight = torch.tensor([weight, 1.0], device=device)

    for epoch in range(1, epochs + 1):
        head.train()
        running = count = 0.0
        for x, ordered, rsa, mask in rsa_batches(
            bundle, boundaries, train_indices, batch_size, device, shuffle=True
        ):
            optimiser.zero_grad()
            disorder, accessibility = head(x)
            loss = F.cross_entropy(disorder, ordered, weight=class_weight, ignore_index=-100)

            if with_rsa and accessibility is not None:
                valid = mask & ~torch.isnan(rsa)
                if valid.any():
                    # Smooth L1 rather than plain MSE: RSA is bounded in [0, 1]
                    # and its distribution is heaped at both ends, so a squared
                    # loss lets the few extreme errors dominate the gradient the
                    # trunk sees, which is the opposite of what an auxiliary
                    # task is for.
                    loss = loss + rsa_weight * F.smooth_l1_loss(
                        accessibility[valid], rsa[valid])

            loss.backward()
            optimiser.step()
            running += float(loss.item())
            count += 1
        schedule.step()
        if epoch % 2 == 0 or epoch == epochs:
            arm = "rsa " if with_rsa else "base"
            print(f"    [{arm}] epoch {epoch:>2}: loss {running / max(count, 1):.4f}",
                  flush=True)
    return head


def disorder_only(head: JointHead) -> nn.Module:
    """A module returning just the disorder logits, for the shared evaluators."""

    class Wrapper(nn.Module):
        def __init__(self, inner: JointHead):
            super().__init__()
            self.inner = inner

        def forward(self, x):
            return self.inner(x)[0]

    wrapper = Wrapper(head)
    wrapper.eval()
    return wrapper


def mcc_from_counts(tp: int, tn: int, fp: int, fn: int) -> float:
    denominator = np.sqrt(float(tp + fp) * (tp + fn) * (tn + fp) * (tn + fn))
    return float((tp * tn - fp * fn) / denominator) if denominator > 0 else 0.0


def evaluate_with_bootstrap(
    head: nn.Module, name: str, threshold: float, draws: int, rng
) -> dict:
    bundleHandle = np.load(DATA / f"{name}.npz")
    bundle = {key: bundleHandle[key] for key in bundleHandle.files}
    chain = bundle["chain"]
    boundaries = np.searchsorted(chain, np.arange(chain[-1] + 2))

    said = np.zeros(len(bundle["ordered"]), dtype=bool)
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
    tp = int((said & truth).sum())
    fp = int((said & ~truth).sum())
    fn = int((~said & truth).sum())
    tn = int((~said & ~truth).sum())
    point = mcc_from_counts(tp, tn, fp, fn)

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
        "mcc": point, "ci_low": float(low), "ci_high": float(high),
        "scores": scores, "said": said, "truth": truth, "chain": chain,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--epochs", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--chains", type=int, default=0, help="0 uses every chain")
    parser.add_argument("--weight", type=float, default=14.5)
    parser.add_argument("--rsa-weight", type=float, default=1.0)
    parser.add_argument("--draws", type=int, default=2000)
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()

    device = torch.device("cpu")
    bundle, boundaries = train_heads.load_split("train")
    total = len(boundaries) - 2

    rng = np.random.default_rng(args.seed)
    order = rng.permutation(total)
    if args.chains:
        order = order[: args.chains]
    cut = int(len(order) * 0.9)
    train_indices, validation_indices = order[:cut], order[cut:]
    print(f"  {len(train_indices):,} training chains, "
          f"{len(validation_indices):,} for threshold tuning\n")

    results = {}
    for with_rsa in (False, True):
        arm = "rsa" if with_rsa else "baseline"
        print(f"  --- {arm} ---")
        head = train(
            bundle, boundaries, train_indices, with_rsa=with_rsa, epochs=args.epochs,
            batch_size=args.batch_size, weight=args.weight,
            rsa_weight=args.rsa_weight, device=device, seed=args.seed)

        wrapped = disorder_only(head)
        # Tuned on VALIDATION chains and applied blind to the benchmarks. The
        # shipped trainer does this and it is the difference between a number
        # that reproduces and an upper bound that does not.
        threshold = train_heads.tune_threshold(
            wrapped, bundle, boundaries, validation_indices, device, args.batch_size)
        print(f"    threshold {threshold:.2f}")

        arm_results = {"threshold": float(threshold)}
        for name in ["cb513", "ts115", "casp12"]:
            measured = evaluate_with_bootstrap(
                wrapped, name, threshold, args.draws, np.random.default_rng(1))
            arm_results[name] = {
                k: v for k, v in measured.items()
                if k in ("mcc", "ci_low", "ci_high")}
            arm_results[name]["scores"] = measured["scores"]
            floor = ONE_HOT_FLOOR[name]
            print(f"    {name}: MCC {measured['mcc']:.3f} "
                  f"[{measured['ci_low']:.3f}, {measured['ci_high']:.3f}] "
                  f"floor {floor:.3f}")
        results[arm] = arm_results
        print()

    print("--- does the auxiliary task help? ---")
    summary = {}
    for name in ["cb513", "ts115", "casp12"]:
        base = results["baseline"][name]
        rsa = results["rsa"][name]
        delta = rsa["mcc"] - base["mcc"]
        # Paired over bootstrap draws: both arms are resampled with the SAME
        # chain draws, so the difference is measured on the same proteins and
        # the shared variation cancels. Comparing two independent intervals
        # would mostly measure which chains each happened to draw.
        paired = rsa["scores"] - base["scores"]
        low, high = np.percentile(paired, [2.5, 97.5])
        wins = float((paired > 0).mean())
        verdict = "helps" if low > 0 else "hurts" if high < 0 else "no effect detectable"
        print(f"  {name}: {base['mcc']:.3f} -> {rsa['mcc']:.3f} "
              f"(delta {delta:+.3f}, paired 95% [{low:+.3f}, {high:+.3f}]) {verdict}")
        summary[name] = {
            "baseline_mcc": base["mcc"], "rsa_mcc": rsa["mcc"], "delta": delta,
            "paired_ci_low": float(low), "paired_ci_high": float(high),
            "fraction_improved": wins, "verdict": verdict,
            "one_hot_floor": ONE_HOT_FLOOR[name],
            "baseline_ci": [base["ci_low"], base["ci_high"]],
            "rsa_ci": [rsa["ci_low"], rsa["ci_high"]],
        }

    OUT.mkdir(exist_ok=True)
    (OUT / "disorder_rsa_results.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"\nwrote {(OUT / 'disorder_rsa_results.json').relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
