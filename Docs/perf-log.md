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

## Open-set rejection for the family classifier (2026-08-25)

### The question

The classifier is closed set: it knows 100 families and must answer with one of
them, so a protein from a family it never saw is assigned the nearest one,
confidently. The project's stated position was that no threshold catches this,
based on ubiquitin (PF00240, not in the set) being called PF00076 at 79.7% while
distance to the nearest class centroid failed to separate it from a correctly
classified kinase.

**That was one protein.** Two proteins are an anecdote. This is the experiment.

### Method

Hold out whole **families**, not sequences: 20 of the 100, five random splits.
Train on the remaining 80, then ask of every held-out sequence whether a score
would have rejected it, and of every in-distribution test sequence whether the
same score would have wrongly rejected it.

Holding out whole families is the entire point. A sequence-level split leaves
each held-out sequence's family in the training set, so the model has seen its
fold, its motifs and its neighbours, and "unknown" would mean nothing. Roughly
1,000 known and 1,500 unknown sequences per split.

### Results, mean AUROC over five splits (0.5 is chance)

| Score | AUROC |
|---|---|
| **Mahalanobis distance** to the nearest class, shared covariance | **0.969 ± 0.005** |
| Maximum softmax probability | 0.945 ± 0.014 |
| Maximum logit | 0.896 ± 0.024 |
| Energy, -logsumexp(logits) | 0.893 ± 0.025 |
| Cosine to the nearest class centroid | 0.850 ± 0.016 |

### What it changes

**The centroid cosine really was the wrong instrument**, and it was the one
tried: at 0.850 it is the weakest of the five. That earlier conclusion was right
about the method and wrong to generalise from it to the question.

**A rejection mechanism does exist.** Mahalanobis distance in the embedding
space separates unseen families from seen ones at 0.969, and it is far the most
*stable* across splits (± 0.005 against ± 0.014 to ± 0.031), which matters more
than the mean: a score whose usefulness depends on which families happen to be
missing is not one to ship a threshold on.

**Max softmax is better than the anecdote suggested**, at 0.945. Ubiquitin is
evidently a hard case rather than a representative one. Worth recording,
because the project has been telling users that confidence cannot detect this,
and on average over 1,500 unseen proteins it partly can.

### The operating point, which is what a threshold needs

AUROC says a score *ranks* unknowns above knowns. It does not say a usable
threshold exists. Holding the false-rejection rate on in-distribution proteins
at 5%:

| Score | Unseen families caught |
|---|---|
| Mahalanobis | **0.805 ± 0.017** |
| Max softmax | 0.761 ± 0.061 |

5% is chosen from the cost of the two mistakes: wrongly warning about a protein
the model does know costs a moment's doubt, while silently naming a family for a
protein from outside the set is the failure this exists to prevent.

### The honest limit

**One unseen protein in five is still missed.** A warning at this threshold is
an improvement, not a solution, and the on-screen statement that the classifier
is closed set has to stay exactly as it is. What changes is that four out of
five such proteins can now be flagged, instead of none.

## How much does the disorder benchmark actually say? (2026-08-25)

### The claim being checked

The app told users that disorder is "less reliable on sequences without close
relatives in the PDB", and the roadmap carried an item to fix a head that
measures *below the no-language-model floor* on novel folds. Both followed from
one number: CASP12 MCC 0.500 against a published one-hot baseline of 0.573.

**CASP12 has 21 chains.**

And its 7,256 residues are not 7,256 independent observations. Disorder is
contiguous: a disordered forty-residue tail is one event, not forty. Treating
residues as independent is what makes a small benchmark look decisive.

### Method

Resample **chains** with replacement, 2,000 draws, recomputing MCC over whatever
residues the drawn chains contain. At the shipped threshold (0.90, read from
`config.json` rather than assumed: the first run used 0.5 and put an interval
around an operating point the app never uses).

Point estimates reproduce `benchmarks.json` exactly, which is what says the
bootstrap is measuring the shipped head and not a different one.

### Results

| Benchmark | Chains | MCC | 95% interval | One-hot floor | Verdict |
|---|---|---|---|---|---|
| CB513 | 513 | 0.430 | [0.372, 0.492] | 0.502 | **Below the floor** (99.2% of resamples) |
| TS115 | 115 | 0.628 | [0.568, 0.681] | 0.594 | Indistinguishable (12.8% below) |
| CASP12 | 21 | 0.501 | [0.337, 0.662] | 0.573 | **Indistinguishable** (80.8% below) |

