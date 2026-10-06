# Security

Aki runs on your Mac with Screen Recording and Accessibility permissions, so we take security reports seriously.

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately through GitHub: **Security → Report a vulnerability** on this repository ([private advisory](../../security/advisories/new)). Include what you found, how to reproduce it, and the Aki version (Settings → General).

You'll get a reply within a few days. We fix confirmed issues first, ship the fix through the signed update channel, and credit you in the release notes if you want.

## Supported versions

Only the latest release gets security fixes — Aki updates itself, so most people are always on it.

## What Aki does to keep you safe

- **Nothing leaves your Mac** except the daily update check and one optional, anonymous install notice on first launch (Aki's version, macOS version and language; turn it off in Get started or Settings → General → Privacy). Marks, crops and settings live in `~/.aki`, readable by your user only (folder `0700`, files `0600`).
- **Local server** on `127.0.0.1` only: every request needs a random token, the `Host` header must be local (DNS rebinding is refused), and only allowed extension origins get CORS. Request bodies are size-limited.
- **Never reads secrets on screen**: password, card and one-time-code fields are never read — neither on web pages nor in other apps — and field values are stripped from captured HTML.
- **Signed updates** (Sparkle, EdDSA) over HTTPS; an update without Aki's signature is refused. The app itself is always signed with the same "Aki Dev" certificate.
- **One-line installer** checks the downloaded app's signature *and* the fingerprint of Aki's certificate before installing anything.
- **Talking to the browser**: Aki asks Chrome for the element under the pointer with a fixed script; text from pages is escaped and never executed.
