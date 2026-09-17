# Contributing

Thanks for taking a look — contributions are genuinely welcome, and you do not
need any of the project owner's accounts or credentials to work on this.

## Getting set up

```sh
git clone https://github.com/amaeteventurestudios/multi-ai-usage-monitor.git
cd multi-ai-usage-monitor
./build.sh                          # builds "Multi AI Usage Monitor.app"
./test.sh                           # runs the test suite
open "Multi AI Usage Monitor.app"
```

You need the Xcode Command Line Tools (`xcode-select --install`). A full Xcode
install is not required, and the test suite deliberately does not depend on one.

`./rebuild-and-restart.sh` stops a running instance, rebuilds and restarts it.
Use it while iterating: overwriting a running binary invalidates its ad-hoc
signature and macOS will refuse to launch the result.

## How the code is laid out

```
Sources/Core/      Pure logic, models, storage, networking, provider adapters.
                   No AppKit. Everything here is testable.
Sources/App/       AppKit: the status item, the dropdown, the settings window.
Tests/             The test suite and sanitised response fixtures.
```

The dependency runs one way: `App` uses `Core`, never the reverse. If you find
yourself wanting to import AppKit in `Core`, the logic probably wants to move.

### Key types

- `AIAccount` — the unit of everything. Accounts, not providers, are what the app
  stores credentials for, refreshes, renders and warns about.
- `CredentialSource` — where one account's credential lives.
- `UsageMetric` — one allowance, percentage- or count-based, with a `MetricState`
  that covers "we cannot read this" as a first-class case.
- `UsageProvider` — the adapter protocol.
- `UsageCoordinator` — owns accounts, state, the refresh cycle and backoff.

## Adding a provider

1. Add a case to `ProviderKind` in `Sources/Core/Models.swift`, with a display
   name and a badge letter.
2. Add the credential source cases it needs to `CredentialSource`, including
   `isValid(for:)` and the two label properties.
3. Create `Sources/Core/<Name>UsageProvider.swift` with two pieces:
   - a class conforming to `UsageProvider` that does credential handling and
     networking;
   - a separate `enum <Name>UsageParser` with a pure `parse(_:account:now:calendar:)`
     that turns a JSON object into an `AccountUsage`.
4. Register it in `ProviderRegistry`.
5. Add a **sanitised** fixture under `Tests/Fixtures/` and tests for the parser.
6. Add the credential source options to `AccountEditorController.availableSources()`.

Nothing in the UI switches on which providers exist, so that is usually all.

### Rules for a parser

- A successful response with no usable window must **throw**, not return zeroes.
  Replacing good numbers with a confident `0%` is worse than keeping stale ones.
- Never invent a reset time, a percentage or a count. If the provider does not
  say, the metric is `.unsupported` (with a `detail` explaining why) or its reset
  is `nil`.
- Name windows from what the provider reports, not from a constant. If the API
  says `limit_window_seconds: 18000`, the label comes from that.
- Percentages are always **used**, never remaining.

## Testing

`./test.sh` compiles `Sources/Core` together with `Tests` and runs the result.
There is no XCTest dependency — see `docs/DECISIONS.md` for why.

Write tests for anything deterministic: parsing, date arithmetic, formatting,
thresholds, dedup logic, persistence, migration. Use the helpers in
`Tests/TestHarness.swift`:

```swift
test("a 200 with no windows is a parse failure, not a confident 0%") {
    var threw = false
    do { _ = try MyParser.parse(fixture("my-empty.sample.json"), account: makeAccount()) }
    catch { threw = true }
    expect(threw)
}
```

Date tests must pin a calendar and timezone (`calendar("America/New_York")`) so
they do not depend on the machine's locale, and anything weekly should cover both
daylight-saving transitions.

**No real credentials in tests, ever.** Fixtures use `user@example.com`,
`/Users/example/…` and obviously fake token values, and are named `*.sample.json`
so they cannot be mistaken for live files.

## Security rules

These are not negotiable:

- **Never commit a credential.** Not a token, not an `auth.json`, not a Keychain
  export, not a fixture built from a real response you forgot to sanitise.
- Secrets go in the Keychain. Never in user defaults, never in a settings file,
  never in a log line, never in an error message shown to the user.
- Do not write to credential files the app does not own — in particular
  `~/.codex/auth.json`.
- Anything user-visible or clipboard-bound goes through `Redact` first.
- Deleting an account may delete only a credential copy this app imported.

If you are about to commit something credential-adjacent, run
`git diff --cached` and read it.

## Branches and pull requests

- Branch from `main`, named for the work: `feature/gemini-provider`,
  `fix/stale-badge`, `docs/readme-install`.
- Keep commits logical and their messages in the imperative mood
  ("Add a Gemini provider adapter", not "changes").
- Before opening a PR: `./build.sh` and `./test.sh` both pass, and no credential
  is in the diff.
- Fill in the PR template. It exists to catch exactly the things that are easy to
  forget.

## Compatibility

**macOS 12 Monterey is the floor, and Intel support must not regress.** Before
using an API, check its availability. If it needs macOS 13 or later, either guard
it with `if #available` and provide a Monterey path, or use the AppKit
equivalent. AppKit is entirely welcome here — this is not a codebase that prefers
modern SwiftUI to a working app on Monterey.

## Code of conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
