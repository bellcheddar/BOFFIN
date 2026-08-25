# CLAUDE.md

Working agreement for the BOFFIN repository. Read this at the start of every session.

**BOFFIN** = Boundary, Order, Fitness and Family INference.
A SwiftUI app for iOS and iPadOS: on-device protein sequence analysis on the Apple Neural Engine, plus an interactive structure viewer intended as a mobile equivalent of PyMOL.

Full specification: `Docs/BOFFIN_BUILD_PLAN.md`. That document is authoritative. This file is the short version plus current state.

---

## Current state

- **Phase:** 3, 5 and 6 complete bar disulfides; **7 in progress** (Mol\* vendored, BinaryCIF parsed, bridge and track painting done)
- **Last completed:** Phase 7's viewer bridge and track painting on 2026-08-25 (see `Docs/CHANGELOG.md`)
- **Blocked on:** nothing. Open questions 1, 2 and 3 are answered. **Release** is blocked on two unverified licences: the DTU head-training datasets, and SIFTS, which states none at all

### Phase 7 findings

- **SPM's `.copy` of a directory does not reliably invalidate on inner-file
  changes.** The bundled `boffin-bridge.js` can lag the source, so the app runs
  a bridge that does not match the code beside it. It reads as "no handler for
  X" against a file that visibly has one; `rm -rf .build` fixes it. The
  handler-coverage test is what catches it at all.

- **A resource bundle must not contain a folder called `Resources`.** SPM's
  `.copy("Resources")` produces one, it is read as a macOS-style bundle, and
  codesign refuses it with "bundle format unrecognized, invalid, or unsuitable"
  at link time. The directory is `Web`.
- **BinaryCIF is not a format name to Mol\***: it is `mmcif` with the binary
  flag set. `'bcif'` returns "unknown data format name".
- **Integer packing continues across several elements.** Stopping at the first
  extreme value truncates every large coordinate, and delta encoding makes the
  error accumulate down the column, so test the LAST atom and not only the first.
- **Take `auth_seq_id`, never `label_seq_id`.** The latter counts from one along
  the entity and is not what any paper quotes.

### Phase 5 findings

- **Pooled language-model embeddings are ANISOTROPIC and an index of them must
  be whitened.** Random pairs scored a cosine of 0.848 on average with a 99.9th
  percentile of 0.980, so int8 quantisation lost a quarter of the true nearest
  neighbours (recall@10 0.748) without erroring. Subtracting the mean and
  projecting out four principal directions took recall@10 to 0.966 and moved the
  null to 0.000. The transform ships in the file and every query must go through
  it: skipping it does not fail, it ranks badly.
- **A threshold on a similarity must be measured, never chosen.** The floor is
  the 99.9th percentile of unrelated pairs, 0.641, computed at pack time. The
  0.5 picked by eye beforehand would have admitted the entire index.
- **A validation stage can fail for its own reasons.** The Core ML cross-check
  reported the implementations ranking differently; they agree to a Spearman of
  0.999989. The check had whitened the index and not the query, which is exactly
  the mismatch it was written to catch.
- **`app.tabBars` does not exist on iPadOS 26** (a SwiftUI `TabView` renders a
  top strip), and `isHittable` is false on a tab because each is a Button
  containing an identical Button. Reach tabs through one helper and assert on
  the destination.

- **A `#require` inside a test is not a skip: it is a FAILURE.** Artefact-gated
  suites written that way turned a missing build artefact into four consecutive
  red CI runs while every local run stayed green, because the artefacts exist on
  this machine. Gate the SUITE with `.enabled(if:)`, which reports skipped.
  BoffinML and BoffinData both use that now.
- **A truncated `curl` download does not look truncated.** `--max-time` leaves
  the partial file on disk and `|| echo` swallows the exit code, so
  `entries.idx` arrived with 19,151 of its 258,224 entries and the build did not
  error: every absent entry simply fell to a default rank, turning "best
  resolution structure of this protein" into "alphabetically first PDB ID".
  Check byte counts against `Content-Length` and assert coverage in the builder.
- **Best-resolution-wins picks FRAGMENTS.** The highest-resolution chain for
  ADRB2 is a ninety-residue C-terminal peptide at 1.9 A; the receptor itself
  (2RH1) is 2.4 A and loses. Since the index stores one embedding per accession,
  that would have put a disordered tail in the index in place of a GPCR. Rank on
  UniProt coverage first, resolution only among comparable coverage.
