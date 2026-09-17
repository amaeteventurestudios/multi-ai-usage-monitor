# Engineering decisions

Decisions taken during Phase One where the brief left room, recorded so nobody
has to re-derive the reasoning — or re-litigate it.

---

## 1. The project stays Apache-2.0 rather than becoming MIT

**Problem.** The goal was MIT licensing. The upstream project the app derives
from is Apache License 2.0.

**Options.** (a) Relicense everything MIT. (b) Keep Apache-2.0. (c) Dual-license,
with new files MIT and inherited files Apache-2.0.

**Decision.** Keep Apache-2.0 for the whole project.

**Reason.** Apache-2.0 permits derivative works but does not permit dropping its
own terms; only the copyright holder can relicense their code. Option (a) would
be a licence violation. Option (c) is legally possible but produces a codebase
where a contributor has to know which files carry which terms — and the app's
Swift files are heavily intermingled, so the boundary would be arbitrary.
Apache-2.0 is permissive in substantially the same way MIT is, with the addition
of an explicit patent grant.

**Consequences.** `LICENSE` keeps the upstream copyright line and adds ours.
`NOTICE` states the licensing structure and, as Apache §4(b) requires, gives
prominent notice of the modifications. Files with inherited code carry a short
header saying so.

**Future work.** If the upstream author ever agrees to MIT-licence their
contribution, this can be revisited.

---

## 2. Tests use a small custom harness, not XCTest

**Problem.** The suite has to run on the machines the app is built on. XCTest
ships with Xcode, not with the Command Line Tools, and the target machine has
only the CLT — `swift test` there fails with `error: XCTest not available`.

**Options.** (a) XCTest via a `Package.swift`, requiring full Xcode. (b) A
minimal assertion harness compiled with `swiftc`. (c) Both.

**Decision.** (b) — `Tests/TestHarness.swift` plus `./test.sh`.

**Reason.** A test suite that cannot run on the project's own reference machine
is not a test suite. The harness is about a hundred lines, prints per-test
results and a failure summary, and exits non-zero on failure, which is all CI
needs. Adding XCTest as well would mean maintaining two suites to get one.

**Consequences.** No `swift test`, no Xcode test navigator. `./test.sh` compiles
`Sources/Core/*.swift` together with `Tests/*.swift` and runs the result — the
same command locally and in CI.

**Future work.** If the project ever gains a full Xcode dependency for other
reasons, an XCTest wrapper around the same assertions would be easy.

---

## 3. Keychain access through `/usr/bin/security`, not Security.framework

**Problem.** Keychain items are access-controlled by code signature. The app is
built locally with `swiftc` and signed ad-hoc, so its identity changes on every
rebuild.

**Options.** (a) `SecItemCopyMatching` directly. (b) Shell out to `security`.

**Decision.** (b), which is also what upstream did for reading Claude Code's item.

**Reason.** With (a), every rebuild produces a new ad-hoc identity and macOS
prompts for Keychain access again — or denies it. The `security` tool is already
trusted for these items, so reads keep working across rebuilds. This is a
consequence of distributing unsigned; it is not a security weakening, since the
same user-level protections apply either way.

**Consequences.** Keychain calls spawn a process. That happens a few times per
refresh at most, which is nothing next to a network round trip.

**Future work.** If the project gains a Developer ID and a stable signature,
switching to Security.framework becomes straightforward and is worth doing.

---

## 4. Notifications via `osascript`, not `UNUserNotificationCenter`

**Problem.** `UNUserNotificationCenter` refuses to deliver from a bundle without
a registered, signed identifier.

**Decision.** Keep upstream's `osascript` approach.

**Reason.** It works for an unsigned, locally built app, which is how everyone
runs this today. `UNUserNotificationCenter` would deliver nothing at all.

**Consequences.** macOS attributes the notifications to Script Editor rather
than to this app, and the app cannot set a custom sound or action. Documented in
the README so nobody files it as a bug.

**Future work.** Switch as part of signed releases.

---

## 5. Move Up / Move Down instead of drag-and-drop reordering

**Problem.** The brief prefers drag-and-drop, with a documented fallback.

**Decision.** Buttons.

