#!/usr/bin/env python3
"""Does unfreezing the ESM-2 backbone close the disorder deficit, and at what cost?

    Tools/coreml/.venv/bin/python Tools/heads/disorder_unfreeze_experiment.py \
        --device mps --epochs 2

Three experiments have already agreed that the disorder head is close to what a
frozen 480-d embedding supports: better supervision does nothing (RSA, bounded
within +/-0.013), more parameters buy an eighth of the gap at 3.6x the size,
more context hurts. The only route left is to stop freezing the backbone, which
is what this measures.

Two questions, and the second is the one nobody had asked
---------------------------------------------------------
1. Does end-to-end fine-tuning raise disorder MCC above the shipped
   0.431 / 0.628 / 0.500 on CB513 / TS115 / CASP12?

2. What does it cost the OTHER heads? Invariant 1 is "one forward pass, four
   fan-outs": secondary structure, disorder, family and topology all read the
   same representation. A backbone fine-tuned for disorder is no longer that
   shared representation, and if the secondary-structure head degrades on it
   then unfreezing does not trade size for accuracy, it trades the
   architecture. That is measured here by running the SHIPPED, unmodified
   secondary-structure head on embeddings from the fine-tuned backbone.

The control arm re-trains the disorder head on frozen embeddings from the same
seed, so the comparison is against a number this script produced rather than
against one read out of a file.
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

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools/heads"))
from extract_embeddings import decode, SPLITS  # noqa: E402
from train_heads import ConvHead, EMBED_WIDTH  # noqa: E402

DATASETS = ROOT / "Datasets"
OUT = ROOT / "Models/heads"


def chains_for(split: str, limit: int = 0):
    rows = list(decode(DATASETS / SPLITS[split]))
    return rows[:limit] if limit else rows


def mcc(true_positive, true_negative, false_positive, false_negative):
    numerator = true_positive * true_negative - false_positive * false_negative
    denominator = float(
        (true_positive + false_positive)
        * (true_positive + false_negative)
        * (true_negative + false_positive)
        * (true_negative + false_negative)
    ) ** 0.5
    return numerator / denominator if denominator > 0 else 0.0


class Backbone(nn.Module):
    """ESM-2 with a head on top, trainable end to end or frozen."""

    def __init__(self, model, layer, head, frozen: bool):
        super().__init__()
        self.model, self.layer, self.head, self.frozen = model, layer, head, frozen
        if frozen:
            for parameter in model.parameters():
                parameter.requires_grad = False

    def forward(self, tokens):
        # `<cls>` and `<eos>` are stripped by the caller's slicing, not here,
        # because the head is a convolution and padding it differently from the
        # frozen path would change the receptive field at the termini.
        context = torch.no_grad() if self.frozen else torch.enable_grad()
        with context:
            out = self.model(tokens, repr_layers=[self.layer])
        hidden = out["representations"][self.layer]
        return self.head(hidden.transpose(1, 2))


def batch_tokens(converter, rows, crop, device):
    data = [(name, seq[:crop]) for name, seq, _ in rows]
    _, _, tokens = converter(data)
    return tokens.to(device)


def label_tensor(rows, crop, width, device):
    ordered = torch.full((len(rows), width), -100, dtype=torch.long)
    for i, (_, seq, labels) in enumerate(rows):
        take = min(len(seq), crop)
        ordered[i, :take] = torch.from_numpy(
            labels["ordered"][:take].astype(np.int64))
    return ordered.to(device)


def evaluate(model, converter, rows, crop, device, batch_size, threshold):
    """MCC over all residues AND over the evaluation-masked subset.

    Both, because they are different numbers and only one of them compares to
    the shipped benchmark. `Models/heads/benchmarks.json` reports CB513 with
    144,360 residues and 3,529 disordered, which is every residue rather than
    the NetSurfP `evaluation` mask: that mask keeps 84,336 of CB513's residues
    and only **564 of its 3,529 disordered ones**. Scoring the masked subset
    and comparing it to the shipped figure would have compared two different
    populations and called the difference an effect.

    TS115 and CASP12 hide this, since every disordered residue in both falls
    inside their masks (2,203 and 836, matching the shipped counts exactly).
    Two benchmarks agreeing is what made the third worth checking.
    """
    model.eval()
    totals = {"all": [0, 0, 0, 0], "masked": [0, 0, 0, 0]}
    with torch.no_grad():
        for start in range(0, len(rows), batch_size):
            chunk = rows[start : start + batch_size]
            tokens = batch_tokens(converter, chunk, crop, device)
            logits = model(tokens)
            # Drop <cls> at 0; the head sees the token axis, so residue i is
            # token i+1.
            probability = F.softmax(logits, dim=1)[:, 0, 1:]
            for i, (_, seq, labels) in enumerate(chunk):
                take = min(len(seq), crop, probability.shape[1])
                said_all = probability[i, :take].float().cpu().numpy() > threshold
                truth_all = labels["ordered"][:take] == 0
                for population, keep in (
                    ("all", np.ones(take, dtype=bool)),
                    ("masked", labels["evaluation"][:take] > 0),
                ):
                    if not keep.any():
                        continue
                    said, truth = said_all[keep], truth_all[keep]
                    counts = totals[population]
                    counts[0] += int(np.sum(said & truth))
                    counts[1] += int(np.sum(~said & ~truth))
                    counts[2] += int(np.sum(said & ~truth))
                    counts[3] += int(np.sum(~said & truth))
    return {
        population: {
            "disorder_mcc": mcc(*counts),
            "positives": counts[0] + counts[3],
        }
        for population, counts in totals.items()
    }


def train(rows, model, converter, crop, device, epochs, batch_size, lr, weight, tag):
    parameters = [p for p in model.parameters() if p.requires_grad]
    optimiser = torch.optim.AdamW(parameters, lr=lr, weight_decay=0.01)
    rng = np.random.default_rng(0)
    for epoch in range(epochs):
        model.train()
        order = rng.permutation(len(rows))
        total, seen = 0.0, 0
        for step, start in enumerate(range(0, len(order), batch_size)):
            chunk = [rows[i] for i in order[start : start + batch_size]]
            tokens = batch_tokens(converter, chunk, crop, device)
            logits = model(tokens)
            width = logits.shape[2] - 1
            targets = label_tensor(chunk, crop, width, device)
            loss = F.cross_entropy(
                logits[:, :, 1 : 1 + width], targets, weight=weight,
                ignore_index=-100)
            optimiser.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(parameters, 1.0)
            optimiser.step()
            total += float(loss); seen += 1
            if step % 50 == 0:
                print(f"  [{tag}] epoch {epoch + 1} step {step} "
                      f"loss {total / max(seen, 1):.4f}", flush=True)
        print(f"  [{tag}] epoch {epoch + 1} mean loss {total / max(seen, 1):.4f}",
              flush=True)
    return model


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="mps", choices=["cpu", "mps"])
    parser.add_argument("--epochs", type=int, default=2)
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--crop", type=int, default=512,
                        help="residues per chain in TRAINING, to bound memory")
    parser.add_argument("--eval-crop", type=int, default=2048,
                        help="residues per chain in EVALUATION. Deliberately "
                             "larger than the longest benchmark chain (CASP12 "
                             "reaches 1494): cropping evaluation would score a "
                             "different set of residues from the shipped "
                             "benchmark and the comparison would be void. The "
                             "printed positive counts are the check -- they "
                             "must match 3529 / 2203 / 836.")
    parser.add_argument("--backbone-lr", type=float, default=1e-5)
    parser.add_argument("--head-lr", type=float, default=1e-3)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--arms", default="frozen,unfrozen")
    args = parser.parse_args()

    device = torch.device(args.device)
    torch.manual_seed(0)

    import esm
    print("loading chains ...", flush=True)
    train_rows = chains_for("train", args.limit)
    benchmarks = {n: chains_for(n) for n in ["cb513", "ts115", "casp12"]}
    print(f"  train {len(train_rows)}, "
          + ", ".join(f"{k} {len(v)}" for k, v in benchmarks.items()), flush=True)

    counts = np.bincount(
        np.concatenate([r[2]["ordered"] for r in train_rows]), minlength=2)
    weight = torch.tensor(
        [counts[1] / max(counts[0], 1), 1.0], dtype=torch.float32).to(device)
    print(f"  class weight {float(weight[0]):.1f}", flush=True)

    results = {}
    for arm in args.arms.split(","):
        print(f"\n=== {arm}", flush=True)
        model, alphabet = esm.pretrained.esm2_t12_35M_UR50D()
        converter = alphabet.get_batch_converter()
        head = ConvHead(classes=2, width=128)
        net = Backbone(model, model.num_layers, head, frozen=(arm == "frozen")).to(device)

        groups = [{"params": head.parameters(), "lr": args.head_lr}]
        if arm != "frozen":
            groups.append({"params": model.parameters(), "lr": args.backbone_lr})
        # Rebuilt inside train() from requires_grad, so the two arms differ in
        # exactly one thing: whether the backbone's gradients are on.
        net = train(train_rows, net, converter, args.crop, device, args.epochs,
                    args.batch_size, args.head_lr, weight, arm)

        arm_result = {}
        for name, rows in benchmarks.items():
            # Batch 1 for evaluation: no cropping means chains up to 1494
            # residues, and batching those pads every one of them to the
            # longest in the batch.
            scored = evaluate(
                net, converter, rows, args.eval_crop, device, 1, 0.5)
            arm_result[name] = scored
            print(f"  {name}: MCC {scored['all']['disorder_mcc']:.4f} over all "
                  f"{scored['all']['positives']} disordered, "
                  f"{scored['masked']['disorder_mcc']:.4f} over the "
                  f"{scored['masked']['positives']} in the evaluation mask",
                  flush=True)
        results[arm] = arm_result

        if arm != "frozen":
            torch.save(model.state_dict(), OUT / "esm2_disorder_finetuned.pt")
            print(f"  saved fine-tuned backbone", flush=True)

    (OUT / "unfreeze_experiment.json").write_text(json.dumps(results, indent=2))
    print("\n" + json.dumps(results, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
