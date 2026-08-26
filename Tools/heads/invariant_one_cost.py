#!/usr/bin/env python3
"""What does fine-tuning the backbone for disorder cost the other heads?

    Tools/coreml/.venv/bin/python Tools/heads/invariant_one_cost.py --device mps

Invariant 1 is "one forward pass, four fan-outs": secondary structure,
disorder, family and topology all read the same representation. A backbone
fine-tuned for disorder is no longer that shared representation, and the
question this answers is whether the other heads survive reading it.

The SHIPPED secondary-structure head is used unmodified. Retraining it on the
fine-tuned backbone would answer a different and easier question -- whether a
multi-task fine-tune is possible -- and would hide the cost being measured
here, which is what happens to an app that fine-tunes one head's backbone and
keeps the others.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools/heads"))
from extract_embeddings import decode, SPLITS, Q8_NAMES, Q8_TO_Q3  # noqa: E402
from train_heads import ConvHead  # noqa: E402

HEADS = ROOT / "Models/heads"
Q3_OF_Q8 = np.array([Q8_NAMES.index(Q8_TO_Q3[c]) if False else
                     "HEC".index(Q8_TO_Q3[c]) for c in Q8_NAMES])


def q3_accuracy(model, head, converter, layer, rows, device, crop):
    correct = total = 0
    with torch.no_grad():
        for name, seq, labels in rows:
            _, _, tokens = converter([(name, seq[:crop])])
            hidden = model(tokens.to(device), repr_layers=[layer])["representations"][layer]
            logits = head(hidden.transpose(1, 2))
            take = min(len(seq), crop, logits.shape[2] - 1)
            predicted = logits[0, :, 1 : 1 + take].argmax(dim=0).cpu().numpy()
            truth = labels["q8"][:take]
            correct += int(np.sum(Q3_OF_Q8[predicted] == Q3_OF_Q8[truth]))
            total += take
    return correct / max(total, 1), total


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="mps", choices=["cpu", "mps"])
    parser.add_argument("--crop", type=int, default=2048)
    parser.add_argument("--splits", default="cb513,ts115,casp12")
    args = parser.parse_args()

    import esm
    device = torch.device(args.device)

    head = ConvHead(classes=8, width=128)
    head.load_state_dict(torch.load(HEADS / "secondary_structure.pt", map_location="cpu"))
    head = head.to(device).eval()

    finetuned = HEADS / "esm2_disorder_finetuned.pt"
    if not finetuned.exists():
        print(f"missing {finetuned}: run disorder_unfreeze_experiment.py first")
        return 1

    print(f"{'split':<8} {'frozen Q3':>10} {'fine-tuned Q3':>14} {'delta':>8} {'residues':>10}")
    for split in args.splits.split(","):
        rows = list(decode(ROOT / "Datasets" / SPLITS[split]))

        stock, _ = esm.pretrained.esm2_t12_35M_UR50D()
        converter = stock.alphabet.get_batch_converter() if hasattr(stock, "alphabet") else None
        model, alphabet = esm.pretrained.esm2_t12_35M_UR50D()
        converter = alphabet.get_batch_converter()
        layer = model.num_layers
        model = model.to(device).eval()
        before, residues = q3_accuracy(
            model, head, converter, layer, rows, device, args.crop)

        model.load_state_dict(torch.load(finetuned, map_location="cpu"))
        model = model.to(device).eval()
        after, _ = q3_accuracy(model, head, converter, layer, rows, device, args.crop)

        print(f"{split:<8} {before:>10.4f} {after:>14.4f} {after - before:>+8.4f} "
              f"{residues:>10,}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
