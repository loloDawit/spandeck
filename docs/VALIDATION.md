# Private-use validation (#94)

How each promise in [`PRIVATE_USE.md`](PRIVATE_USE.md) is verified, and what is left for the owner. Labels:
- **[test]**: an automated test on synthetic data and fakes; it runs in CI (`swift test --no-parallel`).
- **[runtime]**: observed in a running app, by the owner, in the `spandecktest` account.
- **[owner]**: needs the owner, a visible app, a real install or explicit consent. Listed in the checklist below.

An offscreen SwiftUI render proves that the view tree builds and lays out for a state. It doesn't prove drawing, animation or click-to-content time.

## 1. Scenario matrix
| Scenario | Automated evidence | Still needs |
|---|---|---|
| Fresh install, first launch | `AcceptanceTests.freshInstallWithNothingConfigured`, `LaunchPathTests.defaultLaunchSideEffects` [test]; default launch at `6e777c0` [runtime] ([Run 4](https://github.com/loloDawit/spandeck/issues/5#issuecomment-6243694333), audit 0009) | Run on the candidate [owner] |
| No configured integrations | the same; `GrokConsentTests`, `LaunchPathTests.forcedRefreshWithoutConsentReadsNothing` [test] | — |
| Existing cache | `AcceptanceTests.historyIsCountedOnceAcrossUpdatesRelaunchAndCorruptCache`, `LedgerCacheTests.relaunchKeepsIdsAndOffsets` [test] | — |
| Corrupt cache recovery | the same journey; `LedgerCacheTests.unusableCacheRebuilt`, `cacheWithOtherKeyRebuilt` [test] | — |
| Missing transcript directories | `AcceptanceTests.freshInstall…`, `TrustStateTests.noTranscriptFolderIsNotFound`, `folderRemovedAfterReading…` [test] | — |
| Offline operation | `AcceptanceTests.quotaIntegrationEnableOfflineAndRollBack`, `LaunchPathTests.offlineStartupUsesBundledPricing` [test] | — |
| Supported provider data | F01–F49 (`LedgerFixtureTests`), `UsageTests`, `GrokCounterCompletenessTests`, `AcceptanceTests.grokUsageWithoutCreditsConsent` [test] | Your real transcripts [owner, consent] |
| Unsupported provider data | `AcceptanceTests.unsupportedDataIsExplainedNotZeroed`, `CostCompletenessTests`, `DataCompletenessTests`, `ModelIdentifierTests` [test] | — |
| Incremental updates | the history journey, `RewriteTests`, `LedgerCacheTests.streamingGrowthCountedOnce` [test] | — |
| Background refresh | `ShutdownTests.realLedgerKeepsTheMainActorResponsive` [test]; #8 and #88 harnesses (main thread held ≤ a few ms) | In-app timings via diagnostics [owner] |
| Open and closed popover | `renderPopover` in the acceptance journeys (offscreen); #88 harness | Real `NSPopover`, drawing, click-to-content [owner] |
| Cancellation during indexing | `AcceptanceTests.quitDuringIndexingThenRelaunch`, `ShutdownTests` (F01–F49 under stops) [test] | Quit from the menu during a first index [owner] |
| Quit and relaunch | the history journey, `ShutdownTests.relaunchAfterAStopPrunesLikeAFullScan` [test] | [owner] |
| Permission denial | `TrustStateTests.unreadableTranscriptFolderIsReported`, `AcceptanceTests.deniedCredentialSendsNothing`, `LedgerCacheTests.unlistableFolder*` [test] | — |
| Integration enable / disable / rollback | `AcceptanceTests.quotaIntegrationEnableOfflineAndRollBack`, `LaunchPathTests.disablingClaudeLimitsClearsAndStops`, `GrokConsentTests`, `QuotaVisibilityTests` [test] | Consent-enabled paths against real endpoints are V16: unverified by owner rule |
| Diagnostics enabled / disabled | `DiagnosticsTests` (10) [test] | Start, stop and export in the app [owner] |
| No unexpected network or credential access | every journey asserts the transport's requests and credential reads; `LaunchPathTests.sideEffectsOnlyInLiveEnvironment`, `testsNeverUseLiveDependencies` [test]; Run 4 R4-C1 [runtime] ([report](https://github.com/loloDawit/spandeck/issues/5#issuecomment-6243694333)) | Run on the candidate [owner] |
| Stale or reset quota | `TrustStateTests` (F-3), `GrokErrorStateTests` [test] | — |
| Cache and file permissions | `LedgerCacheTests.ownerOnlyModes`, `BackupExclusionTests`, `DiagnosticsTests` (0600) [test]; Run 4 R4-P4a–f [runtime] | — |
| No sensitive data at rest | `PrivacyCanaryTests`, `LedgerCacheTests.cacheHoldsNoPathsIdsOrContent`, `DiagnosticsTests.exportCarriesNoContentPathOrIdentity` [test]; Run 4 R4-C2 [runtime] | — |

## 2. Owner validation checklist (one pass, in order)
The candidate is built by `scripts/package-candidate.sh` from the final `main` of #94 ([`INSTALL.md`](INSTALL.md)). Steps A–C use the `spandecktest` account with synthetic fixtures, as in Run 4. Step D is the personal-account decision.

**A. Default launch on the candidate** (`spandecktest`; `scripts/runtime-verify.sh`, runs 1–2 as in audit 0003 §8):
1. Install from the candidate DMG; check `shasum -a 256 -c SHA256SUMS` first.
2. Launch. Check: no Keychain prompt, no network connection, no login item, no `grok` process. Only `~/Library/Application Support/SpanDeck/` and the `io.github.lolodawit.SpanDeck` preferences are written.
3. With no `~/.claude/projects`, the usage card shows "No Claude Code transcripts found…", not 0 / $0.00.

**B. Everyday use** (`spandecktest`, synthetic transcripts):
1. Open and close the popover ten times. It should open promptly, with no visible hitch, and close cleanly.
2. Copy in a fixture transcript. Totals appear within about 10 s. Append a line, and the totals grow once.
3. Quit from the popover during the first index of a larger fixture. Quit should take at most about 5 s. Relaunch: the totals are exact.
4. Replace the cache with garbage while SpanDeck is quit, then relaunch. Totals are rebuilt.
5. Settings ▸ Start diagnostic session… Read the disclosure, start, use the app for a few minutes, quit, and relaunch. Then Settings ▸ Export diagnostics… Check that the JSON has `launch`, `firstUsage`, `popoverOpen`, `refresh`, `cacheSave` and `shutdown` events, and no paths or names. Finally Stop, then Delete.
6. VoiceOver over the usage notes and the limits card (#7 criterion).

**C. Integrations** (optional; consent-enabled paths are V16):
1. Turn launch at login on, then off. It should appear in, and disappear from, System Settings ▸ Login Items.
2. Claude plan limits and Grok credits stay off. Turning them on sends a real credential to a provider. Do that only if you decide to on the personal account (step D).

**D. Personal-account use (reserved decision):**
1. Decide whether to authorize SpanDeck on your main account. It is NO-GO until you say so (#5, #11).
   - SpanDeck never reads or changes `~/Library/Application Support/Headroom`.
   - It reads your Claude Code transcripts locally, and sends nothing anywhere unless you enable plan limits.
2. If authorized: install, launch, and compare the totals with your expectations for a day you know. Optionally run a diagnostics session for a day, and attach the export to #96 to decide U1–U3 (#88) and O1/O2 (#87).

Record results on #94: pass or fail per step, and the commit of the candidate.

## 3. Results
| Run | Candidate | Account | Result |
|---|---|---|---|
| — | — | — | pending (owner) |
