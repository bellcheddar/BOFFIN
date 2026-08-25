#!/usr/bin/env python3
"""Build a Pfam-labelled training set for the family classifier.

    Tools/coreml/.venv/bin/python Tools/data/fetch_pfam_training.py

Writes `Datasets/pfam/train.json`: reviewed (Swiss-Prot) sequences, each with
the single Pfam family it is labelled with.

Design decisions worth stating
------------------------------

**Single-label, not multi-label.** Many proteins carry several Pfam domains. A
multi-domain protein labelled with only one of them teaches the classifier that
the others are wrong, so entries with more than one Pfam annotation are
EXCLUDED rather than assigned their first domain. That costs coverage and buys a
label that means what it says.

**Reviewed entries only.** Swiss-Prot annotations are curated; TrEMBL's are
propagated automatically, so training on them partly teaches the model to
reproduce whatever assigned them.

**Capped per family.** Pfam family sizes span orders of magnitude. Without a cap
the classifier learns the prior and reports the biggest families for everything,
which scores well on accuracy and is useless.

Licence: UniProt is CC BY 4.0. Pfam and InterPro are CC0. Both are recorded in
Docs/ATTRIBUTIONS.md.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Datasets/pfam"

USER_AGENT = "boffin-pfam-fetcher (research use; marc@marcdeller.com)"
BASE = "https://rest.uniprot.org/uniprotkb/search"


def fetch_page(url: str) -> tuple[str, str | None]:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response:
        body = response.read().decode("utf-8")
        link = response.headers.get("Link", "")
    nextURL = None
    if 'rel="next"' in link:
        nextURL = link.split("<", 1)[1].split(">", 1)[0]
    return body, nextURL


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--per-family", type=int, default=150)
    parser.add_argument("--families", type=int, default=100)
    parser.add_argument("--max-pages", type=int, default=120)
    parser.add_argument("--min-length", type=int, default=50)
    parser.add_argument("--max-length", type=int, default=1000)
    args = parser.parse_args()

    query = urllib.parse.quote("reviewed:true AND database:pfam")
    url = (
        f"{BASE}?query={query}"
        "&fields=accession,xref_pfam,sequence,protein_name"
        "&format=tsv&size=500"
    )

    byFamily: dict[str, list[dict]] = defaultdict(list)
    multiDomainSkipped = 0
    lengthSkipped = 0
    seen = 0
    pages = 0

    while url and pages < args.max_pages:
        try:
            body, url = fetch_page(url)
        except (urllib.error.URLError, OSError) as error:
            print(f"\nfetch failed after {pages} pages: {error}", file=sys.stderr)
            break
        pages += 1

        for line in body.splitlines()[1:]:
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            accession, pfam, sequence = parts[0], parts[1], parts[2]
            seen += 1

            families = [f for f in pfam.strip(";").split(";") if f]
            # Single-label only: see the module docstring.
            if len(families) != 1:
                multiDomainSkipped += 1
                continue
            if not (args.min_length <= len(sequence) <= args.max_length):
                lengthSkipped += 1
                continue

            family = families[0]
            if len(byFamily[family]) < args.per_family:
                byFamily[family].append({"accession": accession, "sequence": sequence})

        ready = sum(1 for v in byFamily.values() if len(v) >= args.per_family)
        print(
            f"\r  page {pages}: {seen:,} entries seen, {len(byFamily):,} families, "
            f"{ready} at quota",
            end="", flush=True)
        if ready >= args.families:
            break
    print()

    # Keep only families with enough examples, largest first.
    ordered = sorted(byFamily.items(), key=lambda kv: -len(kv[1]))
    kept = {
        family: entries
        for family, entries in ordered[: args.families]
        if len(entries) >= max(20, args.per_family // 4)
    }

    total = sum(len(v) for v in kept.values())
    print(f"\nkept {len(kept)} families, {total:,} sequences")
    print(f"  skipped {multiDomainSkipped:,} multi-domain entries (single-label only)")
    print(f"  skipped {lengthSkipped:,} outside {args.min_length} to {args.max_length} residues")

    sizes = Counter({family: len(entries) for family, entries in kept.items()})
    print("  largest families:", sizes.most_common(5))
    print("  smallest kept   :", sizes.most_common()[-3:])

    OUT.mkdir(parents=True, exist_ok=True)
    destination = OUT / "train.json"
    destination.write_text(json.dumps(kept, indent=1) + "\n")
    print(f"\nwrote {destination.relative_to(ROOT)} "
          f"({destination.stat().st_size / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
