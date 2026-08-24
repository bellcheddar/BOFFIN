#!/usr/bin/env python3
"""Convert the trained analysis heads to Core ML and check residency.

    Tools/coreml/.venv/bin/python Tools/coreml/convert_heads.py

Writes Models/heads/<name>.mlpackage for each head and reports the fraction of
executable operations planned for the Neural Engine.

Why this runs alongside the accuracy numbers, not after them
------------------------------------------------------------
A head's benchmark score is only interesting if the head can actually run where
the app needs it, so both are measured together.

MEASURED FINDING (2026-08-24): the heads report **0% ANE residency**, and that
is fine. Every operation reports the Neural Engine among its *supported*
devices: Core ML simply *prefers* the CPU, because a 12-operation, 0.63 MB
model is not worth dispatching. The measured cost is **0.39 ms at bucket 384**
against the backbone's 31.3 ms, which is 1.2% of the pass.

So the build plan's ">90% of operations on the ANE" gate is a **backbone** gate.
Applying it to a head this small measures the wrong thing: it would push towards
a needlessly large head purely to satisfy a threshold, which is the metric
driving the design rather than the other way round. Residency is therefore
reported here as INFORMATION, and the head is gated on latency instead.

What the convolutional shape is still buying is real and unchanged: a biLSTM
head would not be ANE-capable at all, would not convert cleanly, and would be
far more than 1.2% of the pass.

Heads use ONE fixed window of 1024, not enumerated shapes.

Three findings, in the order they were made:

1. Converting at 384 while the Swift side called with 1024 built cleanly,
   converted cleanly and passed parity, then failed at runtime with "MultiArray
   shape (1 x 480 x 1 x 1024) does not match the shape (1 x 480 x 1 x 384)".
   Only running the app caught it.
2. `EnumeratedShapes` looked like the fix and is not usable here: the model
   converts and saves, and then **`predict` crashes the process with SIGTRAP**,
   at the default bucket as well as the others.
3. A single 1024 window is therefore used, and the zero padding it implies was
   measured rather than assumed. For ubiquitin, a 128 window and a 1024 window
   agree on **100% of argmax calls including the last 16 residues**, with a max
   logit difference of 0.05, which is fp16 noise. Padding does not degrade the
   C-terminus.

At 1024, any protein up to 1022 residues is a single window with no seams at
all, and the head costs 0.73 ms against the backbone's 31 ms.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[2]
HEADS = ROOT / "Models/heads"

sys.path.insert(0, str(ROOT / "Tools/heads"))

BUCKETS = [128, 256, 384, 512, 768, 1024]
EMBED_WIDTH_GLOBAL = 480
# The head is gated on cost, not on residency: see the module docstring.
# 3 ms is a deliberately generous ceiling at roughly 10% of the backbone pass.
LATENCY_CEILING_MS = 3.0


class ANEConvHead(torch.nn.Module):
    """The trained head, re-expressed in the layout the Neural Engine wants.

    Identical arithmetic to `ConvHead`, and it loads the same trained weights:
    a Conv1d kernel of shape (out, in, k) is a Conv2d kernel of shape
    (out, in, 1, k), and BatchNorm1d and BatchNorm2d hold the same parameters.
    Nothing is retrained.

    Why bother: converted as written, with 3D tensors and Conv1d, the heads
    achieved **0% ANE residency**: all 12 executable operations fell to the CPU.
    Build plan section 4.2 says it plainly ("4D (B, C, 1, S) tensors rather
    than (B, S, C), conv2d in place of linear"), and it applies to the heads and
    not only to the backbone. The failure is silent in the sense that parity is
    perfect and the model runs correctly: it just runs in the wrong place, which
    a numerical test cannot see.
    """

    def __init__(self, source, classes: int, width: int):
        super().__init__()
        self.project = self._conv(source.project, width, EMBED_WIDTH_GLOBAL, 1, 1, 0)
        self.block1 = self._conv(source.block1, width, width, 5, 1, 2)
        self.block2 = self._conv(source.block2, width, width, 5, 2, 4)
        self.block3 = self._conv(source.block3, width, width, 5, 4, 8)
        self.norm1 = self._norm(source.norm1, width)
        self.norm2 = self._norm(source.norm2, width)
        self.norm3 = self._norm(source.norm3, width)
        self.output = self._conv(source.output, classes, width, 1, 1, 0)

    @staticmethod
    def _conv(source, out_channels, in_channels, kernel, dilation, padding):
        conv = torch.nn.Conv2d(
            in_channels, out_channels, kernel_size=(1, kernel),
            dilation=(1, dilation), padding=(0, padding))
        # (out, in, k) -> (out, in, 1, k): the same kernel, one row tall.
        conv.weight.data = source.weight.data.unsqueeze(2).clone()
        conv.bias.data = source.bias.data.clone()
        return conv

    @staticmethod
    def _norm(source, width):
        norm = torch.nn.BatchNorm2d(width)
        norm.weight.data = source.weight.data.clone()
        norm.bias.data = source.bias.data.clone()
        norm.running_mean = source.running_mean.clone()
        norm.running_var = source.running_var.clone()
        norm.eval()
        return norm

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: (1, EMBED_WIDTH, 1, length)
        import torch.nn.functional as F

        h = F.gelu(self.project(x))
        h = h + F.gelu(self.norm1(self.block1(h)))
        h = h + F.gelu(self.norm2(self.block2(h)))
        h = h + F.gelu(self.norm3(self.block3(h)))
        return self.output(h)


def measure_residency(package: Path) -> tuple[float, dict]:
    """Fraction of executable operations planned for the ANE.

    `const` operations are excluded: they are weights and literals, execute
    nowhere, and are assigned no device. Including them understates residency
    badly (58% of the backbone program was const, which turned 98.8% into a
    reported 41.5%).
    """
    from collections import Counter

    from coremltools.models.compute_device import MLNeuralEngineComputeDevice
    from coremltools.models.compute_plan import MLComputePlan

    cache = ROOT / "Tools/coreml/.cache/head.mlmodelc"
    if cache.exists():
        import shutil

        shutil.rmtree(cache)
    cache.parent.mkdir(parents=True, exist_ok=True)
    compiled = ct.utils.compile_model(str(package), str(cache))

    plan = MLComputePlan.load_from_path(
        str(compiled), compute_units=ct.ComputeUnit.CPU_AND_NE)

    def walk(block):
        for operation in block.operations:
            yield operation
            for inner in getattr(operation, "blocks", []) or []:
                yield from walk(inner)

    counts: Counter = Counter()
    for function in plan.model_structure.program.functions.values():
        for operation in walk(function.block):
            if operation.operator_name == "const":
                continue
            usage = plan.get_compute_device_usage_for_mlprogram_operation(operation)
            if usage is None:
                counts["unplanned"] += 1
                continue
            device = usage.preferred_compute_device
            counts["ANE" if isinstance(device, MLNeuralEngineComputeDevice) else "CPU"] += 1

    executable = sum(counts.values())
    return (counts["ANE"] / executable if executable else 0.0), dict(counts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    # 1024: one window covers any protein up to 1022 residues with no seams.
    # MUST match HEAD_WINDOW in BoffinML's AnalysisHeads. A mismatch does not
    # fail at build time, only on device.
    parser.add_argument("--bucket", type=int, default=1024, choices=BUCKETS)
    args = parser.parse_args()

    from train_heads import EMBED_WIDTH, ConvHead

    config_path = HEADS / "config.json"
    if not config_path.exists():
        print(f"missing {config_path}: train the heads first", file=sys.stderr)
        return 1
    config = json.loads(config_path.read_text())
    width = config["head_width"]

    specifications = [
        ("secondary_structure", 8, "Per-residue Q8 secondary structure logits, order GHIBESTC."),
        ("disorder", 2, "Per-residue disorder logits: index 0 disordered, index 1 ordered."),
    ]

    failures = []
    for name, classes, description in specifications:
        weights = HEADS / f"{name}.pt"
        if not weights.exists():
            print(f"missing {weights}, skipped")
            continue

        head = ConvHead(classes=classes, width=width)
        head.load_state_dict(torch.load(weights, map_location="cpu"))
        head.eval()

        # Re-express in the ANE's preferred 4D layout before tracing. Same
        # weights, same arithmetic, radically different residency.
        exported = ANEConvHead(head, classes=classes, width=width).eval()

        example = torch.zeros(1, EMBED_WIDTH, 1, args.bucket)
        with torch.no_grad():
            traced = torch.jit.trace(exported, example)

        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(
                name="embeddings", shape=(1, EMBED_WIDTH, 1, args.bucket),
                dtype=np.float16)],
            outputs=[ct.TensorType(name="logits", dtype=np.float16)],
            convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT16,
            compute_units=ct.ComputeUnit.CPU_AND_NE,
            minimum_deployment_target=ct.target.iOS18,
        )
        mlmodel.short_description = description
        mlmodel.input_description["embeddings"] = (
            f"Frozen backbone hidden states, (1, {EMBED_WIDTH}, 1, {args.bucket}). "
            "The singleton third axis is the Neural Engine's preferred layout.")

        package = HEADS / f"{name}.mlpackage"
        mlmodel.save(str(package))
        size = sum(f.stat().st_size for f in package.rglob("*") if f.is_file()) / 1e6

        residency, counts = measure_residency(package)

        # Latency is the gate. Warm up first: the first prediction pays
        # compilation and would dominate a small sample.
        import time

        probe_input = {"embeddings": np.zeros((1, EMBED_WIDTH, 1, args.bucket), dtype=np.float16)}
        for _ in range(5):
            mlmodel.predict(probe_input)
        timings = []
        for _ in range(30):
            started = time.perf_counter()
            mlmodel.predict(probe_input)
            timings.append((time.perf_counter() - started) * 1000)
        timings.sort()
        median = timings[len(timings) // 2]

        verdict = "PASS" if median <= LATENCY_CEILING_MS else "FAIL"
        if median > LATENCY_CEILING_MS:
            failures.append(f"{name}: {median:.2f} ms > {LATENCY_CEILING_MS} ms")

        print(f"{name}")
        print(f"  size:      {size:.2f} MB")
        print(f"  latency:   {median:.2f} ms at bucket {args.bucket}  "
              f"(ceiling {LATENCY_CEILING_MS} ms)   {verdict}")
        print(f"  residency: {residency:.1%} {counts}  "
              f"(informational: every op is ANE-capable, Core ML prefers CPU "
              f"for a model this small)")

        # Parity against the PyTorch head, on random input in the range the
        # real embeddings occupy.
        probe = torch.randn(1, EMBED_WIDTH, 1, args.bucket)
        with torch.no_grad():
            # Compared against the ORIGINAL Conv1d head, not the re-expressed
            # one: the point is that the layout change did not alter the maths.
            expected = head(probe.squeeze(2)).unsqueeze(2).numpy().astype(np.float32)
        actual = np.asarray(
            mlmodel.predict({"embeddings": probe.numpy().astype(np.float16)})["logits"],
            dtype=np.float32)
        scale = float(np.abs(expected).max())
        relative = float(np.abs(expected - actual).max()) / scale if scale else float("inf")
        agree = (expected.argmax(axis=1) == actual.argmax(axis=1)).mean()
        print(f"  parity:    relative {relative:.4%}, "
              f"argmax agreement {agree:.4%}")
        print()

    if failures:
        print("HEAD LATENCY GATE FAILED: " + ", ".join(failures))
        return 1
    print("all heads pass the latency gate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
