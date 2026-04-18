# ADR-001 · Single-surface WYSIWYG

**Status:** accepted · **Date:** 2026-04-17

## Context

Every markdown editor in the market splits the screen: raw source on the
left, rendered HTML on the right. The writer reads one, thinks in the other,
and when they copy text they must choose which half. Warde's *Crystal Goblet*
rejects that split — "printing should be invisible"; the wine (text) should
never compete with the vessel.

Reader is a markdown editor for people whose clipboard-of-record is
markdown (Slack, GitHub, Obsidian vaults, notes apps). Any architecture
that transforms the source into a second representation creates a boundary
the writer has to manage.

## Decision

There is one surface. The markdown source is the displayed text. Styling
is layered on as `NSAttributedString` attributes over the existing
characters; no characters are ever added, removed, or rewritten by the
render path. Syntax markers (`**`, `#`, backtick, brackets) remain visible
at tertiary ink — present but quiet.

Preview mode (⇧⌘P) hides the syntax markers by stripping ranges tagged
`.isMarkdownSyntax` in a scratch `NSAttributedString`, but the underlying
storage retains the verbatim source; returning to edit mode restores it
byte-for-byte.

## Consequences

**Wins.** Copy/paste round-trips losslessly by construction — if the
displayed characters are the source, there is nothing for the clipboard
to translate. There is no "export" step, no stale preview, no mental
overhead choosing which pane to read. Diffing two documents is trivial.

**Costs.** Images can't actually render as bitmaps without replacing
characters; they remain `![alt](url)` syntax in italicised ink. The same
is true of rendered tables — we style the source, we don't draw a grid.
For a reader app that's a feature, not a bug (tables read fine as ASCII);
for an HTML-preview app it'd be a deal-breaker.

**Scope guard.** Any feature request that would require transforming
the source text — auto-numbered headings, table-cell reflow, embedded
diagrams — violates this ADR and should be declined or rethought.
