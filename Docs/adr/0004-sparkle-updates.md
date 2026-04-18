# ADR-004 · Sparkle for auto-update

**Status:** accepted · **Date:** 2026-04-18

## Context

Shipping a downloadable `.app` from GitHub means users install by
dragging-to-Applications. Without auto-update, every bug fix forces the
user to manually re-download, and eventually the installed copy drifts
far enough from current that security fixes don't land.

## Decision

Use [Sparkle](https://sparkle-project.org) (2.x) with an appcast hosted
at `https://raw.githubusercontent.com/thejefflarson/reader/main/appcast.xml`
and release zips hosted on GitHub Releases.

Every release is signed with an **EdDSA (ed25519)** keypair:

- Private key lives in the macOS Keychain under service
  `https://sparkle-project.org`; never checked into the repo.
- Public key is in `Resources/Info.plist` (`SUPublicEDKey`).

Sparkle refuses to install any update whose zip does not validate
against the embedded public key. Losing the private key does not
compromise existing installs — it just means no further updates can
be published until the key is rotated (which requires a new public
key shipped in a fresh install, since Info.plist is embedded).

`scripts/release.sh` builds Release, zips via `ditto`, calls
`tools/sign_update` (Sparkle-supplied binary) for the signature, and
appends an `<item>` to `appcast.xml`. The flow ends with a `gh release
create` uploading the zip — Sparkle picks it up on the user's next
background check.

## Consequences

**Wins.** Users get bug fixes without friction after first install.
The signing chain is independent of Apple Developer ID (which we
don't have), so we can ship updates cryptographically even while
the first install remains Gatekeeper-warned.

**Costs.** The first install is Gatekeeper-warned because we're
ad-hoc-signed (ADR implicit: no Developer ID). Right-click → Open
the first time, after which Sparkle's updater handles subsequent
installs via a helper tool that inherits the existing install's
codesign requirement.

**Secret-handling rules.** The private key must never leave the
release machine's Keychain. If moving to a CI-driven release pipeline,
the signing step has to run locally and the signed zip be uploaded —
or a CI-only signing key has to be issued and the old key revoked.

## Alternatives considered

- **Manual re-install.** Rejected: forces friction on every patch,
  guarantees stale installs.
- **Mac App Store.** Rejected: Apple Developer Program cost, sandbox
  restrictions (file access, default handler registration), review
  delay incompatible with quick iteration.
- **Custom update mechanism.** Rejected: Sparkle's signature + install
  helper solves a security-critical problem correctly; a hand-rolled
  replacement would be a liability.
