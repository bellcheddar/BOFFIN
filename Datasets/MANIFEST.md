# Datasets


## Codon usage (Phase 6)

| File | Source | Terms |
|---|---|---|
| `codon/ecoli_cds.fna` | NCBI efetch, `U00096.3`, `rettype=fasta_cds_na` | RefSeq/GenBank records are in the public domain |

`Tools/data/generate_codon_table.py` counts every codon in every annotated
coding sequence of *Escherichia coli* K-12 MG1655 and emits
`Packages/BoffinCore/Sources/BoffinCore/Generated/CodonTable.swift`.

**4,317 coding sequences, 1,342,016 codons.** One CDS was skipped for a length
that is not a multiple of three, which means it is annotated across a frameshift
or a gap; counting it would slide every codon after the break by one.

The obvious alternative was Kazusa's published table, and its entry for this
organism (species 83333) is built on **14 CDS and 5,122 codons**. That is a fine
sample of fourteen genes and a poor description of the organism, and it is
exactly the artefact that acquires authority by being quoted: an official name
and no visible N. Computing the table is a download and forty lines.
