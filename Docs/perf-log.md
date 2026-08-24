# Performance log

Budgets from build plan section 4.5, measured on iPhone 15 Pro class hardware
and re-measured at the end of every phase. Regressions are bugs, not
trade-offs.

| Operation | Budget |
|---|---|
| Cold launch to interactive | < 1.2 s |
| Embed, 300 residues | < 250 ms |
| Full 300-residue delta-LLR scan | < 6 s |
| Family classification | < 50 ms |
| Homolog search, 100 k index | < 100 ms |
| Structure load, 5 k atoms | < 1.5 s |
| ANE residency | > 90 % of ops |

---

## Phase 0 (2026-08-24)

No measurements. Phase 0 ships no analytical code and no model: there is
nothing yet whose performance means anything.

Cold launch is deliberately **not** recorded for the placeholder shell. A
sub-second launch for a screen showing three lines of static text is not
evidence about the launch budget, and logging it would create a baseline that
looks like a regression the moment real work is wired in.

First real entries land in Phase 1 (ruler interaction at 120 Hz) and Phase 2
(embedding latency and ANE residency), the latter being the number the whole
premise of the app rests on.

For the record, the only timing worth noting from Phase 0 is the UI launch test
on the simulator: 5.05 s on iPhone 17 Pro and 4.94 s on iPad Pro 13-inch (M5).
That figure is `XCUIApplication().launch()` plus test harness overhead on a
simulated device, **not** cold launch to interactive on real hardware, and it
must not be compared against the 1.2 s budget. Simulator timings are not device
timings and are recorded here only so nobody later mistakes their absence for an
oversight.


## Phase 1 (2026-08-24)

No device measurements yet: everything below the model layer is composition
arithmetic over a few hundred residues, and the 120 Hz ruler budget is a
*device* number that a simulator cannot honestly report.

What is established instead is the structural property the budget depends on:
the ruler draws only the residues in the viewport plus overscan, pinned by
`TrackRulerGeometryTests`. A 10,000-residue sequence in a 400-point viewport
draws fewer than 100 residues, not 10,000. That is the difference between
meeting the budget and missing it by two orders of magnitude, and it is checked
by a test rather than by eye.

The ruler's frame timing on real hardware is a Phase 3 measurement, once there
are model-derived tracks stacked on it and the row count is realistic.


## Phase 2 (2026-08-24)

### Neural Engine residency: 98.8% (gate: >90%) PASS

The number the whole premise rests on. Measured with `MLComputePlan`, which
reports the device Core ML plans for each operation, rather than read off an
Instruments trace.

| | esm2_t12_35M_UR50D |
|---|---|
| Executable operations | 755 |
| Planned for the ANE | 746 (**98.8%**) |
| Planned for the CPU | 9 (1.2%) |
| `const` operations excluded | 1043 |

The 9 CPU operations are the padding-mask logic (`equal`, `greater_equal`,
`select`, `cast`, one `add`, one `gather`): trivial elementwise work that is
expected to stay on the CPU.

**Counting `const` in the denominator would have reported 41.5% and a false
FAIL.** Constants are weights and literals that execute nowhere and are assigned
no device; here they are 58% of the program. Residency is a claim about the
operations that actually run.

### Precision is not a free choice

| | fp16 | fp32 |
|---|---|---|
| ANE residency | **98.8%** | **0.0%** (all 682 ops on CPU) |
| Package size | 67.4 MB | 134.4 MB |
| Max absolute error vs PyTorch | 0.031 | 0.0017 |
| Relative error (of signal scale) | 0.61% | 0.03% |
| Cosine similarity | 0.99997 | 0.99999 |
| delta-LLR Spearman rho | 0.999975 | 0.999999 |

The Neural Engine is fp16 hardware. fp32 is more accurate and **cannot run on
the ANE at all**, which makes it unshippable for this app regardless of its
accuracy. This is why the plan's original `max absolute error < 1e-2` gate was
replaced with a relative one: as written it selected for a model that defeats
the premise.

### Latency: development Mac only, NOT the budget

Measured on an M1 Max. The build plan's budgets are for iPhone 15 Pro class
hardware and an M-series ANE is not an A-series ANE, so **these are not the
budget numbers and must not be recorded as though they were.**

| Bucket | Median ms |
|---|---|
| 128 | 4.0 |
| 256 | 10.0 |
| 384 | 31.3 |
| 512 | 47.7 |
| 768 | 92.2 |
| 1024 | 147.3 |

A 300-residue sequence needs 302 tokens and so lands in the 384 bucket: 31 ms
here. The budget is < 250 ms on an iPhone. That leaves a large apparent margin,
but the honest statement is that **the < 250 ms budget is still unmeasured**: it
needs an on-device XCTest measure block, which is outstanding.


