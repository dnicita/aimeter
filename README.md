# AIMeter

A macOS menu bar app that tracks your Claude usage at a glance — session (5‑hour),
weekly, and weekly‑Sonnet limits — plus Anthropic service status.

Personal fork of [ClaudeUsageBar](https://github.com/Artzainnn/ClaudeUsageBar) (MIT),
rebranded **AIMeter** with a reworked icon, dynamic colors, and several fixes/features.

> ⚠️ Not affiliated with or endorsed by Anthropic. "Claude" is a trademark of
> Anthropic. AIMeter reads usage via claude.ai's internal API using your own
> session cookie, stored locally in the macOS Keychain. Use at your own risk.

## Features
- **Segmented progress ring** in the menu bar (session %): green→red gradient,
  fills with usage, blinks (accelerating) past 75%, red at the limit.
- **Center status dot** that blinks on Anthropic service disruptions
  (🟡 minor / 🔴 major), at a distinct rhythm.
- **Per‑window colors** (Session = green, Weekly = sky‑blue, Sonnet = orange) in
  the bar and the popover.
- **Reset countdowns** ("resets in 1h59m / 2d17h").
- Optional extra values in the bar (weekly %, timers…) via Settings toggles.
- **Real launch‑at‑login** (LaunchAgent), session cookie in the **Keychain**,
  **cookie‑expiry detection** (401/403), configurable refresh, stale‑data warning.

## Build (personal, local)
Requires macOS + the Swift toolchain (Xcode or Command Line Tools).

```sh
cd app
./create_signing_cert.sh   # once: stable self-signed identity (no repeated prompts)
./build-local.sh --install # build universal .app, sign, install to /Applications
```

The app is a single Swift file (`app/ClaudeUsageBar.swift`) compiled with `swiftc`.
Ad‑hoc / self‑signed only — **not** notarized for distribution.

## Setup
Launch AIMeter, open the popover → **Set Session Cookie**, and paste your
claude.ai cookie (from your browser's DevTools). It's stored in the Keychain and
auto‑refreshes; you're notified if it expires.

## License
MIT — see [LICENSE](LICENSE). Retains the original ClaudeUsageBar copyright.
