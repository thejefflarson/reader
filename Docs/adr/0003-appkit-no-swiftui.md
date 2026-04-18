# ADR-003 · AppKit, not SwiftUI

**Status:** accepted · **Date:** 2026-04-18

## Context

SwiftUI is the default "new app" framework on macOS. It's terse, declarative,
ships with the OS, and has a decent text view primitive in `TextEditor`.

Reader's core is an `NSTextView` subclass with overrides of `insertText`,
`keyDown`, `writeSelection`, `drawInsertionPoint`, plus an
`NSTextStorageDelegate` that runs the styler on every edit. These are
AppKit-native concerns. `TextEditor` in SwiftUI wraps `NSTextView` but
does not expose the overrides we need.

## Decision

Reader is an AppKit app. `main.swift` bootstraps `NSApplication.shared.run()`.
Windows, menus, toolbar, text view, bottom dock are all AppKit types.
There is one embedded `NSVisualEffectView` (retired in a later cleanup)
and no `NSHostingView`.

## Consequences

**Wins.** Direct access to every `NSTextView` / `NSLayoutManager` /
`NSTextContainer` knob. The editor is a 250-line `NSTextView` subclass,
not a SwiftUI bindings dance around an `NSViewRepresentable`. Behaviour
is predictable under stress (rapid typing, large pastes, IME
composition).

**Costs.** More verbose view setup (`NSLayoutConstraint.activate([...])`
vs. `VStack`). No ecosystem of SwiftUI-only libraries. Cannot target
iOS/iPadOS without substantial rework — but per ADR-001 this is a
macOS app and that's by design.

## Alternatives considered

- **SwiftUI + `TextEditor`.** Rejected: the override surface we need
  (caret geometry, pasteboard types, storage delegate, draw cycle)
  isn't exposed. We would end up with `NSViewRepresentable` wrapping
  `NSTextView`, reintroducing AppKit under a SwiftUI coat.
- **Mac Catalyst.** Rejected: UIKit's text stack is its own dialect
  and the resulting app doesn't feel native on macOS.
