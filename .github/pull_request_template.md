## What this changes

<!-- A sentence or two. Link the issue if there is one. -->

## Why

<!-- The problem it solves. -->

## How it was tested

<!-- What you ran, and what you checked by hand. -->

---

## Checklist

- [ ] `./build.sh` succeeds
- [ ] `./test.sh` passes with no failures
- [ ] New deterministic logic has tests
- [ ] **macOS 12 Monterey compatibility considered** — no API newer than
      macOS 12 without an `#available` guard and a Monterey path; the deployment
      target is unchanged
- [ ] Intel (x86_64) support is unaffected
- [ ] **No credentials are committed** — no tokens, no `auth.json`, no Keychain
      exports, no real responses in fixtures. `git diff` has been read.
- [ ] No secret can reach user defaults, logs, error messages or the clipboard
- [ ] Documentation updated where behaviour changed (README, `docs/`)
- [ ] New or changed provider behaviour is documented, including anything the
      provider does **not** expose (`docs/KNOWN_LIMITATIONS.md`)
- [ ] `CHANGELOG.md` updated under Unreleased
- [ ] No usage number is fabricated, estimated or counted locally and presented
      as authoritative

## Notes for the reviewer

<!-- Anything you are unsure about, or want a second opinion on. -->
