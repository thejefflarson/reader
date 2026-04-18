# ADR-002 · Regex-based styler, not a CommonMark AST

**Status:** accepted · **Date:** 2026-04-18

## Context

Every keystroke re-runs the styler across the full document. We need the
styling pipeline to be fast (<16 ms per keystroke), dependency-light, and
easy to extend as markdown features accrete.

The two viable architectures are:

1. **AST parser** — plug in `swift-cmark` or Apple's `swift-markdown`,
   parse on every keystroke, walk the AST, stamp attributes.
2. **Regex tape** — a list of `NSRegularExpression` rules applied in
   order, each stamping attributes on its matches. The document's
   character content is never transformed; only attributes change.

## Decision

Regex tape. Each construct is a `Rule` in `MarkdownStyler.swift`:

```swift
struct Rule {
    let pattern: NSRegularExpression
    let occupies: Bool
    let stamp: (NSTextCheckingResult, Context) -> Void
}
```

Rules run in order. A rule marked `occupies = true` forbids later rules
from firing inside its match range, so code spans and fenced blocks are
never re-interpreted as bold or headings.

## Consequences

**Wins.** Zero runtime dependencies — `Foundation.NSRegularExpression`
only. Adding a new construct (task lists, tables, footnotes) is a ~10-line
closure. The styler is stateless between keystrokes; we can invalidate and
re-run freely. Easy to test — hand the styler an `NSTextStorage`, assert
attributes on specific ranges.

**Costs.** Some constructs are genuinely hostile to regex: nested
emphasis (`**_bold italic_**`), reference links that need a
whole-document scan to resolve, HTML, tables with merged cells. We
handle the common cases and accept imperfect styling on pathological
input — the *source* still renders as plain text, which is the safest
failure mode given ADR-001.

**Scope guard.** If a future feature requires true nested parsing (e.g.,
lists inside block-quotes inside tables), we revisit this ADR rather
than pile lookarounds into the regex pile.

## Alternatives considered

- **Apple's `swift-markdown`.** Produces a clean AST, handles every
  CommonMark edge case. Rejected: adds a meaningful SPM dependency,
  the AST-to-attributes walk is harder to reason about than a regex
  tape, and any bug in the parser blocks text rendering — whereas a
  bug in one regex rule just means one construct is unstyled.
- **TextKit 2 block-based layout.** Richer rendering primitives
  (block-level callouts for tables, inline attachments for images).
  Rejected for v1: we don't want non-text glyphs in the storage per
  ADR-001. Worth revisiting if we ever render code blocks as
  first-class gutter-numbered elements.
