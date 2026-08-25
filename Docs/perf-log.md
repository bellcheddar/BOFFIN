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


## Phase 5 (2026-08-25)

### Family classifier

| | |
|---|---|
| Families | 100 Pfam |
| Training sequences | 8,178 (Swiss-Prot, single-domain only) |
| Top-1 accuracy | **0.978** |
| Top-5 accuracy | 0.998 |
| Random baseline | 0.010 |
| Calibration error | **0.0099** |
| Head size | 0.81 MB |

**Temperature scaling was fitted and then NOT applied.** The head measured an
expected calibration error of 0.013 raw against 0.015 scaled on the calibration
split, so scaling made it worse. Temperature scaling corrects over-confidence;
it is not a ritual, and applying it unconditionally would have degraded exactly
the number the risk register cares about. The decision is made on the
calibration split, never on test.

### The limitation that accuracy hides

The classifier is **closed set**. It answers with one of its 100 families
whatever it is given, so a protein from any other family is assigned the nearest
one and reported confidently. Measured: **ubiquitin, whose family PF00240 is not
in the trained set, is called PF00076 at 79.7%.**

Confidence cannot detect this, because the model genuinely is confident.

Cosine similarity to the nearest class centroid was evaluated as an
out-of-distribution signal and is honestly weak: correctly-classified CDK2
measures 0.829 while misclassified ubiquitin measures 0.864, so it does not
separate right from wrong. It does separate inside-the-training-distribution
from outside it (in-distribution 5th percentile 0.929), so it is reported and
used only for that narrower claim. The limitation itself is stated on screen on
every call rather than scored around.

Spot checks where the trained set does contain the family, all correct:
CDK2 to PF00069 (protein kinase), beta-2 adrenergic receptor to PF00001 (7TM
rhodopsin family), PETase to PF00561 (alpha/beta hydrolase).


## Phase 5 (part 4): homolog index and SIFTS (2026-08-25)

### The index

| | |
|---|---|
| Entries | **72,421** (one per UniProt accession in the PDB) |
| Dimensions | 480 |
| Storage | int8, L2-normalised, whitened |
| Embedding time | 110.6 min on an M1 Max, 74,287 tiles |
| Packed size | 34.8 MB vectors, 31.3 MB metadata, 43.3 MB SIFTS = **109.3 MB** |
| **Search latency** | **5.4 ms per query**, release build, exhaustive |
| Budget | 100 ms for a 100 k index |

Exhaustive, not approximate. One query is a 34.8 M multiply-and-add and lands 18
times inside the budget, so an ANN structure would buy latency that is not
needed and pay for it in recall that is silently imperfect.

### Whitening, which the index would have been broken without

Pooled language-model embeddings are anisotropic: they occupy a narrow cone.
Measured on the raw index, two proteins picked at random score a cosine of
**0.848**, and the 99.9th percentile of random pairs is **0.980**, while real
homologues score 0.97 to 0.99. Everything useful lives in a sliver of the range,
and int8 quantisation of that sliver destroyed a quarter of it.

| | recall@1 | recall@10 | null mean | null 99.9th |
|---|---|---|---|---|
| raw | 0.568 | **0.748** | 0.848 | 0.980 |
| centred | 0.855 | 0.944 | 0.001 | 0.819 |
| centred, 2 PCs removed | 0.875 | 0.963 | 0.000 | 0.659 |
| **centred, 4 PCs removed** | **0.892** | **0.966** | **0.000** | **0.641** |
| centred, 8 PCs removed | 0.890 | 0.962 | 0.001 | 0.602 |

Recall is against exhaustive float search on the same vectors, so it measures
purely what quantisation costs. Four principal directions is where it stops
improving. The transform is stored in the vector file and applied to every
query, because an unwhitened query against a whitened index does not error, it
just ranks badly.

The similarity floor is the measured 99.9th percentile of unrelated pairs,
**0.641**, and it travels in the file rather than being a number chosen by eye.
Before whitening the equivalent figure was 0.980, so any round number picked by
eye would have admitted the whole index.

