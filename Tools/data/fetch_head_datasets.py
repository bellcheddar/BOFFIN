#!/usr/bin/env python3
"""Fetch the training data for the Phase 3 analysis heads.

    Tools/coreml/.venv/bin/python Tools/data/fetch_head_datasets.py

Downloads into `Datasets/` (gitignored: these are hundreds of megabytes) and
writes `Datasets/MANIFEST.md` recording every source URL, download date, byte
count and SHA-256.

Why heads are trained rather than adapted
-----------------------------------------
The obvious route is to fine-tune a published head. It does not work here, for
three independent reasons, each fatal on its own:

1. **Dimension.** DeepTMHMM and NetSurfP-3.0 are both built on ESM-1b, whose
   embeddings are 1280-wide. BOFFIN's backbone is ESM-2 t12 35M at 480. Their
   weights cannot be loaded at all.
2. **Architecture.** They are biLSTM+CRF and ResNet+biLSTM respectively.
   Recurrent layers and CRF decoding do not achieve Neural Engine residency, so
   adopting them would forfeit the 98.8% established in Phase 2, which is the
   thing the whole app is premised on.
3. **Licence.** DeepTMHMM requires a paid commercial licence for use outside
   academia. NetSurfP-3.0 declares no licence at all, which under copyright
   default means all rights reserved. Neither can ship inside BOFFIN.

So BOFFIN trains its own small, ANE-friendly heads on the published *datasets*,
which is what the build plan specified in the first place. Datasets and model
weights are licensed separately, and the datasets are the more permissive half.

LICENCE STATUS: see Docs/ATTRIBUTIONS.md. Several of these are **unverified**
and that is recorded rather than assumed. Unverified is fine for development and
is a blocker for release.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATASETS = ROOT / "Datasets"

USER_AGENT = "boffin-dataset-fetcher (research use; marc@marcdeller.com)"

# NetSurfP-3.0's published train/test split. Carries Q8 and Q3 secondary
# structure, disorder and solvent accessibility per residue, so one download
# supplies two of the three heads.
#
# MMseqs rather than HHblits variants: BOFFIN uses neither profile (the whole
# point is that the language model replaces them), so the smaller file is taken
# and only the sequences and labels are read from it.
NETSURFP = "https://services.healthtech.dtu.dk/services/NetSurfP-3.0/training_data"

SOURCES: dict[str, dict] = {
    "netsurfp_train.npz": {
        "url": f"{NETSURFP}/Train_MMseqs.npz",
        "provides": "secondary structure (Q3/Q8), disorder, RSA: training split",
        "licence": "UNVERIFIED: no terms stated on the DTU download page",
    },
    "netsurfp_cb513.npz": {
        "url": f"{NETSURFP}/CB513_MMseqs.npz",
        "provides": "CB513 benchmark: the standard SS test set",
        "licence": "UNVERIFIED: no terms stated on the DTU download page",
    },
    "netsurfp_ts115.npz": {
        "url": f"{NETSURFP}/TS115_MMseqs.npz",
        "provides": "TS115 benchmark",
        "licence": "UNVERIFIED: no terms stated on the DTU download page",
    },
    "netsurfp_casp12.npz": {
        "url": f"{NETSURFP}/CASP12_MMseqs.npz",
        "provides": "CASP12 free-modelling benchmark",
        "licence": "UNVERIFIED: no terms stated on the DTU download page",
    },
}


def download(url: str, destination: Path, chunk: int = 1 << 20) -> tuple[int, str]:
    """Stream to disk, returning byte count and SHA-256."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    digest = hashlib.sha256()
    total = 0
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".part")

    with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as out:
        declared = response.headers.get("Content-Length")
        declared = int(declared) if declared else None
        while True:
            block = response.read(chunk)
            if not block:
                break
            out.write(block)
            digest.update(block)
            total += len(block)
            if declared:
                print(f"\r    {total / 1e6:8.1f} / {declared / 1e6:.1f} MB", end="", flush=True)
            else:
                print(f"\r    {total / 1e6:8.1f} MB", end="", flush=True)
    print()

    # A truncated download is the failure that matters: it leaves a file that
    # loads, is shorter than it should be, and trains a head on a subset nobody
    # knows is a subset. Only rename once the byte count agrees.
    if declared is not None and total != declared:
        temporary.unlink(missing_ok=True)
        raise OSError(f"truncated: got {total} bytes, expected {declared}")

    temporary.replace(destination)
    return total, digest.hexdigest()


