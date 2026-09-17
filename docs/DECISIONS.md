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


---

## 12. No in-app OAuth sign-in; onboarding adopts a first-party credential

**Problem.** The ideal flow is "click Add Account, sign in, done". Implementing
it means this app running its own OAuth flow against Anthropic and OpenAI.

**Options.** (a) A browser OAuth flow using the client identifier belonging to
the provider's own CLI. (b) Register this app as its own OAuth client. (c) Keep
reading credentials a first-party tool created, but wrap it in a guided flow.

**Decision.** (c).

**Reason.** (a) would mean presenting a third-party menu bar app to the provider
as Claude Code or Codex in order to mint fresh tokens on someone's account. That
is not a provider-supported mechanism, and the brief asked for direct login only
if it could be done "safely and legitimately". (b) is not available — neither
provider offers third-party client registration for these consumer subscription
endpoints. (c) keeps the security model the project has always had: the app
reads credentials, it never mints them.

What (c) gives up is one click. What it keeps is the outcome that actually
mattered — after onboarding, the account no longer depends on what the
first-party tool is signed in to, because its credential has been copied into
this app's own Keychain entry.

**Consequences.** Adding a second Claude account means signing Claude Code in to
it once. The flow makes that three guided steps instead of a manual Keychain
copy. Documented in the README and known limitations.

---

## 13. Captured credentials, not borrowed ones

**Problem.** An account that reads from Claude Code's single Keychain item is not
really a saved account: sign a different account into Claude Code and it starts
reporting someone else's usage.

**Decision.** Saving an account copies the credential into this app's own
Keychain service, keyed by the account's id, before the account record is
written. If the copy fails, nothing is saved.

**Reason.** This is what makes the dashboard a dashboard. It is also what makes
identity trustworthy: an account's numbers and its name stay attached to the same
provider account for as long as the credential lives.

**Consequences.** Removing an account deletes exactly one Keychain item — the
copy — and never the provider's own. Claude's captured copies renew themselves
via their refresh token; OpenAI's cannot, which is covered in known limitations.

---

## 14. Duplicate detection prefers a stable id, and refuses to guess

**Problem.** Two saved profiles for one account would make the dashboard lie
about capacity.

**Decision.** `AccountIdentity.matches` compares the provider's stable account id
when both sides have one, falls back to a case-insensitive e-mail comparison, and
otherwise reports *not the same*.

**Reason.** Wrongly merging two accounts is worse than showing a duplicate the
user can remove in one click: a merge silently attributes one account's usage to
another, which is precisely the decision this app exists to inform. So the
ambiguous case fails open.

---

## 15. Silent reconnect only on proven identity

**Problem.** A captured credential expires. The provider's own tool may now hold a
fresh one — or may hold a completely different account's.

**Decision.** Adopt the live credential only when its account id matches the saved
account's. For OpenAI this is a local comparison; for Claude, whose credential
does not name its account, it costs one profile call on the failure path.

**Reason.** Adopting an unverified credential would repoint an account at someone
else's usage without saying so. The cost of being strict is an occasional manual
reconnect; the cost of being loose is a dashboard that quietly lies.


---

## 16. Two separate settings, because "Minimal" meant two different things

**Problem.** The menu bar settings had one list — Compact, Provider, Minimal —
that conflated *what the title is about* with *how wide each label is*. Adding
three per-account widths, one of which is also called minimal, would have given
the app two different settings both offering "Minimal".

**Decision.** Split them. **Menu Bar Summary** is Per Account / Provider /
Icon Only. **Per-account format** is Detailed / Compact / Minimal Labels, and is
disabled unless the summary is Per Account.

**Reason.** They are genuinely different questions, and naming them as one list
is what made people guess. "Icon Only" also says what it does, which "Minimal"
never did.

**Consequences.** Stored preferences migrate: `compact` becomes `perAccount`,
`minimal` becomes `iconOnly`. Existing users land on Per Account + Detailed,
which is the intended default.

---

## 17. Abbreviation is computed, not configured

**Problem.** Compact and Minimal formats need short labels, and short labels
collide.

