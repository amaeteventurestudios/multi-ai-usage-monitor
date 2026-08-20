# AI Usage Monitor

A tiny macOS **menu bar** app that shows your **Claude** and **ChatGPT** usage as
live percentages with reset times — the same numbers `/usage` shows inside Claude
Code and `/status` shows inside Codex — without opening a terminal.

```
C 67% · G 7%
```

It picks up whichever providers are already signed in on your Mac. With only one,
the title keeps its original compact form including the reset countdown:

```
⛏ 67% · 4h12m
```

<p align="center">
  <img src="docs/screenshot.png" alt="AI Usage Monitor menu showing session, weekly, and credits usage" width="300">
</p>

Click the menu bar item for a breakdown, grouped by provider. Each bucket is a
colored gradient bar (green → amber → red as it fills) with its reset time:

- **Claude** — session (5-hour), weekly-all, and per-model weekly. If you have
  pay-as-you-go credits, a **Credits (monthly)** row shows what you've used,
  what's left, and the monthly cap in dollars.
- **ChatGPT** — the primary and secondary rate-limit windows for your plan
  (labelled by length, e.g. *Monthly* or *5-hour*), plus code-review limits and a
  credit balance when your account has them.

It notifies you once per window when any bucket crosses 90%. The two providers are
polled independently: one being signed out, expired, or rate-limited never affects
the other.

> **Unofficial project — not affiliated with Anthropic or OpenAI.** This is an
> independent utility, not affiliated with, endorsed by, or sponsored by either.
> "Claude", "Claude Code", and "Anthropic" are trademarks of Anthropic PBC;
> "ChatGPT", "Codex", and "OpenAI" are trademarks of OpenAI — used here only to
> describe what the software works with. It reads **undocumented** usage endpoints
> and reuses the public Claude Code OAuth client id, so it may break at any time
> and could conflict with either provider's terms of service. Use it **at your own
> risk**. It authenticates only with the logins already on your Mac and sends each
> token only to its own provider — no data goes anywhere else.

## Requirements

- macOS 12 (Monterey) or later.
- At least one of:
  - **Claude Code** installed and signed in (`claude`) — the app reads the login
    credential it stores in your Keychain.
  - **ChatGPT desktop app** or **Codex CLI** signed in — the app reads (never
    writes) the credential at `~/.codex/auth.json`.

  No API key or extra token is needed for either, and you can have both.
- Building from source additionally needs the **Xcode Command Line Tools**
  (`xcode-select --install`).

## Install

### Download a release (recommended)

Pre-built binaries live on the **[Releases page](https://github.com/stavrop/ai-usage-monitor/releases/latest)**
(the "Releases" section of the repo — a separate tab, not a folder in the file
list). Download `ClaudeUsage.zip` from the latest release, unzip it, and drag
`ClaudeUsage.app` to `/Applications`.

Release builds are signed with a Developer ID and notarized by Apple, so they
open normally — no Gatekeeper override needed.

### Homebrew

```sh
brew tap stavrop/tap
brew install --cask ai-usage-monitor
```

### Build from source

```sh
git clone https://github.com/stavrop/ai-usage-monitor.git
cd ai-usage-monitor
./build.sh            # compiles ClaudeUsage.app with the Command Line Tools
open ClaudeUsage.app
```

When iterating with the app installed as a login item, use
`./rebuild-and-restart.sh` — it stops the running instance before rebuilding, so
macOS doesn't kill the new build for a code-signature mismatch, then relaunches it.

> A source build is **unsigned**. macOS runs a locally-built app fine, but if you
> copy it to another Mac, remove the quarantine flag first:
> `xattr -dr com.apple.quarantine ClaudeUsage.app`. For distributable, notarized
> builds see [RELEASE.md](RELEASE.md).

On first launch macOS asks for permission to read the `Claude Code-credentials`
Keychain item — choose **Always Allow** so it can refresh silently.

- **90% alerts** use `osascript`, so the notification is attributed to *Script
  Editor*. If you don't see alerts, allow notifications for *Script Editor* in
  System Settings → Notifications.

## Launch at login

A LaunchAgent template lives in [`launchd/`](launchd/). Point it at the binary you
just built and load it:

```sh
# Fill in the absolute path to the built binary and install the agent:
APP_BIN="$(pwd)/ClaudeUsage.app/Contents/MacOS/ClaudeUsage"
sed "s#__APP_BINARY_PATH__#${APP_BIN}#" launchd/com.local.claudeusage.plist \
    > ~/Library/LaunchAgents/com.local.claudeusage.plist

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.claudeusage.plist
```

```sh
# disable:  launchctl bootout   gui/$(id -u)/com.local.claudeusage
# restart:  launchctl kickstart -k gui/$(id -u)/com.local.claudeusage
```

> The agent stores an absolute path. If you move or rebuild the app elsewhere,
> regenerate the plist and re-bootstrap.

## How it works

The app reads the OAuth credential Claude Code already stored in your login
Keychain (`Claude Code-credentials`), refreshes the access token when it has
expired, and polls the usage endpoint every 10 minutes (the countdown in the
title ticks locally between polls, so no extra network traffic):

```http
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <oauth-access-token>
anthropic-beta: oauth-2025-04-20
```

Relevant fields: `five_hour` (session) and `seven_day` (weekly), each with a
utilization percentage and `resets_at`; a `limits[]` array carrying per-model
scoped weekly buckets; and a `spend` block with the pay-as-you-go credit balance
(`used`/`limit` in minor currency units).

Nothing is stored except what Claude Code already keeps in your Keychain, and the
token is sent only to Anthropic's own hosts.

## Configuration

Defaults live at the top of [`main.swift`](main.swift):

| Constant           | Default | Meaning                                   |
|--------------------|---------|-------------------------------------------|
| `REFRESH_INTERVAL` | `600`   | Seconds between usage polls (10 min).     |
| `ALERT_THRESHOLD`  | `90`    | Percent at which a bucket notifies once.  |

Edit and re-run `./build.sh` to change them.

## The app icon

The icon is original — a usage-gauge mark drawn from scratch with CoreGraphics
(see [`tools/make_icon.swift`](tools/make_icon.swift)). Regenerate with:

```sh
swift tools/make_icon.swift icon_1024.png
```

## Support

This app is free and open-source, built in spare time. If it earns a spot in your
menu bar, two small things help more than you'd think:

- ⭐️ **[Star it on GitHub](https://github.com/stavrop/ai-usage-monitor)** —
  stars are how other people find it, and they genuinely make my day.
- ☕️ **[Buy me a coffee](https://buymeacoffee.com/stavrop)** — a small tip keeps the
  late-night maintenance caffeinated and the updates coming.

No pressure at all — even telling a friend means a lot. Thank you! 🙏

## Privacy, terms & security

This app has no servers and collects nothing — it reads the Claude Code and
ChatGPT/Codex logins already on your Mac and talks only to Anthropic and OpenAI. See [PRIVACY.md](PRIVACY.md),
[TERMS.md](TERMS.md), and [SECURITY.md](SECURITY.md). Contributions welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

[Apache License 2.0](LICENSE) © 2026 Georgios Stavropoulos. See also [NOTICE](NOTICE).
Apache-2.0 is used partly for its explicit trademark clause (§6): the license
grants no rights to the "Claude"/"Anthropic" marks this project refers to.
