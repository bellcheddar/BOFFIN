# Fixture manifest

The golden set. Every analytical change is checked against all of these, so
regressions are caught rather than argued about.

Downloaded 2026-08-24. Structures are BinaryCIF from `models.rcsb.org`
(markedly smaller than mmCIF and faster to parse, per build plan section 6.4).
Sequences are RCSB entry FASTA and UniProt canonical FASTA.

All of it is committed so the fixture suite runs with no network, matching the
app's own offline rule.

## Structures

| File | Entry | Exercises |
|---|---|---|
| `structures/1ubq.bcif` | 1UBQ, ubiquitin | Baseline and fast path: small, well behaved, mixed alpha/beta |
| `structures/1hck.bcif` | 1HCK, human CDK2 with ATP and Mg | KLIFS numbering, motif detection, interaction profiling |
| `structures/1xkk.bcif` | 1XKK, EGFR kinase with lapatinib | Halogen bonds: the ligand carries one chlorine and one fluorine |
| `structures/2rh1.bcif` | 2RH1, beta-2 adrenergic receptor with carazolol | GPCRdb generic numbering, TM span prediction |
| `structures/6eqe.bcif` | 6EQE, *Piscinibacter sakaiensis* PETase | Catalytic triad annotation, disulfide detection, **alternate conformations** (709 of 4,596 atoms carry an altloc; 25 residues have alternate CA positions) |
| `structures/1xq8.bcif` | 1XQ8, micelle-bound alpha-synuclein (NMR) | Disorder track, boundary solver refusal. **Not** a multi-model ensemble: this row claimed one and the entry has a single deposited model, verified against the authoritative mmCIF (2,017 ATOM records, all at model 1). Solution NMR does not imply an ensemble, and that inference is how the claim got here. 1L2Y is the fixture that actually carries one |
| `structures/7k00.bcif` | 7K00, *E. coli* 70S ribosome | Viewer performance guardrail (large assembly) |
| `structures/1l2y.bcif` | 1L2Y, Trp-cage miniprotein (NMR) | **Multi-model ensemble.** 38 models, 11,552 atom rows, 304 atoms per model. Added 2026-08-26 because no fixture had more than one model, leaving the ensemble path untested. `AtomStore` deliberately takes a single model, so this exercises that choice being made rather than assumed |
| `structures/1a8o.bcif` | 1A8O, HIV capsid C-terminal domain | **Selenomethionine.** 32 MSE atoms, **all recorded as HETATM**, which is the case `SelectionEvaluator` handles specially so modified residues still count as polymer. Added 2026-08-26: the path was written deliberately and had never been exercised, because the fixture credited with it is a different protein. 644 atoms, 183 KB |
| `structures/1fha.bcif` | 1FHA, human ferritin heavy chain | **Biological assembly construction.** Declares a **24-mer** and deposits a **single chain**: the deposited coordinates look like a monomer and the molecule is a 24-subunit shell. Added 2026-08-26 because no other fixture had an assembly differing from its asymmetric unit, which left assembly construction untestable. 1,361 atoms, 246 KB |
| `structures/1e8a.bcif` | 1E8A, human S100A12 | **Calcium coordination** and a declared dimer assembly. Every earlier claim in this row was wrong and is recorded rather than quietly replaced: it was described as selenomethionine-substituted and credited with non-standard residues and alternate locations. The authoritative entry is *The three-dimensional structure of human S100A12*, with **no MSE**, **no altlocs**, and heteroatoms of only Ca and water. 1A8O carries the selenomethionine, PETase the alternate locations |

## Sequences

