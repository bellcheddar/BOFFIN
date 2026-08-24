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