### Core ML against PyTorch, end to end

The index is embedded in PyTorch at fp32 and queried by the app in Core ML at
fp16 on the Neural Engine. Two implementations of one function.

| | |
|---|---|
| Pooled cosine, raw | 0.999996 |
| Pooled cosine, whitened | 0.999984 |
| Top-20 agreement | **1.00** |
| Spearman over all 72,421 entries | 0.999989 |
| Largest score difference at shared hits | 0.0005 |

The first run of this check reported top-5 agreement of 0.80 and told me to
investigate before shipping. It was right to, and the fault was in the check:
it whitened the index and not the query. That is precisely the mismatch the
stage exists to catch, so it caught itself.

### Neighbours, for judgement rather than metrics

A recall figure only says the quantised search agrees with the float search;
both could agree on nonsense.

| Query | Nearest neighbours |
|---|---|
| CDK2 (P24941) | CDK1, PfPK5, CDK6, CDK4: all CMGC kinases |
| Beta-2 adrenergic receptor (P07550) | H2R, 5-HT2C, 5-HT1F, orexin-2, V1a: all class A GPCRs |
| PETase (A0A0K8P6T7) | cutinases RgCutII, AdCut, and PETase mutants |
| Lysozyme C (P00698) | quail, turkey and pheasant lysozymes |

**Ubiquitin is the exception and the reason it is worth listing them.** Its
nearest neighbours are repeat proteins and designed dimers, not ubiquitin-like
folds, because the index unit is the UniProt entry and P0CG48 is
polyubiquitin-C: a 685-residue polyprotein of nine tandem repeats. The vector is
of the polyprotein, so it lands near other repetitive proteins. That is the
documented limitation of a per-accession index behaving exactly as described,
found by looking at the answers rather than at a score.


## Phase 3 (rest): transmembrane spans and signal peptide (2026-08-25)

Trained on **Swiss-Prot curated features**, not on DeepTMHMM or TOPCONS. Those
are the obvious sources and neither can ship: DeepTMHMM needs a paid commercial
licence outside academia and TOPCONS states no terms at all. UniProt is CC BY
4.0, verified, and curates `TRANSMEM`, `SIGNAL`, `INTRAMEM` and `TOPO_DOM`
directly.

| | |
|---|---|
| Entries | 13,000 (6,000 membrane, 4,000 soluble, 3,000 secreted) |
| Residues | 5.81 M |
| Label balance | 89.2% outside, 8.9% transmembrane, 1.9% signal |
| Head | 391,171 parameters, **0.78 MB** at fp16 |
| Core ML latency | **0.71 ms** at bucket 1024 (ceiling 3.0 ms) |
| Parity | relative 0.11%, argmax agreement 100% |

### Held-out test, 1,300 chains

| | recall | precision | F1 |
|---|---|---|---|
| outside | 0.981 | 0.993 | 0.987 |
| transmembrane | 0.933 | 0.842 | 0.885 |
| signal peptide | 0.955 | 0.932 | 0.943 |

**Span level**, which is what the Boundary tab actually consumes:

| | span recall | span precision | chains fully correct |
|---|---|---|---|
| raw argmax | 0.842 | **0.581** | 0.709 |
| **post-processed** | 0.811 | **0.845** | **0.805** |
| experimental evidence only (n=26) | 0.688 | 0.826 | 0.577 |

### The post-processing, and the hypothesis it disproved

Raw span precision was 0.581 against a per-residue F1 of 0.885, and the obvious
reading is fragmentation: one helix broken in the middle, scored as two wrong
spans. The obvious fix is to merge short gaps. Swept on the VALIDATION split,
that is the wrong fix:

| merge gap | minimum span | recall | precision | F1 |
|---|---|---|---|---|
| **0** | **18** | **0.819** | **0.852** | **0.835** |
| 2 | 18 | 0.767 | 0.802 | 0.784 |
| 4 | 18 | 0.691 | 0.756 | 0.722 |
| 8 | 15 | 0.515 | 0.650 | 0.575 |

