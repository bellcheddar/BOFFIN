# BOFFIN: Build Plan

**Boundary, Order, Fitness and Family INference**
A native SwiftUI application for iOS and iPadOS. On-device protein sequence analysis on the Apple Neural Engine, plus a full interactive structure viewer intended as a mobile equivalent of PyMOL.

Author: Marc C. Deller, D.Phil. (marc@marcdeller.com)
Target agent: Claude Code
Document version: 1.0

---

## 1. Product definition

### 1.1 One-line description

BOFFIN turns an iPhone or iPad into a self-contained protein workstation: paste a sequence, get construct boundaries, disorder and secondary structure, per-position mutational fitness, family and motif assignment, and a fully interactive 3D structure you can annotate and present from.

### 1.2 The architectural insight that unifies the app

Every analytical feature is a read-out from **one ESM-2 forward pass** executed on the Neural Engine:

| Fan-out | Source tensor | Feature |
|---|---|---|
| Per-residue hidden states | `last_hidden_state` | Disorder, secondary structure, TM spans, domain boundaries |
| Masked-token logits | `logits` at masked positions | ΔLLR substitution matrix (variant fitness) |
| Mean-pooled embedding | `mean(last_hidden_state, dim=seq)` | Family classification, homolog cosine search |

One model, one inference, four lenses. The expensive step is amortised across the entire app rather than repeated per feature. **Do not architect these as independent pipelines.**

### 1.3 The second unifying abstraction

Every analytical output is expressed as a **`ResidueTrack`**: an array of values aligned one-to-one with the sequence. Disorder, secondary structure, TM span, ΔLLR score, motif membership, family numbering and structure-derived interactions all stack on a single scrollable ruler. Tabs are filters over that ruler, not separate features.

```swift
protocol ResidueTrack: Sendable {
    var id: TrackID { get }
    var title: String { get }
    var kind: TrackKind { get }        // .continuous, .categorical, .span, .matrix
    var values: TrackValues { get }    // aligned to Sequence.residues.count
    var colourScheme: TrackColourScheme { get }
}
```

Any new feature that cannot be expressed as a `ResidueTrack` or as a structure overlay needs an explicit design decision before implementation.

### 1.4 Scope boundaries

**In scope:** sequence analysis, family and motif annotation, construct design, structure viewing and presentation, interaction profiling, offline operation.

**Out of scope for v1:** structure *prediction* (no AlphaFold or Boltz on device), MSA generation, molecular dynamics, docking, any cloud inference.

**Regulatory posture:** research use only. No clinical, diagnostic or therapeutic claims anywhere in UI copy, App Store metadata or screenshots. Ship a "Research use only" line in About.

---

## 2. Platform and toolchain

| Item | Decision | Rationale |
|---|---|---|
| Language | Swift 6.2, strict concurrency enabled | Data-race safety across the inference actor and UI |
| UI | SwiftUI, no UIKit except where wrapping is unavoidable | Single codebase for iPhone, iPad and future visionOS |
| Minimum OS | iOS 26.0 / iPadOS 26.0 | Verify current SDK at project start and raise if a newer major has shipped |
| IDE | Latest Xcode | |
| Project generation | **Tuist 4.x** | `.pbxproj` is not agent-editable in practice: Tuist keeps project config as reviewable Swift |
| Dependency management | Swift Package Manager only | |
| Testing | swift-testing (`@Test`), XCUITest for flows | |
| CI | GitHub Actions, macOS runner, `tuist generate && xcodebuild test` | |
| Formatting | swift-format, enforced in CI | |

**Rule for the agent:** never hand-edit `.pbxproj`. All target, capability and resource changes go through `Project.swift`.

---

## 3. Module architecture

Local SPM packages under `Packages/`, each independently testable. The app target is a thin shell.

