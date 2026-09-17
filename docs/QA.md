# Manual QA checklist

Automated tests cover the deterministic logic (`./test.sh`). This is the
by-hand pass, because some of what matters here — that the menu bar item
appears, that a credential is really readable, that the app survives a restart —
cannot be asserted in a unit test.

Record the machine you ran it on. Phase One was validated on **macOS 12.7.6,
Intel x86_64**.

## Build and launch

- [ ] `./build.sh` succeeds and prints `Built Multi AI Usage Monitor.app`
- [ ] `./test.sh` succeeds with no failures
- [ ] `open "Multi AI Usage Monitor.app"` launches without a crash
- [ ] The menu bar item appears; there is no Dock icon and no main window
- [ ] `plutil -p "Multi AI Usage Monitor.app/Contents/Info.plist"` shows
      `LSMinimumSystemVersion = 12.0` and the bundle identifier
      `com.amaeteventurestudios.multi-ai-usage-monitor`
- [ ] `lipo -archs "Multi AI Usage Monitor.app/Contents/MacOS/MultiAIUsageMonitor"`
      lists `x86_64` (and `arm64` if the toolchain could cross-compile)

## First launch and migration

- [ ] With a previous installation's settings present, the old refresh interval
      and alert threshold are carried across
- [ ] An account is created for each credential actually present on this Mac
- [ ] No account is created for a provider with no credential
- [ ] No account is given a reset schedule that the provider did not report
- [ ] A detected identity is used as the suggested account name

## Existing functionality still works

- [ ] Claude usage loads: Session and Weekly (all) rows show percentages
- [ ] OpenAI usage loads: a Codex window shows a percentage
- [ ] The OpenAI weekly row is named `Codex Weekly`, not `ChatGPT Weekly`
- [ ] Reset times shown match what the provider reports

## Onboarding and identity

- [ ] "+ Add Claude Account" opens a guided flow, not a form full of Keychain
      and JSON questions
- [ ] The flow detects the account and shows its e-mail and plan before saving
- [ ] The saved account is named `Claude (your-address@example.com)`
- [ ] "+ Add OpenAI Account" detects the e-mail *and* the plan, and saves as
      `OpenAI — <Plan> (your-address@example.com)`
- [ ] Adding an account that is already saved is refused by name
- [ ] Cancelling at any step saves nothing

## Multiple accounts and persistence

- [ ] Sign Claude Code in to a second account, add it: both accounts now appear
- [ ] Adding the second does not change the first account's credential or name
- [ ] Both Claude accounts appear in the dropdown with distinct names and badges
      (`C1`, `C2`)
- [ ] Quit and relaunch the app: both accounts are still there, still named,
      still reporting
- [ ] **Close every browser profile you signed in with**: both accounts keep
      reporting
- [ ] Sign Claude Code out entirely: saved accounts keep reporting from their own
      captured credentials
- [ ] Restart the Mac: accounts, names, order and reset rules all survive
- [ ] An OpenAI account pointed at a custom `auth.json` path works alongside the
      default one
- [ ] Badges disappear (`C` not `C1`) when a provider has only one account

## Reconnect

- [ ] An account whose credential has expired shows "Reconnect required", and
      keeps its last numbers
- [ ] Reconnect on that account opens the same guided flow
- [ ] After reconnecting, the display name, reset rule, position, threshold and
      enabled state are all unchanged
- [ ] Reconnecting an account with a *different* account's credential is refused
      and explains why
- [ ] Reconnecting one account leaves every other account untouched

## Reset schedules

- [ ] Account A configured with a Monday 2:00 AM fallback shows
      `Resets (local schedule) Monday 2:00 AM` when the provider reports nothing
- [ ] Account B configured with Monday 7:00 AM shows its own time, not A's
- [ ] When the provider *does* report a reset, the line reads `Resets …` with no
      "local schedule" qualifier
- [ ] The countdown ("3d 14h remaining") decreases over time without a refresh

## Refresh

- [ ] **Refresh Now** (⌘R) updates the numbers and the "Updated" line
- [ ] Automatic refresh fires at the configured interval
- [ ] Setting the interval to "Manual only" stops automatic refreshes
- [ ] Changing the interval takes effect without restarting the app

## Failure isolation

- [ ] Point one account at a nonexistent credential path: that account shows an
      error, every other account keeps working
