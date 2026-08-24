# CLAUDE.md

Working agreement for the BOFFIN repository. Read this at the start of every session.

**BOFFIN** = Boundary, Order, Fitness and Family INference.
A SwiftUI app for iOS and iPadOS: on-device protein sequence analysis on the Apple Neural Engine, plus an interactive structure viewer intended as a mobile equivalent of PyMOL.

Full specification: `Docs/BOFFIN_BUILD_PLAN.md`. That document is authoritative. This file is the short version plus current state.

---

## Current state

- **Phase:** 2 (ML core) **complete**. Phase 3 (Order tab) is next
- **Last completed:** Phase 2 on 2026-08-24 (see `Docs/CHANGELOG.md`)
- **Blocked on:** **open question 1 gates Phase 3** and must be answered before it starts: which datasets for the disorder, SS and TM heads (DisProt, CB513, TOPCONS, DeepTMHMM), and are they trained here or are published heads fine-tuned? Q2 and Q3 gate Phase 5

### Decisions and findings from Phase 2

- **The premise is proven: 98.8% ANE residency** for esm2_t12_35M_UR50D. The
  risk register's fatal risk is retired.
- **fair-esm's `RotaryEmbedding` caches cos/sin tables keyed on sequence length
  in Python.** A naive `torch.jit.trace` freezes them at the traced length, so
  with `EnumeratedShapes` every other bucket is silently wrong. `convert_backbone.py`
  swaps in a traceable version and asserts that it replaced a non-zero count.
