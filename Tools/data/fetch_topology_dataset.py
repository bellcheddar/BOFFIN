#!/usr/bin/env python3
"""Build a transmembrane-span and signal-peptide dataset from Swiss-Prot.

    Tools/coreml/.venv/bin/python Tools/data/fetch_topology_dataset.py

Writes `Datasets/topology/train.json`.

Why not DeepTMHMM or TOPCONS
----------------------------
Those are the obvious sources and BOFFIN cannot ship a head trained on them.
DeepTMHMM requires a paid commercial licence outside academia; TOPCONS and the
DTU download pages state no terms at all, which defaults to all rights reserved.
`Docs/ATTRIBUTIONS.md` has recorded that as unverified since Phase 3, and it
blocks release rather than development, which means it blocks release.

UniProt is **CC BY 4.0**, verified at source, and Swiss-Prot curates exactly the
features this needs: `TRANSMEM`, `SIGNAL`, `TOPO_DOM` and `INTRAMEM`. So the
labels are derived from a source that can actually be shipped.

What this costs, stated rather than discovered later
-----------------------------------------------------
Swiss-Prot TRANSMEM annotations are a mixture of experimental determination and
curated inference from homology and hydrophobicity, and the entry does not
always say which. That is weaker supervision than a benchmark curated to be
experimental only, and it is why the evidence code is kept per feature: a head
trained on everything can be compared against one trained on experimental
evidence alone, rather than the difference being assumed either way.

Negatives are real here, unlike the disorder case. A soluble Swiss-Prot protein
with no TRANSMEM feature is a genuine negative, because the curators would have
annotated one had it existed. That is the opposite of DisProt, where the absence
of a disorder annotation means nothing (see Docs/CHANGELOG.md, Phase 3).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Datasets/topology"

USER_AGENT = "boffin-topology-fetcher (research use; marc@marcdeller.com)"
BASE = "https://rest.uniprot.org/uniprotkb/search"

# The backbone's ceiling, less the two special tokens.
MAX_LENGTH = 1022
MIN_LENGTH = 30


def fetch_page(url: str) -> tuple[dict, str | None]:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=180) as response:
        body = json.loads(response.read().decode("utf-8"))
        link = response.headers.get("Link", "")
    nextURL = None
    if 'rel="next"' in link:
        nextURL = link.split("<", 1)[1].split(">", 1)[0]
    return body, nextURL


def spans(entry: dict, kind: str) -> list[tuple[int, int, str]]:
    """Feature spans of one type, one-based and inclusive, with evidence."""
    found = []
    for feature in entry.get("features", []):
        if feature.get("type") != kind:
            continue
        location = feature.get("location", {})
        start = location.get("start", {}).get("value")
        end = location.get("end", {}).get("value")
        if start is None or end is None or end < start:
            # A feature with an uncertain boundary has no value as a label: it
            # is precisely the boundary this head has to predict.
            continue
        codes = {e.get("evidenceCode", "") for e in feature.get("evidences", [])}
        # ECO:0000269 is experimental evidence used in a manual assertion.
        evidence = "experimental" if "ECO:0000269" in codes else "inferred"
        found.append((start, end, evidence))
    return found


def collect(query: str, wanted: int, pages: int) -> dict[str, dict]:
    url = (
        f"{BASE}?query={urllib.parse.quote(query)}"
        "&fields=accession,sequence,ft_transmem,ft_signal,ft_topo_dom,ft_intramem,protein_name"
        "&format=json&size=500"
    )
    entries: dict[str, dict] = {}
    page = 0
    while url and page < pages and len(entries) < wanted:
        try:
            body, url = fetch_page(url)
        except (urllib.error.URLError, OSError) as error:
            print(f"\n  fetch failed after {page} pages: {error}", file=sys.stderr)
            break
        page += 1
        for entry in body.get("results", []):
            sequence = entry.get("sequence", {}).get("value", "")
            if not (MIN_LENGTH <= len(sequence) <= MAX_LENGTH):
                continue
            accession = entry.get("primaryAccession")
            if not accession or accession in entries:
                continue
            entries[accession] = {
                "accession": accession,
                "sequence": sequence,
                "transmem": spans(entry, "Transmembrane"),
                "signal": spans(entry, "Signal"),
                "intramem": spans(entry, "Intramembrane"),
                "topology": [
                    (s, e, (f.get("description") or "").lower())
                    for f in entry.get("features", [])
                    if f.get("type") == "Topological domain"
                    for s, e in [(
                        f.get("location", {}).get("start", {}).get("value"),
                        f.get("location", {}).get("end", {}).get("value"))]
                    if s is not None and e is not None and e >= s
                ],
                "name": (entry.get("proteinDescription", {})
                         .get("recommendedName", {})
                         .get("fullName", {})
                         .get("value", "")),
            }
        print(f"\r  page {page}: {len(entries):,} entries", end="", flush=True)
    print()
    return entries


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--membrane", type=int, default=9000)
    parser.add_argument("--soluble", type=int, default=9000)
    parser.add_argument("--secreted", type=int, default=4000)
    parser.add_argument("--max-pages", type=int, default=60)
    args = parser.parse_args()

    print("membrane proteins with curated TRANSMEM features")
    membrane = collect(
        "reviewed:true AND ft_transmem:*", args.membrane, args.max_pages)

    print("secreted proteins with curated SIGNAL features")
    secreted = collect(
        "reviewed:true AND ft_signal:* AND NOT ft_transmem:*",
        args.secreted, args.max_pages)

    # Negatives matter as much as positives, and unlike the disorder case they
    # are real: a curated soluble cytoplasmic protein with no TRANSMEM feature
    # is a genuine negative rather than an unobserved one.
    print("soluble cytoplasmic proteins as negatives")
    soluble = collect(
        "reviewed:true AND NOT ft_transmem:* AND NOT ft_signal:* "
        "AND (cc_scl_term:SL-0091 OR cc_scl_term:SL-0191)",
        args.soluble, args.max_pages)

    merged: dict[str, dict] = {}
    for group, label in ((membrane, "membrane"), (secreted, "secreted"), (soluble, "soluble")):
        for accession, entry in group.items():
            if accession in merged:
                continue
            entry["group"] = label
            merged[accession] = entry

    counts = Counter(e["group"] for e in merged.values())
    residues = sum(len(e["sequence"]) for e in merged.values())
    tmSpans = sum(len(e["transmem"]) for e in merged.values())
    experimental = sum(
        1 for e in merged.values() for s in e["transmem"] if s[2] == "experimental")
    print(f"\n{len(merged):,} entries, {residues / 1e6:.2f} M residues")
    for name, count in counts.most_common():
        print(f"  {name:<10} {count:,}")
    print(f"  {tmSpans:,} TRANSMEM spans, {experimental:,} with experimental evidence "
          f"({experimental / max(tmSpans, 1):.1%})")
    print(f"  {sum(len(e['signal']) for e in merged.values()):,} SIGNAL features")

    OUT.mkdir(parents=True, exist_ok=True)
    destination = OUT / "train.json"
    destination.write_text(json.dumps(list(merged.values())) + "\n")
    print(f"\nwrote {destination.relative_to(ROOT)} "
          f"({destination.stat().st_size / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