### What this changes

**The CASP12 claim is not established.** The interval spans the floor from well
below to well above it. 80.8% of resamples land below, which is suggestive and
is not evidence; on 21 chains it could hardly be anything else. Chasing that
number with more capacity or an auxiliary task would have been optimising
against noise, and any improvement would have been unfalsifiable on the same
benchmark.

**The real deficit is on CB513**, where the interval sits wholly below the
floor across 513 chains. That is the one solid version of "the language model is
not helping here", and it is the benchmark the project had been quoting *least*.

**The TS115 claim also needs softening.** "Beats NetSurfP-2.0" sits close enough
to its own floor that 12.8% of resamples fall below it. Still the best of the
three, still not the clean win the phrasing implied.

### Consequence

The roadmap item changes from "improve the head on novel folds" (a target the
benchmark cannot see) to "improve it on CB513" (a target 513 chains can). The
on-screen wording now says the head measures below its no-language-model
baseline on **one** benchmark, without claiming which kind of sequence that
generalises to, because the data does not support the generalisation.

None of this makes the head better. It says which number to chase, and stops
the app asserting something 21 proteins cannot support.

## Solvent accessibility as an auxiliary task: no effect (2026-08-25)

### The hypothesis

NetSurfP predicts relative solvent accessibility jointly with everything else,
and RSA and disorder are arguably the same physical fact seen twice: a residue
nobody can see in a crystal is usually one with nothing packed against it. A
shared trunk should give the rare binary disorder label a denser training
signal. The RSA labels were already in the cached embeddings.

### The control

Both arms use the shipped `ConvHead` trunk unchanged, the same seed, bit
identical initialisation, the same batches in the same order, the same class
weight, and thresholds tuned on the same 1,085 validation chains and applied
blind. 9,762 training chains, 6 epochs. The only difference is the auxiliary
loss.

**The control arm reproduces the shipped head**, which is what makes the rest of
this worth reading: CB513 0.426 against the recorded 0.430, TS115 0.643 against
0.628, CASP12 0.515 against 0.501, and it independently tuned to a threshold of
0.90, which is the shipped value.

### Result

| Benchmark | Baseline | With RSA | Paired 95% interval | Verdict |
|---|---|---|---|---|
| CB513 | 0.426 | 0.428 | [-0.007, +0.013] | No effect |
| TS115 | 0.643 | 0.641 | [-0.012, +0.008] | No effect |
| CASP12 | 0.515 | 0.517 | [-0.025, +0.028] | No effect |

Paired over bootstrap draws: both arms resampled with the same chain draws, so
the difference is measured on the same proteins and the shared chain-to-chain
variation cancels. Comparing two independent intervals would mostly have
measured which chains each happened to draw.

### Why this is a useful answer and not a failed experiment

**The interval is tight.** On CB513 the effect is bounded within ±0.013 MCC.
That is not "we could not detect an effect", which is what an underpowered test
says; it is "the effect, if any, is smaller than 0.013", which rules the
hypothesis out at any size worth shipping a second head for. The deficit against
the no-language-model floor on CB513 is 0.076, and auxiliary RSA closes at most
a sixth of that in the most optimistic corner of its interval.

**It closes an avenue cheaply.** The roadmap listed three candidates for this
head: RSA as an auxiliary task, more capacity, and PDB-derived negatives. One is
now measured and dead, on the benchmark that can actually see a change, using
labels that were already on disk. The other two remain.

**The likely reason, stated as a hypothesis rather than a finding**: the
embedding is frozen, so the auxiliary task can only reshape a 128-wide trunk
sitting on top of representations it cannot alter. NetSurfP trains its backbone.
An auxiliary signal that cannot reach the representation has much less to give.

## The disorder comparison was against the wrong model (2026-08-25)

### What was claimed

That BOFFIN's disorder head measures below a "no-language-model floor", and
therefore that on this benchmark the embeddings contribute nothing. It was on
screen, in the README and in the roadmap.

### Why it was wrong

