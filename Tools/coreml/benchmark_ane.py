#!/usr/bin/env python3
"""Measure Neural Engine residency and embedding latency.

    Tools/coreml/.venv/bin/python Tools/coreml/benchmark_ane.py \
        --model esm2_t12_35M_UR50D

Residency is measured, not eyeballed. `MLComputePlan` reports the compute device
Core ML has planned for every operation in the program, so ">90 % of ops on the
ANE" becomes a number this script prints rather than something inferred from a
trace in Instruments.

A caveat that must travel with every number below
-------------------------------------------------
This runs on the development Mac. The build plan's budgets are for
"iPhone 15 Pro class hardware", and an M-series ANE is not an A-series ANE:
**the latency figures here are not the budget numbers** and must not be recorded
as though they were. What does transfer is residency, which answers a structural
question ("can these operations run on the Neural Engine at all?") rather than a
speed one, and that is the question the project's fatal risk depends on.

Real device latency needs an on-device XCTest measure block, which arrives with
the app-side harness.
"""

from __future__ import annotations

import argparse
import statistics
import sys
import time
from collections import Counter
from pathlib import Path

import coremltools as ct
import numpy as np
from coremltools.models.compute_device import (
    MLCPUComputeDevice,
    MLGPUComputeDevice,
    MLNeuralEngineComputeDevice,
)
from coremltools.models.compute_plan import MLComputePlan

ROOT = Path(__file__).resolve().parents[2]
MODELS_DIR = ROOT / "Models"

BUCKETS = [128, 256, 384, 512, 768, 1024]
RESIDENCY_FLOOR = 0.90

# Compiled models are build artefacts, kept out of the repository.
_COMPILED_CACHE = ROOT / "Tools/coreml/.cache/compiled.mlmodelc"


def device_name(device) -> str:
    if isinstance(device, MLNeuralEngineComputeDevice):
        return "ANE"
    if isinstance(device, MLGPUComputeDevice):
        return "GPU"
    if isinstance(device, MLCPUComputeDevice):
        return "CPU"
    return type(device).__name__


def walk_operations(block):
    for operation in block.operations:
        yield operation
        for argument in getattr(operation, "blocks", []) or []:
            yield from walk_operations(argument)


def _reset_cache() -> None:
    import shutil

    if _COMPILED_CACHE.exists():
        shutil.rmtree(_COMPILED_CACHE)
    _COMPILED_CACHE.parent.mkdir(parents=True, exist_ok=True)


def measure_residency(package: Path) -> tuple[float, Counter, list[tuple[str, str]]]:
    # MLComputePlan reads a COMPILED model (.mlmodelc), not the .mlpackage.
    # Pointing it at the package fails with an iostream error about
    # coremldata.bin that says nothing about the real cause.
    #
    # Compiled to an explicit path rather than via MLModel.get_compiled_model_path(),
    # whose temporary directory is reclaimed before the compute plan can read it
    # and which then reports the model as simply "not found".
    compiled = Path(ct.utils.compile_model(str(package), str(_COMPILED_CACHE)))

    plan = MLComputePlan.load_from_path(
        str(compiled), compute_units=ct.ComputeUnit.CPU_AND_NE)

    program = plan.model_structure.program
    if program is None:
        raise SystemExit("model is not an mlprogram: residency cannot be read")

    counts: Counter = Counter()
    non_ane: list[tuple[str, str]] = []
    constants = 0

    for function in program.functions.values():
        for operation in walk_operations(function.block):
            # `const` operations are weights and literals. They execute nowhere,
            # and Core ML assigns them no compute device. Counting them in the
            # denominator is not a conservative choice, it is a meaningless one:
            # for this model they are 58% of the program, which turns a genuine
            # 98.8% residency into a reported 41.5% and a false FAIL. Residency
            # is a statement about the operations that actually run.
            if operation.operator_name == "const":
                constants += 1
                continue

            usage = plan.get_compute_device_usage_for_mlprogram_operation(operation)
            if usage is None:
                # A non-const operation with no planned device is a genuine
                # unknown and is counted against residency, not excused.
                counts["unplanned"] += 1
                non_ane.append((operation.operator_name, "unplanned"))
                continue
            preferred = device_name(usage.preferred_compute_device)
            counts[preferred] += 1
            if preferred != "ANE":
                non_ane.append((operation.operator_name, preferred))

    counts["const (excluded)"] = constants
    executable = sum(
        count for device, count in counts.items() if device != "const (excluded)")
    residency = counts["ANE"] / executable if executable else 0.0
    return residency, counts, non_ane


def measure_latency(package: Path, bucket: int, repeats: int) -> list[float]:
    model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_AND_NE)
    tokens = np.zeros((1, bucket), dtype=np.int32)
    tokens[0, 0] = 0

    # Warm up: the first prediction pays Neural Engine compilation, which the
    # app hides behind EmbeddingEngine.warmUp() and which would otherwise
    # dominate a small sample here.
    for _ in range(3):
        model.predict({"tokens": tokens})

    timings = []
    for _ in range(repeats):
        start = time.perf_counter()
        model.predict({"tokens": tokens})
        timings.append((time.perf_counter() - start) * 1000)
    return timings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="esm2_t12_35M_UR50D")
    parser.add_argument("--package", default=None, help="override the .mlpackage path")
    parser.add_argument("--repeats", type=int, default=25)
    args = parser.parse_args()

    package = Path(args.package) if args.package else MODELS_DIR / f"{args.model}.mlpackage"
    if not package.exists():
        print(f"missing {package}", file=sys.stderr)
        return 1

    print(f"model: {package.name}")
    size_mb = sum(f.stat().st_size for f in package.rglob("*") if f.is_file()) / 1e6
    print(f"size:  {size_mb:.1f} MB\n")

    print("--- Neural Engine residency (measured via MLComputePlan) ---")
    _reset_cache()
    residency, counts, non_ane = measure_residency(package)
    constants = counts.get("const (excluded)", 0)
    executable = sum(
        count for device, count in counts.items() if device != "const (excluded)")
    print(f"  executable operations: {executable}"
          f"   (plus {constants} const, excluded: they run nowhere)")
    for device, count in counts.most_common():
        if device == "const (excluded)":
            continue
        print(f"  {device:>9}: {count:5d}  ({count / executable:6.1%})")
    verdict = "PASS" if residency >= RESIDENCY_FLOOR else "FAIL"
    print(f"\n  ANE residency: {residency:.1%}   (gate: >{RESIDENCY_FLOOR:.0%})   {verdict}")

    if non_ane:
        print("\n  operations not planned for the ANE:")
        for name, device in Counter(non_ane).most_common(12):
            print(f"    {name[0]:<28} -> {name[1]}   x{device}")

    print("\n--- latency on THIS MAC (not the iPhone budget: see the docstring) ---")
    print(f"{'bucket':>7}  {'median ms':>10}  {'p90 ms':>8}  {'min ms':>8}")
    for bucket in BUCKETS:
        timings = measure_latency(package, bucket, args.repeats)
        timings.sort()
        median = statistics.median(timings)
        p90 = timings[int(len(timings) * 0.9) - 1]
        print(f"{bucket:>7}  {median:>10.1f}  {p90:>8.1f}  {timings[0]:>8.1f}")

    print()
    return 0 if residency >= RESIDENCY_FLOOR else 1


if __name__ == "__main__":
    raise SystemExit(main())