| File | Source | Notes |
|---|---|---|
| `sequences/1UBQ.fasta` | RCSB entry FASTA | 76 residues |
| `sequences/1HCK.fasta` | RCSB entry FASTA | 298 residues |
| `sequences/2RH1.fasta` | RCSB entry FASTA | 500 residues: see the caveat below |
| `sequences/6EQE.fasta` | RCSB entry FASTA | 298 residues |
| `sequences/1XQ8.fasta` | RCSB entry FASTA | 140 residues |
| `sequences/P24941_CDK2_HUMAN.fasta` | UniProt P24941 | CDK2 canonical |
| `sequences/P07550_ADRB2_HUMAN.fasta` | UniProt P07550 | ADRB2 canonical, no fusion |
| `sequences/A0A0K8P6T7_PETASE.fasta` | UniProt A0A0K8P6T7 | PETase canonical, signal peptide included |
| `sequences/P37840_SYUA_HUMAN.fasta` | UniProt P37840 | Alpha-synuclein canonical |

Both the entry sequence and the UniProt canonical sequence are kept for the
four proteins where they differ. Construct sequences and canonical sequences
are not interchangeable, and a test that silently swaps one for the other will
pass while measuring the wrong thing.

## Malformed inputs

| File | Case |
|---|---|
| `malformed/empty.fasta` | Zero bytes |
| `malformed/truncated-header-only.fasta` | Header with no sequence |
| `malformed/truncated-midline.fasta` | Cut mid-sequence, no trailing newline |
| `malformed/empty-record.fasta` | Multi-record file where one record is empty |
| `malformed/non-canonical-codes.fasta` | X, B, Z, J, U, O: must be preserved, never coerced |
| `malformed/pasted-alignment.fasta` | Lower case, block numbering, whitespace, gap characters |
| `malformed/bare-sequence.txt` | No header at all |
| `malformed/crlf.fasta` | CRLF line endings, as arriving from a share sheet |

## Caveats, resolved 2026-08-26

All three were judgement calls the build plan said to surface rather than
guess. Answering them found two real defects, both in code no fixture had ever
reached.

1. **2RH1 is a fusion construct, and it is kept as one.** T4 lysozyme replaces
   most of ICL3, which is why the entry sequence is 500 residues. The GPCRdb
   tests were already asserting against `P07550_ADRB2_HUMAN.fasta`, the
   unmodified receptor, which is right: generic numbering is defined on the
   receptor and asserting against the chimera would bake lysozyme into the
   expectations. What was missing is the stress test 2RH1 was collected for,
   because no test loaded the file at all. It does now, and it failed:
   numbering assigned **5x70 to 5x76 and 6x24 to lysozyme residues**, with
   5x70 at 238, 5x71 at 244 and 5x74 at 279. Positions within one helix cannot
   be six and thirty-three residues apart. `FamilyStore` now drops any segment
   whose numbers do not land on consecutive residues, which removes seven of
   the eight; the last is the alignment placing TM6's boundary one residue
   across the splice, and the test bounds it at one rather than waiving it.

2. **1HCK stays, and 1XKK joins it.** The question was whether the profiler
   wanted a drug-like inhibitor instead of ATP. It wants both, and the reason
   is not preference: ATP with Mg exercises hydrogen bonds, hydrophobic
   contacts, salt bridges and metal coordination, and **nothing exercised
   halogen bonds at all**. `1xkk.bcif` is EGFR with lapatinib, whose ligand
   carries exactly one chlorine and exactly one fluorine -- which is what makes
   it the right choice rather than merely a halogenated one, since it separates
   two errors at once. The dead rule counted fluorine as a halogen-bond donor,
   which it is not, and tested distance without direction: it reported eight
   halogen bonds on this entry, **five of them from the single fluorine**, and
   three from one chlorine, which one sigma-hole cannot do. Now one, from the
   chlorine, to Leu788's backbone oxygen at 3.10 A.

3. **7K00 stays in the repository.** The trade was 7.3 MB against the fixture
   suite running fully offline. Offline wins easily at this size: the whole
   `.git` directory is 16 MB, so the ribosome is a rounding error next to the
   guarantee that the suite needs no network. Revisit only if the repository
   grows enough for it to matter.

## Checksums (SHA-256)