The floor was **NetSurfP's architecture** fed one-hot amino acids. BOFFIN's
number is a small dilated convolutional head fed frozen 480-dimensional ESM-2
embeddings. Two things differ at once, so the gap could not be attributed to
either, and it was being attributed to the representation.

### The missing arm

The same head, same seed, same schedule, same class weight, same chains, same
threshold-tuning protocol. Only the first 1x1 projection changes shape, from
480 channels to 20.

| Benchmark | This head, one-hot | This head, embeddings | Embedding gain | NetSurfP one-hot |
|---|---|---|---|---|
| CB513 | 0.380 [0.332, 0.429] | 0.426 | **+0.046** | 0.502 |
| TS115 | 0.537 [0.480, 0.590] | 0.643 | **+0.106** | 0.594 |
| CASP12 | 0.512 [0.400, 0.615] | 0.515 | +0.003 | 0.573 |

### What it means

**The embeddings are contributing.** On CB513 they are worth +0.046 MCC over
one-hot in an otherwise identical model, and +0.106 on TS115. The claim that
the language model adds nothing there was false.

**The gap to NetSurfP is architecture and training budget, not representation.**
This head on one-hot scores 0.380 where NetSurfP on one-hot scores 0.502. The
0.122 between those two is the part that has nothing to do with embeddings: a
128-wide three-block convolutional head against a much larger model trained end
to end, with the backbone itself learning.

**It confirms the hypothesis offered after the RSA null.** That result was
explained by the embedding being frozen, leaving an auxiliary signal nowhere to
go. The same explanation covers this: the deficit lives in the head and in what
it is allowed to change, not in the input.

### What changes

The remaining roadmap work moves from labels to capacity. PDB-derived negatives
were the next candidate; on this evidence, head capacity and letting more of the
model adapt are the better bets, and the benchmark that can see the difference
is CB513.

The on-screen wording is corrected. It had said this head "measures below what
the same head achieves with no language model at all", which is exactly the
error: the same head with no language model achieves 0.380, not 0.502.

## Capacity does not close the disorder gap either (2026-08-25)

### The sweep

Four configurations, same seed, same chains, same batches in the same order,
same class weight, thresholds tuned on the same validation chains and applied
blind, compared paired over the same bootstrap draws. At width 128 with
dilations 1, 2, 4 the sweep head is `ConvHead` exactly, and it reproduced the
shipped baseline bit-identically, including the intervals.

| Arm | CB513 | Delta | Paired 95% | Verdict | Parameters | fp16 | Field |
|---|---|---|---|---|---|---|---|
| w128 (shipped) | 0.426 | — | — | — | 308,738 | 0.62 MB | 29 |
| w256 | 0.434 | +0.009 | [+0.000, +0.018] | Helps, barely | 1,108,994 | 2.22 MB | 29 |
| d4 | 0.418 | -0.007 | [-0.017, +0.003] | No effect | 391,042 | 0.78 MB | 61 |
| w256d4 | 0.414 | -0.012 | [-0.023, -0.002] | **Hurts** | 1,437,442 | 2.87 MB | 61 |

### Width

The only arm that clears zero does so with its lower bound AT zero: +0.009 MCC
for 3.6x the parameters and 1.6 MB more asset. Against a deficit of 0.076
against NetSurfP's one-hot baseline, that is a eighth of the gap for a head that
has to ship on a phone and run on the Neural Engine. Not a trade worth making,
and reported as "helps" only because the arithmetic says so.

### Depth, and a refuted hypothesis

The sweep was designed around an explicit prediction: disordered regions are
long, the shipped head sees 29 residues, and a fourth dilated block seeing 61
should help if disorder is a statement about a larger neighbourhood.

**It does not.** `d4` is 0.007 worse and `w256d4`, which is both changes at
once, is the only arm that measurably HURTS. More context is not what this head
is missing. Whatever the extra block adds, it dilutes more than it contributes
at this data budget.

### Three experiments, one conclusion

| Experiment | Result |
|---|---|
| RSA auxiliary task | Bounded within ±0.013. No effect |
| One-hot control | Embeddings worth +0.046; gap to NetSurfP is architecture |
| Capacity sweep | Width buys an eighth of the gap at 3.6x size; depth hurts |

