#!/usr/bin/env python3
"""Export a golden embedding so the Swift side can check cross-language parity.

    Tools/coreml/.venv/bin/python Tools/coreml/export_golden.py

Writes Fixtures/expected/<model>.golden.json.

Why this exists: BoffinML's own tests can prove the tiler is self-consistent,
but self-consistency is exactly what a wrong tokeniser also has. Committing the
PyTorch answer for a known sequence lets the Swift tests assert against the
reference implementation rather than against themselves, which is the only way
to catch a Swift-side tokenising or slicing error.

Small on purpose: the pooled embedding plus two hidden state rows, rounded, is a
few kilobytes and is enough to catch any misalignment.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).parent))

from convert_backbone import ESMBackbone, load_model, make_traceable  # noqa: E402
from validate_parity import UBIQUITIN, build_tokens  # noqa: E402

MODEL = "esm2_t12_35M_UR50D"


def main() -> int:
    model, alphabet = load_model(MODEL)
    make_traceable(model, 1024)
    reference = ESMBackbone(model, model.num_layers).eval()

    tokens = build_tokens(alphabet, UBIQUITIN, 128)
    with torch.no_grad():
        hidden, _ = reference(tokens)
    hidden = hidden.numpy().astype(np.float64)[0]

    # Real residues only: index 0 is <cls> and index len+1 is <eos>. Pooling
    # over those, or over padding, would dilute the vector towards whatever the
    # model does with nothing.
    residues = hidden[1 : 1 + len(UBIQUITIN)]

    payload = {
        "model": MODEL,
        "sequence": UBIQUITIN,
        "residue_count": len(UBIQUITIN),
        "width": int(residues.shape[1]),
        "pooled": [round(float(v), 5) for v in residues.mean(axis=0)],
        "first_residue": [round(float(v), 5) for v in residues[0]],
        "last_residue": [round(float(v), 5) for v in residues[-1]],
        "note": (
            "PyTorch fp32 reference for esm2_t12_35M_UR50D. The Swift engine "
            "runs the fp16 Core ML conversion, so agreement is expected to "
            "within fp16 precision (about 1% of signal scale), not to the digit."
        ),
    }

    out = ROOT / "Fixtures/expected" / f"{MODEL}.golden.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2) + "\n")
    print(f"wrote {out.relative_to(ROOT)} ({out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