- **Refusing to tile the index would have removed every large protein**,
  including EGFR at 1,210 residues. The app already tiles long queries, so the
  index tiles identically: capacity 1022, overlap 128, overlapping positions
  averaged. Both sides must change together.
- **PDB author numbering cannot be derived by offset from the first observed
  residue.** It is whatever the depositor chose: not 1-based, not contiguous,
  sometimes negative for expression tags, sometimes carrying insertion codes.
  SIFTS segments give the offset per contiguous run; 1.87% are non-arithmetic
  and are refused rather than interpolated.
- **Embedding cosine is not sequence identity** and reads as one to anyone who
  has run BLAST. Every hit carries a real alignment identity AND a coverage,
  because identity denominated on the reference reads 100% for a query with a
  large insertion.

- **A closed-set classifier reports the nearest trained class, confidently, for
  anything outside its label set.** Ubiquitin (PF00240, not trained) is called
  PF00076 at 79.7%. No confidence threshold catches it. State the limitation;
  do not try to score around it.
- **Cosine to the nearest class centroid is a weak OOD signal here**: correct
  CDK2 sits at 0.829, wrong ubiquitin at 0.864. It separates in- from
  out-of-distribution, not right from wrong, and is only used for that claim.
- **Temperature scaling can make calibration worse.** Fitted 1.17, and the
  calibration split said raw 0.013 beat scaled 0.015, so it is not applied.
  Decide on the calibration split, never on test.

- **Sequence identity over ALIGNED COLUMNS is a biased statistic.** It excludes
  gaps, so a short overlap that happens to match scores as highly as a full
  correspondence. Ubiquitin scored 0.35 against a kinase pocket and ADRB2 scored
  0.48 against PLK2 that way. Divide by the REFERENCE length instead.
- **Alignment score does not answer family membership.** It answers "how close
  is the nearest reference". Numbering is gated on the motif detector, which
  does answer membership and whose negative controls pass.

- **Motif patterns need ORDERING CONSTRAINTS, not just patterns.** "HRD" occurs
  by chance about once per 8,000 residues. Requiring HRD before DFG at 12 to 45
  residues' separation is what turns a pattern match into evidence.
- **Motif variants must be measured, not recalled.** Across the 521 human KLIFS
  kinases, the HRD histidine is Y in 45 and the DFG phenylalanine is L in 51, so
  a strict HRD/DFG search misses about a tenth of the kinome.
- **Positional heuristics are not definitions.** "The first lysine after the
  glycine-rich loop" found CDK2's K24 rather than K33; the published VAIK motif
  finds the right one.
- **KLIFS pockets are DISCONTINUOUS in sequence.** The 85 residues are a
  structural pocket, so they cannot be located by substring search and mapping a
  pasted sequence onto them needs real alignment. That is why the numbering
  tables are bundled and the mapping is still outstanding.
- Licences verified at source: **GPCRdb CC BY 4.0**; **KLIFS states open for
  academia and industry but names no licence**, which is recorded as stated-open
  rather than rounded up.

### Phase 4 findings

- **`MLMultiArray` IS NOT DENSELY PACKED.** Core ML pads rows for alignment.
  Always index through `array.strides`, never `index * width`. Getting this
  wrong reads a shifted-but-real-looking vector: token 0 is correct because its
  offset is zero, and everything after it is quietly wrong. It produced a
  perfect-looking delta-LLR heatmap that was garbage.
- **Identical output after a real code change means the wrong code path is
  being examined.** Three successive "fixes" here returned byte-for-byte
  identical numbers before the real bug was found. Read that as a signal.
- **Core ML will not combine a batch dimension with enumerated sequence
  shapes.** Enumerated batch crashes predict with SIGTRAP; fixed batch with
  enumerated lengths hangs at 0% CPU. Batch 1 with enumerated lengths is the
  only configuration that works, so masked-marginal scoring is unbatched.
- **`ANECompilerService` can wedge at 100% CPU** and starve every subsequent
  conversion (they sit at 0% CPU for tens of minutes). It is root-owned, so
  clearing it needs `sudo pkill -9 -f ANECompilerService`. Symptoms look exactly
  like a hung conversion.
- **`AnalysisHeads.headWindow` and `EmbeddingEngine.scoringBatchSize` must match
  the converter by hand.** Both fail only at runtime.

### Phase 3 findings (rest)

