# Installing a private-use candidate (#94)

This is for the owner's own Mac. A candidate is a **local, ad-hoc-signed build**: it isn't Developer ID signed or notarized, and it isn't a release ([`RELEASE_SIGNING.md`](RELEASE_SIGNING.md)). **Never** bypass Gatekeeper to run one: no "Open Anyway", no `xattr -d com.apple.quarantine`, no `spctl --master-disable`. Build it on the Mac that will run it; a local build carries no quarantine attribute.

## Requirements
- macOS 14 or later, on Apple Silicon or Intel. The binary is universal, with a minimum of 14.0 on both slices. It has only been run on macOS 26.5 on Apple Silicon.
- To build: Xcode 16.4 or later (CI uses 16.4; the reference build used 26.6).

## Build a candidate
```bash
git switch main && git pull --ff-only
scripts/package-candidate.sh        # serial tests, universal build, DMG, provenance
```
The output is `build/candidate/<commit>/`:
- `SpanDeck-<version>.dmg`;
- `PROVENANCE.txt`: the commit, architectures, minimum macOS, signature, test result, toolchain and SHA-256;
- `SHA256SUMS`.

To check the DMG:
```bash
cd build/candidate/<commit> && shasum -a 256 -c SHA256SUMS
```

## Install
1. If SpanDeck is running, quit it from its popover (**Quit**). This lets it save its usage index (#86).
2. Open the DMG and drag `SpanDeck.app` to `/Applications`, replacing any older SpanDeck.

   Or use `scripts/install-app.sh build/SpanDeck.app`. It refuses to replace anything but SpanDeck's bundle id, and never touches Headroom. It ends a running SpanDeck with a signal rather than Quit: that's safe, since the previous index is kept and re-read, but Quit first is better.
3. Open SpanDeck from `/Applications`. It appears in the menu bar. No Dock icon.

**First launch:**
- No Keychain read, no network request and no login item.
- Usage is indexed from the local transcripts; the footer shows progress.
- Plan limits, Grok credits, launch at login and diagnostics stay off until you turn them on.

## Upgrade
- Quit, replace the app, and open it again.
- **The usage index (`claude-ledger.json`, cache v7)** is kept when the new build uses the same format. If the format changed, the old index is discarded and rebuilt from the transcripts.
- **Usage whose transcripts no longer exist** can't be rebuilt. Claude Code removes transcripts after about 30 days by default ([`USAGE_CACHE.md`](USAGE_CACHE.md)).
- **Settings** carry over (preferences domain `io.github.lolodawit.SpanDeck`).

## Roll back
1. Keep the previous candidate's DMG, and check it against its `SHA256SUMS`.
2. Quit SpanDeck and replace the app with the older one.
3. An older build that doesn't recognize the index discards it and rebuilds. It never misreads it. Only usage whose transcripts are gone is lost.

## Uninstall
1. In SpanDeck: turn off **Launch at login** (Settings) if you turned it on. Turn off **Claude plan limits** and **Grok credits** if they're on, then **Quit**.
2. Delete `/Applications/SpanDeck.app`.
3. Remove SpanDeck's data. Only these exist:
   ```bash
   rm -rf "$HOME/Library/Application Support/SpanDeck"   # usage index, its key, prices, diagnostics
   defaults delete io.github.lolodawit.SpanDeck           # SpanDeck's settings
   ```
   - SpanDeck stores nothing in the Keychain.
   - It writes no log file in release builds. A few one-line messages (for example a login-item change that failed) go to the system log, with no path, id or usage data.
   - It never changes Claude Code's or Grok's files. When enabled, `grok models` may update the Grok CLI's own files.
4. If you skipped step 1, open System Settings ▸ General ▸ Login Items and remove SpanDeck.

**Not touched:** an upstream Headroom install, `~/Library/Application Support/Headroom`, and the `dev.headroom.Headroom` preferences (#11, audit 0008).