Better supervision does not help. More parameters do not help. More context
hurts. **The head is close to what a frozen 480-dimensional embedding supports
at this data budget**, and the residual gap to NetSurfP lives where BOFFIN
cannot currently follow: a larger backbone, trained end to end, with the
representation itself adapting to the task.

### The decision this raises

The only remaining route is to stop freezing the backbone: fine-tune ESM-2 for
this task, or move to a larger one. Both conflict directly with the premises
this app is built on. The 98.8% Neural Engine residency was achieved on a
specific converted graph, the model is 67 MB before any of this, and a
fine-tuned backbone is a second copy of it rather than an edit to the head.

That is a project-direction question rather than an engineering one, and it is
recorded here rather than answered.

## 500 families, and a rejection method that reversed (2026-08-26)

### Coverage

The classifier grew from 100 Pfam families to 500: 40,158 sequences fetched
(87,354 multi-domain entries skipped, single-label only), embedded in about 35
minutes, and trained on the same protocol.

| | 100 families | 500 families |
|---|---|---|
| Top-1 | 0.9792 | **0.9858** |
| Top-5 | 0.9988 | 0.9963 |
| Calibration error | 0.0082 | 0.0040 |
| Random baseline | 0.0100 | 0.0020 |

**Accuracy went up while the task got five times harder.** A 500-way choice is
strictly harder than a 100-way one, so this is the larger per-family sample
(100 sequences against an average of 82) more than compensating. Temperature
scaling was fitted and again not applied: the head is already calibrated.

### The reversal

The trainer had been printing a detection rate of 0.805 beside the new
threshold. That number was measured on the **100-family** model, and it was
hardcoded. Re-running the experiment at the new family count, holding out 100
families instead of 20:

| Score | 100 families | 500 families |
|---|---|---|
| Mahalanobis AUROC | 0.969 ± 0.005 | 0.941 ± 0.011 |
| Max softmax AUROC | 0.945 ± 0.014 | 0.941 ± 0.010 |
| **Mahalanobis @5% FPR** | **0.805 ± 0.017** | **0.736 ± 0.038** |
| **Max softmax @5% FPR** | **0.761 ± 0.061** | **0.763 ± 0.009** |

At 500 classes Mahalanobis is no better on AUROC, **worse at the operating
point**, and **four times less stable** across which families happen to be
held out. Max softmax held flat and became far steadier.

### What ships, and why the argument reversed with it

The case for Mahalanobis at 100 families was stated explicitly: stability
matters more than the mean when a threshold has to ship, because a score whose
usefulness depends on which families are missing is not one to ship a threshold
on. Applied consistently at 500 families, that same argument selects max
softmax.

So the 1.88 MB asset, its binary format, its loader and its cross-language
parity test are all removed. The head's own confidence is the score, the
threshold is one float in the metadata JSON, and it is fitted on the
calibration split rather than on train (optimistic, the head has seen those) or
test (the set the flagging rate is reported on).

Confidence floor 0.9700, flagging 5.3% of held-out in-distribution proteins.

Offered as hypothesis: 500 class means estimated under one shared covariance
are individually noisier than 100, so distance to the nearest mean degrades,
while a softmax over 500 competitors gives a novel protein more ways to be
uncertain.

### The failure this avoided

Nothing would have broken. The Mahalanobis asset would have loaded, the
distances would have computed, the threshold would have applied, and the app
would have shipped the worse of two scores while quoting a detection rate
belonging to a model it no longer runs. The only reason it surfaced is that the
family count changed and the measurement was repeated rather than inherited.

A test now pins the family count the rate was measured at, so retraining at a
different size fails loudly instead of quietly invalidating the sentence on
screen.

## A stale Core ML model paired with fresh labels (2026-08-26)

Retraining the family classifier at 500 families rewrote `family.pt` and
`family_labels.json`. It did **not** rewrite `family.mlpackage`, which is
converted separately by `Tools/coreml/convert_heads.py`. The app loads the
mlpackage and the labels, and for a few minutes those described different
classifiers: a 100-class model and 500 names.

**The failure is silent and total.** Swift's `zip` truncates to the shorter
sequence, so 100 logits against 500 names yields 100 well-formed pairs carrying
the first 100 of the NEW names. Those are different families from the ones the
old model was trained on. Every classification would have come back confident,
plausible and wrong, with nothing in a log and no exception anywhere.