```
BOFFIN/
├── Project.swift                 # Tuist manifest
├── CLAUDE.md                     # agent working agreement
├── App/                          # BoffinApp target: entry point, routing, DI only
├── Packages/
│   ├── BoffinCore/               # domain models, no I/O, no UI, no Core ML
│   │   ├── Sequence, Residue, ResidueTrack, Construct, Motif
│   │   ├── FASTA / UniProt / PDB-SEQRES parsers
│   │   └── pI, extinction coefficient, MW, hydropathy (analytical, no ML)
│   ├── BoffinML/                 # Core ML wrappers and the inference actor
│   │   ├── EmbeddingEngine (actor)
│   │   ├── Heads: Disorder, SecondaryStructure, Membrane, FamilyClassifier
│   │   ├── MaskedMarginalScorer
│   │   └── ShapeBucketing, TokenBuffer, ANEResidencyProbe
│   ├── BoffinData/               # bundled reference data, GRDB/SQLite
│   │   ├── FamilyStore (Pfam, KLIFS, GPCRdb numbering)
│   │   ├── SIFTSMapper
│   │   ├── EmbeddingIndex (Accelerate cosine search)
│   │   └── AssetManager (Background Assets / on-demand resources)
│   ├── BoffinStructure/          # structure domain + parsing + geometry
│   │   ├── mmCIF / PDB parser, AtomStore (struct-of-arrays)
│   │   ├── SelectionLanguage (PyMOL-like parser → AST)
│   │   ├── InteractionProfiler (PLIP-lite, see §8)
│   │   └── Scene, Representation, ColourTheme models
│   ├── BoffinViewer/             # Mol* bridge, WKWebView host, JS message plumbing
│   ├── BoffinCharts/             # sequence logo, ΔLLR heatmap, track ruler renderers
│   └── BoffinUI/                 # design system, shared components, brand tokens
└── Fixtures/                     # golden test data (see §11)
```

**Dependency rule:** `BoffinCore` depends on nothing. `BoffinML`, `BoffinData` and `BoffinStructure` depend only on `BoffinCore`. `BoffinUI` and `BoffinCharts` may depend on `BoffinCore` only. The app target wires everything. Enforce with a CI check that greps import graphs.

---

## 4. Machine learning layer

### 4.1 Model selection

| Model | Params | Role | Notes |
|---|---|---|---|
| ESM-2 `t12_35M_UR50D` | 35 M | **Default backbone** | fp16 ≈ 70 MB, comfortable ANE residency, good headroom on iPhone |
| ESM-2 `t6_8M_UR50D` | 8 M | Low-power fallback | For older devices or battery-saver mode |
| ESM-2 `t30_150M_UR50D` | 150 M | Optional iPad Pro / M-series download | Ship via Background Assets, not in the base bundle |

Heads are small MLPs or 1D CNNs trained separately on top of frozen embeddings, each a few hundred KB. They are converted as separate `.mlpackage` files so heads can be updated without reshipping the backbone.

### 4.2 Conversion pipeline

Keep a `Tools/coreml/` directory containing a reproducible Python conversion pipeline. This is not shipped in the app but **is** part of the repo and CI.

```
Tools/coreml/
├── pyproject.toml            # pinned: torch, fair-esm, coremltools, numpy
├── convert_backbone.py
├── convert_heads.py
├── validate_parity.py        # PyTorch vs Core ML, per-tensor tolerance
└── benchmark_ane.py
```

Conversion requirements:

1. **Precision:** fp16 throughout. Evaluate 8-bit palettisation of the backbone as a size optimisation; gate on parity tests passing.
2. **Static shapes.** The Neural Engine will not accept fully dynamic sequence lengths. Use `EnumeratedShapes` with buckets `[128, 256, 384, 512, 768, 1024]` tokens. Pad to the smallest fitting bucket, mask the padding, slice the output. Sequences beyond 1024 are tiled with 128-residue overlap and stitched (mean over overlap).
3. **ANE-friendly tensor layout.** Follow the principles in Apple's `ml-ane-transformers` reference: 4D `(B, C, 1, S)` tensors rather than `(B, S, C)`, split-einsum attention, `conv2d` in place of `linear`, chunked heads. A naive `torch.jit.trace` of HuggingFace ESM will fall back to GPU and defeat the entire premise of the app.
4. **Compute units:** `configuration.computeUnits = .cpuAndNeuralEngine`. Explicitly excluding GPU makes silent fallback loud during development.
5. **Parity gate:** max absolute error on `last_hidden_state` < 1e-2 and Spearman ρ > 0.99 on a held-out ΔLLR matrix, versus PyTorch reference.
6. **Residency gate:** verify with the Xcode Core ML Instrument that > 90 % of operations execute on the ANE. Record the figure in `Docs/perf-log.md` on every model change.

### 4.3 Inference actor

```swift
public actor EmbeddingEngine {
    public func embed(_ sequence: Sequence) async throws -> EmbeddingResult
    public func maskedMarginals(_ sequence: Sequence,
                               positions: [Int]) async throws -> LLRMatrix
    public func warmUp() async
}
```

- Single actor serialises access; Core ML models are not thread-safe under concurrent prediction.
- `warmUp()` on app launch with a dummy 128-token input: first prediction pays ANE compilation cost, and users should never see it.
- Results cached by `SHA256(sequence)` in a size-bounded on-disk cache so returning to a tab is instant.
- Long masked-marginal scans yield progress via `AsyncStream<Progress>` and are cancellable.

