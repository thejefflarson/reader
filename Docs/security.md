# Security review

Scope: the Reader code in `Sources/Reader`, its handling of user-controlled
data (markdown source, clipboard, files), and its release + update chain.

## Threat model

Reader is a local desktop app. The user is trusted. Attackers we care about
are authors of **markdown documents** the user opens — a hostile `.md` file
should not be able to exploit the user, steal credentials, or execute code.

We do *not* defend against an attacker who has already compromised the
user's machine (can read the Keychain, replace our binary on disk, etc.);
that's outside Reader's remit.

## Findings

### 1. Unbounded URL schemes in link styling  ·  fixed

Before the fix, the styler's link and autolink rules wrote any URL the
regex matched into the `.link` attribute so long as `URL(string:)`
succeeded and `url.scheme != nil`. `NSTextView` opens clicked `.link`
values via `NSWorkspace.open(_:)`, which honours schemes we don't want
(`file://`, `ftp://`, and custom app schemes like `slack://` or
`spotify://`). A malicious `.md` could ship a plausible-looking
`[click me](file:///etc/passwd)` or `[update](myapp:///delete)` that
fires on click.

**Fix:** allowlist schemes to `http`, `https`, `mailto`. Anything else is
still readable as markdown but no longer carries a clickable `.link`.

### 2. HTML paste used WebKit parsing  ·  mitigated

`NSAttributedString(html:documentAttributes:)` is a WebKit-backed
parser. It can fetch external resources, honour CSS, and has a large
attack surface (see CVE history for WebKit). A hostile clipboard
payload could, in theory, phone home or trigger a parser vulnerability.

**Fix:** dropped the HTML paste path entirely. Reader now only accepts
plain text (the primary path — markdown source) and RTF as a fallback.
RTF is parsed by AppKit's native RTF reader, which has a smaller surface
than WebKit and cannot fetch remote resources.

### 3. Markdown parser regex DoS  ·  audited, no change

Scanned every regex in `MarkdownStyler` for catastrophic-backtracking
patterns (`(a+)+`, nested `*` quantifiers without anchors, ambiguous
alternation). None present. The one multi-line pattern
(`fencedCode`) uses `[\s\S]*?` lazy matching which is O(n). Stress
test `testStylerHandlesRepeatedKeystrokes` runs 200 consecutive identical
characters in under 2s.

### 4. Sparkle update chain  ·  audited, by design

- Feed URL is hard-coded HTTPS:
  `https://raw.githubusercontent.com/thejefflarson/reader/main/appcast.xml`.
- Every release ZIP carries an EdDSA signature; the public key is in
  `Info.plist` (`SUPublicEDKey`). Sparkle rejects any update whose
  signature doesn't validate.
- Private signing key lives only in the macOS Keychain on the release
  machine, never in the repo.

Attack resistance: a DNS or TLS compromise against github.com (or CDN
MITM) cannot substitute a malicious update because the EdDSA signature
fails validation. Losing the private key means no further updates can
ship; it does not compromise existing installs.

Documented in ADR-004.

### 5. Supply chain pinning  ·  fixed

`Package.resolved` was in `.gitignore`, so a fresh checkout could
resolve Sparkle to any 2.x release. Committed `Package.resolved` so
builds reproduce from a pinned revision. Bumping Sparkle is now an
explicit change.

### 6. First-install Gatekeeper warning  ·  accepted, documented

Reader is ad-hoc codesigned (no Apple Developer ID). First launch
shows the standard "can't verify developer" prompt; user right-clicks
→ Open to consent once, then Sparkle updates apply silently. This is
an ADR-004 tradeoff; resolving it requires the $99/year Developer
Program.

### 7. File I/O  ·  audited, safe

All file reads/writes go through `NSOpenPanel` / `NSSavePanel` URLs or
Finder-invoked `application(_:open:)`. No path construction from user
content. `String(contentsOf:encoding:)` and `String.write(to:)` cannot
traverse outside the user-selected URL.

### 8. Recent-documents history  ·  accepted

`NSDocumentController.noteNewRecentDocumentURL` writes to
`NSUserDefaults`. This is file-path leakage of the user's own
documents to other apps that can read the app's prefs. Standard macOS
behaviour; we do not special-case clearing.

## Non-findings (explicitly checked)

- No dynamic code execution anywhere in the source.
- No shell escapes or `Process` invocations that take user content as
  arguments.
- No credentials, API keys, tokens, or secrets hard-coded.
- No network calls other than Sparkle's appcast fetch.
- No extended entitlements beyond hardened runtime.

## Follow-ups (not blocking v1)

- Investigate macOS App Sandbox. Would restrict file system access to
  documents the user explicitly opens via NSOpenPanel. Currently not
  sandboxed; see ADR-004 cost note.
- Consider a content-hash of release ZIPs additional to the EdDSA
  signature, for defence in depth.
- If the app starts making any outbound network calls beyond Sparkle,
  add a Privacy manifest (`PrivacyInfo.xcprivacy`).