**Decision.** A generic shortest-unique-prefix algorithm, grouped by whatever
already disambiguates the rendered label — the provider initial in Compact,
nothing in Minimal Labels.

**Reason.** Hard-coding abbreviations for the four accounts this was designed
around would break for the fifth. The algorithm expands a name only as far as it
must, is deterministic so the menu bar does not reshuffle between refreshes, and
numbers genuinely identical aliases rather than rendering two accounts
indistinguishably — an ambiguous menu bar is worse than an ugly one.

---

## 18. The menu bar keeps account order, and shows aliases rather than addresses

**Problem.** Should the menu bar sort by usage, so the busiest account leads?
And should it show the identity it worked so hard to confirm?

**Decision.** No to both. Order follows the user's arrangement; labels are short
aliases.

**Reason.** A menu bar is read positionally — you learn where your accounts sit
and glance at that spot. Re-sorting by usage would move them exactly when
something changed, which is when you most need to find them. And a row of
e-mail addresses in the menu bar is unreadable at that size and visible to
anyone near the screen; the dropdown carries the full identity, which is where
identity matters.


---

## 19. The menu bar is drawn, not spelled with block characters

**Problem.** Two stacked usage bars per account have to fit inside a 22-point
menu bar, in colour, at predictable widths.

**Options.** (a) Unicode block characters in the status item's title. (b) Draw
into an `NSImage` and set it as the button's image. (c) A custom `NSView` in the
status item.

**Decision.** (b), via `NSImage(size:flipped:drawingHandler:)`.

**Reason.** Block characters give no control over width, render differently
depending on the installed fonts, and cannot show two rows or per-window colour.
(c) works but invites layout and event-handling surprises inside the status bar
for no gain here. The drawing handler runs at draw time inside the current
appearance, so `NSColor.labelColor` and friends resolve correctly in both light
and dark menu bars — and it predates macOS 12 comfortably.

**Consequences.** The status item's width is computed from measured text, so it
is exact. Text-only and Icon Only modes keep using the button's title, which is
simpler and lets the system handle truncation.

---

## 20. One layout model, shared by the menu bar and its preview

**Problem.** A settings preview that formats things itself will eventually
disagree with the real menu bar.

**Decision.** `MenuBarLayout` produces the cells; `MenuBarRenderer` draws them.
The preview calls exactly the same two, on the same live data.

**Reason.** A preview that can lie is worse than no preview. This way a
formatting change cannot reach one without the other, and the layout rules stay
testable without a screen.

---

## 21. Both providers use one vocabulary: "5-hour" and "Weekly"

**Problem.** Claude's short window was called "Session" and OpenAI's windows were
prefixed "Codex", so the two providers could not be compared at a glance.

**Decision.** Name both providers' windows "5-hour" and "Weekly", classified from
the window length the provider reports. Move the Codex qualifier to the detail
line under the OpenAI bars.

**Reason.** "Session" says nothing about how long it lasts, and the whole point
of the dashboard is comparing accounts across providers. The qualifier still
matters — these OpenAI windows govern Codex requests, not ChatGPT messages — so
it is stated rather than dropped, just not in a place that makes every label
provider-specific again.

**Consequences.** The role is data-derived, so a provider that changes a window's
length reclassifies itself rather than being mislabelled.

---

## 22. Provider mode takes the worst account per *window*

**Problem.** In Provider mode, what are a provider's two figures when it has
several accounts?

**Decision.** The highest usage for each window independently, so a provider's
five-hour figure and its weekly figure may come from different accounts.

**Reason.** The question Provider mode answers is "how constrained is this
provider right now", and that is constrained-per-window. Taking both figures from
whichever account is worst overall would hide a second account that is about to
run out of weekly allowance.

---

## 23. `O` for OpenAI, with `G` reserved

**Problem.** OpenAI's badge was `G`, presumably for GPT.

**Decision.** `O` for OpenAI. `G` is reserved for a future Gemini adapter.

**Reason.** A badge people have learned and then have to relearn is a worse cost
than changing it now, while the project has one user.