- [ ] Turn off Wi-Fi and refresh: previous numbers stay on screen, marked `Stale`
- [ ] The menu bar title shows `!` for the failing account only, not a global
      error
- [ ] Restore connectivity and refresh: the error clears

## Stale data

- [ ] After a failed refresh, the last good numbers are still shown
- [ ] Rows carry a `Stale` marker and an age ("Updated 23 min ago")
- [ ] Rows that were never a live value (`ChatGPT messages`) stay `Unavailable`
      rather than becoming stale

## Settings

- [ ] Renaming an account updates the dropdown and the menu bar
- [ ] Disabling an account removes it from the dropdown and the menu bar
- [ ] Move Up / Move Down reorders the dropdown and the menu bar
- [ ] Each menu bar summary mode renders as described
- [ ] The Display tab's background opacity slider runs 70% to 100%, defaults to
      95%, changes the settings window immediately as it is dragged, and the
      "Current: N%" caption tracks the thumb
- [ ] At 100% the window is fully solid; at 70% the desktop shows through and the
      text is still comfortably readable, in both Light and Dark Mode
- [ ] The account editor and the onboarding sheet use the same opacity
- [ ] The chosen opacity is still in effect after quitting and relaunching
- [ ] Each menu bar summary mode shows a sentence explaining what will appear
- [ ] The per-account format picker offers Detailed, Compact and Minimal Labels,
      each with a description, and the live preview updates as you change it
- [ ] The format picker is disabled unless the summary mode is Per Account

## Menu bar formats

With four accounts (Claude Amaete, Claude StarLogic, OpenAI Business,
OpenAI Personal):

- [ ] Detailed reads `C Amaete 57% · C StarLogic 22% · G Business 90% · G Personal 41%`
- [ ] Compact reads `C-A 57% · C-S 22% · G-B 90% · G-P 41%`
- [ ] Minimal Labels reads `A 57% · S 22% · B 90% · P 41%`
- [ ] Changing the format takes effect immediately, with no restart
- [ ] The format survives quitting and relaunching
- [ ] Account order in the menu bar matches the order in Settings, and does not
      re-sort itself by usage
- [ ] Percentages match the dropdown, and are usage *used*
- [ ] An account that cannot refresh shows `!` in its place, in every format
- [ ] Editing an account's **Menu Bar Name** updates the menu bar immediately
- [ ] Two accounts with aliases sharing a first letter are disambiguated
      (e.g. `Business` and `Beta` become `G-Bu` and `G-Be`)
- [ ] No e-mail address appears in the menu bar in any format

## OpenAI Business and Personal

- [ ] Business is saved and reporting
- [ ] Switch the ChatGPT app / `codex login` to the Personal account
- [ ] **+ Add OpenAI Account** shows the *Personal* account's e-mail and plan
      before anything is saved — press Check Again if it still shows Business
- [ ] Saving creates a second account; Business is untouched
- [ ] Both appear in the dropdown with their own identities
- [ ] Quit and relaunch: both remain
- [ ] Switch the active Codex/OpenAI login back to Business, refresh: Personal
      still reports from its own captured credential
- [ ] Adding Business again is refused with "already added"
- [ ] Removing an account asks for confirmation first
- [ ] Settings survive quitting and relaunching the app
- [ ] Accounts, their order and their reset rules survive a relaunch

## Notifications

- [ ] A warning fires once when an account crosses the threshold
- [ ] It does not fire again on the next poll within the same window
- [ ] "Reset Notification State" in Advanced re-arms it
- [ ] An expired credential produces exactly one auth warning naming the account

## Security

- [ ] `Copy Diagnostics` output contains no token, no `Bearer`, no home path,
      and a masked e-mail
- [ ] `~/Library/Logs/MultiAIUsageMonitor.log` contains no credential material
- [ ] `~/.codex/auth.json` modification time is unchanged after a full session
      (`stat -f "%m %N" ~/.codex/auth.json` before and after)
- [ ] Removing an imported account deletes only this app's Keychain item:
      `security find-generic-password -s "Claude Code-credentials"` still succeeds
- [ ] `defaults read com.amaeteventurestudios.multi-ai-usage-monitor` contains no
      token

## Responsiveness

- [ ] With no network, the menu opens promptly and the app stays responsive
- [ ] With four accounts configured, a refresh does not block the UI
