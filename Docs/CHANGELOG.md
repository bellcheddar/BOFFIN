# Changelog

One short entry per phase, per the build plan's delivery gate.

## Phase 0: Foundations (2026-08-24)

Repository initialised and scaffolded.

- Git repository created on `main`.
- Seven local SPM packages under `Packages/`, one per module, each
  independently buildable and testable.
- Module dependency rule encoded in the package manifests and enforced by
  `Tools/check-module-graph.sh`, which is canary-tested against both an illegal
  source import and an illegal manifest dependency.
- Tuist manifest (`Project.swift`, `Tuist.swift`) as the single source of
  project configuration. The generated `.xcodeproj` is gitignored, and CI fails
  if one is ever committed.
- App shell with a placeholder root view, unit test target and a launch UI test.
- `BoffinCore`: the residue and sequence domain types, and the `ResidueTrack`
  abstraction with alignment validation. Non-canonical residues are preserved
  rather than coerced, and author numbering is kept structurally separate from
  array index.
- `BoffinUI`: brand and scientific palette tokens, typography with a legibility
  floor, spacing scale.
- `BoffinCharts`: sequence logo information-content mathematics, tested against
  hand-computed values.
- `BoffinML`: shape bucket definitions for the Neural Engine.
- CI: module graph check, formatting lint, no-committed-project check, no-CDN
  check, per-package tests, and a simulator build and test matrix across iPhone
  and iPad.
- `swift-format` configuration, whole tree formatted and lint-clean.
- Golden fixture set committed with provenance, checksums and stated caveats.
- Licence audit begun: PLIP (GPL v2), Mol* (MIT) and ESM-2 (MIT) verified at
  source.

**Phase 0 acceptance met on 2026-08-24.** The app builds and runs on both the
iPhone 17 Pro and iPad Pro 13-inch (M5) simulators (TEST SUCCEEDED), 27 package
tests pass, the project opens from a clean checkout with no generation step, and
CI's structural gates and package tests are green.

Two changes to the plan landed during the phase:

- **Tuist was dropped** in favour of a native, committed `BOFFIN.xcodeproj`. The
  seven local SPM packages were kept, so the module dependency rule stays
  mechanically enforceable.
- **The packages' macOS platform is 14, not 26.** It exists only for host-side
  testing and pinning it high made the binaries unloadable on CI.

Known gaps carried into Phase 1 are listed in `CLAUDE.md`.