- **The ANE is fp16 hardware.** fp32 achieves 0% residency (all 682 ops on CPU).
  The plan's `max absolute error < 1e-2` parity gate was therefore unachievable
  and has been revised to relative error < 1% plus cosine > 0.999 (Marc's call).
- **Exclude `const` from the residency denominator.** They execute nowhere and
  are 58% of this program: including them reports 41.5% instead of 98.8%.
- **The model is a build artefact and is NOT committed** (67 MB). The tokeniser
  JSON IS committed: it is the Python-to-Swift contract and is 1 KB. Tests that
  need the model skip with an explicit reason when it is absent.
- **Python 3.12 and torch 2.7.0 specifically.** coremltools 9.0 ships no wheel
  for this machine's default 3.14, and warns on any torch newer than 2.7.0.

### Decisions taken in Phase 1

- **Both pKa scales, user-selectable** (Marc's call). Bjellqvist matches ExPASy
  ProtParam; EMBOSS matches command-line pipelines. Every result carries the
  scale that produced it, because they disagree by 0.2 to 0.5 pH units.
- **Constant tables are generated, never transcribed.** The DIWV table is 400
  values; hand typing it is exactly the silently-wrong-but-believed failure
  hard rule 6 exists to prevent. `Tools/data/generate_amino_acid_tables.py`
  emits the Swift from checksummed sources.
- **The isoelectric point brackets 0 to 14, not 4.05 to 12.** Biopython
  brackets the narrow range and returns the *bound* for sequences outside it,
  so poly-aspartate reads exactly 4.05. Tests pin both the agreement (ubiquitin
  6.5616, identical) and the deliberate divergence (DDDEEE 3.49, not 4.05).
- **Non-canonical residues are excluded from properties and counted**, never
  coerced or silently dropped. `nonCanonicalCount` drives a UI warning.
- **Hydropathy leaves the termini blank** rather than averaging a truncated
  window. A half-window average is a different statistic wearing the same
  colour, and the termini are where construct boundaries get chosen.
- **`TrackRulerStyle` is injected by the app.** BoffinCharts and BoffinUI
  cannot see each other under the dependency rule, so the app wires the brand
  palette into the renderer. That is the rule working, not a workaround.

### What Phase 0 delivered

Repo, seven SPM packages, Xcode project, app shell, CI, swift-format, design
tokens, `ResidueTrack` with alignment validation, fixture set with provenance,
and the start of the licence audit. All seven packages build and the whole tree
is lint-clean.

### Phase 0 acceptance, honestly stated

| Criterion | Status |
|---|---|
| Module skeleton with the dependency rule enforced | Met: `Tools/check-module-graph.sh` passes and is canary-tested both ways |
| Package tests pass | Met: 27 tests across seven packages, all green under Xcode 26.6 |
| Project opens from a clean checkout | Met: `BOFFIN.xcodeproj` is committed, three targets, seven local packages resolve |
| CI green | Met for the structural gates and package tests on run 2; the simulator jobs are the last to confirm |
| Empty app builds and runs on iPhone and iPad simulators | Met: TEST SUCCEEDED on iPhone 17 Pro and iPad Pro 13-inch (M5), 2026-08-24 |
| Fixture set committed | Met, with three caveats flagged in `Fixtures/MANIFEST.md` |
| `CLAUDE.md` in place | Met |
| README with To Do roadmap | Met: house standard, 13 badges verified, Elementor assets in `Docs/web/` |

### What CI's first run caught

Treating the first run as debugging rather than a gate was the right call: it
found three real defects that local testing could not have.

1. **`.macOS(.v26)` on every package** made the test bundles unloadable on the
   macOS 15 runner ("built for macOS 26.0 which is newer than running OS").
   That platform line exists only so `swift test` runs on the host, so it must
   be as LOW as the sources compile against, not pinned to the newest OS. Now
   `.v14`.
2. **The app had no `CFBundleIdentifier`.** With `GENERATE_INFOPLIST_FILE=NO`
   Xcode injects nothing, and a plist missing the bundle identity keys builds a
   perfectly good `.app` that then fails at *install* time with an error that
   reads like a simulator fault.
3. **Pinned simulator model names were wrong.** The runner had an iPhone 16 Pro
   where this machine has a 17 Pro. CI now resolves a device by family at run
   time via `Tools/pick-simulator.py`, which parses simctl's JSON rather than
   grepping it (device names contain brackets: "iPad Pro 13-inch (M5)").

Useful locally: `-destination 'generic/platform=iOS Simulator'` builds the app
without needing a simulator runtime at all.

### Toolchain notes worth keeping

- `swift test` cannot run under Command Line Tools alone: `lib_TestingInterop.dylib`
  ships only with Xcode. The suites compile and link but will not execute.
- `sudo xcode-select -s` has no TTY in an agent session. Setting
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` achieves the same
  thing without sudo, and is how the package tests were run.
- Xcode 26 does **not** bundle simulator runtimes: `xcodebuild -downloadPlatform iOS`
  is a separate ~8.5 GB download. A fresh machine is not ready for a simulator
  build just because Xcode is installed. Running it while Xcode is already
  fetching the same asset creates a duplicate registration, one marked
  `Unusable - Other Failure: Duplicate of <uuid>`; clear it with
  `xcrun simctl runtime delete <uuid> --keep-asset`.
- **Never `killall com.apple.CoreSimulator.CoreSimulatorService`.** It is the
  commonly suggested fix for Xcode not enumerating simulators, and on macOS 26
  it unmounts the runtime cryptex volume, which does not re-establish without a
  reboot. `simctl runtime list` still reports `Ready` while every device reads
  `unavailable, runtime profile not found`, so the diagnostics actively mislead.
  This happened here on 2026-08-24 and cost the simulator acceptance row.
  Diagnose with `mount | grep iOS_` before reaching for anything.
- Tuist was trialled and dropped on 2026-08-24 at Marc's request, in favour of
  a native Xcode project. The seven local SPM packages were kept: they are what
  make the dependency rule mechanically enforceable, and dropping Tuist changed
  how the *project* is managed, not how the *modules* are structured.

### Decisions taken in Phase 0 that were not in the build plan

- Packages declare `.macOS(.v26)` alongside `.iOS(.v26)` so package tests run
  on the host without a simulator. The app itself remains iPhone and iPad only.
- `Sequence` is named `ProteinSequence`, to avoid shadowing the standard
  library protocol and making every generic constraint in `BoffinCore`
  ambiguous.
- `AminoAcid`, `ResidueIdentity` and `Residue` have hand-written `Codable`
  conformances, because `Character` is not `Codable`. They round-trip through
  one-letter strings, which also keeps cached analyses readable by hand.
- The build plan was moved from the repository root to `Docs/`, which is where
  this file already said it lived.

Update this block at the end of every session.

---

## The two invariants

**1. One forward pass, four fan-outs.**
Every analytical feature reads from a single ESM-2 pass on the ANE: per-residue hidden states (order, boundaries), masked-token logits (fitness), pooled embedding (family, homolog search). Do not build independent pipelines per feature.

**2. Everything is a ResidueTrack.**
Disorder, secondary structure, TM spans, ΔLLR, motifs and structure-derived interactions are all arrays aligned to the sequence, stacked on one ruler. Tabs are filters over that ruler. Any feature that cannot be expressed as a `ResidueTrack` or a structure overlay needs an explicit design decision first.

---

## Hard rules

1. **`BOFFIN.xcodeproj` is committed and is the source of truth.** Make project changes (targets, capabilities, resources, build settings) in Xcode and commit the resulting `project.pbxproj` diff. Never commit `xcuserdata`. Tuist was dropped on 2026-08-24 in favour of a plain native Xcode project.
2. **Never break offline operation.** No CDN references, no network in any core path. Network features are additive and degrade cleanly.
3. **Never string-interpolate into JavaScript.** All Mol* traffic goes through the typed command envelope in `BoffinViewer`.
4. **Never link or port PLIP.** It is GPL v2. The interaction profiler is a clean-room Swift implementation of published geometric criteria.
5. **Never loop one Core ML prediction per residue.** Batch masked positions.
6. **Where science is at stake, write the test first** from the published definition. A plausible-looking but silently wrong implementation of KLIFS or GPCRdb numbering is worse than no feature, because it will be believed.
7. **Ask before inventing scientific defaults.** Surface uncertain thresholds, cutoffs and numbering rules rather than picking a plausible number.
8. **British English, no em dashes** (colons or parentheses instead) in all user-facing copy, comments and docs.
9. **Every new dependency needs a licence check** recorded in `Docs/ATTRIBUTIONS.md`.
10. **One phase at a time.** Do not start Phase N+1 until Phase N acceptance criteria are met.

---

## Module dependency rule

```
BoffinCore          → nothing
BoffinML            → BoffinCore
BoffinData          → BoffinCore
BoffinStructure     → BoffinCore
BoffinCharts        → BoffinCore
BoffinUI            → BoffinCore
BoffinViewer        → BoffinCore, BoffinStructure
App                 → everything (wiring only)
```

CI enforces this. If a feature seems to need an upward dependency, the abstraction is in the wrong module.

---

## Performance budgets

Measured on iPhone 15 Pro class hardware, logged to `Docs/perf-log.md` at the end of every phase.

| Operation | Budget |
|---|---|
| Cold launch to interactive | < 1.2 s |
| Embed, 300 residues | < 250 ms |
| Full 300-residue ΔLLR scan | < 6 s |
| Family classification | < 50 ms |
| Homolog search, 100 k index | < 100 ms |
| Structure load, 5 k atoms | < 1.5 s |
| ANE residency | > 90 % of ops |

Regressions are bugs, not trade-offs.

---

## Golden fixtures

`Fixtures/` holds the reference set. Every analytical change is checked against all of them:

| Fixture | Exercises |
|---|---|
| 1UBQ (ubiquitin) | Baseline, fast path |
| CDK2 + ATP-site ligand | KLIFS numbering, motifs, interaction profiling |
| β2-adrenergic receptor | GPCRdb numbering, TM prediction |
| PETase / cutinase | Catalytic triad annotation, Marc's domain |
| α-synuclein | Disorder track, boundary solver refusal |
| Ribosomal assembly | Viewer performance guardrails |
| Malformed inputs | Truncated FASTA, non-canonical residues, altlocs, NMR ensembles |

---

## Commands

```bash
open BOFFIN.xcodeproj     # the project is committed: no generation step

xcodebuild build -project BOFFIN.xcodeproj -scheme BOFFIN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild test  -project BOFFIN.xcodeproj -scheme BOFFIN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

./Tools/check-module-graph.sh                       # enforce the dependency rule
swift format lint --recursive --strict App Packages
(cd Packages/BoffinCore && swift test)               # per-package, no simulator

./Tools/coreml/convert.sh # rebuild Core ML models (requires Python env)
./Tools/coreml/validate_parity.py
```

`Tools/bootstrap-xcodeproj.rb` created the project once and is kept for
provenance only. **Running it again overwrites the project and discards every
change made in Xcode since.**

---

## Brand

Navy `#1C244B`, accent blue `#467FF7`. System font for UI, monospace for sequences, Baloo 2 for the wordmark only. Diverging red–white–blue for ΔLLR, sequential for continuous tracks. Dark mode is first-class: structures on true black for OLED presentation.

---

## Out of scope for v1

Structure prediction (no AlphaFold or Boltz on device), MSA generation, molecular dynamics, docking, any cloud inference. Route prediction requests to BoltzMaker on the desktop.

Research use only. No clinical, diagnostic or therapeutic language anywhere.
