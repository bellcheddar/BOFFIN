# Dynamic Type audit

Phase 11, 2026-08-25. Every fixed point size in the app and its UI packages,
classified, and what was done about it.

## The distinction the audit turns on

A protein app has two kinds of text and they want opposite treatment.

**Text laid out as text** (labels, captions, cards, an editor) must scale with
the user's setting. A caption hard-set to 9 points is still 9 points at the
largest accessibility size, which is the setting that exists for people who
cannot read 9 points.

**Text drawn inside a canvas** (a residue label in the ruler, an axis label in
the heat map, a letter in a sequence logo, a residue name in the interaction
diagram) must not. A label has to fit the column it labels. Scaling it to 310%
does not make the chart accessible, it makes it unreadable and the columns stop
lining up with the data they describe. The accessibility answer for a chart is
VoiceOver and Audio Graphs, both of which are built: a shape's question is
"where does it change", and that is answered by hearing it, not by enlarging it
until it no longer fits.

Confusing the two is how an audit makes an app worse.

## Findings

| Where | Was | Now | Why |
|---|---|---|---|
| `FamilyTabView` pocket anchor label | `size: 9, monospaced` | `.caption2` monospaced | UI text |
| `FamilyTabView` measurement caption | `size: 9` | `.caption2` | UI text |
| `StructureTabView` DSSP provenance note | `size: 9` | `.caption2` | UI text, and it is a caveat: shrinking a caveat below legibility is how it stops being one |
| `SceneDeck` representation label | `size: 9, monospaced` | `.caption2` monospaced | UI text |
| `BoundaryTabView` constraint disposition | `size: 9` | `.caption2` | UI text |
| `BoundaryTabView` protease scar | `size: 9, monospaced` | `.caption2` monospaced | UI text |
| `BoundaryTabView` refusal position | `size: 9, monospaced` | `.caption2` monospaced | UI text |
| `BoundaryTabView` construct card | `size: 10, monospaced` | `.sequenceFont(size: 10)` | Monospaced text the user reads, inside a horizontal scroll view that absorbs the extra width. Scaling monospace uniformly preserves the column alignment |
| `SequenceInputView` editor | `Typography.sequence(size: 13)` | `.sequenceFont(size: 13)` | The user types into it |
| `TrackRulerView`, `LLRHeatmapView`, `SequenceLogoView`, `InteractionDiagram` | fixed sizes | **unchanged** | Canvas. See above |

Nine of the ten were slips rather than decisions: several sat directly beside a
correctly-scaled `.caption2` sibling in the same `HStack`.

Note that 9 points was below Apple's own legibility floor of 11 even at the
default text size, so these were not only unscalable, they were too small to
begin with.

## The defect the audit found

`Typography.sequence(size:)` carried this doc comment:

> Sequence text is monospaced **and scales with Dynamic Type**, but never below
> a legibility floor.

The floor was real, implemented and tested. The scaling was never implemented at
all: `Font.system(size:)` is a fixed point size and ignores the user's setting
entirely. The comment described an intention, the test checked only the half
that existed, and the two could not contradict each other because nothing
asserted the missing half.

Both behaviours now exist and are named for what they do:

- `Typography.sequence(size:)` is fixed, for canvases.
- `View.sequenceFont(size:)` scales, for text.

The floor is applied to the **scaled** size rather than the base size, which is
the ordering that matters: applied to the base, a user on the smallest text
setting scales 13 points down past 11 and the floor never fires, which is the
one setting it exists for. `Typography.sequencePointSize(_:)` exists as plain
arithmetic so that ordering can be tested without standing up a view hierarchy,
because a test written against the modifier itself can only check that it
compiles.

## Layout, not just type

Two places break their layout rather than their type at large sizes, and both
now use `ViewThatFits` to fall from a horizontal arrangement to a vertical one:

- `NoSequenceView`'s two example buttons, which clip their own labels side by
  side. A truncated button is a button whose purpose has been deleted.
- `OnboardingView`'s icon-beside-paragraph rows, where `Label`'s own layout
  clips the icon once the text needs the full width.
