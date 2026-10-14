# Architecture

Status: current-source inventory plus proposed target; no refactor has happened yet.

## Present fork baseline (Headroom v1.1)
- `Sources/Headroom/main.swift`: lifecycle, menu bar, timers.
- `Dependencies.swift`, `ProviderServices.swift`: injectable Keychain/network/process/login-item/preferences seams (#12) and the launch path, including the Claude plan-limits consent (#15) and the menu-bar switches that pause quota polling (#19).
- `Clients.swift`: Claude OAuth Keychain read (opt-in); unofficial usage endpoint; Grok token/file integration (opt-in, #17).
- `Ledger.swift`: local Claude JSONL/Grok usage scanning, deduplication, price lookup, disk cache.
- `Store.swift`, `StatusRenderer.swift`, `PopoverView.swift`, `Hover.swift`: state and UI.
- `SystemSampler.swift`, `Consumers.swift`: hardware and per-process metrics.
- `KeepAwake.swift`: idle-sleep prevention.
- `Tests/HeadroomTests`: existing test suite; GitHub Actions runs `swift test`.

Important: the current code reads local Claude and Grok usage files and downloads LiteLLM pricing. Only after the user opts in per provider does it obtain a Claude bearer token from login Keychain and call Anthropic's unofficial usage endpoint (#15), or read the Grok CLI key, call Grok's billing endpoint and possibly run `grok models` (#17). Quota polling also stops while that provider's menu-bar gauge is hidden (#19); local usage files are read either way. Launch at login is only enabled from Settings. See `docs/THREAT_MODEL.md`.

## Target boundaries (proposal)
```text
Claude Code / future provider
       |
       +-- supported telemetry + optional status-line integration
       +-- read-only transcript / local usage import
       +-- optional quota connector (explicit consent and capability labels)
       v
Source adapters -> validation / redaction -> normalization
                                             |
                                   identity / reconciliation
                                             |
                                       local store
                                             |
                                  query & analytics layer
                                             |
                           native menu bar + session explorer
```

### Responsibilities
- **Adapters** preserve source identity and timestamps; they do not silently reinterpret missing data.
- **Normalization** maps records to canonical model, session, request, and tool event representations with source confidence.
- **Reconciliation** merges overlapping observations by identity and deterministic precedence rules, including late/streaming updates.
- **Local store** keeps only a minimal metric/event index by default; raw inputs remain at their original paths.
- **UI** presents observed vs estimated vs unavailable measures distinctly; never represents local estimates as authoritative plan quotas.

## Design constraints
- Begin in-process in Swift unless measured performance or permission boundaries justify a separate collector.
- No hosted backend or cloud account required for normal use.
- Avoid localhost HTTP servers when direct in-process or protected IPC is sufficient.
- Maintain migration compatibility and opt-out/offboarding for collected local data.
- Installation of status-line hooks or telemetry changes requires preview, backup, consent, and full rollback.
- Release provenance, code signing, and notarization precede production distribution.
- Keep original Headroom files and license until behavior has been replaced and tested.

## First decisions to write as ADRs
1. Canonical event identity and deduplication precedence across JSONL/telemetry/status.
2. Supported versus unofficial quota retrieval and safe credentials policy.
3. Local storage format, retention, deletion, and schema migration.
4. Instrumentation lifecycle and collision-safe integration with existing user settings.
5. Enterprise and Bedrock coverage, authorization, provenance, and actual-cost boundaries.

No source compatibility with unreleased upstream Bedrock changes is assumed.
