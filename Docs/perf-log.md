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