Two guards, because the two files have no link between them:

**At runtime**, the class count reported by the model is compared against the
label count before anything is read, and a mismatch throws with the fix in the
message rather than proceeding.

**At test time**, the mlpackage's modification date is compared against the
labels'. Verified to discriminate rather than merely pass: touching the labels
forward makes it fail with the reconversion instruction, and reconverting makes
it pass again. A guard that has never been seen to fail is not a guard.

Comparing dates rather than loading the model is deliberate: Core ML is not
available on the macOS test host for an iOS package, and the signal that matters
is "these two were not produced together", which a timestamp carries.

## The fixture that unblocked assembly construction, and what it found (2026-08-26)

### Why a new fixture

Assembly *construction* was untestable: every golden fixture's declared assembly
already equalled its asymmetric unit, so building it was a no-op on all seven.
The criterion for a fixture that fixes that is objective, not a matter of taste,
so candidates were fetched and measured rather than guessed:

| Candidate | Declared | Deposited |
|---|---|---|
| 1HVR, 1TIM | 2 | 2 |
| 2SOD, 4INS | 2 | 4 |
| 1GFL | 1 | 2 |
| 2GLS | 12 | 12 |
| 1HTO | 12 | 24 |
| **1FHA, 1AEW** | **24** | **1** |

**1FHA**, human ferritin heavy chain: 24-mer declared, one chain deposited,
1,361 atoms, 246 KB. The textbook case, and small.

### Three findings, none of them expected

**Mol\* builds the assembly on LOAD.** Ferritin arrives as 32,664 atoms, which
is 1,361 x 24. The default preset is assembly-aware, so BOFFIN has been showing
biological assemblies all along, and asking for the "model" is what yields the
deposited coordinates. The project's notes had this backwards: they described
the risk of seeing a monomer where the molecule is a dimer, and the real risk is
the reverse, that a user believes they are looking at deposited coordinates.

**`listAssemblies` computed a diagnostic and threw it away.** The handler
carefully worked out which path it took, or why none worked, assigned it to
`note`, and the return statement omitted the field. So every empty list arrived
identical, which is exactly the confusion the note was written to prevent. It
went unnoticed because no fixture declared an assembly the viewer could fail to
find.

**This Mol\* build cannot enumerate assemblies.** With the note finally
returned, it read "no symmetry provider in this Mol* build". Probing the
namespace: `Symmetry` exposes `findAssembly` and `getUnitcellLabel`,
`StructureSymmetry` exposes `buildAssembly` and friends. Builders and a lookup,
no list, and no `Symmetry.Provider` at all.

### The fix

Assemblies now come from BOFFIN's own parse of `_pdbx_struct_assembly`, which
had the answer throughout. The viewer is still asked, and its reply is the
fallback for a format the parser cannot read.

Same lesson as the crystal cell, and the second time it has applied: read the
entry rather than interrogating a minified viewer's internals. BOFFIN parses the
file anyway.

BoffinViewer 25 tests, BoffinStructure 99, 22 UI tests.

## The picker was labelling a 24-mer "deposited coordinates" (2026-08-26)

A direct consequence of the ferritin finding, and the user-facing half of it.

Mol*'s default preset builds the biological assembly on load. The viewer model
initialised its assembly selection to `nil` regardless, and `nil` is the
picker's tag for "Deposited coordinates". So on ferritin the control asserted
the screen showed a single deposited chain while it showed a 24-subunit shell.

A picker that disagrees with the picture is worse than no picker: it is a label
making a false claim about what you are looking at, in an app whose entire
argument is that it says what it is showing.

**Measured, not assumed.** Rather than hardcoding "the default preset builds
assembly 1", the load path compares the atom count the viewer reports against
the count BOFFIN parses from the same bytes. More atoms on screen than in the
file means an assembly was built, and the selection is set accordingly. That
survives a Mol* upgrade changing its preset, where an assumption would not.

**The explanatory text was backwards too**, in the same direction as the
project's notes: it warned that "a dimer with one chain in the asymmetric unit
looks like a monomer until the assembly is built". The real risk is the
opposite. It now says the viewer shows the biological assembly by default and
that choosing deposited coordinates is how to see exactly what was solved.

A test pins the selection against the fixture, and it is discriminating by
construction: before the fix the model set `nil` unconditionally, so comparing
it against the first declared assembly's id could not have passed.

