# Generated data manifest

Constant tables in `BoffinCore` are generated, not transcribed. Regenerate
with `python3 Tools/data/generate_amino_acid_tables.py` and commit the
result together with this manifest.

Last generated: **2026-08-25**

| Source | URL | SHA-256 |
|---|---|---|
| `IUPACData.py` | <https://raw.githubusercontent.com/biopython/biopython/master/Bio/Data/IUPACData.py> | `897fb42f1bd6e3f837be6918ae6c54e77e61013b284cbabd4e7dfc01723e1a91` |
| `ProtParamData.py` | <https://raw.githubusercontent.com/biopython/biopython/master/Bio/SeqUtils/ProtParamData.py> | `488a4c336556c5e6aa41e9208cd4a9390d7a29d3d83e2c8be1f0cb518c718947` |
| `IsoelectricPoint.py` | <https://raw.githubusercontent.com/biopython/biopython/master/Bio/SeqUtils/IsoelectricPoint.py> | `93a0d329ba6379edd07c53f5ea8ecb39c9684d9218ab3fcb4736e1324e2caed2` |
| `Epk.dat` | <https://raw.githubusercontent.com/kimrutherford/EMBOSS/master/emboss/data/Epk.dat> | `db2702d55a271069775d63b04c8ed3b17e4c7e8eefc83302705882b133c7b0a1` |
| `BLOSUM62` | <https://raw.githubusercontent.com/biopython/biopython/master/Bio/Align/substitution_matrices/data/BLOSUM62> | `85510d3846ee6d5f4778e425cf8daf6e0dbb889b306f2d13434e1254780efb40` |

## What is taken from each

| Source | Table | Underlying paper |
|---|---|---|
| `IUPACData.py` | Average free amino acid masses | IUPAC-IUB standard atomic weights |
| `ProtParamData.py` | Kyte-Doolittle hydropathy | Kyte & Doolittle, J Mol Biol 157:105 (1982) |
| `ProtParamData.py` | DIWV dipeptide instability, 400 entries | Guruprasad et al., Protein Eng 4:155 (1990) |
| `IsoelectricPoint.py` | Bjellqvist pKa scale | Bjellqvist et al., Electrophoresis 14:1023 (1993) |
| `Epk.dat` | EMBOSS pKa scale | EMBOSS `iep` |

These are published scientific constants, used here as machine-readable
transcriptions of the papers cited above rather than as code. Licensing of
the sources is recorded in `Docs/ATTRIBUTIONS.md`.

Extinction coefficients at 280 nm (Trp 5500, Tyr 1490, cystine 125) are from
Pace et al., Protein Sci 4:2411 (1995) and are written directly into the
generator: three numbers do not need a download to be trustworthy.

