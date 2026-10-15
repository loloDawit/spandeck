# Security policy

SpanDeck is an early-stage, security-focused fork of Headroom. The current codebase still contains inherited behavior such as reading local transcripts. Reading Claude OAuth credentials (#15) and Grok CLI credentials (#17) is opt-in and off by default. Hiding a provider's plan gauge from the menu bar also pauses its quota polling, without changing consent (#19). Grok failure messages never include the key, response bodies or `grok models` output, which is not captured (#21). Provider quota requests identify as `SpanDeck (unofficial quota monitor)`, not as an official client, and a rejected credential (HTTP 401) is not resent until a 5 min (Claude) or 10 min (Grok) pause ends (#24). It has **not yet passed a SpanDeck security audit**. Do not treat development builds as approved for enterprise-managed machines.

## Reporting a vulnerability
Please do **not** open public issues containing credentials, private transcripts, exploit payloads with real user data, or details that expose private infrastructure.

Use GitHub's private vulnerability reporting for this repository **if enabled** in its Security settings. If private reporting is not enabled, contact the maintainer privately through an established channel; do not publish sensitive details in a public issue. Do not assume that the presence of this policy means private reporting is currently active.

A useful report includes affected commit/version, impact, non-sensitive reproduction steps, expected versus actual behavior, and a suggested mitigation if known. Sanitize examples.

## Supported versions
There is no SpanDeck stable/security-supported release yet. Fork commits, branches, and prerelease builds are for development.

## Target security posture (planned, not currently guaranteed)
- Local-first data processing, minimal collection, no telemetry by default.
- No automatic credential extraction, raw prompt capture, or login-item setup. *Done for the Claude Keychain read and the login item (#15) and for Grok credentials and `grok models` (#17).*
- Opt-in instrumentation that does not silently overwrite user configuration.
- Measured data-retention limits and an explicit offboarding path.
- Source and artifact verification, security tests, Developer ID signing/notarization before public release.

See [the initial threat model](docs/THREAT_MODEL.md) and [roadmap](docs/ROADMAP.md).