BoffinViewer 26 tests, 22 UI tests.

## The ensemble fixture was not an ensemble (2026-08-26)

Auditing viewer claims against measured behaviour, after the assembly text
turned out to be backwards.

The Structure tab says, when a file holds several models: "N models in this
file: an NMR ensemble. One is shown; superimposing all of them renders as a
single very badly resolved structure." **No fixture could ever trigger it**, and
1XQ8 was recorded in the manifest as the multi-model fixture.

**1XQ8 has one model.** Verified against the authoritative mmCIF from RCSB:
2,017 ATOM records, every one at `pdbx_PDB_model_num` 1, method SOLUTION NMR.
Being solution NMR does not imply an ensemble, and that inference is how the
claim reached the manifest.

**One thing that looked like a bug and is not.** `AtomStore.from` returned 304
atoms for a 1L2Y file holding 11,552 rows, which reads exactly like silent data
loss. It is deliberate and documented: the method takes a single model,
defaulting to the first, because loading twenty superimposed copies renders as
one badly resolved structure and every geometric measurement would span copies
that are not in contact. The code was right.

**1L2Y added**: Trp-cage, 38 models, 11,552 atom rows, 304 atoms per model,
591 KB. The first fixture with more than one model.

Four tests now cover what could not be covered before: that the fixture really
holds 38 models, asserted against the raw table rather than the parsed store so
it cannot become vacuous; that exactly one model's worth is loaded and the ratio
is exact, so a parser that started concatenating models fails rather than
quietly producing a structure whose distances span two copies; that the model
parameter is not decorative, since model 7 must hold the same atoms in different
places; and that 1XQ8 loses nothing on load, because there is only one model to
lose.

BoffinStructure 103 tests.

## Auditing the fixture manifest by measurement (2026-08-26)

Two fixture claims had already proved false, both by the same route: a property
inferred from what the entry IS rather than measured from what the file
CONTAINS. So every remaining claim was measured.

| Claim | Verdict |
|---|---|
| 1HCK carries ATP and Mg | **True.** Heteroatoms are ATP, MG, HOH |
| 7K00 is 7.3 MB | **True.** 7,679,004 bytes, 149,338 atoms |
| 2RH1 is a fusion construct | **True.** 442 observed residues |
| 1E8A is selenomethionine-substituted | **False** |

**1E8A is not what the manifest said it was, in any respect.** The
authoritative entry is *The three-dimensional structure of human S100A12*: no
MSE anywhere, no alternate locations, heteroatoms of only calcium and water. It
was credited with non-standard residues and alternate locations and has
neither. What it does have is calcium coordination and a declared dimer
assembly, and it is now recorded for those.

**The path it was supposed to test is real, careful, and had never run.**
Selenomethionine is how a great many structures are phased, so MSE is one of the
commonest non-standard residues in the PDB, and it is deposited as HETATM. A
viewer treating HETATM as "not polymer" drops a methionine out of the middle of
a chain: the cartoon breaks where it should be and a pocket selection returns a
hole rather than an error. `SelectionEvaluator` handles this deliberately, with
MSE in `polymerResidues` alongside SEC, PYL, HYP, SEP, TPO, PTR, CSO and CME,
and explicit logic to accept MSE even when the record says HETATM.

**1A8O added**: HIV capsid C-terminal domain, 644 atoms, 183 KB, **32 MSE atoms
all recorded as HETATM**, four selenium. Found by querying RCSB for entries
containing MSE under 1,500 atoms rather than by guessing, after five guesses in
a row had none.

Four tests: that the fixture really carries MSE as HETATM, since MSE as plain
ATOM would test nothing; that it counts as polymer; that the exception has not
widened into "all heteroatoms are polymer", which would pull every water into a
binding site; and that 1E8A has no MSE, kept as the record of the claim.

BoffinStructure 107 tests.

## A bug found by asking which code paths have no fixture (2026-08-26)

After three false fixture claims, the productive question stopped being "which
fixtures are wrong" and became "which deliberate code paths has nothing ever
run". Measuring the fixtures for the features the code special-cases:

