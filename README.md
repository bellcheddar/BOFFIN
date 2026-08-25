# 🧬 BOFFIN

> **Turn an iPhone or iPad into a self-contained protein workstation: paste a sequence, get boundaries, disorder, fitness and family, then present the structure from the same device.**

![swift](https://img.shields.io/badge/swift-6.2-F05138?logo=swift&logoColor=white) ![swiftui](https://img.shields.io/badge/SwiftUI-iOS%2026%20%C2%B7%20iPadOS%2026-0071E3?logo=apple&logoColor=white) ![xcode](https://img.shields.io/badge/Xcode-26.6-1575F9?logo=xcode&logoColor=white) ![project](https://img.shields.io/badge/project-native%20Xcode-1575F9) ![coreml](https://img.shields.io/badge/Core%20ML-Neural%20Engine-000000?logo=apple&logoColor=white) ![esm2](https://img.shields.io/badge/ESM--2-t12__35M__UR50D-467FF7) ![ane](https://img.shields.io/badge/ANE%20residency-98.8%25-00d084) ![molstar](https://img.shields.io/badge/Mol*-MIT-00897B) ![swift-testing](https://img.shields.io/badge/swift--testing-331%20passing-9b51e0) ![data](https://img.shields.io/badge/data-RCSB%20%C2%B7%20UniProt%20%C2%B7%20Pfam%20%C2%B7%20KLIFS%20%C2%B7%20GPCRdb-4a9fd4) ![offline](https://img.shields.io/badge/offline-no%20cloud%20inference-00d084) ![phase](https://img.shields.io/badge/phase-5%20of%2012%20%28Family%20tab%29-fcb900) ![licence](https://img.shields.io/badge/licence-not%20yet%20chosen-lightgrey) ![author](https://img.shields.io/badge/author-Marc%20C.%20Deller%2C%20D.Phil.-1C244B)

<table>
<tr>
<td>🌐 <b>Website</b></td><td><a href="https://marcdeller.com" target="_blank" rel="noopener noreferrer">marcdeller.com</a></td>
<td>✉️ <b>Contact</b></td><td><a href="mailto:marc@marcdeller.com">marc@marcdeller.com</a></td>
<td>🐙 <b>GitHub</b></td><td><a href="https://github.com/bellcheddar/Boffin" target="_blank" rel="noopener noreferrer">bellcheddar/Boffin</a></td>
</tr>
</table>

---

**BOFFIN** (**B**oundary, **O**rder, **F**itness and **F**amily **IN**ference) is a native SwiftUI application for iOS and iPadOS. It runs protein language model inference on the Apple Neural Engine, entirely on device, and pairs it with a full interactive structure viewer intended as a mobile equivalent of PyMOL.

Why it matters: the analyses a structural biologist actually reaches for (where does the ordered domain start, which mutations will be tolerated, what family is this, has anyone crystallised something like it) normally mean a laptop, a cluster queue or a web service that wants your sequence. BOFFIN does all of them from a single forward pass on a phone, in aeroplane mode, with no sequence ever leaving the device. It is useful for: designing a construct at the bench before you order the gene, sanity-checking a variant on the train, triaging a homolog set between meetings, and presenting a structure from an iPad without carrying a laptop to the room.

Research use only. No clinical, diagnostic or therapeutic claims.

## 🧭 The two invariants

Everything in BOFFIN follows from two design commitments. They are load-bearing, not stylistic, and they are why the app can be fast on a phone.

**1. One forward pass, four fan-outs.** Every analytical feature is a read-out from a *single* ESM-2 pass on the Neural Engine, not an independent pipeline:

| Fan-out | Source tensor | Feature |
|---|---|---|
| Per-residue hidden states | `last_hidden_state` | Disorder, secondary structure, TM spans, domain boundaries |
| Masked-token logits | `logits` at masked positions | ΔLLR substitution matrix (variant fitness) |
| Mean-pooled embedding | `mean(last_hidden_state)` | Family classification, homolog cosine search |

The expensive step is amortised across the whole app rather than repeated per feature.

**2. Everything is a `ResidueTrack`.** Disorder, secondary structure, TM spans, ΔLLR, motifs and structure-derived interactions are all arrays aligned one-to-one with the sequence, stacked on one scrollable ruler. Tabs are filters over that ruler, not separate features. Any feature that cannot be expressed as a `ResidueTrack` or a structure overlay needs an explicit design decision first.

A misaligned track does not crash: it draws a convincing picture of the wrong thing. Every track is therefore validated against its sequence at the point of production.

## ✨ What it will do

| Tab | Purpose |
|---|---|
| **Order** | Disorder probability, SS3/SS8, TM helices and signal peptide, low complexity, plus MW, pI, ε₂₈₀ and GRAVY over any selection |
| **Fitness** | ΔLLR heatmap (20 amino acids × N positions), sequence logo in bits, mutation basket, disorder masking, CSV and PNG export |
| **Family** | Pfam-level classification with calibrated confidence, KLIFS pocket numbering for kinases, GPCRdb generic numbering for class A GPCRs, motif tracks, SIFTS mapping, embedding homolog search |
| **Boundary** | Ranked construct truncations that never cut through a motif, TM span or disulfide, with crystallisation precedent from the homolog set and tag/linker planning |
| **Structure** | Mol\*-based viewer: representations, colour themes (including painting any `ResidueTrack` onto the structure), a PyMOL-like selection language, measurements, scenes, presentation mode, Pencil annotation, and `.pml` import/export |

## 🧱 Architecture

Local SPM packages under `Packages/`, each independently testable. The app target is a thin shell that wires them together.

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

This is not a convention: `Tools/check-module-graph.sh` fails the build on any violation, checking both source imports and package manifest declarations. If a feature seems to need an upward dependency, the abstraction is in the wrong module.

`BOFFIN.xcodeproj` is a plain native Xcode project, committed to the repository and the source of truth for project configuration. Clone and open it: there is no generation step and no extra toolchain to install. Project changes are made in Xcode and land as a `project.pbxproj` diff. Per-user state (`xcuserdata`) is gitignored, and CI fails if any is ever committed.

## 📋 Requirements

| Requirement | Version | Notes |
|---|---|---|
| macOS | 26 (Tahoe) | Development machine |
| Xcode | 26.x | Command Line Tools alone are not enough: `swift test` needs `lib_TestingInterop.dylib`, which ships only with Xcode. Xcode 26 does not bundle simulator runtimes, so run `xcodebuild -downloadPlatform iOS` once |
| Swift | 6.2 language mode | Strict concurrency enabled |
| Target OS | iOS 26.0 / iPadOS 26.0 | |

## 🔧 Getting started

```bash
git clone https://github.com/bellcheddar/Boffin.git
cd Boffin

open BOFFIN.xcodeproj     # no generation step: the project is committed

xcodebuild build -project BOFFIN.xcodeproj -scheme BOFFIN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild test  -project BOFFIN.xcodeproj -scheme BOFFIN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

./Tools/check-module-graph.sh                 # enforce the module dependency rule
swift format lint --recursive --strict App Packages
```

Package-level tests run without a simulator, because every package declares macOS alongside iOS:

```bash
cd Packages/BoffinCore && swift test
```

## 🧪 Fixtures and testing

`Fixtures/` holds the golden set, committed with provenance and SHA-256 checksums in `Fixtures/MANIFEST.md`. It is committed rather than fetched so the test suite runs with no network, matching the app's own offline rule.

| Fixture | Exercises |
|---|---|
| 1UBQ (ubiquitin) | Baseline and fast path |
| 1HCK (CDK2 with ATP and Mg) | KLIFS numbering, motifs, interaction profiling |
| 2RH1 (β2-adrenergic receptor) | GPCRdb numbering, TM prediction |
| 6EQE (*Piscinibacter sakaiensis* PETase) | Catalytic triad annotation |
| 1XQ8 (α-synuclein, NMR) | Disorder track, boundary solver refusal, multi-model ensemble |
| 7K00 (*E. coli* 70S ribosome) | Viewer performance guardrail |
| 1E8A (selenomethionine) | Non-standard residues, alternate locations |
| 8 malformed inputs | Truncated FASTA, empty records, non-canonical codes, CRLF, bare sequence |

Three fixture choices are judgement calls rather than facts, and are flagged in the manifest rather than assumed: 2RH1 is a T4 lysozyme fusion rather than wild-type ADRB2 (which is why its entry sequence is 500 residues), 1HCK carries ATP rather than a drug-like inhibitor, and 7K00 is 7.3 MB.

Where scientific correctness is at stake (numbering schemes, interaction geometry, biochemical constants), the test is written first from the published definition. A plausible-looking implementation of GPCRdb numbering that is silently wrong is worse than no feature, because it will be believed.

## 📊 Performance budgets

Measured on iPhone 15 Pro class hardware and re-measured at the end of every phase, logged to `Docs/perf-log.md`. Regressions are bugs, not trade-offs.

| Operation | Budget |
|---|---|
| Cold launch to interactive | < 1.2 s |
| Embed, 300 residues | < 250 ms |
| Full 300-residue ΔLLR scan | < 6 s |
| Family classification | < 50 ms |
| Homolog search, 100 k index | < 100 ms |
| Structure load, 5 k atoms | < 1.5 s |
| ANE residency | > 90 % of ops |

The residency figure is the one the whole premise rests on: a naive trace of HuggingFace ESM falls back to the GPU and defeats the point of the app, so the conversion follows Apple's `ml-ane-transformers` tensor layout from the start rather than as a later optimisation.

## ⚖️ Licensing and attribution

Every dependency, data source and model is recorded in `Docs/ATTRIBUTIONS.md` before it is used, with the licence as read at source and the date it was read.

Verified so far:

| Source | Licence | Consequence |
|---|---|---|
| PLIP | **GNU GPL v2** (verified 2026-08-24) | **Never linked, vendored or ported.** The interaction profiler is a clean-room Swift implementation of the published geometric criteria, which are standard structural chemistry and not themselves proprietary |
| Mol\* | MIT (verified 2026-08-24) | Vendored offline with pinned commit hash. No CDN reference anywhere: CI fails the build if one appears |
| ESM-2 | MIT (verified 2026-08-24) | Weights bundled. Note the ESM Metagenomic Atlas *data* is separately CC BY 4.0 and is not used |

KLIFS is the one term still to confirm, since redistribution of derived numbering tables inside a shipped app is genuinely in question, and it gates the Family tab.

## ✅ To Do

Roadmap for BOFFIN, in dependency order. Each phase ends with tests green, performance logged and a demoable build. A phase does not begin until the previous one's acceptance criteria are met. Suggestions welcome.

- [x] **Phase 0: repository foundations.** Git, seven local SPM packages, Xcode project, app shell, CI, swift-format, brand and scientific palette tokens, `ResidueTrack` with alignment validation, and the golden fixture set with provenance and checksums. The module dependency checker is canary-tested against both a planted illegal import and a planted illegal manifest dependency, because a rule-checker that has never failed is not a checker
- [x] **Dropped Tuist for a native Xcode project.** Tuist was trialled in Phase 0 and removed on 2026-08-24. The seven local SPM packages were kept, since they are what makes the module dependency rule mechanically enforceable: this changed how the *project* is managed, not how the *modules* are structured. The accepted cost is that project changes now land as generated `.pbxproj` diffs, which merge badly
- [x] **Closed the Phase 0 acceptance gaps.** 27 package tests pass, the project opens from a clean checkout with no generation step, and the app builds and runs on both the iPhone 17 Pro and iPad Pro 13-inch (M5) simulators. CI's first run earned its keep by finding three defects local testing could not: packages pinned to `.macOS(.v26)` were unloadable on the macOS 15 runner, the app had no `CFBundleIdentifier` (with `GENERATE_INFOPLIST_FILE=NO` Xcode injects nothing, so it builds fine and fails at install), and pinned simulator model names were wrong for the runner
- [ ] **Answer the seven open questions.** Listed in `Docs/BOFFIN_BUILD_PLAN.md` §15. Q1 (head training data) gates Phase 3, Q2 (index scope) and Q3 (family coverage) gate Phase 5. None of them gate Phases 1, 2 or 4, so sequence and ML work is not blocked
- [x] **Phase 1: the sequence spine.** FASTA and UniProt parsing with a diagnostics channel (nothing is changed silently), analytical properties (MW, pI on two selectable pKa scales, ε₂₈₀ reduced and cystine, GRAVY, instability index), and the virtualised track ruler with pinch-zoom and drag selection. Constant tables including the 400-entry DIWV table are generated from checksummed sources rather than transcribed. Found and fixed a real correctness trap: the common reference implementation brackets its pI search to pH 4.05 to 12 and returns the *bound* for sequences outside it, so a poly-acidic peptide reads exactly 4.05; BOFFIN brackets 0 to 14 and reads 3.49
- [x] **Phase 2: ML core.** The premise is proven: **98.8% ANE residency** (746 of 755 executable operations), measured with `MLComputePlan` rather than eyeballed in Instruments. Parity passes on all six shape buckets (relative error 0.61%, cosine 0.99997, ΔLLR Spearman ρ 0.999975). Ships the pinned conversion pipeline, the `EmbeddingEngine` actor with bucketing, overlap tiling, warm-up and caching, and a cross-language golden test so a Swift-side tokenising error cannot hide behind self-consistency. Three findings: fair-esm's rotary embeddings cache by sequence length and a naive trace freezes them at one bucket; **the ANE is fp16 hardware**, so fp32 gets 0% residency and the plan's absolute parity gate had to become a relative one; and `const` operations must be excluded from the residency denominator or 98.8% reads as 41.5%
- [x] **Phase 3 (part): secondary structure and disorder heads.** Trained from scratch on published datasets, because fine-tuning published heads is impossible three ways: DeepTMHMM and NetSurfP-3.0 are built on ESM-1b at 1280 dimensions against our 480, their biLSTM+CRF architectures forfeit ANE residency, and neither is redistributable. Measured against the published baselines including the no-language-model floor: Q3 0.808/0.824/0.743 and Q8 0.676/0.718/0.630 on CB513/TS115/CASP12, which is 3 to 5 points under a 19× larger backbone. Disorder MCC 0.628 on TS115 beats NetSurfP-2.0
- [ ] **Improve the disorder head on novel folds.** MCC 0.500 on CASP12 is *below* the no-language-model floor of 0.573, so on sequences with no close PDB relatives it is currently worse than not using the model. The UI says so rather than averaging it away. Worth trying: RSA as an auxiliary task (NetSurfP predicts it jointly), more head capacity, or a CAID-style reference set with PDB-derived negatives
- [x] **Phase 3 (rest): TM spans and signal peptide.** The blocker was never technical: DeepTMHMM needs a paid commercial licence outside academia and TOPCONS states no terms at all, so a head trained on either could not ship. **UniProt is CC BY 4.0 and Swiss-Prot curates `TRANSMEM` and `SIGNAL` directly**, so the labels now come from somewhere redistributable. 13,000 entries, 5.81 M residues, a 0.78 MB head at 0.71 ms. Per-residue F1 0.885 transmembrane and 0.943 signal. **Accepted on the fixture, not on an average: the beta-2 adrenergic receptor shows exactly seven transmembrane spans**, ubiquitin none, PETase none. A hypothesis died on the way: span precision of 0.58 looks like fragmented helices and merging short gaps is the obvious fix, but the validation sweep rejects it at every gap because adjacent helices are separated by short loops and merging fuses two real ones. A length filter alone took precision to 0.845
- [ ] **Verify every dataset licence before release.** Two remain unverified and both block shipping rather than development. The **DTU pages for the secondary-structure and disorder datasets state no terms at all**, and `Datasets/MANIFEST.md` records that rather than assuming; the transmembrane head no longer depends on them, but the SS and disorder heads still do. **SIFTS states no licence either**: EMBL-EBI publishes a five-year commitment to adopt Creative Commons, which is an intention and not a grant
- [x] **Phase 4: Fitness tab.** ΔLLR heatmap, sequence logo (information-content and signed modes), mutation basket, disorder masking and CSV export. Two scoring modes, each labelled with how it was produced: masked marginal, and a fast preview by wild-type marginal that is one forward pass instead of N. Found and fixed a bug that produced a completely convincing heatmap of garbage: `MLMultiArray` is not densely packed, so indexing by `token × vocabulary` instead of by the array's own strides reads a shifted row for every token after the first
- [ ] **Measure the ΔLLR scan on a real device.** Masked marginal is 9.35 s per 300 residues on an M1 Max against a 6 s budget specified for iPhone 15 Pro hardware. Batching would recover about 31% and Core ML will not combine a batch dimension with enumerated sequence shapes (SIGTRAP or an indefinite hang, depending on configuration), so this needs either device measurement, a per-bucket model, or a relaxed budget
- [x] **Phase 5 (part): family motifs.** Protein kinase and class A GPCR motifs annotated on the shared ruler, detected by published sequence patterns with ordering constraints rather than pattern alone (HRD occurs by chance about once per 8,000 residues). Validated against CDK2's textbook numbering: G-loop G11, β3 lysine K33, HRD H125, DFG D145. Negative controls matter as much, and ubiquitin, ADRB2 and PETase are all correctly refused. Variants handled because they were measured across all 521 human KLIFS kinases: the HRD histidine is Y in 45 of them, the DFG phenylalanine L in 51
- [x] **Phase 5 (part 2): canonical numbering.** Needleman-Wunsch with affine gaps over BLOSUM62 maps a pasted sequence onto the bundled KLIFS and GPCRdb tables. Verified against textbook numbering (KLIFS 17 → CDK2 K33, KLIFS 81 → D145, GPCRdb 3x50 → ADRB2 R131) and, just as important, cross-family numbering is refused. Two corrections on the way: identity over *aligned columns* is badly biased (it excludes gaps, so ubiquitin scored 0.35 against a kinase pocket), and alignment score is the wrong instrument for family membership, so numbering is gated on the motif detector instead
- [x] **Phase 5 (part 3): Pfam classifier.** 97.8% top-1 across 100 families (1% random baseline), 99.8% top-5, calibration error under 0.01, in a 0.81 MB head over the pooled embedding. Temperature scaling was fitted and then *not* applied, because the calibration split said it made things worse. Records a failure accuracy cannot show: the classifier is **closed set**, so ubiquitin (family PF00240, not trained) is called PF00076 at 79.7% confidence, and no threshold catches that — the limitation is stated on screen on every call
- [ ] **Expand classifier coverage beyond 100 families.** Pfam has over 30,000. The closed-set behaviour is stated honestly but the real fix is coverage, plus a genuine open-set rejection mechanism: cosine to the nearest class centroid was measured and is too weak (correct CDK2 scores 0.829, misclassified ubiquitin 0.864)
- [x] **Phase 5 (part 4): SIFTS mapping and homolog search.** Exhaustive search over one pooled embedding per UniProt accession in the PDB (72,421 entries, int8, Accelerate), plus SIFTS segments carrying SEQRES, UniProt and PDB author numbering together. An ANN index was considered and rejected: at this size a query is a 34.8 M multiply-and-add, so approximation would buy latency the app does not need and pay in silently imperfect recall. Three defects found on the way, none of which raised an error: a **truncated `curl` download** left 19,151 of 258,224 PDB entries and quietly redefined "best structure of this protein" as "alphabetically first PDB ID"; **ranking chains by resolution selects fragments** (ADRB2's best-resolution chain is a 90-residue tail at 1.9 A, beating the receptor at 2.4 A, which would have put a disordered peptide in the index in place of a GPCR); and a **1,022-residue ceiling excluded EGFR** and 3,533 others, so the index now tiles exactly as the app does
- [x] **Fixed CI, red for four consecutive commits.** `try #require(modelIsAvailable)` inside a test does not skip it: it marks the test FAILED. Thirteen BoffinML tests went red on a runner with no 67 MB converted model while every local run stayed green, because the artefacts exist on this machine. Suites are now gated with `.enabled(if:)`, which reports *skipped*. The simulator job was failing for a cousin of the same problem: tapping "Fast preview" with no model returned silently, so the UI test saw neither a heatmap nor an explanation
- [x] **Whitened the homolog index, which was quietly losing a quarter of its answers.** Pooled ESM-2 embeddings are anisotropic: random pairs scored a cosine of **0.848** on average with a 99.9th percentile of **0.980**, so everything that distinguishes a hit from a stranger sat in the last two percent of the range, which is precisely what int8 quantisation cannot hold. Measured recall@10 against exhaustive float search was **0.748**, with no error and no symptom. Centring and projecting out four principal directions took it to **0.966** and moved the null to 0.000, which also makes the number on screen mean something. The similarity floor is now the measured 99.9th percentile of unrelated pairs (0.641) rather than a plausible-looking 0.5. Search is **5.4 ms over 72,421 entries** in release, eighteen times inside budget
- [x] **Fixed the iPad UI tests, failing for two reasons that were both about the tests.** `app.tabBars` finds nothing on iPadOS 26 because a SwiftUI `TabView` renders a top strip rather than a UIKit tab bar, and `isHittable` is false on a tab because each is published as a Button containing an identical Button. Seven UI tests now pass on both iPhone 17 Pro and iPad Pro 13-inch
- [x] **Phase 6 (part): construct solver, precedent and tag planning.** Truncations ranked against **hard constraints that are enforced rather than scored**: a weighted penalty would let a construct that bisects the DFG motif win on everything else about it, and that construct is not a compromise, it is dead protein. Refusal is a first-class result, so a fully disordered input is declined with the reason rather than returning an empty list. Precedent is carried into the user's own numbering through the homolog alignment. The tab shows what it is *enforcing* as prominently as what it proposes. Tag planning includes the check that earns its keep: **a protease whose recognition sequence occurs inside the construct is refused, not ranked lower**, because TEV cutting the protein in half looks like proteolysis in the prep rather than a design error
- [x] **Phase 6 (part 2): the construct card.** Boundaries, rationale, enforced regions, tag plan, protease refusals, computed properties and a FASTA record, as plain text with a share sheet. Plain text because a card is read by a person, forwarded, and pasted into a supplier's web form, and all three survive it better than a PDF. Everything on it is either measured or labelled a convention: linker length has no measurement behind it, so the provenance travels *inside* the card rather than around it. One mismatch caught on the way: the pKa scale was a parameter to the text renderer, so a card could print the EMBOSS provenance above Bjellqvist numbers, which differ by 0.2 to 0.5 pH units. It is now stored with the properties it produced, so the mismatch is not expressible
- [x] **Phase 6 (part 3): primer-ready DNA.** The codon table is **computed from 4,317 coding sequences and 1,342,016 codons** of the *E. coli* K-12 reference genome, not copied: Kazusa's published table for this organism rests on **14 CDS and 5,122 codons**, which is a fine sample of fourteen genes and exactly the artefact that acquires authority by being quoted. The generator avoids what it can see itself creating (homopolymers, eleven common cloning sites, rare codons) and records every substitution. A failing test bought one residue of lookahead: a legal codon can strand the *next* residue, since `ATG`-`CAT` is fine and the methionine after it has only `ATG`, completing an NdeI site that cannot then be designed around
- [ ] **Phase 6 (rest): disulfide pairs as a hard constraint.** Pairs cannot be read off a sequence, so a boundary can currently separate two cysteines that pair. Needs the structure viewer
- [x] **Phase 7 (part): structure viewer.** Mol\* 5.11.0 vendored (MIT, checksummed in `VENDOR.md`), a BinaryCIF and MessagePack parser written from the specification, the typed bridge in both directions, and the `ResidueTrack` painted onto the structure. **1UBQ loads offline and Mol\* reports 660 atoms, which is exactly what BOFFIN's own parser reads from the same file** — two independent implementations agreeing. Nothing is interpolated into JavaScript: a test passes a chain identifier of `A'); window.evil=1; ('` and asserts it survives as data. Another test reads the bridge shim out of the bundle and checks every Swift command name has a handler, because a command with no handler is a silent no-op. Two useful failures: `.copy("Resources")` makes a bundle codesign refuses with no hint that a directory name caused it, and BinaryCIF is not a format name to Mol\* but mmCIF with a binary flag
- [x] **Phase 7 (part 2): picking, fetching and predictions labelled as such.** Tap-to-select completes the bridge's return path, walking Mol\*'s segment maps rather than reading `auth_asym_id` at the element index, which is right for a single-chain structure and wrong for every other one. RCSB and AlphaFold fetch, additive and offline-safe, with identifiers validated before any request and the AlphaFold model version pinned rather than "latest" — a silently changing model is a silently changing figure. **A predicted model is not a structure and the type will not let that be lost**: an experimental B-factor and a predicted pLDDT are the same field in the same format meaning opposite things, so `StructureSource` carries which it is and every prediction shows a caveat
- [x] **Phase 7 (part 3): assemblies, ensembles and memory.** The deposited coordinates are the **asymmetric unit**, a crystallographic convenience that is frequently not the molecule: a dimer with one chain in it looks like a monomer until the biological assembly is built, which is a picture of the wrong protein rather than an incomplete one. The viewer lists what a structure declares, builds it, and says so. NMR ensembles report how many models they hold and that one is shown. Memory pressure releases the structure and keeps the page alive, so recovery is one command rather than a blank viewer. Two things the tests caught: a nil assembly encoded to `{}` and worked only by coincidence in someone else's `if`, and **SPM's `.copy` of a directory does not reliably invalidate on inner-file changes**, so the bundled bridge lagged its own source
- [ ] **Phase 7 (rest): representations and export.** Surfaces and symmetry mates, altloc selection, high-DPI and transparent PNG export for figures
- [x] **Phase 8 (part): the selection language.** Tokeniser, recursive-descent parser and evaluator. **`byres (polymer within 5 of organic)` returns CDK2's ATP site on 1HCK**, checked against structural facts rather than the evaluator's own output: ten to forty residues, includes the hinge and the glycine-rich loop, no heteroatoms, and every selected residue confirmed within 5 Å of the ligand. `or` binds loosest as in PyMOL; `50-120` is one token on purpose, since splitting on the minus would break the negative residue numbers the PDB uses for expression tags; and an unknown keyword names itself rather than returning everything or nothing, because an over-broad selection makes a figure that is wrong in a way nobody can see
- [x] **Phase 8 (part 2): measurement.** Distances, angles and dihedrals, with the **sign of a torsion treated as the point rather than a detail** — a viewer reporting the wrong sign is reporting the wrong conformation, and both look equally plausible on screen. Clamping before `acos` is not defensive programming: three nearly collinear atoms put the cosine a hair outside [-1, 1] and `acos(1.0000000001)` is NaN, which reaches a label as "nan degrees". Checked on constructed geometry and then on 1UBQ, where the peptide bond measures 1.33 Å, N-CA-C is 111°, and omega is trans. One test fixture was wrong and the real-structure test passing beside it is what said so
- [x] **Phase 8 (part 3): `.pml` round-tripping.** A deck built on a phone opens on a desktop. **The import is the half that has to fail loudly**: a `.pml` file is a program, so a viewer that quietly ignores what it cannot represent draws a scene that is subtly not the one the file describes. Unsupported commands are reported with their line numbers. The selection expression travels verbatim, which is the whole reason for adopting PyMOL's syntax rather than inventing one, and presenter notes survive as comments because PyMOL has no field for them and they are the half of a deck that explains the other half
- [ ] **Phase 8 (rest): builder, scenes and presentation.** Visual selection builder for touch, scene decks in the UI, presentation mode with external display and presenter view, and Pencil annotation
- [ ] **Phase 9: Interaction profiling.** Clean-room `InteractionProfiler`, 3D overlay, 2D diagram and table. Protonation assumptions surfaced in the UI: a profile that silently guesses protonation states is worse than one that says what it assumed
- [ ] **Phase 10: Platform integration.** App Intents, share extension, Quick Look preview, document types, CloudKit sync, Handoff, widget and Live Activity
- [ ] **Phase 11: Polish and release.** Accessibility audit, onboarding, empty and error states, privacy manifest, attributions screen, TestFlight
- [ ] **Phase 12 (stretch): native renderer and AR.** Metal impostor renderer spike benchmarked against Mol\*, RealityKit AR presentation, visionOS evaluation. Gated on measured performance rather than preference
- [ ] **Choose a licence.** Not yet decided. The choice is constrained: PLIP's GPL v2 is why the interaction profiler is clean-room, and a closed-source App Store release rules out copyleft dependencies generally
- [ ] **Confirm the three fixture caveats.** Whether GPCRdb tests assert against the 2RH1 fusion or canonical P07550, whether the profiler wants a drug-like CDK2 inhibitor rather than ATP, and whether 7K00 should move to on-demand fetch to lighten the repo

## 🚫 Out of scope for v1

Structure prediction (no AlphaFold or Boltz on device), MSA generation, molecular dynamics, docking, and any cloud inference. Prediction requests are routed to [BoltzMaker](https://github.com/bellcheddar/BoltzMaker) on the desktop instead.

## 📄 Licence

Not yet chosen: see the To Do list above. Until a licence is added, no permissions are granted beyond viewing.

---

## 👤 Author

**Marc C. Deller, D.Phil.**  
Structural biologist & drug discovery scientist  

<table>
<tr>
<td>🌐</td><td><a href="https://marcdeller.com" target="_blank" rel="noopener noreferrer">marcdeller.com</a></td>
<td>✉️</td><td><a href="mailto:marc@marcdeller.com">marc@marcdeller.com</a></td>
<td>🐙</td><td><a href="https://github.com/bellcheddar/Boffin" target="_blank" rel="noopener noreferrer">github.com/bellcheddar/Boffin</a></td>
</tr>
</table>