### 4.4 Masked marginal scoring

For each position *i*, mask it and read the log-softmax over the 20 canonical amino acids. Score for mutation `wt→mt`:

```
ΔLLR(i, mt) = log P(mt | x_masked(i)) − log P(wt | x_masked(i))
```

Batch masked positions into a single prediction call per shape bucket. A 300-residue protein is 300 masked variants: batch them 32 at a time and it is a few seconds on an A17-class ANE, not minutes. **Never loop one prediction per position.**

### 4.5 Performance budget

| Operation | Target (iPhone 15 Pro class) |
|---|---|
| Cold launch to interactive | < 1.2 s |
| Single embed, 300 residues | < 250 ms |
| Full 300-residue ΔLLR scan | < 6 s, with progress |
| Family classification | < 50 ms after embedding |
| Homolog search, 100 k index | < 100 ms |
| Structure load, 5 k atoms | < 1.5 s to first render |

Every phase ends with these numbers re-measured and logged.

---

## 5. Feature specification

### 5.1 Order tab

Per-residue tracks derived from the hidden states.

- **Disorder** probability, continuous 0–1, with a threshold band.
- **Secondary structure** SS3 and SS8, categorical, rendered as classic cartoon glyphs above the ruler.
- **Membrane topology:** TM helix spans, signal peptide, predicted topology orientation.
- **Low complexity** and compositional bias, computed analytically (SEG-like), no ML needed.
- **Analytical panel:** MW, pI, extinction coefficient at 280 nm, GRAVY, instability index, over any selection.

Interaction: pinch to zoom the ruler, drag to select a span, tap a residue for a detail popover, long-press to send a selection to another tab.

### 5.2 Fitness tab

- **ΔLLR heatmap:** 20 amino acids × N positions, diverging colour scale centred at zero. Horizontally scrollable, pinch-zoomable, with a locked amino-acid axis.
- **Sequence logo:** information content in bits, stacked glyphs, rendered from the model's position-wise probability distribution. Interactive: tap a column to pin it, scrub to compare.
- **Wild-type highlight** and a **mutation basket** the user builds by tapping cells.
- **Motif awareness:** a mutation landing on a canonical motif position (see Family tab) is flagged in the detail view, which is what turns a raw ΔLLR into an interpretable call.
- **Disorder masking:** an option to grey out positions in predicted disordered regions, since scoring them is rarely actionable.
- Export: CSV of the full matrix, PNG of the heatmap, PDF of the logo.

### 5.3 Family tab

This is the BoltzMaker-derived layer, and the piece that gives the other tabs their interpretive frame.

**Step 1: detect.** A linear or shallow MLP head over the pooled embedding classifies into family, returning a ranked list with calibrated confidence. Trained on Pfam-A labelled sequences. No HMMER on device.

**Step 2: fall back.** If top-1 confidence is below threshold, run a bundled Pfam-A HMM subset (top candidate families only) through a compact Swift Viterbi implementation, or defer to the homolog search result. Never present a low-confidence call as certain.

**Step 3: number.** Apply the family's canonical residue numbering scheme:

| Family | Scheme | Anchors |
|---|---|---|
| Protein kinases | KLIFS 85-residue pocket numbering | G-loop, αC-Glu, gatekeeper, hinge, HRD, DFG |
| GPCRs (class A first) | GPCRdb generic numbering | TM1–TM7 with x.50 anchors, DRY, CWxP, NPxxY, ICL/ECL boundaries |
| Serine hydrolases and PETase-like | Pfam domain coordinates + catalytic annotation | Catalytic triad, oxyanion hole, disulfides |
| Everything else | Pfam domain coordinates | Domain start and end, clan membership |

**Step 4: annotate.** Motifs become a `ResidueTrack` like everything else, so they stack directly against disorder, secondary structure and ΔLLR on the same ruler.

**Step 5: map.** SIFTS gives UniProt ↔ PDB residue correspondence, so a homolog hit lands on real PDB author residue numbers rather than sequence indices. This matters enormously in practice and is the difference between a toy and a tool.

**Homolog search:** cosine similarity over a bundled index of pre-computed embeddings, restricted to the detected family, returning PDB IDs with resolution, method, ligands and a one-tap load into the structure viewer.

### 5.4 Boundary tab

Construct design, and the tab that ties directly to the crystallisation work.

