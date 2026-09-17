# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Background opacity control** in Settings → Display. A slider from 60% to
  100% (default 90%) sets how solid the app's own windows are drawn. It applies
  to the settings window and the account editor sheet immediately, with no
  restart, and persists between launches. The tint is the dynamic system window
  colour, so Dark Mode keeps its contrast instead of washing out. The floor is
  deliberately above zero — a preference that can make the app unreadable is not
  worth offering.

### Changed

- The copyright holder for this project's own contributions is now
  **Amaete Umanah** rather than Amaete Venture Studios, in LICENSE, NOTICE, the
  per-file modification headers and the About pane. Upstream attribution to
  Georgios Stavropoulos and stavrop/ai-usage-monitor is unchanged.

## [0.1.0] — Phase One

First release of **Multi AI Usage Monitor**, a fork of
[stavrop/ai-usage-monitor](https://github.com/stavrop/ai-usage-monitor)
rebuilt around multiple accounts per provider.

Versioning restarts at 0.1.0: this is a new project with a new bundle
identifier, not a continuation of the upstream version series.

### Added

- **Accounts as first-class objects.** An `AIAccount` has its own display name,
  enabled state, ordering, credential source, reset behaviour and notification
  threshold. Two Claude accounts and two OpenAI accounts can be monitored at
  once, and adding a fifth is a settings change.
- **Per-account credential sources.** Claude accounts read from Claude Code's
  Keychain item, from a credential imported into this app's own Keychain entry,
  or from a JSON file. OpenAI accounts read from `~/.codex/auth.json` or any
  other path. Configuring one account never changes another's source.
- **Credential import** into this app's Keychain service, via a secure field, so
  a second Claude account can coexist with the first.
- **Per-account weekly reset rules**, used as a clearly-labelled fallback when a
  provider reports no reset time, computed with calendar arithmetic so daylight
  saving transitions are handled correctly.
- **Generic usage metrics** covering percentage- and count-based allowances, with
  states for available, loading, stale, unsupported, authentication-required,
  rate-limited and error — so an allowance the app cannot read says so instead of
  showing nothing.
- **Error isolation per account**, with actionable recovery text naming the
  account and its credential source.
- **Stale data handling**: a failed refresh keeps the last good numbers, marked
  stale with their age.
- **Menu bar summary modes** — compact, per provider, and minimal — plus toggles
  for percentages, badges, countdowns and highest-only.
- **Redesigned settings** with Accounts, Display, Notifications, Refresh,
  Advanced and About sections, an account editor, and account reordering.
- **Notification deduplication** keyed by account, metric, threshold and usage
  window, re-arming automatically after each reset; separate one-off warnings for
  authentication failures.
- **Concurrent refresh** with per-account exponential backoff that honours
  `Retry-After`.
- **Diagnostics**: levelled local logging with redaction of tokens, keys, bearer
  headers, home paths and e-mail addresses, plus "Copy Diagnostics" and
  "Open Logs".
- **Migration** from a previous installation: old provider switches, custom
  paths, refresh interval and alert threshold are carried across, and an account
  is created for each credential actually present.
- **A test suite** (`./test.sh`, 300+ assertions) covering reset arithmetic
  including both DST transitions, persistence, migration, provider parsing
  against sanitised fixtures, notification dedup, staleness, error
  classification, redaction and menu bar formatting.
- **Documentation**: README, CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, plus
  `docs/DECISIONS.md`, `docs/KNOWN_LIMITATIONS.md`, `docs/PRIVACY.md` and
  `docs/QA.md`. GitHub issue and pull request templates, and a CI workflow.

### Changed

- **Renamed** from "AI Usage Monitor" / `ClaudeUsage.app` to
  **Multi AI Usage Monitor**, bundle identifier
  `com.amaeteventurestudios.multi-ai-usage-monitor`.
- **OpenAI metrics are named "Codex …"**, with the window read from the
  `limit_window_seconds` the API reports. The previous "ChatGPT · Weekly" label
  described a Codex window and read as a chat-message allowance.
- **Percentages are explicitly "used"** everywhere, so a number can never be
  misread as remaining.
- **Restructured** a single 1,400-line `main.swift` into `Sources/Core`
  (logic, storage, providers; no AppKit) and `Sources/App` (the interface).
- **Default refresh interval** is 5 minutes, chosen from a fixed list rather
  than a free-text field.
- `build.sh` pins the deployment target to macOS 12.0 explicitly and produces a
  universal binary when the toolchain can cross-compile.

### Removed

- The launch-time tip jar and the donation link to the upstream author.
  Attribution now lives in the About pane, the README and NOTICE.
- Upstream release automation (Homebrew cask template, `RELEASE.md`,
  `tools/build_release.sh`) and the upstream GitHub Pages site, which pointed at
  a repository and tap that do not host this project.

### Security

- No secret is written to user defaults, settings, logs or error messages.
- `~/.codex/auth.json` is never written; credential *files* are never modified.
- Removing an account deletes only a credential copy this app imported.
- Diagnostics are redacted before reaching the clipboard.

### Known limitations

- ChatGPT message allowances cannot be read with the available credential and
  are reported as `Unavailable` rather than estimated. See
  [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md).

[Unreleased]: https://github.com/amaeteventurestudios/multi-ai-usage-monitor/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/amaeteventurestudios/multi-ai-usage-monitor/releases/tag/v0.1.0
