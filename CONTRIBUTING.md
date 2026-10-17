# Contributing to SpanDeck

SpanDeck is a fork of [sandrich/headroom](https://github.com/sandrich/headroom), licensed under MIT. Preserve upstream copyright and attribution.

## Development workflow
1. Read [product charter](docs/PRODUCT.md), [architecture](docs/ARCHITECTURE.md), and [threat model](docs/THREAT_MODEL.md).
2. Open or select an issue, and check its status and owner in the [project](docs/PROJECT_MANAGEMENT.md). Describe behavior, data-source assumptions, risk, and acceptance criteria. Give the issue and your PR the matching milestone (`M0`–`M4`).
3. Branch from `main` with a descriptive topic name. Do not implement unrelated changes in one PR.
4. Run `swift test` and `swift build` on macOS 14+ with appropriate Swift/Xcode toolchain. Record any unavailable checks honestly.
   CI runs `swift test --no-parallel` on a 3-core runner. On a Mac with more cores, `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test` (one-thread pool) shows failures that only appear when cores are scarce.
   For screenshots, a debug build renders synthetic data only: `swift run SpanDeck --snapshot <existing folder>` writes `strip-light.png`, `strip-dark.png` and `popover.png`, then exits without starting the app. Release builds refuse `--snapshot` (R10, #36).
5. Describe evidence for changed accounting semantics and attach synthetic fixture coverage.
6. Submit a PR; do not merge with failing checks or unresolved credential/privacy risks.

## Safety rules
- Do not commit tokens, authentication files, local transcripts, private repository names, internal hostnames, or personally identifying analytics.
- Use fabricated, small fixtures with controlled timestamps, request IDs, cache fields and costs.
- No new external endpoint, permission, auto-start, local server, CLI subprocess or data-collection source without threat-model and documentation updates.
- No direct modifications to a user's Claude settings, hooks or status line without preview, opt-in, backup and rollback.
- Keep unknown/missing metrics distinct from true zeros.
- Test streaming-record deduplication, source overlap, stale data, partial data, network failures and malformed responses where relevant.

## Pull-request expectations
Include intent, linked issue, data-flow and privacy impact, screenshots for UI changes, validation results, migration/rollback notes and limitations. Be precise about what was not tested.

## Syncing upstream
Use an `upstream` remote and review upstream changes before merging them. Upstream fixes can be proposed independently. Do not auto-merge changes that alter credentials, network access or transcript collection.