| Feature | Fixtures carrying it |
|---|---|
| Explicit hydrogens | 6EQE (2,102), 1XQ8 (1,004), 1L2Y (150) |
| Metals | 1HCK, 1E8A, 7K00, 1FHA, 6EQE |
| Selenomethionine | 1A8O, added yesterday |
| Residue numbers below 1 | **none** |
| Modified residues other than MSE | **none** |

That last row is where the bug was.

### The bug

`SelectionEvaluator`'s polymer rule read:

    (inPolymerSet && !isHeteroatom) || (isHeteroatom && inPolymerSet && name == "MSE")

`polymerResidues` carries SEC, PYL, HYP, SEP, TPO, PTR, CSO and CME alongside
MSE, and **only MSE took the HETATM exception**. Every other modified residue
was in the set and could never benefit from it, because modified residues are
deposited as HETATM by definition: that is why they need the exception at all.

**SEP, TPO and PTR are the ones that matter.** Phosphoserine, phosphothreonine
and phosphotyrosine are deposited as HETATM and are the entire point of a
kinase-substrate structure. A phosphopeptide lost its phosphoresidues from
every `polymer` selection: the cartoon breaks at the modified residue, and
`byres (polymer within 5 of organic)` returns a pocket with a hole in it exactly
where the chemistry is. No error, and a figure that looks deliberate.

### The fix, and why it is a named set rather than a simpler rule

The obvious simplification is to accept any name in `polymerResidues` whatever
the record type, which is wrong in the opposite direction. A free alanine or
glycine bound in a site is deposited as HETATM and is a LIGAND. Blanket
acceptance would pull it into the protein, which is just as invisible and just
as wrong.

So `modifiedPolymerResidues` names the nine residues that take the exception,
and the standard twenty appearing as HETATM stay out as the ligands they are.

Tested both directions, because only testing the first would have licensed the
simplification that breaks the second.

### Still open

No fixture has a residue numbered below 1. The selection tokeniser treats
`50-120` as a single token specifically so that the minus sign in an expression
tag's negative numbering is not read as a range separator, and nothing exercises
a structure that actually has one.

BoffinStructure 110 tests.

## The honesty mechanism was overclaiming (2026-08-26)

The interaction profiler's assumptions statement exists so a reader can tell
which criteria were applied and which were not. For a structure carrying
explicit hydrogens it said:

> The structure contains explicit hydrogens, which were used for donor geometry
> where present.

**They are not used.** The hydrogen bond criterion is heavy-atom distance alone,
unconditionally, and `criteria.hydrogenBondAngle = 100` is declared once and read
nowhere, not even in a test.

This is the fourth claim in three days that the code did not support, and the
worst placed: the string is the mechanism built to prevent exactly this, so it
was overclaiming rigour in the one sentence a careful reader would trust.

**Why it survived.** The only profiling test uses CDK2, which has no hydrogens,
so the branch shown for a structure WITH them had never been rendered. PETase
carries 2,102 hydrogens and was in the fixture set the whole time.

The statement now says the hydrogens are not used and that bonds are called on
heavy-atom distance, the same as for a structure without them. Three tests cover
it, including that PETase really does carry hydrogens, so the suite cannot go
vacuous if the fixture changes.

### The decision this raises, which is not a programming one

`hydrogenBondAngle` is the right number and applying it would be better science
on a structure whose hydrogens are real. But hydrogens in most deposited
structures are CALCULATED by refinement software rather than observed, so
filtering donor geometry on them would be filtering on a model's assumptions
while reporting the result as a measurement. Whether BOFFIN should do that is a
judgement about what the app is claiming, not a question about code, and it is
recorded here rather than answered.

## Hydrogen bonds now use explicit hydrogens (2026-08-26)

Marc's decision, taken after the assumptions statement was found overclaiming:
use explicit hydrogens for donor geometry where a structure carries them.

### What changed

`hydrogenBondAngle` had been declared and never read. It is now applied: where
a structure has hydrogens, one of the two polar atoms must actually donate at a
donor-hydrogen-acceptor angle of at least 100 degrees, measured at the hydrogen.

Hydrogens are attached to their **nearest** heavy atom within 1.3 A, by distance
rather than connectivity, because BinaryCIF carries no bond table for the
polymer. 1.3 A spans the real bond lengths (O-H 0.98, N-H 1.01, C-H 1.09) and
stops short of the nearest non-bonded contact. Nearest-only matters: a hydrogen
between two polar atoms is bonded to one and merely close to the other, and
assigning it to both would invent a donor.