- **Proposed constructs:** ranked truncations with rationale, derived from disorder boundaries, domain edges, secondary structure integrity and motif constraints.
- **Hard constraints:** never truncate through a canonical motif, a predicted TM span, a disulfide pair or a domain core. These are enforced by the solver, not suggested.
- **Precedent:** for each construct, which PDB entries in the homolog set have comparable boundaries, and at what resolution. This is the "has anyone crystallised something like this" answer.
- **Tag planning:** N- versus C-terminal placement given predicted signal peptide and termini order, plus linker and protease site suggestions.
- **Output:** a construct card with sequence, boundaries, computed properties and primer-ready DNA if a codon table is selected. Shareable as PDF or plain text.

### 5.5 Structure tab: the PyMOL-equivalent

This is a first-class feature, not an add-on. The target user is standing at a bench, sitting on a plane, or in front of a room presenting.

**Viewing**
- Load from bundled subset, RCSB fetch when online, AlphaFold DB fetch by UniProt accession, or from Files, Drive, AirDrop, share sheet.
- Formats: mmCIF (primary), BinaryCIF (preferred for size), legacy PDB, mmtf if trivial.
- Representations: cartoon, sticks, lines, spheres, surface (molecular and solvent-excluded), ribbon, backbone trace.
- Colour themes: chain, element, secondary structure, B-factor / pLDDT, hydrophobicity, conservation from the family alignment, and **any BOFFIN ResidueTrack**. Painting the ΔLLR track onto the structure is the single most compelling demo in the app: build it early.
- Assemblies, symmetry mates, alternate locations, multi-model NMR ensembles.

**Selection**
- A **PyMOL-like selection language** parsed in Swift into an AST, then compiled to Mol* MolScript. Support the subset that matters: `chain A and resi 50-120`, `byres (polymer within 5 of organic)`, `name CA`, `ss H+S`, `b > 50`, `not solvent`, named selections, boolean composition.
- A **visual selection builder** for touch: chain picker, residue range sliders, sphere-around-selection, so the language is optional rather than mandatory.
- Tap-to-select on the structure itself, with a persistent selection inspector.

**Measurement**
- Distances, angles, dihedrals, with labels that survive scene changes.
- Per-residue B-factor and pLDDT readout on tap.
- Contact and clash detection using the interaction engine (§8).

**Scenes and presentation**
- **Scenes**: named camera + representation + selection states, ordered into a deck. This is the PyMOL session concept, made touch-native.
- **Presentation mode**: full-bleed, chrome-free, swipe or external-keyboard arrows to advance scenes, smooth interpolated camera transitions between them. AirPlay and external display support with a presenter view on the iPad showing notes and the next scene.
- **Apple Pencil annotation** on iPad: draw over the structure, annotations anchored to scene index.
- **Export**: high-DPI PNG, transparent-background PNG for figures, a `.boffin` scene bundle, and a PyMOL `.pml` script so scenes round-trip to the desktop. The `.pml` export is a strong differentiator and should not be dropped.

**Session interoperability**
- Import a `.pml` script: parse the common subset (`load`, `hide`, `show`, `color`, `select`, `set_view`, `orient`, `png`) and map onto BOFFIN scenes. Fail loudly and legibly on unsupported commands rather than silently ignoring them.

---

## 6. Structure viewer implementation

### 6.1 Decision: Mol* in `WKWebView` for v1

**Rationale:** Mol* is MIT-licensed, is the reference viewer of the PDB, handles mmCIF and BinaryCIF correctly, has a mature representation and colour-theme system, and gives a complete viewer in days rather than months. A native Metal renderer is the right long-term answer for presentation-grade rendering and AR, but it is not the right way to start.

### 6.2 Bundling and offline operation

- Vendor the Mol* UMD build (`molstar.js`, `molstar.css`) into `BoffinViewer/Resources/`. **No CDN references anywhere**: the app must work in aeroplane mode.
- Load via `loadFileURL(_:allowingReadAccessTo:)` from the bundle directory.
- Pin the Mol* version in a `VENDOR.md` with the commit hash and licence text.
- `webView.isInspectable = true` under `#if DEBUG` so Safari Web Inspector works during development.

### 6.3 The Swift ↔ JS bridge

Define a single typed protocol and generate both sides from it. Ad-hoc `evaluateJavaScript` string interpolation scattered through view code is the failure mode to avoid.

```swift
public protocol ViewerCommand: Encodable, Sendable { var name: String { get } }

public actor ViewerBridge {
    func send<C: ViewerCommand, R: Decodable>(_ command: C) async throws -> R
    var events: AsyncStream<ViewerEvent> { get }   // picks, hovers, load completion
}
```

- Swift → JS: `callAsyncJavaScript` with a JSON-encoded command envelope. Never string-interpolate user input into JS.
- JS → Swift: `WKScriptMessageHandlerWithReply`, one handler named `boffin`, dispatching a tagged event union.
- A thin `boffin-bridge.js` shim sits between the envelope protocol and the Mol* plugin API, so a future native renderer can implement the same protocol and the SwiftUI layer does not change.

