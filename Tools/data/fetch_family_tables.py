#!/usr/bin/env python3
"""Fetch the family numbering tables BOFFIN bundles.

    Tools/coreml/.venv/bin/python Tools/data/fetch_family_tables.py

Writes into `Datasets/family/` and records provenance in its MANIFEST.

Why tables rather than an algorithm
-----------------------------------
Both KLIFS and GPCRdb assign their numbers by structure-based alignment against
curated references. Reimplementing that from the papers would be exactly the
"plausible-looking but silently wrong" failure hard rule 6 exists to prevent: a
GPCRdb number that is off by one through a helix bulge is not obviously wrong,
and it would be believed. So the published assignments are bundled and BOFFIN
maps a user's sequence onto them, rather than deriving them.

Licences, checked at source on 2026-08-25
------------------------------------------
* **GPCRdb: CC BY 4.0** for data (Apache 2.0 for their code). Commercial use is
  permitted with attribution, which `Docs/ATTRIBUTIONS.md` carries.
* **KLIFS: stated open.** Their FAQ says "both for academia and industry all
  data in KLIFS is freely available/open". That is a clear permission but not a
  named licence, so it is recorded as stated-open rather than as CC-anything,
  and the distinction is kept rather than rounded up.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Datasets/family"

USER_AGENT = "boffin-family-fetcher (research use; marc@marcdeller.com)"

# Receptors to bundle GPCRdb numbering for. Class A first, per the build plan,
# and beta-2 adrenergic specifically because it is the Phase 0 fixture.
GPCRDB_RECEPTORS = [
    "adrb2_human", "adrb1_human", "drd2_human", "oprm_human",
    "acm1_human", "agtr1_human", "ccr5_human", "cxcr4_human",
    "hrh1_human", "5ht2a_human", "aa2ar_human", "opsd_human",
]


def get(url: str) -> object:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=90) as response:
        return json.loads(response.read().decode("utf-8"))


def fetch_gpcrdb() -> dict:
    """Per-residue generic numbers and segments for each bundled receptor.

    `display_generic_number` carries BOTH schemes, as `1.25x25`: the part before
    the `x` is Ballesteros-Weinstein and the part after is GPCRdb. They differ
    wherever a helix has a bulge or constriction, which is the entire reason
    GPCRdb exists, so both are kept and labelled rather than one being picked.
    """
    receptors = {}
    for name in GPCRDB_RECEPTORS:
        try:
            residues = get(f"https://gpcrdb.org/services/residues/extended/{name}/")
        except (urllib.error.URLError, OSError) as error:
            print(f"  {name}: FAILED {error}", file=sys.stderr)
            continue

        entries = []
        for residue in residues:
            display = residue.get("display_generic_number")
            if not display:
                continue
            ballesteros, _, gpcrdb = display.partition("x")
            entries.append({
                "position": residue["sequence_number"],
                "residue": residue["amino_acid"],
                "segment": residue.get("protein_segment"),
                "ballesteros_weinstein": ballesteros,
                "gpcrdb": gpcrdb,
            })
        receptors[name] = entries
        print(f"  {name}: {len(entries)} numbered residues")
    return receptors


def fetch_klifs() -> dict:
    """The 85-residue KLIFS pocket for every human kinase.

    The pocket is a FIXED 85 positions by construction, with gaps written as
    `-`. Anything else means the API changed shape and the numbering can no
    longer be trusted, so the length is asserted rather than assumed.
    """
    kinases = get("https://klifs.net/api/kinase_information?species=Human")
    entries = {}
    wrong_length = 0
    for kinase in kinases:
        pocket = kinase.get("pocket") or ""
        if len(pocket) != 85:
            wrong_length += 1
            continue
        entries[kinase["name"]] = {
            "uniprot": kinase.get("uniprot"),
            "family": kinase.get("family"),
            "group": kinase.get("group"),
            "full_name": kinase.get("full_name"),
            "pocket": pocket,
        }
    print(f"  {len(entries)} human kinases with an 85-residue pocket "
          f"({wrong_length} skipped for wrong length)")
    return entries


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    today = datetime.date.today().isoformat()

    print("GPCRdb ...")
    gpcrdb = fetch_gpcrdb()
    print("KLIFS ...")
    klifs = fetch_klifs()

    written = []
    for name, payload, description in (
        ("gpcrdb_numbering.json", gpcrdb, "Per-residue GPCRdb and Ballesteros-Weinstein numbers"),
        ("klifs_pockets.json", klifs, "85-residue KLIFS pocket per human kinase"),
    ):
        body = json.dumps(payload, indent=1).encode("utf-8")
        (OUT / name).write_bytes(body)
        written.append((name, len(body), hashlib.sha256(body).hexdigest(), description))
        print(f"wrote {name} ({len(body) / 1e6:.2f} MB)")

    lines = [
        "# Family numbering tables",
        "",
        "Fetched by `Tools/data/fetch_family_tables.py`. Bundled rather than derived:",
        "both schemes assign numbers by structure-based alignment against curated",
        "references, and reimplementing that would produce numbers that are wrong in",
        "ways nobody can see.",
        "",
        f"Last fetched: **{today}**",
        "",
        "| File | Bytes | Contents | SHA-256 |",
        "|---|---|---|---|",
    ]
    for name, size, digest, description in written:
        lines.append(f"| `{name}` | {size:,} | {description} | `{digest[:16]}...` |")
    lines += [
        "",
        "## Licences, checked at source 2026-08-25",
        "",
        "| Source | Terms | Status |",
        "|---|---|---|",
        "| GPCRdb | **CC BY 4.0** (data), Apache 2.0 (code) | Verified. Commercial use permitted with attribution |",
        "| KLIFS | \"both for academia and industry all data in KLIFS is freely available/open\" (FAQ) | Clear permission, but **no named licence**. Recorded as stated-open rather than rounded up to a CC licence |",
        "",
        "Attribution for both is carried in `Docs/ATTRIBUTIONS.md` and surfaced in the",
        "in-app Acknowledgements screen.",
        "",
    ]
    (OUT / "MANIFEST.md").write_text("\n".join(lines) + "\n")
    print(f"wrote {(OUT / 'MANIFEST.md').relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