**Reason.** Drag-and-drop in AppKit means an `NSTableView` with a data source,
a drag type, and promise handling — a substantial amount of machinery for a list
that is typically two to four rows. The settings pane is a rebuilt stack view,
which is far simpler to keep correct. The capability (reorder, persist, have the
menu and menu bar honour the order) is identical either way, and is tested.

**Future work.** Worth revisiting if account lists ever get long.

---

## 6. Migration sets no reset override for anybody

**Problem.** The reference user's Claude accounts reset Monday 02:00 and
Monday 07:00. Should migration write those in?

**Decision.** No. Migration creates accounts with `preferProviderReset` on and no
weekly rule.

**Reason.** Both providers report their own reset timestamps, and the live check
during development confirmed Claude returns `resets_at` for every window — the
observed "Monday 7:00 AM" came from the API, not from configuration. Writing a
weekday and hour into every migrated account would be inventing a fact that
happens to be right for one machine. The per-account rule exists for providers
that stay silent, and is set in the account editor.

**Consequences.** A migrated install shows exactly what the provider says.
Nothing in the public source encodes anyone's schedule.

---

## 7. The ChatGPT message allowance is a real metric in an `unsupported` state

**Problem.** The brief asks for ChatGPT Pro message counts. Investigation
against a live credential showed the Codex token returns HTTP 403 from the
ChatGPT backend endpoints that would report them; the Codex usage endpoint
reports only Codex windows.

**Options.** (a) Omit the metric. (b) Count messages locally. (c) Show the metric
in an `unsupported` state with the reason.

**Decision.** (c).

**Reason.** (a) leaves a user wondering whether the app forgot. (b) would be
wrong by construction — the same person sends messages from the web and desktop
clients that this app cannot see — and presenting a partial local count as an
allowance is exactly the kind of false confidence the product exists to remove.
(c) answers the question honestly and leaves the metric plumbing in place.

**Consequences.** `UsageMetric` carries `usedCount` / `limitCount` and the
`unsupported` state, so the day a readable source exists the change is a parser,
not a redesign.

---

## 8. OpenAI metrics are named "Codex …", not "ChatGPT …"

**Problem.** The previous build showed "ChatGPT · Weekly 88%".

**Decision.** Name every metric from this endpoint `Codex <window>`, with the
window read from `limit_window_seconds`.

**Reason.** A live check confirmed the endpoint reports Codex rate-limit windows
(`604800` seconds → weekly). Calling that "ChatGPT Weekly" invites exactly the
confusion the product exists to remove — it reads as a chat-message allowance.
Deriving the window name from the seconds the API returns also means a new window
length labels itself correctly instead of being hard-coded as "5-hour".

---

## 9. Completion handlers rather than `async`/`await`

**Problem.** Swift concurrency is available on macOS 12, but the app's existing
networking is completion-based.

**Decision.** Keep completion handlers in the provider protocol.

**Reason.** The refresh coordinator is already serialised onto the main queue and
the call graph is shallow. Converting would churn every provider and the
coordinator for no behavioural gain, while adding back-deployment considerations
for an app whose whole point is staying comfortably within macOS 12.

**Future work.** A protocol with an `async` variant would be a clean, contained
change if the codebase ever grows deeper call chains.

---

## 10. The tip jar and upstream donation links were removed

**Problem.** The upstream project ships a launch-time "support this app" window
and a donation link to the upstream author.

**Decision.** Remove both. Keep and expand the upstream credit in the About pane,
the README and NOTICE.

**Reason.** Soliciting donations on the upstream author's behalf from a fork they
do not control is presumptuous; soliciting them for ourselves on the back of
their code is worse. Attribution is the right way to credit upstream, and it is
now more prominent than the donation button was.

---

## 11. Upstream release and packaging automation was removed

**Problem.** The tree carried a Homebrew cask template, a `RELEASE.md` and a
`tools/build_release.sh` that all point at the upstream repository's releases and
tap.

**Decision.** Remove them for now.

**Reason.** They would be actively misleading in this repository: the cask points
at a tap that does not host this app, and the release script uploads to a
repository we do not publish to. This project has no releases yet.

**Future work.** Reinstate, pointed at this project's own releases, when there is
a signed build to ship.