### 6.4 Performance guardrails

- WKWebView will struggle above roughly 100 k atoms on an iPhone. Detect atom count on load and automatically drop to a coarser preset (backbone trace, illustrative preset, no surface) above a threshold, with a visible, dismissible notice.
- Prefer BinaryCIF over mmCIF for network fetches: markedly smaller and faster to parse.
- Release the web view under memory pressure and restore from the scene state, rather than being terminated by the system.

### 6.5 Native renderer, phased later

Track a `MetalRenderer` spike as a stretch phase: struct-of-arrays `AtomStore`, instanced impostor spheres and cylinders, screen-space ambient occlusion, ProMotion 120 Hz, and a RealityKit path for AR presentation. Gate the decision on measured Mol* performance rather than on preference.

---

## 7. Charts and visualisation

All custom, all SwiftUI, no web charting.

| Chart | Implementation |
|---|---|
| Track ruler | `Canvas` with a virtualised viewport: only draw visible residues |
| ΔLLR heatmap | `Canvas` drawing into a cached `CGImage` per tile, tiled horizontally |
| Sequence logo | `Canvas`; glyphs as `Text` resolved to paths, scaled non-uniformly by information content |
| Simple bar and line charts | Swift Charts |
| Interaction diagram | Custom `Canvas` 2D ligand interaction plot (the PLIP-style figure) |

Sequence logo mathematics: information content per position `R_i = log2(20) − H_i` where `H_i = −Σ p·log2(p)`, glyph height `= p(aa) × R_i`. Support both frequency mode and ΔLLR mode (positive above the axis, negative below).

Accessibility: every chart carries an `accessibilityChartDescriptor` so VoiceOver users get Audio Graphs, and every track exposes per-residue values as accessibility elements. This is not optional polish.

---

## 8. Interaction profiling (PLIP-equivalent)

### 8.1 The licensing constraint, stated plainly

PLIP is distributed under GPL v2. Linking or porting it into a closed-source App Store application is not viable. **Verify the current licence before writing any code.** The safe route is a clean Swift implementation of the published geometric criteria, which are standard structural chemistry and not themselves proprietary.

### 8.2 Approach

Implement `InteractionProfiler` in `BoffinStructure` using a uniform grid or k-d tree neighbour search over the `AtomStore`.

