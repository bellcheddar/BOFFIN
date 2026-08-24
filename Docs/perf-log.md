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