```
a25daa0086c54d1c50e0805bf7f19210c9447cbc9983c67616f07023eef5b053  malformed/bare-sequence.txt
6371942fcae3f1196c95c0a2bc364e52021df4cdca5ef0c012aee9b5f7b46a46  malformed/crlf.fasta
0d0b0d63961d164c00c45d7bd41bc1b7b102fdffbc187ca5635c5743665ebdfa  malformed/empty-record.fasta
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  malformed/empty.fasta
80374328336d09522f01bca983e696ef8aae5c117dfecb90219365c87c4069f3  malformed/non-canonical-codes.fasta
3c089a7a070f07ca5e5b5e5d5b21b42124626157822fad3157734a1daff73e4c  malformed/pasted-alignment.fasta
ac326b841d1ebd69df3c008559166e6b926eb313b4f0a50588d570ccfec9c688  malformed/truncated-header-only.fasta
0448d93aec6983b708dda7dd57e902a858c0428c71c5bc678ce6491df289994f  malformed/truncated-midline.fasta
221f007aff5e9dfc1ebd418dd0f227485b8a84abf8ed19ef2e3c8cfe36e96519  sequences/1HCK.fasta
f00b1a97f51c157133e1e2b3f3ed868aa2edf79591e8b5206a1bdd0f3b7c94d2  sequences/1UBQ.fasta
465439c76c85740d1605be0614b5f2c3b8e70c968fd1f284d934a96fb183e8db  sequences/1XQ8.fasta
71eeaa14ea90569d049d620276550747d17af6a254fa4cfef396e854dc9e4f0e  sequences/2RH1.fasta
e8eecb232bc6ae3242efde8de6757d8ce2343ad087feef33c9d2f5fd5a931b68  sequences/6EQE.fasta
e1d2c99f6cfa33ceb1faa519ea9dda372e391511f7a295c9474c1af8be61c207  sequences/A0A0K8P6T7_PETASE.fasta
1891e8bb239fdf226999095969c779ba169ddd2f36b2acb4af451bec4263c3c5  sequences/P07550_ADRB2_HUMAN.fasta
0af10cffa3bde6c6db5c14cd094bdc554c98091188b9ea590392a37a0d7f1485  sequences/P24941_CDK2_HUMAN.fasta
44fb78fc03c1b336f175c08b0945206f5ed574564b8d637f9f7f3d4ea1ceae92  sequences/P37840_SYUA_HUMAN.fasta
f93b5f370b0b63d0d33fc20da568595e74213d370f00f08900c55adda859cb22  structures/1e8a.bcif
9b13dc6074a20e0ad88d84a7d91dd128f193db9a115577b13c91b625866d2763  structures/1hck.bcif
c0bfdef0a5ddb24dddd2c22111e78cf2c3c4e3ddf232fa6c18f59593e4adcb08  structures/1xkk.bcif
d691a4b8a0c5d9a34709fac878560c987e99815271c5dfcf10efa650bed81d72  structures/1ubq.bcif
75ba05bff833481f2b8240e4a4ed19bb94b01775923d4675d6d153135edfe11d  structures/1xq8.bcif
7cf4b591b17e0ab2bab783290d46df1e99da3bba3c2a6501862eb4ebe286277f  structures/2rh1.bcif
730f10a7598769463e81d2107b18953c967a826e0a7b53e7dfa11d31528076bd  structures/6eqe.bcif
0a50e05d731ba19ac710433aae5c3e244a3a41fca1973b75540c42db3730442d  structures/7k00.bcif
0920e18721ee85102ccce6f8de7cef2f7b0c6c1a87107a81b5c3521f96a0e0ab  structures/1fha.bcif
3287cc3b2b0bfb0d5dcae685ac4ec8c40723927f70ec82049b55e32935fbc0c7  structures/1l2y.bcif
ca59d7ab675557659005ef1ebd677d19d02dc8a84818262e573fbc504250da14  structures/1a8o.bcif
```