def fetch_disprot(destination: Path) -> tuple[int, str]:
    """Fetch the whole of DisProt in one request.

    Two traps here, both of which produced silently wrong results first time:

    * The API's `size` field in the RESPONSE is the **total number of entries**
      (3,337), not a page size. Reading it as a page size invites paging that
      does not exist.
    * The API **ignores** a `page` parameter: `page=1` and `page=2` both return
      the same first accession. A paging loop that stops when a short batch
      arrives therefore never stops, and simply accumulates the same 200 entries
      over and over. The first attempt reached 93,436 "entries" that way, which
      is 28 times the real database, and nothing errored.

    The whole set is 27 MB and downloads in about 20 seconds, so it is fetched
    in one request and the entry count is checked against the total the API
    reports.
    """
    url = (
        "https://disprot.org/api/search?release=current"
        "&show_ambiguous=false&show_obsolete=false&size=100000"
    )
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=600) as response:
        payload = json.loads(response.read().decode("utf-8"))

    entries = payload.get("data", [])
    reported = payload.get("size")
    accessions = {entry.get("acc") for entry in entries}

    if reported is not None and len(entries) != reported:
        raise OSError(
            f"got {len(entries)} entries but the API reports {reported} in total")
    if len(accessions) != len(entries):
        raise OSError(
            f"{len(entries)} entries but only {len(accessions)} unique accessions: "
            "the fetch is duplicating records")

    print(f"    {len(entries)} entries, all unique")
    destination.parent.mkdir(parents=True, exist_ok=True)
    body = json.dumps({"entries": entries}, indent=1).encode("utf-8")
    destination.write_bytes(body)
    return len(body), hashlib.sha256(body).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", help="fetch a single named source")
    parser.add_argument(
        "--skip-existing", action="store_true", default=True,
        help="do not re-download files that are already present")
    args = parser.parse_args()

    DATASETS.mkdir(parents=True, exist_ok=True)
    records: list[dict] = []

    for name, source in SOURCES.items():
        if args.only and args.only != name:
            continue
        destination = DATASETS / name
        if args.skip_existing and destination.exists():
            body = destination.read_bytes()
            print(f"{name}: already present ({len(body) / 1e6:.1f} MB)")
            records.append(
                {**source, "name": name, "bytes": len(body),
                 "sha256": hashlib.sha256(body).hexdigest()})
            continue

        print(f"{name}: {source['url']}")
        try:
            size, digest = download(source["url"], destination)
        except (urllib.error.URLError, OSError) as error:
            print(f"    FAILED: {error}", file=sys.stderr)
            records.append({**source, "name": name, "error": str(error)})
            continue
        records.append({**source, "name": name, "bytes": size, "sha256": digest})

    # DisProt last: it is the slowest and least likely to be needed first, since
    # NetSurfP already carries disorder labels.
    if not args.only or args.only == "disprot.json":
        destination = DATASETS / "disprot.json"
        if args.skip_existing and destination.exists():
            body = destination.read_bytes()
            print(f"disprot.json: already present ({len(body) / 1e6:.1f} MB)")
            size, digest = len(body), hashlib.sha256(body).hexdigest()
        else:
            print("disprot.json: https://disprot.org/api/search (paged)")
            try:
                size, digest = fetch_disprot(destination)
            except Exception as error:  # noqa: BLE001
                print(f"    FAILED: {error}", file=sys.stderr)
                size, digest = 0, ""
        records.append({
            "name": "disprot.json",
            "url": "https://disprot.org/api/search",
            "provides": "curated intrinsic disorder regions (independent disorder benchmark)",
            "licence": "UNVERIFIED: DisProt papers are CC BY; database terms not confirmed at source",
            "bytes": size,
            "sha256": digest,
        })

    today = datetime.date.today().isoformat()
    lines = [
        "# Head training datasets",
        "",
        "Downloaded by `Tools/data/fetch_head_datasets.py`. These files are **not**",
        "committed: they are hundreds of megabytes and are reproducible from the",
        "URLs below.",
        "",
        f"Last fetched: **{today}**",
        "",
        "| File | Bytes | Provides | SHA-256 |",
        "|---|---|---|---|",
    ]
    for record in records:
        if "error" in record:
            lines.append(
                f"| `{record['name']}` | FAILED | {record['provides']} | {record['error']} |")
            continue
        lines.append(
            f"| `{record['name']}` | {record['bytes']:,} | {record['provides']} | "
            f"`{record.get('sha256', '')[:16]}...` |")

    lines += ["", "## Sources and licence status", "", "| File | URL | Licence |", "|---|---|---|"]
    for record in records:
        lines.append(f"| `{record['name']}` | <{record['url']}> | {record['licence']} |")

    lines += [
        "",
        "**Every licence above is UNVERIFIED.** That is recorded rather than assumed,",
        "and it is a blocker for release, not for development. Before BOFFIN ships a",
        "head trained on any of these, the terms must be confirmed at source and",
        "written into `Docs/ATTRIBUTIONS.md`. The same discipline that keeps PLIP out",
        "of the interaction profiler applies here.",
        "",
    ]
    (DATASETS / "MANIFEST.md").write_text("\n".join(lines) + "\n")
    print(f"\nwrote {(DATASETS / 'MANIFEST.md').relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