## Phase 3 (2026-08-24)

### Head accuracy, against the NetSurfP-3.0 paper's own baselines

Benchmarks are the published ones (Table 1, Nucleic Acids Research 50:W510).
"one-hot" uses no language model at all and is the floor: below it, the
embeddings are contributing nothing.

| | CB513 | TS115 | CASP12 |
|---|---|---|---|
| **BOFFIN Q3** | **0.808** | **0.824** | **0.743** |
| one-hot floor | 0.719 | 0.746 | 0.704 |
| NetSurfP-3.0 | 0.846 | 0.856 | 0.791 |
| **BOFFIN Q8** | **0.676** | **0.718** | **0.630** |
| one-hot floor | 0.573 | 0.628 | 0.576 |
| NetSurfP-3.0 | 0.711 | 0.749 | 0.669 |
| **BOFFIN disorder MCC** | **0.431** | **0.628** | **0.500** |
| one-hot floor | n/a | 0.561 | 0.573 |
| NetSurfP-2.0 | n/a | 0.624 | 0.653 |
| NetSurfP-3.0 | n/a | 0.662 | 0.621 |

Secondary structure sits 3 to 5 points below NetSurfP-3.0, which runs a
650M-parameter backbone and a ResNet+biLSTM head on a server, against BOFFIN's
35M backbone and 0.63 MB head on a phone. Comfortably clear of the floor
everywhere.

Disorder **beats NetSurfP-2.0 on TS115** and is **below the one-hot floor on
CASP12** (0.500 against 0.573). CASP12 is free-modelling targets with no close
homologues, which is exactly where a small model without MSA profiles should be
weakest, so the shape of the failure is coherent. It is surfaced in the UI
rather than averaged into a single reassuring number.

The disorder decision threshold is **0.900, tuned on validation and applied
blind**. An earlier sweep on the test sets themselves suggested 0.631 on TS115;
that was an upper bound, not a result, and is not what is reported here.

### Head cost

| | secondary structure | disorder |
|---|---|---|
| Size | 0.63 MB | 0.63 MB |
| Latency (bucket 1024) | 0.64 ms | 0.58 ms |
| Core ML vs PyTorch argmax | 100% | 100% |

Against the backbone's 31 ms, each head is roughly 2% of a pass. Both are
gated on **latency, not residency**: see the note below.

### Why the heads report 0% ANE residency, and why that is correct

Every operation in both heads lists the Neural Engine among its **supported**
devices. Core ML *prefers* the CPU, because a 12-operation, 0.63 MB model is
not worth dispatching. The build plan's ">90% of operations on the ANE" is a
**backbone** gate; applied to a head this small it would push towards making
the head bigger purely to satisfy a threshold, which is the metric driving the
design rather than the reverse.

What the convolutional shape is still buying is unchanged and real: a biLSTM
head would not be ANE-capable at all and would be far more than 2% of the pass.


## Phase 4 (2026-08-25)

### Substitution scanning, 300 residues, on this Mac

| Mode | Cost | Passes |
|---|---|---|
| Fast preview (wild-type marginal) | **31 ms** | 1 |
| Masked marginal | **9.35 s** | 300 |
| Budget (iPhone 15 Pro class) | < 6 s | |

**Masked marginal misses the 6 s budget on this hardware, and that is stated
rather than rounded away.** The budget is specified for an iPhone 15 Pro, and an
A-series Neural Engine is not an M-series one, so the figure on device is
unknown and could land either side. It has not been measured there.

Batching would have closed most of the gap and is not available. Measured at
bucket 384: 31.2 ms per variant at batch 1, 21.6 at batch 8 (a 31% saving,
saturating there), 22.6 at batch 16. Core ML would not accept a batch dimension
alongside enumerated sequence shapes in any configuration tried:

* enumerated batch: converts, saves, predicts at the default shape, then
  crashes the process with SIGTRAP on any other batch;
* fixed batch 8 with enumerated sequence lengths: converts and saves, then
  hangs indefinitely on first predict at 0% CPU;
* fixed batch and fixed length: works, but needs one model per bucket or a
  second 67 MB model against a 200 MB bundle target.

What makes the miss tolerable is the fast mode: a single forward pass for the
whole matrix, 300 times cheaper, so the interactive answer is immediate and the
accurate scan runs behind it.

### Model

The backbone was reconverted to add a `logits` output, which Phase 2 did not
need. Residency and parity were re-measured rather than assumed to carry over:
**98.8% ANE residency**, parity passing on all six buckets, delta-LLR Spearman
rho 0.999975 against PyTorch.