Merging costs recall at every gap, because adjacent helices in a polytopic
membrane protein are separated by short loops: closing a gap of four fuses two
genuine helices and destroys both. The low precision was short spurious spans,
not split real ones, and a length filter alone removes them for almost nothing
(recall 0.841 to 0.819, precision 0.600 to 0.852).

The chosen parameters are written into `Models/heads/config.json` and read by
the app, so the Swift side cannot drift from the sweep that chose them.

### Acceptance, on the fixtures

The build plan accepts this phase when "the GPCR fixture shows seven TM spans".
Run end to end against the converted backbone and head:

- **Beta-2 adrenergic receptor: exactly 7 spans**, each 18 to 40 residues, in
  order, between residues 20 and 360.
- **Ubiquitin: 0 spans.** The negative control matters as much: a head that
  finds membrane helices in a cytosolic protein is useless as a hard constraint
  however good its aggregate numbers look.
- **PETase: 0 spans.**

### What the numbers do not say

Only **6.9%** of Swiss-Prot `TRANSMEM` spans carry experimental evidence
(ECO:0000269); the rest are curated inference. The test split is therefore
scored twice, and on the experimental subset span recall falls from 0.811 to
0.688. That subset is 26 chains, which is too few to call precisely, but it is
the honest direction of travel and the reason the aggregate figure should not be
quoted alone.


## Heads trained on PDB-derived labels (2026-08-25)

The disorder and secondary-structure heads ship trained on NetSurfP's
distributions. These are trained on labels derived from the PDB directly, to
answer a question the licence discussion never did: **does the curation matter?**

| | |
|---|---|
| Chains | 5,012, one per UniProt accession |
| Residues | 1,476,209 |
| Selection | X-ray, 2.5 A or better |
| Disorder | 7.1% of residues |
| Structure | 41.3% helix, 19.9% strand, 38.8% coil |
| Split | by ACCESSION, not by chain |

Split by accession because two chains of one protein in different entries are
the same sequence, and splitting by chain puts a protein in both halves: the
test score then measures memorisation.

### Disorder

| | recall | precision | F1 |
|---|---|---|---|
| ordered | 0.915 | 0.982 | 0.947 |
| disordered | 0.771 | 0.396 | 0.524 |

**Accuracy 0.905, Matthews correlation 0.510.** Predicting "ordered" everywhere
scores **0.9325 accuracy and zero MCC**, which is why accuracy is not the
headline here.

The shipped head, trained on NetSurfP, measured MCC 0.628 on TS115 and 0.500 on
CASP12. This one lands inside that range. It is not a like-for-like comparison
and must not be quoted as one: this is a held-out split of the SAME source, not
CB513.

The honest weakness is precision: 0.396 means the head calls disorder about two
and a half times as often as it is there. Class weighting bought recall at that
cost, and for the Boundary tab that trade is the right way round, since a
missed disordered tail is a construct that will not crystallise while a false
one is a boundary a user can overrule.

### Secondary structure, three state

| | recall | precision | F1 |
|---|---|---|---|
| helix | 0.847 | 0.874 | 0.860 |
| strand | 0.782 | 0.807 | 0.794 |
| coil | 0.807 | 0.770 | 0.788 |

**Accuracy 0.819.** The shipped Q8 head collapsed to three states measured
0.808, 0.824 and 0.743 on CB513, TS115 and CASP12. Again inside the range, again
not the same benchmark.

### What this settles

**The curation was not load-bearing.** Labels taken straight from PDB entries
train heads that match the ones trained on NetSurfP's versions of the same
underlying data, within the uncertainty of comparing across benchmarks. The
licence question, now decided separately, was never a question about quality.

Eight-state is the exception: `_struct_conf` gives three, and Q8 needs DSSP over
the coordinates. `SecondaryStructureAssigner` now computes that, so the labels
can be produced, but running it across five thousand entries needs the assigner
in the label pipeline rather than in the app, and that has not been done.
