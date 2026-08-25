# Vendored third-party code

## Mol\*

| | |
|---|---|
| Version | **5.11.0** |
| Source | `https://unpkg.com/molstar@5.11.0/build/viewer/molstar.js` and `.css` |
| Upstream | https://github.com/molstar/molstar |
| Licence | **MIT**, verified in the npm metadata and vendored as `molstar-LICENSE.txt` |
| `molstar.js` | 5,027,864 bytes, SHA-256 `7fad5561c74bc900930fb57d6ab028d1aafdda82223a901bf932b1098e84f1f3` |
| `molstar.css` | 72,842 bytes, SHA-256 `5b68ceb6d3642549b4e9b2c071e58e41b98a5350ae269180587b39da86925d55` |
| Fetched | 2026-08-25 |

### Why it is committed rather than downloaded

Hard rule 2: the app must work in aeroplane mode, and a CDN reference is a
network dependency in the core path however fast the CDN is. The UMD build is
loaded from the bundle with `loadFileURL(_:allowingReadAccessTo:)`.

Five megabytes of committed JavaScript is a real cost and it is the smaller one.
The alternative is an app that shows a blank viewer on a plane.

### Updating

Fetch the same two files at the new version, replace them, update the version,
sizes and checksums above, and re-run the viewer tests. Do not edit the vendored
files: anything BOFFIN needs from Mol\* goes through `boffin-bridge.js`, which
is ours.
