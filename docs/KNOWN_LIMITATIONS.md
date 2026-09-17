# Known limitations

Only limitations actually observed while building and testing Phase One. Nothing
here is speculation.

---

## ChatGPT message allowances cannot be read

**What.** The "x of y messages" allowance a paid ChatGPT plan grants is not
displayed. The metric appears as `ChatGPT messages — Unavailable`.

**Why.** The credential this app reads (`~/.codex/auth.json`, shared by the
Codex CLI and the ChatGPT desktop app) is scoped to Codex. Probing the ChatGPT
backend endpoints that would report a message allowance with that credential
returns **HTTP 403** in every case tested. The Codex usage endpoint itself
reports only Codex rate-limit windows.

**Why it is not worked around.** Counting messages locally would be wrong by
construction: the same person sends messages from ChatGPT on the web, from the
desktop app and from other clients, none of which this app can see. A partial
count presented as an allowance would be worse than no number. Screen scraping
and OCR are out for the same reason plus several others.

**Status.** The metric exists in the model with `usedCount` / `limitCount`
fields and an `unsupported` state, so adding real numbers later is a parser
change rather than a redesign.

---

## Codex's short rolling window is only shown when the API reports it

**What.** A "Codex 5-hour" row appears only sometimes.

**Why.** The usage endpoint returns `secondary_window: null` when there is no
active short window. The app renders the windows the provider actually sends and
does not invent a row for one it did not.

---

## Claude does not name the account

**What.** A Claude account's display name defaults to something like
`Claude (max)` rather than an e-mail address.

**Why.** Neither the credential nor the usage endpoint identifies the account by
e-mail; the credential records a plan. Rather than invent an identity, the app
uses the plan as a starting label and lets you rename the account to whatever
makes sense. OpenAI accounts *do* carry an e-mail and plan in the credential, so
those get a more specific suggestion.

---

## A second Claude account needs a manual credential import

**What.** Adding a second Claude account is not one click.

**Why.** Claude Code stores exactly one credential in its Keychain item, and this
app does not implement an OAuth sign-in flow of its own — deliberately, since the
whole security model rests on reading credentials rather than minting them. So
the second account's credential has to be imported once, by hand, into this
app's own Keychain entry. The procedure is in the README.

---

## Refreshed tokens are not written back to credential *files*

**What.** For an account whose source is a JSON credential file you chose, a
token refreshed by this app is kept in memory for the session and the file is
left alone.

**Why.** The app does not own those files. A botched write to `~/.codex/auth.json`
would sign you out of Codex entirely. The trade is that the app re-reads the file
on the next launch, which may then need refreshing again.

---

## Notifications are attributed to Script Editor

**What.** macOS shows usage warnings as coming from Script Editor, not from
Multi AI Usage Monitor.

**Why.** `UNUserNotificationCenter` will not deliver from an unsigned bundle
without a registered identifier, so notifications go through `osascript`. This
resolves itself if the project ever ships signed builds.

---

## CI cannot prove the app runs on Monterey

**What.** The GitHub Actions workflow builds and tests, but on a newer macOS
runner than the minimum this project supports.

**Why.** GitHub-hosted macOS 12 runners have been retired. The workflow compiles
with `-target <arch>-apple-macosx12.0` and asserts the built binary's minimum OS
version is 12.0, which proves the *deployment target* is right. It does not
prove runtime behaviour on Monterey. That is verified by hand — see
[QA.md](QA.md) — and Phase One was developed and tested on macOS 12.7.6 on an
Intel Mac.

---

## The app is unsigned and unnotarised

**What.** Gatekeeper will complain about a copy moved between machines, and
there is no release download.

**Why.** No Developer ID is configured for this project yet. Building locally
with `./build.sh` avoids the issue entirely.