Detection types and starting geometric criteria (these follow PLIP's published defaults; **verify each against the PLIP documentation and adjust in a single tunable config struct**):

| Interaction | Criteria |
|---|---|
| Hydrophobic contact | C···C ≤ 4.0 Å, both apolar carbon |
| Hydrogen bond | D···A ≤ 4.1 Å, D–H···A angle ≥ 100° |
| π-stacking (parallel) | ring centroid distance ≤ 5.5 Å, offset ≤ 2.0 Å, plane angle < 30° |
| π-stacking (T-shaped) | as above, plane angle 50–90° |
| Salt bridge | charged group centroid distance ≤ 5.5 Å, opposite formal charge |
| π-cation | ring centroid to cationic centre ≤ 6.0 Å, offset ≤ 2.0 Å |
| Halogen bond | X···A ≤ 4.0 Å, C–X···A ≈ 165° ± 30°, X···A–Y ≈ 120° ± 30° |
| Water bridge | both distances 2.5–4.1 Å, appropriate donor and acceptor angles |
| Metal coordination | ≤ 3.0 Å to N, O or S |

Protonation is the hard part. For v1, use residue- and atom-name-based typing with standard pH 7.4 assumptions, plus explicit hydrogens where present in the file. Document the assumption in the UI: an interaction profile that silently guesses protonation states is worse than one that says what it assumed.

### 8.3 Presentation

- 3D overlay in the viewer: dashed lines, per-type colours, toggleable by type.
- 2D interaction diagram, generated natively, exportable as PDF for figures.
- Tabular list, sortable, with distances and angles, exportable as CSV.
- Pre-computed profiles for the bundled PDB subset, so the common case is instant and the engine only runs on user-supplied structures.

---

## 9. Data assets and licensing

### 9.1 Bundled and downloadable assets

| Asset | Approx size | Delivery |
|---|---|---|
| ESM-2 35M backbone (fp16) | ~70 MB | In bundle |
| Analysis heads (disorder, SS, TM, family) | ~5 MB | In bundle |
| Pfam family metadata + clan map | ~20 MB | In bundle |
| KLIFS pocket numbering tables | ~5 MB | In bundle |
| GPCRdb generic numbering tables | ~5 MB | In bundle |
| SIFTS slice for indexed entries | ~30 MB | Background Assets |
| Embedding index (100 k entries, fp16) | ~15 MB | Background Assets |
| Pre-computed interaction profiles | ~50 MB | Background Assets |
| ESM-2 150M (optional) | ~300 MB | Background Assets, user-initiated |

Base bundle target: **under 200 MB**. Everything else arrives through the Background Assets framework with clear progress and the ability to purge.

Ship a `Tools/data/` pipeline that regenerates every bundled asset reproducibly from public sources, with a manifest recording source version, download date and checksum. Assets that cannot be regenerated are technical debt.

### 9.2 Licence audit (verify all of these before shipping)

| Source | Expected terms | Action |
|---|---|---|
| Mol* | MIT | Include licence text, vendor with commit hash |
| ESM-2 weights | MIT (facebookresearch/esm) | Confirm; include attribution |
| RCSB PDB data | CC0 | Attribute anyway |
| Pfam / InterPro | CC0 | Attribute |
| KLIFS | Check current terms | Confirm redistribution of derived numbering tables |
| GPCRdb | CC BY 4.0 | Attribute in About, honour the licence |
| AlphaFold DB | CC BY 4.0 | Attribute; label predicted models clearly |
| PLIP | GPL v2 | **Do not link or port.** Clean-room implementation only |

Maintain `Docs/ATTRIBUTIONS.md` and surface it in an in-app Acknowledgements screen. For a scientific tool by a named scientist, correct attribution is a professional obligation as much as a legal one.

---

## 10. Design system and interaction design

### 10.1 Brand tokens

Carried from marcdeller.com, expressed as a SwiftUI `Theme` in `BoffinUI`:

- Navy `#1C244B` (primary surface, headers)
- Accent blue `#467FF7` (interactive elements, selection)
- Semantic scientific palettes: diverging red–white–blue for ΔLLR, sequential viridis-like for continuous tracks, categorical set for secondary structure and interaction types.
- Typography: system font (San Francisco) for UI, with a monospaced face for sequences. Baloo 2 reserved for the wordmark and icon only. Do not import a web font for body UI: Dynamic Type and system font metrics matter more than brand fidelity here.
- British English throughout. No em dashes: colons or parentheses instead.

### 10.2 Human Interface Guidelines compliance

- **iPhone:** `TabView` with the four analytical tabs plus Structure. Sheets for detail, not full-screen pushes where a sheet reads better.
- **iPad:** `NavigationSplitView`, three columns: sequence list, analysis, structure. Multitasking and Stage Manager aware. Full pointer support: hover states, right-click context menus, precise selection.
- **Keyboard:** a real shortcut set on iPad (`⌘F` selection language, `⌘⇧S` new scene, arrow keys to step residues, space to play the scene deck).
- **Apple Pencil:** annotation, precise structure picking, Scribble into the selection field.
- **Dynamic Type:** every text style scales. Sequence monospace scales but never below a legibility floor.
- **Dark mode:** first-class. Structures on a true black background for OLED presentation.
- **VoiceOver:** full traversal of tracks, tables and the mutation basket. Audio Graphs for charts.
- **Reduce Motion:** scene transitions become cross-fades.
- **Haptics:** subtle confirmation on selection snap and scene change, nothing gratuitous.

### 10.3 System integration

- **App Intents / Shortcuts:** "Analyse sequence", "Open structure", "Score variant" as intents, so BOFFIN composes with the rest of the user's workflow and appears in Spotlight.
- **Share extension:** accept FASTA, PDB, mmCIF, UniProt and PDB URLs from any app.
- **Quick Look preview extension:** preview `.pdb`, `.cif` and `.fasta` files system-wide.
- **Document types:** register `.boffin` scene bundles; support Open In Place from Files and Drive.
- **Handoff and iCloud sync:** sequences, scenes and mutation baskets sync via CloudKit. Model documents so a sequence started on iPhone continues on iPad.
- **Widgets:** a small widget showing the last analysed sequence and its family call.
- **Live Activity:** progress for long ΔLLR scans and large asset downloads.

---

## 11. Testing strategy

### 11.1 Golden fixtures

Commit a small `Fixtures/` set with expected outputs, so regressions are caught rather than argued about:

- Ubiquitin (1UBQ): small, well-behaved, all-α/β, fast.
- A kinase (e.g. CDK2 with an ATP-site ligand): exercises KLIFS numbering, motif detection and interaction profiling.
- A class A GPCR (e.g. β2-adrenergic): exercises GPCRdb numbering and TM prediction.
- A PETase or cutinase: Marc's own domain, exercises catalytic triad annotation.
- A disordered protein (e.g. α-synuclein): exercises the disorder track and the boundary solver's refusal to propose constructs.
- A large ribosomal assembly: exercises viewer performance guardrails.
- Malformed inputs: truncated FASTA, non-canonical residues, selenomethionine, altlocs, missing density, multi-model NMR.

### 11.2 Test layers

| Layer | Tool | Gate |
|---|---|---|
| Domain logic | swift-testing unit tests | 80 % line coverage on `BoffinCore` |
| ML parity | Compare Core ML output against committed PyTorch reference tensors | Tolerances from §4.2 |
| Selection language | Property-based tests: parse → compile → evaluate | Round-trip stability |
| Interaction profiler | Compare against published interaction lists for the fixture set | Recall > 0.9 on hydrogen bonds and hydrophobic contacts |
| Viewer bridge | JS unit tests plus Swift integration tests against a headless web view | Command round-trip |
| UI flows | XCUITest | Core journeys per phase |
| Performance | XCTest metrics + `Docs/perf-log.md` | Budgets from §4.5 |

### 11.3 A standing instruction for the agent

Where scientific correctness is at stake (numbering schemes, interaction geometry, biochemical constants), **write the test first from the published definition, then implement**. A plausible-looking implementation of GPCRdb numbering that is silently wrong is worse than no feature, because it will be believed.

---

## 12. Phased delivery

Each phase ends with: tests green, performance logged, a demoable build, and a short entry in `Docs/CHANGELOG.md`. **Do not begin a phase until the previous phase's acceptance criteria are met.**

### Phase 0: Foundations
Repo, Tuist manifest, module skeleton with the dependency rule enforced, CI, swift-format, design system tokens, fixture set committed, `CLAUDE.md` in place.
**Accept:** empty app builds and runs on iPhone and iPad simulators; CI green; `tuist generate` reproducible from clean checkout.

### Phase 1: The sequence spine
`Sequence`, `Residue`, `ResidueTrack`, FASTA and UniProt parsing, analytical properties (MW, pI, ε₂₈₀, GRAVY), the scrollable track ruler with pinch-zoom and residue selection.
**Accept:** paste a sequence, see it rendered on the ruler with analytical tracks; zoom and selection smooth at 120 Hz; malformed input handled gracefully.

### Phase 2: ML core
Conversion pipeline in `Tools/coreml/`, backbone `.mlpackage`, `EmbeddingEngine` actor, shape bucketing, tiling for long sequences, warm-up, caching, parity and residency gates.
**Accept:** embed a 300-residue sequence in < 250 ms; ANE residency > 90 % confirmed in Instruments; parity tests pass; numbers in `Docs/perf-log.md`.

### Phase 3: Order tab
Disorder, SS3/SS8, TM and signal peptide heads, low-complexity, all rendered as tracks with the analytical panel.
**Accept:** fixture proteins produce sensible tracks; α-synuclein reads as disordered; the GPCR shows seven TM spans.

### Phase 4: Fitness tab
Batched masked-marginal scoring, ΔLLR heatmap, sequence logo, mutation basket, disorder masking, CSV and PNG export.
**Accept:** full 300-residue scan < 6 s with progress and cancellation; heatmap scrolls smoothly; logo mathematically correct against a hand-computed fixture.

### Phase 5: Family tab
Family classifier head, confidence calibration, Pfam metadata store, KLIFS and GPCRdb numbering, motif tracks, SIFTS mapping, embedding index and homolog search.
**Accept:** CDK2 classifies as a kinase and the DFG, HRD, gatekeeper and hinge annotate at the correct KLIFS positions; β2AR classifies as class A GPCR with correct x.50 anchors; homolog search over 100 k entries < 100 ms.

### Phase 6: Boundary tab
Construct solver with motif and TM hard constraints, precedent lookup from the homolog set, tag and linker planning, construct card export.
**Accept:** proposed constructs never cut through an annotated motif; precedent shows real PDB entries with boundaries; solver declines to propose for a fully disordered input and says why.

### Phase 7: Structure viewer
Mol* vendored and bundled offline, `ViewerBridge` protocol both sides, structure loading from all sources, representations, colour themes including **ResidueTrack painting**, tap-to-select.
**Accept:** load 1UBQ offline from bundle in < 1.5 s; paint the ΔLLR track onto the structure; large-assembly guardrail triggers correctly.

### Phase 8: PyMOL mode
Selection language parser and compiler, visual selection builder, measurements, scenes, presentation mode, external display, Pencil annotation, PNG and `.pml` export, `.pml` import.
**Accept:** `byres (polymer within 5 of organic)` evaluates correctly on the kinase fixture; a five-scene deck presents on an external display with presenter view; exported `.pml` reproduces the scene in desktop PyMOL.

### Phase 9: Interaction profiling
`InteractionProfiler` clean-room implementation, 3D overlay, 2D diagram, table, pre-computed profiles for the bundled subset.
**Accept:** recall > 0.9 against published interaction lists for the kinase fixture; profile of a 5 k-atom structure < 1 s; assumptions surfaced in the UI.

### Phase 10: Platform integration
App Intents, share extension, Quick Look extension, document types, CloudKit sync, Handoff, widget, Live Activity.
**Accept:** a FASTA shared from Mail opens and analyses; a sequence started on iPhone resumes on iPad; Shortcuts action runs headlessly.

### Phase 11: Polish and release
Full accessibility audit, localisation scaffolding, onboarding, empty and error states, App Store assets, TestFlight, privacy manifest, attributions screen.
**Accept:** VoiceOver traversal of every screen; Dynamic Type at accessibility sizes without clipping; privacy manifest complete and honest (no data collection, no network required); TestFlight build distributed.

### Phase 12 (stretch): Native renderer and AR
Metal impostor renderer spike, benchmark against Mol*, RealityKit AR presentation mode, visionOS target evaluation.

---

## 13. Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| ESM-2 does not achieve ANE residency after conversion | Fatal to the premise | Prove this in Phase 2 before building anything on top. Follow `ml-ane-transformers` layout from the start, not as a later optimisation |
| Static shape requirement makes long sequences awkward | Medium | Bucketing plus overlap tiling, designed in from Phase 2 |
| WKWebView memory pressure with large structures | High | Atom-count guardrails, coarse presets, state restoration after eviction |
| App bundle size | Medium | Background Assets for everything non-essential, 8-bit palettisation if parity holds |
| PLIP licensing | High if mishandled | Clean-room Swift implementation, licence audited in Phase 0, never linked |
| Numbering scheme correctness (KLIFS, GPCRdb) | High: silently wrong science | Test-first from published definitions, validated against known reference proteins |
| Family classifier over-confidence | Medium | Calibrated confidence, explicit low-confidence state in the UI, never present a guess as a call |
| Scope creep into structure prediction | High | Explicitly out of scope for v1. Route users to BoltzMaker on the desktop instead |
| App Review: scientific claims | Medium | Research-use-only framing, no diagnostic language anywhere |

---

## 14. Working agreement for the agent

1. **Read `CLAUDE.md` before every work session.** It holds the current phase, the invariants and the open questions.
2. **One phase at a time.** Do not begin Phase N+1 while Phase N acceptance criteria are unmet.
3. **Never edit `.pbxproj`.** Project changes go through `Project.swift` and `tuist generate`.
4. **Never introduce a network dependency into a core path.** The app must work fully offline. Network features are additive and must degrade cleanly.
5. **Never string-interpolate into JavaScript.** All bridge traffic goes through the typed command envelope.
6. **Where science is at stake, write the test first** from the published definition.
7. **Log performance numbers** to `Docs/perf-log.md` at the end of every phase. Regressions are bugs.
8. **Ask before inventing scientific defaults.** If a threshold, cutoff or numbering rule is uncertain, surface the question rather than picking a plausible number.
9. **British English, no em dashes** in all user-facing copy, comments and documentation.
10. **Every new dependency requires a licence check** recorded in `Docs/ATTRIBUTIONS.md`.

---

## 15. Open questions for Marc

These need answers before or during Phase 0, and are deliberately not guessed at:

1. **Head training data.** Which datasets for the disorder, SS and TM heads (DisProt, CB513, TOPCONS, DeepTMHMM)? Are you training these, or fine-tuning published heads?
2. **Index scope.** What does the bundled embedding index cover: a curated PDB subset, the full PDB at cluster representatives, or a domain-focused set weighted to kinases, GPCRs and hydrolases?
3. **Family coverage at v1.** Kinases and class A GPCRs only, or a broader Pfam-level fallback from day one?
4. **Crystallisation link.** Should the Boundary tab surface a crystallisation propensity estimate now, or stay decoupled from the Top96 project until that dataset is normalised?
5. **Distribution.** Public App Store release, or TestFlight for a controlled group first?
6. **Backbone size default.** Is a 300 MB optional 150M download acceptable to the target user, or is 35M the ceiling?
7. **Icon.** BOFFIN carries a wordmark, so `marcs-vibe-icon` applies rather than `marcs-page-icon`. Blue-haired bespectacled scientist as the mark?

---

*Built for Marc C. Deller, D.Phil. · marcdeller.com · marc@marcdeller.com*
