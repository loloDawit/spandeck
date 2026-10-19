# SpanDeck

**Secure, local-first observability for AI coding agents.**

SpanDeck aims to help engineers understand sessions, context usage, model and agent execution, tokens, and estimated cost — with explicit provenance and privacy controls.

> **Early-stage fork, not a released product.** SpanDeck is built on the inherited [Headroom](https://github.com/sandrich/headroom) menu-bar app. Since #11 it has its own macOS identity: `SpanDeck.app`, `io.github.lolodawit.SpanDeck`, `~/Library/Application Support/SpanDeck/`. It never touches Headroom's app or data. The Swift module is still named `Headroom` internally. There is no signed or notarized release. What a private-use build promises is in [`docs/PRIVATE_USE.md`](docs/PRIVATE_USE.md); how to build and install one is in [`docs/INSTALL.md`](docs/INSTALL.md). Do not mistake planned protections for implemented protections.

## Project direction

- **Local first:** normal use should not require a hosted service or external telemetry.
- **Explainable metrics:** distinguish observed tokens, provider-reported quotas, estimated API-equivalent prices and actual bills.
- **Context and session transparency:** explore model sessions, agent activity, tool invocations, compaction and cache behavior where supported data exists.
- **Consent and least privilege:** no unsolicited credential retrieval, autostart, remote upload, or mutation of Claude configuration in the target design.
- **Evidence-backed optimization:** diagnostics before automatic intervention.

See [product charter](docs/PRODUCT.md), [architecture](docs/ARCHITECTURE.md), [threat model](docs/THREAT_MODEL.md) and [roadmap](docs/ROADMAP.md).

## What is available today

This fork initially inherits Headroom v1.1's implementation, including:
- Native macOS menu bar and dashboard for CPU, GPU, memory and battery.
- Claude Code subscription usage gauges and reset times where the unofficial endpoint responds.
- Local transcript-derived token summaries and model-cost estimates.
- Optional Grok usage and a keep-awake feature.

Added in SpanDeck: missing or unreadable transcript folders are explained, not shown as zero, and a quota whose window has reset isn't shown as current (#95). There is also an opt-in local diagnostics session ([`docs/DIAGNOSTICS.md`](docs/DIAGNOSTICS.md)).

**Inherited security notice:** The current code reads local Claude and Grok usage files. Cost estimates use a reviewed LiteLLM price snapshot built into the app (one pinned commit, checksum-verified): prices are **never downloaded at launch**, and the only price download is one you start, of that same pinned file, if the built-in prices fail verification (#27). Costs are estimates at list prices, not your Anthropic bill. Usage without a known price is never counted as $0: totals show `≥$x` (known part only, rounded down) or `n/a`. Grok amounts are as reported by the Grok CLI, and a Grok turn with no reported cost is unknown, not $0 (#30). Credential-based plan data is **off until you enable it** in the app: the Claude Code OAuth credential from macOS Keychain (Anthropic's unofficial usage endpoint, #15), and the Grok CLI key plus `grok models` refresh (Grok's billing endpoint, #17). Hiding a provider's plan gauge in Settings pauses its quota polling until you show it again; token usage is still counted (#19). Once Grok credits are enabled, a failed refresh is shown with its cause (sign-in, access, endpoint or temporary error) instead of hiding Grok (#21). Both plan-data integrations are **unofficial**: requests identify themselves as `SpanDeck (unofficial quota monitor)` rather than as Claude Code or the Grok CLI, and either may stop working if a provider enforces client identity or changes its endpoint. A rejected sign-in (HTTP 401) pauses that provider's polling (Claude 5 min, Grok 10 min after its recovery attempt) instead of resending the credential every minute (#24). Launch at login is **only enabled from Settings** (#15). The local usage cache stores no transcript paths, message ids or content (opaque keyed ids), is stored with owner-only file permissions, and can be cleared from Settings without touching transcripts (#33, [details](docs/USAGE_CACHE.md)). What still differs from the target posture is listed in [`docs/PRIVATE_USE.md`](docs/PRIVATE_USE.md) §4–§5 and the [threat model](docs/THREAT_MODEL.md). Do not install on an enterprise-managed machine without appropriate approval. See [SECURITY.md](SECURITY.md).

## Development baseline

Requirements: macOS 14+, Swift 5.9+ and a compatible Apple developer toolchain.

```bash
git clone https://github.com/loloDawit/spandeck.git
cd spandeck
git remote add upstream https://github.com/sandrich/headroom.git
swift test
swift build
```

Those commands compile and test; they **do not install or launch** the application. Since #11 the app is `SpanDeck.app` (`io.github.lolodawit.SpanDeck`, `~/Library/Application Support/SpanDeck/`), separate from upstream Headroom's identity and data. The Swift module and target are still named `Headroom` internally. `./build.sh install` replaces only `/Applications/SpanDeck.app` and never touches Headroom. Using SpanDeck on an account with real history needs the owner's authorization (#94; [`docs/VALIDATION.md`](docs/VALIDATION.md)).

Current CI: [Swift tests](.github/workflows/test.yml), carried forward from Headroom and hardened in R11. It runs on every pull request and every push to `main`, serially on `macos-15` (#46). Merging needs a green `test` check (ruleset since 2026-10-18). CI runs the mocked test suite only. It doesn't verify the app on a real Mac, and nothing is signed or notarized ([roadmap](docs/ROADMAP.md#release-blockers)).

## Working with Claude Code

[CLAUDE.md](CLAUDE.md) documents the development contract, safety and privacy constraints, review workflow, and milestone priorities. The initial objective is **M0 — baseline and threat-driven tests**, not a large rewrite.

## Upstream and attribution

SpanDeck is a fork of [sandrich/headroom](https://github.com/sandrich/headroom). The initial implementation, hardware monitoring, menu-bar design and baseline usage ledger are inherited from Headroom contributors. The original [MIT license and copyright](LICENSE) are preserved. Built-in model prices are extracted from [LiteLLM](https://github.com/BerriAI/litellm)'s `model_prices_and_context_window.json` (MIT License, Copyright (c) 2023 Berri AI); the exact commit and checksums are in `Sources/Headroom/PricingSnapshot.swift`, regenerated with `scripts/update-pricing-snapshot.py`. Future changes will retain their applicable notices.

For upstream's original features and installation instructions, consult [Headroom's README](https://github.com/sandrich/headroom#readme). Upstream release binaries are not SpanDeck releases.
