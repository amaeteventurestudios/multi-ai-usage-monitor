# Multi AI Usage Monitor

**One menu bar dashboard for monitoring usage across multiple Claude and OpenAI accounts.**

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![macOS 12+](https://img.shields.io/badge/macOS-12%2B-lightgrey.svg)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.7-orange.svg)](#build-from-source)
[![Open Source](https://img.shields.io/badge/Open%20Source-yes-brightgreen.svg)](#contributing)

---

## Overview

Multi AI Usage Monitor is a native macOS menu bar app that shows how much of each
AI subscription allowance you have used, for **every account you have**, in one
place. Click the menu bar item and you can immediately answer:

- Which account is this?
- Which provider is it?
- Which allowance is this — a rolling session window, a weekly one, Codex or ChatGPT?
- How much have I used, and how much is left?
- When does it reset, and is that the provider's own reset time or my local schedule?
- Is this number current, or stale?
- Did one of my accounts stop authenticating?

It is local-first, has no backend of its own, and collects nothing.

## Why this exists

AI subscription limits are confusing, and they get more confusing the more
accounts you have. Two Claude accounts reset at different times. An OpenAI
Business workspace and a personal Plus account are separate allowances entirely.
The Codex weekly window is not the same thing as your ChatGPT message allowance.

Most usage monitors assume one account per provider. This one does not: an
**account** is the unit the app stores credentials for, refreshes, renders,
warns about and errors on — so two Claude accounts are genuinely independent, and
adding a third is a settings change rather than a rewrite.

## Screenshots

Screenshots are not included in this release. Every screenshot of a working
install contains a real e-mail address, plan identifier, credential path and
usage figures, and sanitising one properly takes more care than shipping it
quickly deserves. The dropdown layout is described in
[docs/QA.md](docs/QA.md), and sanitised screenshots will land in
`docs/images/` in a future release.

Conceptually, the dropdown looks like this:

```
AI USAGE

CLAUDE
 Personal Claude
 C1 · Keychain · Claude Code · Connected
   Session                                 21% used
   ▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░
   Resets 4:20 PM · 4h 30m remaining

   Weekly (all)                            15% used
   ▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
   Resets Monday 7:00 AM · 3d 19h remaining

 Work Claude
 C2 · Keychain · this app · Connected
   ...
   Resets Monday 2:00 AM · 3d 14h remaining

OPENAI
 Business Premium
 G1 · File · Codex default · Connected
   Codex Weekly                            89% used
   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░
   Resets Sunday 5:39 PM · 3d 5h remaining

   ChatGPT messages                     Unavailable
   Not detectable yet — this credential only exposes Codex usage.

Updated 11:04:22 AM
Refresh Now                                       ⌘R
Settings…                                         ⌘,
Quit                                              ⌘Q
```

## Features

- **Multiple accounts per provider** — two Claude accounts and two OpenAI
  accounts side by side, each with its own credential, reset schedule, warning
  threshold and error state.
- **Honest numbers.** Every percentage is *used*, and the word "used" is printed
  next to it. Nothing is estimated, extrapolated or counted locally and passed
  off as authoritative. An allowance the app cannot read says `Unavailable` and
  explains why.
- **Per-account reset schedules**, with the provider's own reset time preferred
  and a local weekly rule as a clearly-labelled fallback. Daylight saving is
  handled by the calendar, not by adding 604800 seconds.
- **Error isolation.** One account failing never blanks another, and never turns
  the menu bar title into a single word "Error".
- **Stale data is kept, not discarded.** A failed refresh costs you the freshness
  of a number, never the number.
- **Local notifications** at a configurable threshold, deduplicated per account,
  per metric and per usage window, re-arming automatically after each reset.
- **Three menu bar summary modes** — compact (`C1 12% · C2 43% · G 88%`),
  per provider (`Claude 43% · OpenAI 88%`), or minimal (`AI`).
- **Background opacity control** — a slider from 60% to 100% for how solid the
  app's windows are drawn, applied immediately and remembered between launches.
- **No telemetry, no analytics, no backend, no account.**

## Supported providers

| Provider | Metrics | Source |
|---|---|---|
| Claude (Anthropic) | Session (5-hour), Weekly (all), Weekly (model-scoped), extra-usage credits | Claude Code's OAuth credential, plus the Anthropic OAuth usage endpoint |
| OpenAI | Codex rolling window, Codex weekly window, Codex code review, any additional window the API reports | The Codex/ChatGPT credential at `~/.codex/auth.json`, plus the Codex usage endpoint |

ChatGPT's own message allowance is **not** currently readable — see
[Known limitations](docs/KNOWN_LIMITATIONS.md).

## Multi-account support

Each account is an independent object with its own:

- display name (rename it to whatever makes sense to you)
- enabled/disabled state and position in the list
- credential source
- reset behaviour
- notification threshold

**Claude** accounts can read from:

1. **Claude Code's Keychain item** — the credential Claude Code already manages.
2. **This app's own Keychain entry** — a credential you explicitly imported.
   This is how a second Claude account coexists with the first: Claude Code
   stores exactly one credential, so a second account needs its own home.
   Removing the account deletes only this copy.
3. **A JSON credential file** at a path you choose. Read-only, never written.

**OpenAI** accounts can read from:

1. **`~/.codex/auth.json`** — the default the Codex CLI and ChatGPT app share.
2. **Any other `auth.json` path**, so a second workspace's credential can live
   somewhere else (for example `~/.codex-personal/auth.json`).

Choosing a source for one account never changes another account's source.

## Requirements

- macOS 12 Monterey or later
- Intel (x86_64) or Apple Silicon (arm64)
- Xcode Command Line Tools (`xcode-select --install`) — a full Xcode install is
  not required
- Claude Code and/or the ChatGPT desktop app / Codex CLI, signed in

## Installation

There is no signed release yet. Build from source:

```sh
git clone https://github.com/amaeteventurestudios/multi-ai-usage-monitor.git
cd multi-ai-usage-monitor
./build.sh
open "Multi AI Usage Monitor.app"
```

The app appears in the menu bar. It has no Dock icon and no main window.

### Launch at login

Copy `launchd/com.amaeteventurestudios.multi-ai-usage-monitor.plist` to
`~/Library/LaunchAgents/`, replace `__APP_BINARY_PATH__` with the absolute path
to the built binary, and load it:

```sh
launchctl bootstrap "gui/$(id -u)" \
  ~/Library/LaunchAgents/com.amaeteventurestudios.multi-ai-usage-monitor.plist
```

`./rebuild-and-restart.sh` stops a running instance, rebuilds and restarts it —
useful while developing, and necessary because overwriting a running binary
invalidates its ad-hoc signature.

## Build from source

```sh
./build.sh     # builds "Multi AI Usage Monitor.app" (universal where possible)
./test.sh      # runs the test suite
```

`build.sh` uses `swiftc` and a hand-written `Info.plist` — no Xcode project, no
GUI step. The deployment target is pinned to macOS 12.0.

## Configuration

Open **Settings…** from the menu (⌘,). On first launch the app looks for
credentials already on this Mac and creates an account for each one it finds,
carrying across any settings from a previous installation.

### Claude accounts

**First account** — usually detected automatically from Claude Code's Keychain
item. If not: *Accounts → + Add Claude Account*, choose
*Claude Code credential (macOS Keychain)*, name it, save.

**Second account** — Claude Code keeps only one credential at a time, so the
second account needs its own copy:

1. Sign in to the second Claude account with Claude Code.
2. Copy that account's credential JSON (the object containing `claudeAiOauth`)
   out of the login Keychain.
3. In *Settings → Accounts → + Add Claude Account*, choose
   *Imported credential (this app's Keychain entry)* and use
   **Import Credential…**. The value is typed into a secure field and written
   straight to the Keychain.
4. Sign Claude Code back in to whichever account you use day to day.

From then on the two accounts read from different places and never overwrite
each other.

### Reset schedules

Both providers report their own reset times, and those are used as-is and
labelled `Resets …`. If a provider goes quiet, an account's **Weekly reset
fallback** takes over and is labelled `Resets (local schedule) …` so you always
know which you are looking at. Set it per account in the editor — for example
Monday 02:00 for one account and Monday 07:00 for another. Times are in your
Mac's current time zone and follow daylight saving correctly.

### OpenAI accounts

**Business/work account** — usually detected from `~/.codex/auth.json`.

**Second (personal) account** — sign in with that account, copy the resulting
`auth.json` somewhere else (for example `~/.codex-personal/auth.json`), then
*+ Add OpenAI Account → Credential file at a custom path → Choose File…*. The
file is validated when you pick it and only ever read.

## Credential security

- Secrets live in the **macOS Keychain**, or in credential files that the
  provider's own tools already keep on this Mac.
- Nothing secret is ever written to user defaults, settings files, logs or the
  clipboard.
- `~/.codex/auth.json` is **only read, never written**. The Codex CLI and the
  ChatGPT app own its refresh cycle; an expired token is reported, not renewed.
- Claude tokens are refreshed and written back only to the store they came from.
  A credential *file* you pointed at is never modified — a refreshed token is
  held in memory for the session instead.
- Removing an account deletes only a credential copy this app imported. Claude
  Code's item and `~/.codex/auth.json` are never touched.
- Diagnostics strip JWTs, API keys, bearer headers, token fields, home directory
  paths and (unless you opt in) e-mail addresses.

## Privacy

Local-first. Usage is fetched directly from Anthropic and OpenAI using your own
credentials. There is no server of ours in the loop, no account to create, and
no analytics or telemetry of any kind. See [docs/PRIVACY.md](docs/PRIVACY.md).

## Notifications

Warnings fire once per account, per metric, per usage window, and re-arm after
that window resets. The global threshold defaults to 90% used; any account can
override it. Auth failures raise a separate one-off warning naming the account
that needs attention.

Notifications are delivered through `osascript`, which means macOS attributes
them to Script Editor. That is a consequence of running unsigned —
see [docs/DECISIONS.md](docs/DECISIONS.md).

## Known limitations

The honest list lives in [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md).
The headline one: **ChatGPT message allowances cannot currently be read.** The
Codex credential is not authorised for the endpoints that would report them, and
this app will not fabricate a count by watching your local activity, because you
also send messages from the web and desktop clients. The metric is shown as
`Unavailable` with the reason, and the architecture is ready for real numbers the
day a readable source exists.

## Roadmap

Phase One (this release) is the multi-account foundation. Possible later work:
historical graphs and usage trends, cost analysis, additional providers
(Gemini, GitHub Copilot, Cursor, Perplexity, OpenRouter), and optional
cross-device sync. None of it is promised.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md), which covers
building, testing, and how to add a provider adapter. Please read
[SECURITY.md](SECURITY.md) before reporting anything credential-related, and
never attach tokens or auth files to an issue.

## Upstream attribution

This project is a derivative of
**[stavrop/ai-usage-monitor](https://github.com/stavrop/ai-usage-monitor)** by
Georgios Stavropoulos, used under the Apache License 2.0. The credential
reading, token refresh, response parsing and progress-bar drawing all began
there, and the project is much better for it. Please star the upstream project
too.

To track upstream changes:

```sh
git remote add upstream https://github.com/stavrop/ai-usage-monitor.git
git fetch upstream
git log --oneline HEAD..upstream/main    # what's new upstream
git diff HEAD upstream/main -- <path>    # compare a specific area
```

The architectures have diverged, so upstream changes should be reviewed and
ported deliberately rather than merged wholesale.

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

The upstream project is Apache-2.0 licensed, and a derivative work cannot be
relicensed under MIT without the upstream author's permission. This project
therefore stays Apache-2.0, which is permissive in substantially the same way.
The reasoning is recorded in [docs/DECISIONS.md](docs/DECISIONS.md).

Not affiliated with, endorsed by, or sponsored by Anthropic or OpenAI.
