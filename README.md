# SpanDeck

**Secure, local-first observability for AI coding agents.**

SpanDeck aims to help engineers understand sessions, context usage, model and agent execution, tokens, and estimated cost — with explicit provenance and privacy controls.

> **Early-stage fork, not a completed product.** SpanDeck currently contains the inherited [Headroom](https://github.com/sandrich/headroom) macOS menu-bar implementation. The runtime app, binary, icons, cache paths, and existing integrations have not yet been rebranded or hardened. These changes are tracked in the [roadmap](docs/ROADMAP.md). Do not mistake planned protections for implemented protections.

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

**Inherited security notice:** The current code reads local Claude and Grok usage files and downloads LiteLLM pricing. Credential-based plan data is **off until you enable it** in the app: the Claude Code OAuth credential from macOS Keychain (Anthropic's unofficial usage endpoint, #15), and the Grok CLI key plus `grok models` refresh (Grok's billing endpoint, #17). Hiding a provider's plan gauge in Settings pauses its quota polling until you show it again; token usage is still counted (#19). Launch at login is **only enabled from Settings** (#15). The remaining behaviors are inherited from Headroom and are not yet the desired SpanDeck security posture. Do not install on an enterprise-managed machine without appropriate approval. See [SECURITY.md](SECURITY.md).

## Development baseline

Requirements: macOS 14+, Swift 5.9+ and a compatible Apple developer toolchain.

```bash
git clone https://github.com/loloDawit/spandeck.git
cd spandeck
git remote add upstream https://github.com/sandrich/headroom.git
swift test
swift build
```

Those commands compile and test; they **do not install or launch** the application. The current build target is still named `Headroom`. Avoid the original `./build.sh install` until inherited permissions, credentials and auto-start behavior are audited.

Current CI: [Swift tests](.github/workflows/test.yml), carried forward from Headroom. Build and test passing have not been independently verified for the SpanDeck fork.

## Working with Claude Code

[CLAUDE.md](CLAUDE.md) documents the development contract, safety and privacy constraints, review workflow, and milestone priorities. The initial objective is **M0 — baseline and threat-driven tests**, not a large rewrite.

## Upstream and attribution

SpanDeck is a fork of [sandrich/headroom](https://github.com/sandrich/headroom). The initial implementation, hardware monitoring, menu-bar design and baseline usage ledger are inherited from Headroom contributors. The original [MIT license and copyright](LICENSE) are preserved. Future changes will retain their applicable notices.

For upstream's original features and installation instructions, consult [Headroom's README](https://github.com/sandrich/headroom#readme). Upstream release binaries are not SpanDeck releases.
