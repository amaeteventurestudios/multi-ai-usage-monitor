# Security policy

## Supported versions

This project is in early development. Security fixes land on `main` and in the
next release. There are no supported older versions yet.

## Reporting a vulnerability

Please report privately first, especially anything touching credential handling.

**Preferred:** GitHub's private vulnerability reporting, from the
[Security tab](https://github.com/amaeteventurestudios/multi-ai-usage-monitor/security)
of this repository ("Report a vulnerability"). This keeps the report visible only
to the maintainers until a fix is ready.

If private reporting is not available to you, open a public issue that describes
**only** the class of problem — for example "the diagnostics report can include
credential material under some conditions" — and asks a maintainer to get in
touch. Do not include a working exploit, a reproduction that leaks a secret, or
step-by-step extraction instructions in a public issue.

No security contact e-mail address is published for this project. Rather than
invent one, please use the channels above.

Please allow a reasonable period for a fix before publishing details.

## Never include these in a report

Whatever channel you use:

- access tokens, refresh tokens, ID tokens or API keys
- the contents of `~/.codex/auth.json` or any other credential file
- Keychain items or exports
- session cookies or `Authorization` headers
- unredacted diagnostics output
- screenshots showing any of the above

The app's **Copy Diagnostics** button produces output with tokens, home paths
and e-mail addresses already stripped. Please use it, and still read the result
before pasting it anywhere.

## What this app does with your credentials

Understanding this may help you judge whether something is a vulnerability:

- Credentials are read from the macOS Keychain, or from credential files the
  provider's own tools already maintain on this Mac.
- Credentials you import are written to the Keychain under this app's own
  service name (`com.amaeteventurestudios.multi-ai-usage-monitor.credentials`)
  and nowhere else.
- `~/.codex/auth.json` is only ever read. The app does not write it.
- Claude tokens are refreshed and written back only to the store they came from.
  Credential *files* are never modified.
- Credentials are transmitted only to the provider they belong to
  (`api.anthropic.com`, `platform.claude.com`, `chatgpt.com`), over HTTPS.
- Removing an account deletes only a credential copy this app imported.

## Scope

In scope: credential leakage into logs, defaults, diagnostics, error messages or
the clipboard; writing to credential files the app does not own; deleting
credentials it does not own; sending credentials anywhere other than the
provider they belong to; any path that lets another local process obtain a
credential through this app.

Out of scope: the app being unsigned and unnotarised (a known, documented
consequence of building locally — see `docs/KNOWN_LIMITATIONS.md`);
vulnerabilities in Claude Code, the Codex CLI or the ChatGPT desktop app
themselves; the security of the provider APIs.
