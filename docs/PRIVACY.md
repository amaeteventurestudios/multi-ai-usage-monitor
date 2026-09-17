# Privacy

Multi AI Usage Monitor is local-first. This document describes exactly what it
does, in the same words the code uses.

## What stays on your Mac

Everything, except the requests described below.

- **Credentials** are read from the macOS Keychain, or from credential files the
  provider's own tools already keep on this Mac. When you import a credential,
  it is written to the Keychain under this app's own service name and nowhere
  else.
- **Settings** — account names, ordering, enabled state, which credential source
  each account uses, reset rules, thresholds, display preferences — are stored in
  this app's user defaults. No secret is ever written there.
- **Notification state** (which warning has already fired for which usage window)
  is stored in the same place.
- **Logs** stay in memory, and are written to
  `~/Library/Logs/MultiAIUsageMonitor.log` only when you use "Open Logs" or when
  the app quits.

## What leaves your Mac

Two kinds of request, both made directly to the provider, both authenticated with
your own credential:

| Endpoint | Purpose |
|---|---|
| `https://api.anthropic.com/api/oauth/usage` | Read Claude usage for an account |
| `https://platform.claude.com/v1/oauth/token` | Refresh an expired Claude token |
| `https://chatgpt.com/backend-api/wham/usage` | Read Codex/OpenAI usage for an account |

Nothing else. There is no server belonging to this project, no account to create,
no sign-in, no sync and no update check.

## What this app does not do

- No analytics, no telemetry, no crash reporting, no tracking of any kind. There
  is no Google Analytics, Mixpanel, Amplitude, PostHog or Sentry in this codebase,
  and adding one would be rejected.
- It does not write `~/.codex/auth.json`, or any other credential file you point
  it at.
- It does not read your conversations, prompts or any other content — only usage
  counters.
- It does not send your credentials anywhere except to the provider those
  credentials belong to.

## Diagnostics

"Copy Diagnostics" produces a report intended to be safe to paste into a public
issue. Before it reaches the clipboard it is stripped of:

- JWTs, API keys and bearer tokens
- `access_token`, `refresh_token`, `id_token`, `authorization` and `cookie` values
- your home directory path and account name
- e-mail addresses, unless you explicitly turn that off in Advanced settings

It contains the app and OS version, your account display names, credential source
*types* (never contents), credential status, refresh timestamps, HTTP status
categories and metric availability.

Please still read it before posting it.

## Changes

Any change to what leaves your Mac will be called out in
[CHANGELOG.md](../CHANGELOG.md). This document describes Phase One
(version 0.1.0) and will not make claims the implementation does not support.
