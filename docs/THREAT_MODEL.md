# Threat model (initial)

Status: preliminary audit from source inspection; no runtime, binary, dependency or penetration audit has been completed.

Line-level inventory of credentials, file access, subprocesses, egress and launch side effects: [audits/0003-security-inventory.md](audits/0003-security-inventory.md) (issue #3).

## Assets and trust boundaries
Assets: Claude OAuth bearer tokens; local prompts, source code, filenames and tool outputs in transcripts; usage histories; optional provider credentials; workstation resources and settings.

Boundaries:
1. macOS process -> login Keychain, through `/usr/bin/security`.
2. Process -> `~/.claude/projects`, `~/.config/claude/projects`, and Grok local files.
3. Process -> external provider endpoints and, only on an explicit user download, the pinned GitHub-hosted LiteLLM price file (#27).
4. Process -> `~/Library/Application Support/Headroom` cached usage records.
5. Process -> ServiceManagement login-item registration.
6. Proposed future telemetry -> local adapter/store/UI.

## Current risks and intended mitigations
| Risk | Source behavior | Proposed mitigation |
| --- | --- | --- |
| Credential exposure | `Clients.swift` extracts a Claude OAuth token from Keychain and calls an unofficial usage API; Grok key read from `~/.grok/auth.json` | **Claude: off by default with inline consent (#15). Grok: off by default with consent; no `grok models` exec without it (#17). Hiding a provider's menu-bar gauge pauses its quota polling; showing it resumes only under existing consent (#19). Requests use SpanDeck's own User-Agent, and a 401 pauses that provider instead of resending the credential (#24).** Define a supported capability before any alternative credential path |
| Secret-rich raw input | `Ledger.swift` parses session JSONL records containing potentially sensitive material | Persist only allowlisted derived metrics. Add tests asserting prompts, code and tool bodies never enter logs/cache |
| Surprising persistence | Inherited: login item registered on initial launch | **Done (#15):** never registered automatically; enabled/disabled only from Settings; existing registrations untouched |
| Accidental exfiltration | Provider HTTPS calls; LiteLLM prices are built in, with only a user-started, pinned, checksum-verified download (#27) | Egress inventory/allowlist; no telemetry; privacy tests |
| Wrong or inflated numbers | Late streaming records, missing request IDs, overlap across adapters, unknown prices | Provenance and stable identity, fixture coverage, distinguish unknown from zero |
| Supply-chain tampering | New upstream source, release DMG not yet Developer ID notarized | Pin reviewed commits, audit CI/dependencies, sign/notarize and verify releases |
| Local disclosure | Usage history/cache and backups accessible to local account/processes | Data minimization, permissions, retention/deletion, avoid storing identifiers where not required |
| Instrumentation conflicts | Proposed future hooks or status-line changes could overwrite user settings | Never mutate silently; backup, consent, merge semantics, reversible uninstall |
| Excessive resource use | Frequent timers and long session files | Measure and budget scan CPU/memory, bounded indexing/retention, cancellation |

## Safeguards that are NOT yet implemented
- Threat-driven tests, network isolation, data-retention controls, consent-gated credentials, hardened release signing.
- Verified support for enterprise/Bedrock usage, or authoritative quota reporting for all Claude account types.

## Verification plan
- Review each executable and network call; map request headers and response handling without exposing secrets.
- Inspect actual cache output with seeded synthetic transcripts containing canary secrets; assert absence from persisted artifacts and logs.
- Inject streaming duplicates and malformed/partial transcript records.
- Exercise locked/denied Keychain, expired credentials, offline mode, and provider 429/401.
- Confirm default launch causes no login-item mutation. *Covered by mocked tests in #15; OS-level confirmation pending.*
- Use OS network/process observation to compare with the documented egress list.
- Review permissions, CI, artifacts, SBOM/dependencies and reproducibility before recommending installation.

## Privacy commitments (target state)
Local-only by default. Collect only the metadata needed for selected metrics. No raw prompts, source code, tool arguments/results or API responses by default. No remote telemetry without clear opt-in. Explicit retention and deletion controls. Always disclose source/coverage gaps.
