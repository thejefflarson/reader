<div align="center">
<img src="Docs/icon.png" width="256" alt="Reader icon" />

# Reader

</div>

A macOS markdown reader and WYSIWYG editor. One surface: the markdown source *is* the rendered view — syntax marks stay visible as quiet tertiary-ink, so copy and paste round-trip losslessly as markdown. No preview pane, no export step.

**[Download the latest release](https://github.com/thejefflarson/reader/releases/latest)**

## What it does

- **Single-surface editing** — markdown is rendered in place; `**bold**`, `# headings`, `` `code` ``, links, lists, quotes, rules, strikethrough all style as you type
- **Markdown-fidelity clipboard** — copy writes markdown; paste accepts markdown, HTML, or RTF and converts back to markdown
- **Preview mode** — ⌘⇧P hides the syntax marks for a clean read; source is preserved on return
- **Classical typography** — New York serif, 66-character measure, 1.4× leading, warm off-white page; grounded in Bringhurst, Butterick, Hochuli, Tufte, Warde
- **Silent micro-typography** — straight quotes become curly, `--` becomes en-dash, `---` becomes em-dash, `...` becomes ellipsis; suppressed inside code spans
- **Active format indicator** — bold/italic/code/heading/list/quote buttons burn scarlet when the caret is inside that markup
- **Dark mode** — follows System Settings automatically via semantic colors
- **Auto-update** — Sparkle-powered, EdDSA-signed updates from GitHub Releases
- **`.md` handler** — registers for `.md`, `.markdown`, `.mdown`, `.mkd`, `.mkdn` via `CFBundleDocumentTypes`

## Requirements

- macOS 13 (Ventura) or later
- Xcode 15 or later
- [xcodegen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Building

```bash
./scripts/build-app.sh --debug
open build/Debug/Reader.app
```

Or open in Xcode:

```bash
xcodegen generate
open Reader.xcodeproj
```

## Installing

First launch: right-click → Open → Open (Gatekeeper warns on ad-hoc signed apps; subsequent updates install silently via Sparkle).

To make Reader the default markdown handler: `./scripts/build-app.sh --install`, then Finder → Get Info on any `.md` file → Open With → Reader → Change All….

## Releasing

```bash
./scripts/release.sh <version> "release notes"
git add appcast.xml && git commit -m "release <version>"
git tag v<version> && git push --tags
gh release create v<version> build/Reader-<version>.zip \
    --title "Reader <version>" --notes "…"
```

The EdDSA signing key lives in the macOS Keychain; the public half is in `Resources/Info.plist` (`SUPublicEDKey`). Sparkle will refuse any update that isn't signed by the matching private key.

## Design docs

- [Architecture Decision Records](Docs/adr/) — load-bearing decisions: single-surface WYSIWYG, regex styler vs AST, AppKit over SwiftUI, Sparkle for updates
- [Security review](Docs/security.md) — threat model, findings, mitigations