- **A licence problem can have a data solution.** DeepTMHMM and TOPCONS cannot
  ship; Swiss-Prot curates `TRANSMEM` and `SIGNAL` directly and UniProt is CC BY
  4.0. Check whether the annotation already exists somewhere redistributable
  before concluding a feature is blocked.
- **Merging fragmented spans makes transmembrane prediction WORSE.** It is the
  obvious cure for span precision of 0.58 and the validation sweep rejects it at
  every gap: adjacent helices are separated by short loops, so closing a gap of
  four fuses two real helices. A length filter alone took precision to 0.845 for
  a recall cost of 0.03.
- **Only 6.9% of Swiss-Prot `TRANSMEM` spans are experimentally evidenced.**
  Score the test split twice; span recall falls from 0.811 to 0.688 on the
  experimental subset.
- **Swiss-Prot negatives are real**, unlike DisProt's: a curated soluble protein
  with no `TRANSMEM` feature is a genuine negative because a curator would have
  annotated one.

### Phase 3 findings, each of which failed silently

- **`np.load` on a compressed `.npz` is LAZY.** Every `bundle["key"][lo:hi]`
  re-decompresses the whole array: 6.8 s per access here, roughly 20 hours per
  epoch, with no error and the process at 99% CPU looking busy. Materialise
  once. Relatedly, **piping a long run through `grep` block-buffers its log**,
  which left a monitor watching a permanently empty file.
- **DisProt cannot train a disorder classifier.** It curates only
  positively-observed disorder: 17.5% residue coverage, and the "structured"
  region type appears **five times in the whole database**. There are no
  negatives. Useful as an independent recall check, not as training labels.
- **The heads' 0% ANE residency is correct.** Every operation is ANE-*capable*;
  Core ML prefers CPU for a 12-op, 0.63 MB model, at 2% of the backbone pass.
  The >90% gate is a **backbone** gate: applied to a head it would push towards
  a bigger head purely to clear a threshold. Heads are gated on latency.
- **`EnumeratedShapes` crashes `predict` with SIGTRAP for these heads**, after
  converting and saving cleanly. One fixed 1024 window instead, whose zero
  padding was *measured* harmless (100% argmax agreement against a 128 window).
- **`AnalysisHeads.headWindow` must match `--bucket` in `convert_heads.py`.**
  A mismatch builds, converts, passes parity and fails only at runtime. It was
  caught by running the app, not by the test suite.

### Open question 1, answered: heads are TRAINED, not adapted

Marc's first answer was "use published heads, fine-tune them". Investigation
showed that is not possible, for three independent reasons, and he then chose to
train small heads on the published datasets instead (which is what the build
plan specified in section 4.1 all along).

**Do not revisit this without re-reading the three reasons**, because "just
fine-tune DeepTMHMM" is a very reasonable-sounding suggestion:

1. **Dimension.** DeepTMHMM and NetSurfP-3.0 are both built on **ESM-1b, which
   is 1280-wide**. BOFFIN's backbone is ESM-2 t12 35M at **480**. Their weights
   cannot be loaded at all, at any learning rate.
2. **Architecture.** They are biLSTM+CRF and ResNet+biLSTM. Recurrent layers and
   CRF decoding do not achieve Neural Engine residency, so adopting them would
   forfeit the 98.8% Phase 2 established, which is the app's entire premise.
3. **Licence.** DeepTMHMM needs a paid commercial licence outside academia.
   NetSurfP-3.0 **declares no licence at all**, which defaults to all rights
   reserved. Neither can ship inside BOFFIN.

Dimension-compatible ESM-2 35M heads *do* exist on HuggingFace, but they are
2022 HuggingFace-tutorial outputs with roughly a dozen downloads, mostly
unlicensed and with no published evaluation. Using one as the basis of a
scientific tool is exactly the "plausible but silently wrong, and believed"
failure hard rule 6 exists to prevent.

**Dataset licences are all UNVERIFIED and that blocks release, not development.**
The DTU download pages state no terms. `Datasets/MANIFEST.md` records this
honestly rather than assuming. Confirm at source before shipping any head
trained on them.

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
   **Adding a source file is the one exception**, because every phase from 6 onward adds several and the alternative is piling unrelated types into existing files. `python3 Tools/add-file-to-target.py <path> <target>` makes exactly the four edits Xcode makes, deterministically and idempotently. Any three of those four produce a project that builds and silently omits the file, which is why it is a script rather than a hand edit.
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