### What it buys

Two rejections that distance alone accepts, both chemically impossible:

- **A bent geometry.** At 60 degrees the heavy atoms are still inside the
  distance cutoff, so distance alone calls it a bond. The hydrogen is pointing
  somewhere else entirely.
- **An acceptor-acceptor pair.** Two carbonyl oxygens 3 A apart are close and
  neither can donate. Unreachable before, because without hydrogens the profiler
  cannot tell a donor from an acceptor at all.

Both are tested, and the bent case asserts the heavy atoms really are within the
cutoff, so the test cannot pass by the pair being too far apart anyway.

### The honest caveat, which is the reason this needed a decision

Most deposited hydrogens are PLACED by refinement software at idealised geometry
rather than observed. On such a structure this filters contacts using the
refinement's assumptions and reports the result as measurement. The assumptions
statement now names the cutoff and says so, and a test asserts the caveat is
present rather than merely the cutoff: an accurate sentence that omits it would
be worse than the old wrong one, because it would be defensible.

Structures without hydrogens are unchanged and still use distance alone, which
a test pins.

BoffinStructure 117 tests.

## The expression-tag range the tokeniser existed to protect (2026-08-26)

The last gap the fixture audit measured: no fixture has a residue numbered below
one, so the selection language's handling of expression-tag numbering was
unexercised. It turned out not to need a fixture, because the parser was wrong.

The PDB numbers an expression tag backwards from the mature protein's first
residue, so a cleaved His-tag is typically **-20 to -1**. `SelectionLanguage`
treats `50-120` as a single token specifically so the minus in that numbering is
not read as a range separator, and the comment says so.

**`resi -20--1` did not parse.** The body was split on every minus, giving three
parts and "not a number". There was also no way at all to write a range that
ENDS below zero: the high end never received a sign.

So the case the single-token treatment exists for was the one case it could not
express.

| Expression | Before | After |
|---|---|---|
| `resi -5` | -5 | -5 |
| `resi -5-10` | -5 to 10 | -5 to 10 |
| **`resi -20--1`** | **"not a number"** | **-20 to -1** |
| **`resi 50--10`** | **"not a number"** | **-10 to 50** |
| `resi 50-120` | 50 to 120 | 50 to 120 |

The split is now on the FIRST minus after any leading one, and whatever follows
is parsed as a number in its own right including its own sign.

Four tests, one of which is the negative case, one the ordinary ranges that
everything else depends on, and one asserting that nonsense is still refused:
the fix must not have made the parser permissive, because an unparseable number
that silently selects everything makes a figure wrong in a way nobody can see.

BoffinStructure 121 tests.

## CI had been red for five commits and I had not looked (2026-08-26)

The autonomous check found `main` failing on five consecutive completed runs.
Two more showed `cancelled`, which is a push landing while the previous run was
still going, so CI had not actually verified anything for some time.

**One cause, one test.** `testSelectionBuilderComposesAWorkingExpression` fails
on iPad with "no byres control". The builder's Form is taller than the sheet on
that idiom, so the Refine section starts below the fold and a bare `.exists`
returns false.

**The lesson is about the local run, not the test.** CI covers iPhone AND iPad;
I had been running only iPhone and treating a local pass as sufficient. Every
push since the selection builder inherited the same failure, and the fix took
minutes once looked at.

Two further problems surfaced while fixing it, both worth recording:

**A stale element handle.** Tapping the control rebuilds the label's view, so
the earlier `XCUIElement` no longer resolves and reading `.label` fails with "no
matches found" rather than with a wrong value. Re-query after any tap that
changes the view.

**Scrolling drops content out of the accessibility tree.** Reaching the byres
control scrolls the Form, and the count label above it then reads as missing
rather than as off-screen. Same behaviour already met on the Structure tab, now
met again inside a sheet.

**And the simulators wedge.** "Application failed preflight checks" three times
during this session. The recorded recovery works and is the only one that does:
`simctl shutdown all`, `erase` the device, `bootstatus -b`. Never
`killall CoreSimulatorService`, which unmounts the runtime cryptex and needs a
reboot to undo.

Both idioms now pass 22 of 22.
