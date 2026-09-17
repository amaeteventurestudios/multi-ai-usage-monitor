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

## Some plan tiers are named by family rather than in full

**What.** An OpenAI account on `self_serve_business_prolite` is shown as
"Business", not "Business Premium".

**Why.** The plan *family* is unambiguous from the identifier. The tier within it
is not something the app can name with confidence, and inventing a plausible
marketing name for a plan is exactly the kind of small fabrication this project
avoids. The raw identifier is kept in diagnostics, and anyone who knows what
their plan is called can rename the account in one field.

---

## There is no in-app sign-in; accounts are added from a tool you signed in with

**What.** "+ Add Claude Account" does not open a Claude login page. It adds the
account that Claude Code is currently signed in to. The same is true for OpenAI
and the ChatGPT app / `codex login`.

**Why.** A browser OAuth flow would mean this app minting its own tokens, and the
only client identifier available to it is the one belonging to the provider's own
first-party tool. Presenting a third-party menu bar app as that tool is not a
provider-supported mechanism, and is not something to do with somebody's account.
So the app continues to do what it has always done — read a credential the user
deliberately created with a first-party tool — and the onboarding flow makes that
a guided three steps rather than a manual Keychain copy.

Once added, the account no longer depends on that tool: the credential is copied
into this app's own Keychain entry, so you can sign a different account in
afterwards and close the browser profile you used.

---

## An OpenAI account's captured credential expires, and is not renewed

**What.** A saved OpenAI account eventually shows "Reconnect required".

**Why.** OpenAI access tokens are short-lived. Renewing one means exchanging its
refresh token, and the provider may rotate that token in the process — which
would invalidate the copy the ChatGPT app and Codex rely on and sign the user out
of the tools they actually work in. Breaking someone's Codex login to keep a
dashboard's number fresh is not a trade worth making, so the app reports the
state instead of renewing it.

**What softens it.** When a captured OpenAI credential expires, the app checks
whether Codex now holds a live credential for *the same account id* and adopts it
silently. In practice, signing that account back in anywhere on this Mac revives
the saved account with no reconnect step. Claude accounts are not affected: their
credentials carry a refresh token that this app renews into its own copy.

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
