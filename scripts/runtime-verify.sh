#!/bin/bash
# Runtime verification helper for #3 (audit §7 Phase 2). See docs/audits/0003-runtime-verification.md, and
# docs/audits/0008-identity-isolation.md for the #11 coexistence run.
#
# Observes a real SpanDeck process in a dedicated, credential-free macOS account. It never reads credentials, never
# creates Keychain items or provider keys, never sends anything anywhere, and needs no admin rights. SpanDeck's names
# come from identity.env (#11). Upstream Headroom's names appear only as LEGACY_* below: observed, and launched only by
# legacy-launch from a build staged with stage-legacy.
#
#   In your normal account (builds only, launches nothing):
#     scripts/runtime-verify.sh stage            build release + debug from a clean checkout, copy to /Users/Shared
#     scripts/runtime-verify.sh stage-legacy SHA build an older, Headroom-identity commit for the #11 coexistence run
#   In the dedicated test account, in this order:
#     scripts/runtime-verify.sh preflight        safety gate; refuses to continue in an unsafe account
#     scripts/runtime-verify.sh fixtures [N]     synthetic transcripts with canaries (+ N extra files for timing)
#     scripts/runtime-verify.sh identity         after fixtures: add records with one id or none (#55 identity note)
#     scripts/runtime-verify.sh completeness     after fixtures: add records that can't be read (#58 completeness note)
#     scripts/runtime-verify.sh privacy          after fixtures: add a session with every sensitive field kind (#5)
#     scripts/runtime-verify.sh capture LABEL    record files, modes, preferences, assertions, canary hits
#     scripts/runtime-verify.sh launch SECONDS [LABEL]  launch the app normally; watch processes, sockets, logs
#     scripts/runtime-verify.sh quit             wait for you to quit the app from its menu
#     scripts/runtime-verify.sh snapshot         --snapshot in the release app (must refuse) and the debug binary
#     scripts/runtime-verify.sh summary          write a sanitized summary to /Users/Shared/spandeck-rv-results
#     scripts/runtime-verify.sh clean            remove SpanDeck's state and the fixtures (keeps evidence and legacy state)
#   #11 coexistence (docs/audits/0008-identity-isolation.md):
#     scripts/runtime-verify.sh legacy-launch SECONDS [LABEL]  launch the staged legacy (Headroom-identity) build
#     scripts/runtime-verify.sh quit-legacy      wait for you to quit the legacy app from its menu
#     scripts/runtime-verify.sh fingerprint LABEL  names, modes, sizes, hashes of both apps' files and preferences
#     scripts/runtime-verify.sh compare A B      which app's state changed between two fingerprints
#     scripts/runtime-verify.sh seed-legacy-consent / unseed-legacy-consent  set or remove Headroom-domain consent
#     scripts/runtime-verify.sh clean-legacy     remove the test account's legacy state (asks first)
#
# Evidence goes to ~/spandeck-rv-evidence/<run>/. It holds file names, modes, counts and pass/fail lines only:
# no transcript content, no preference values other than booleans and numbers, no network payloads.
set -euo pipefail

RV_USER=${RV_USER:-spandecktest}
SHARED=${RV_SHARED:-/Users/Shared/spandeck-rv}
# Written by the test account (the stage folder belongs to the build account); readable by the build account.
RESULTS=${RV_RESULTS:-/Users/Shared/spandeck-rv-results}
EVIDENCE_ROOT="$HOME/spandeck-rv-evidence"
FIXTURE_MARK=".spandeck-rv-fixtures"
REPO=$(cd "$(dirname "$0")/.." && pwd)
# SpanDeck's identity (#11): the staged copy next to this script, else the checkout's.
if [ -f "$(dirname "$0")/identity.env" ]; then ID_FILE="$(dirname "$0")/identity.env"; else ID_FILE="$REPO/Resources/identity.env"; fi
# shellcheck source=../Resources/identity.env
. "$ID_FILE"
APP_SUPPORT="$HOME/Library/Application Support/$APP_SUPPORT_DIR"
# legacy: upstream Headroom's identity, which SpanDeck builds before #11 shared. Observed only.
LEGACY_NAME=Headroom
LEGACY_BUNDLE_ID=dev.headroom.Headroom
LEGACY_SUPPORT="$HOME/Library/Application Support/Headroom"
LEGACY_LOG="$HOME/Library/Logs/Headroom-hover.log"

die() { echo "STOP: $*" >&2; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }

run_dir() {
    [ -f "$EVIDENCE_ROOT/current" ] || die "no run started; run preflight first"
    cat "$EVIDENCE_ROOT/current"
}
# Commands that write fixtures or start the app only run after a preflight that passed.
gate() {
    [ "$(id -un)" = "$RV_USER" ] || die "running as $(id -un), not $RV_USER"
    [ -f "$(run_dir)/.preflight-ok" ] || die "the last preflight did not pass; nothing is launched"
}
staged() {
    [ -f "$SHARED/current" ] || die "nothing staged; run 'stage' in the build account first"
    cat "$SHARED/current"
}
record() { echo "$(now) $*" | tee -a "$(run_dir)/log.txt"; }

app_pid() { pgrep -x "$APP_NAME" 2>/dev/null | head -1 || true; }
legacy_pid() { pgrep -x "$LEGACY_NAME" 2>/dev/null | head -1 || true; }
legacy_staged() {
    [ -f "$SHARED/legacy-current" ] || die "no legacy build staged; run 'stage-legacy SHA' in the build account first"
    cat "$SHARED/legacy-current"
}

# Fixture registry (#11 review of Run 3): the marker records the run that created the fixtures and each file it wrote.
# A new run refuses fixtures it didn't register; later steps of the same run may add theirs.
fixture_run() { sed -n 's/^run=//p' "$HOME/.claude/projects/$FIXTURE_MARK" 2>/dev/null | head -1; }
register_fixture() { # path relative to ~/.claude/projects
    [ "$(fixture_run)" = "$(basename "$(run_dir)")" ] || die "the fixtures belong to run $(fixture_run), not this one"
    echo "file=$1" >> "$HOME/.claude/projects/$FIXTURE_MARK"
}
# Transcript files under ~/.claude/projects the current run didn't register: names only.
unregistered_fixtures() {
    local projects="$HOME/.claude/projects"
    [ -d "$projects" ] || return 0
    local mine=""; [ "$(fixture_run)" = "$(basename "$(run_dir)")" ] && mine=yes
    (cd "$projects" && find . -name '*.jsonl' -type f | sed 's|^\./||' | sort) | while read -r f; do
        if [ -z "$mine" ] || ! grep -qxF "file=$f" "$projects/$FIXTURE_MARK"; then echo "$f"; fi
    done
}

# Files in the home folder changed since preflight. Skips folders macOS protects with privacy prompts (TCC), the
# evidence and the fixtures; those are never the app's to write.
changed_files() {
    local start=$1
    find "$HOME" \( -path "$EVIDENCE_ROOT" -o -path "$HOME/.claude/projects" -o -path "$HOME/.Trash" \
        -o -path "$HOME/Desktop" -o -path "$HOME/Documents" -o -path "$HOME/Downloads" -o -path "$HOME/Pictures" \
        -o -path "$HOME/Movies" -o -path "$HOME/Music" -o -path "$HOME/Public" \
        -o -path "$HOME/Library/Containers" -o -path "$HOME/Library/Group Containers" -o -path "$HOME/Library/Mail" \
        -o -path "$HOME/Library/Messages" -o -path "$HOME/Library/Safari" -o -path "$HOME/Library/Calendars" \
        -o -path "$HOME/Library/Cookies" -o -path "$HOME/Library/Biome" -o -path "$HOME/Library/Suggestions" \
        -o -path "$HOME/Library/Application Support/com.apple.TCC" -o -path "$HOME/Library/Application Support/AddressBook" \
        -o -path "$HOME/Library/Application Support/CallHistoryDB" -o -path "$HOME/Library/Application Support/Knowledge" \
        -o -path "$HOME/Library/Metadata" -o -path "$HOME/Library/Trial" \) -prune -o -type f -newer "$start" -print 2>/dev/null || true
    find "$(getconf DARWIN_USER_TEMP_DIR)" "$(getconf DARWIN_USER_CACHE_DIR)" -type f -newer "$start" -print 2>/dev/null || true
}

# ---------------------------------------------------------------------------------------------------------------
cmd_stage() {
    cd "$REPO"
    [ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes; stage builds a recorded commit only"
    local sha; sha=$(git rev-parse HEAD)
    ./build.sh
    swift build --product "$APP_NAME"
    local dest="$SHARED/$sha"
    mkdir -p "$dest"
    rm -rf "$dest/$APP_NAME.app"
    cp -R "build/$APP_NAME.app" "$dest/"
    [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$dest/$APP_NAME.app/Contents/Info.plist")" = "$BUNDLE_ID" ] \
        || die "the built app isn't $BUNDLE_ID"
    cp ".build/debug/$APP_NAME" "$dest/$APP_NAME-debug"
    clang -Wall -Wextra -O2 -o "$dest/procwatch" scripts/runtime/procwatch.c
    cp scripts/runtime-verify.sh "$dest/runtime-verify.sh"
    cp Resources/identity.env "$dest/identity.env"
    chmod -R a+rX "$SHARED"
    {
        echo "commit: $sha"
        echo "staged: $(now)"
        echo "release: ./build.sh (swift build -c release, universal, ad-hoc signed)"
        echo "debug: swift build (debug, $(uname -m))"
        echo "swift: $(swift --version 2>&1 | head -1)"
        echo "xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
        echo "macos: $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
        echo "identity: $APP_NAME, $BUNDLE_ID, Application Support/$APP_SUPPORT_DIR"
        echo "release archs: $(lipo -archs "$dest/$APP_NAME.app/Contents/MacOS/$APP_NAME")"
        echo "release sha256: $(shasum -a 256 "$dest/$APP_NAME.app/Contents/MacOS/$APP_NAME" | cut -d' ' -f1)"
        echo "debug sha256: $(shasum -a 256 "$dest/$APP_NAME-debug" | cut -d' ' -f1)"
        echo "procwatch sha256: $(shasum -a 256 "$dest/procwatch" | cut -d' ' -f1) (scripts/runtime/procwatch.c)"
        echo "signature: $(codesign -dv "$dest/$APP_NAME.app" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier|CodeDirectory)' | tr '\n' ' ')"
    } > "$dest/manifest.txt"
    echo "$sha" > "$SHARED/current"
    cat "$dest/manifest.txt"
    echo "Staged in $dest. Nothing was launched."
}

# #11: builds an older commit that still has upstream Headroom's identity (for example 226a7d6) in a temporary
# worktree with that commit's own build.sh, for the coexistence run. Launches nothing.
cmd_stage_legacy() {
    cd "$REPO"
    local want=${1:?stage-legacy SHA}
    local sha; sha=$(git rev-parse --verify "$want^{commit}") || die "unknown commit $want"
    local wt; wt=$(mktemp -d "${TMPDIR:-/tmp}/spandeck-legacy.XXXXXX")
    git worktree add --detach "$wt" "$sha" >/dev/null
    (cd "$wt" && ./build.sh) || { git worktree remove --force "$wt"; die "legacy build failed"; }
    local app="$wt/build/$LEGACY_NAME.app"
    [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" = "$LEGACY_BUNDLE_ID" ] \
        || { git worktree remove --force "$wt"; die "$sha doesn't build $LEGACY_BUNDLE_ID"; }
    local dest="$SHARED/legacy-$sha"
    mkdir -p "$dest"; rm -rf "$dest/$LEGACY_NAME.app"; cp -R "$app" "$dest/"
    git worktree remove --force "$wt"
    chmod -R a+rX "$SHARED"
    {
        echo "legacy commit: $sha"
        echo "staged: $(now)"
        echo "identity: $LEGACY_NAME, $LEGACY_BUNDLE_ID, Application Support/Headroom"
        echo "release sha256: $(shasum -a 256 "$dest/$LEGACY_NAME.app/Contents/MacOS/$LEGACY_NAME" | cut -d' ' -f1)"
    } > "$dest/manifest.txt"
    echo "$sha" > "$SHARED/legacy-current"
    cat "$dest/manifest.txt"
    echo "Staged the legacy build in $dest. Nothing was launched."
}

# ---------------------------------------------------------------------------------------------------------------
cmd_preflight() {
    # Identity first: everything after this only runs in the dedicated account.
    [ "$(id -un)" = "$RV_USER" ] || die "running as $(id -un), not $RV_USER. Do not run the app in this account."
    if dsmemberutil checkmembership -U "$RV_USER" -G admin | grep -q "is a member"; then
        die "$RV_USER is an administrator; use a Standard account"
    fi
    local home; home=$(dscl . -read "/Users/$RV_USER" NFSHomeDirectory | awk '{print $2}')
    [ "$HOME" = "$home" ] || die "HOME ($HOME) differs from the account's home ($home); Foundation uses the account's"

    local run; run="$EVIDENCE_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$run"; chmod 700 "$EVIDENCE_ROOT" "$run"
    echo "$run" > "$EVIDENCE_ROOT/current"
    touch "$run/.start"
    local sha; sha=$(staged)
    local fail=0
    check() { # check "description" command...  (command succeeding = safe)
        local what=$1; shift
        if "$@"; then record "PASS preflight: $what"; else record "FAIL preflight: $what"; fail=1; fi
    }
    absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
    no_claude_item() { ! security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; } # attributes only, never -w
    no_running() { [ -z "$(app_pid)" ]; }
    # A new run starts without transcripts: any left by an earlier run (registered to it or not) fails the
    # preflight, listed by name and never deleted here (`clean` is the explicit way).
    no_old_fixtures() { [ -z "$(unregistered_fixtures)" ]; }
    manifest_ok() {
        local want; want=$(awk '/^release sha256:/{print $3}' "$SHARED/$sha/manifest.txt")
        [ "$want" = "$(shasum -a 256 "$SHARED/$sha/$APP_NAME.app/Contents/MacOS/$APP_NAME" | cut -d' ' -f1)" ]
    }
    # Whether any preference is stored, not whether the file exists: after `defaults delete`, cfprefsd can leave an
    # empty plist behind.
    no_prefs() { ! defaults read "$BUNDLE_ID" >/dev/null 2>&1; }
    not_quarantined() { ! xattr -r "$SHARED/$sha/$APP_NAME.app" 2>/dev/null | grep -q com.apple.quarantine; }
    staged_identity() { [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SHARED/$sha/$APP_NAME.app/Contents/Info.plist")" = "$BUNDLE_ID" ]; }

    record "account $(id -un) uid $(id -u), home $HOME, groups: $(id -Gn)"
    record "machine: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
    record "MDM: $(profiles status -type enrollment 2>&1 | tr '\n' ' ')"
    record "build under test: $sha"
    check "no Claude Code Keychain item (attribute lookup only)" no_claude_item
    check "no ~/.claude/.credentials.json" absent "$HOME/.claude/.credentials.json"
    check "no ~/.grok/auth.json" absent "$HOME/.grok/auth.json"
    check "no ~/.grok/bin/grok" absent "$HOME/.grok/bin/grok"
    check "no ~/.config/claude/projects" absent "$HOME/.config/claude/projects"
    # shellcheck disable=SC2088 # a literal ~ in the message
    check "~/.claude/projects holds no transcripts from an earlier run" no_old_fixtures
    [ -z "$(unregistered_fixtures)" ] || record "leftover transcripts (names only, not deleted): $(unregistered_fixtures | tr '\n' ' ')(registered by run: $(fixture_run))"
    check "no $APP_NAME process running" no_running
    check "no /Applications/$APP_NAME.app" absent "/Applications/$APP_NAME.app"
    check "no ~/Applications/$APP_NAME.app" absent "$HOME/Applications/$APP_NAME.app"
    check "fresh: no ~/Library/Application Support/$APP_SUPPORT_DIR" absent "$APP_SUPPORT"
    check "fresh: no preferences stored for $BUNDLE_ID" no_prefs
    check "staged app is $BUNDLE_ID" staged_identity
    check "staged app matches its manifest hash" manifest_ok
    check "staged app has no quarantine attribute (no Gatekeeper bypass needed)" not_quarantined
    # Legacy (Headroom) state is recorded, not failed: the #11 coexistence run creates it on purpose.
    check "no $LEGACY_NAME process running" eval '[ -z "$(legacy_pid)" ]'
    local lp=absent; [ -e "$LEGACY_SUPPORT" ] && lp=present
    local ld=absent; defaults read "$LEGACY_BUNDLE_ID" >/dev/null 2>&1 && ld=present
    record "legacy state (recorded only): ~/Library/Application Support/Headroom $lp; $LEGACY_BUNDLE_ID preferences $ld; /Applications/Headroom.app $([ -e /Applications/Headroom.app ] && echo present || echo absent)"
    echo
    echo "Manual check: System Settings > General > Login Items & Extensions. Is $APP_NAME listed anywhere? [y/N]"
    read -r ans
    if [ "${ans:-n}" = "y" ]; then record "FAIL preflight: $APP_NAME already listed in Login Items"; fail=1
    else record "PASS preflight: $APP_NAME not listed in Login Items (owner observation)"; fi
    echo "And is $LEGACY_NAME listed? (recorded only) [y/N]"
    read -r ans
    record "legacy: $LEGACY_NAME listed in Login Items: ${ans:-n} (owner observation)"
    [ $fail -eq 0 ] || die "preflight failed; fix the account (or use a fresh one) before launching anything"
    touch "$run/.preflight-ok"
    record "preflight passed; evidence in $run"
}

# ---------------------------------------------------------------------------------------------------------------
cmd_fixtures() {
    gate
    local run; run=$(run_dir)
    local extra=${1:-0}
    local projects="$HOME/.claude/projects"
    [ -z "$(unregistered_fixtures)" ] || die "$projects holds transcripts this run didn't write: $(unregistered_fixtures | tr '\n' ' ')"
    [ ! -f "$projects/$FIXTURE_MARK" ] || [ "$(fixture_run)" = "$(basename "$run")" ] || die "the fixture marker belongs to run $(fixture_run)"
    local tok; tok=$(uuidgen | tr -d '-' | tr 'A-F' 'a-f' | cut -c1-12)
    mkdir -p "$projects"
    [ -f "$projects/$FIXTURE_MARK" ] || echo "run=$(basename "$run")" > "$projects/$FIXTURE_MARK"
    # Distinct canaries. Only the model name may appear in the cache (model names are stored by design).
    cat > "$run/canaries.txt" <<EOF
content=RVCANARY$tok
path=rvpath$tok
id=rvid$tok
model=claude-rvmodel$tok
EOF
    local dir="$projects/-Users-$RV_USER-rvpath$tok"
    mkdir -p "$dir"
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    write_session() { # file lines file-tag (message ids are unique per file, so nothing deduplicates across files)
        local f=$1 n=$2 tag=$3 i
        : > "$f"
        for ((i = 1; i <= n; i++)); do
            printf '{"type":"user","cwd":"/Users/%s/rvpath%s","sessionId":"rvid%s-s","message":{"role":"user","content":"RVCANARY%s prompt %d"},"timestamp":"%s"}\n' \
                "$RV_USER" "$tok" "$tok" "$tok" "$i" "$ts" >> "$f"
            # Two streaming copies of the same message (same id + requestId): counted once.
            printf '{"type":"assistant","requestId":"req_rvid%s_%s_%d","cwd":"/Users/%s/rvpath%s","message":{"id":"msg_rvid%s_%s_%d","model":"claude-sonnet-4-5","content":[{"type":"text","text":"RVCANARY%s reply"}],"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"%s"}\n' \
                "$tok" "$tag" "$i" "$RV_USER" "$tok" "$tok" "$tag" "$i" "$tok" "$ts" >> "$f"
            printf '{"type":"assistant","requestId":"req_rvid%s_%s_%d","cwd":"/Users/%s/rvpath%s","message":{"id":"msg_rvid%s_%s_%d","model":"claude-sonnet-4-5","content":[{"type":"text","text":"RVCANARY%s reply"}],"usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"%s"}\n' \
                "$tok" "$tag" "$i" "$RV_USER" "$tok" "$tok" "$tag" "$i" "$tok" "$ts" >> "$f"
        done
        # One unpriced model: should show as n/a (R7) and appear by name in the cache.
        printf '{"type":"assistant","requestId":"req_rvid%s_%s_x","message":{"id":"msg_rvid%s_%s_x","model":"claude-rvmodel%s","usage":{"input_tokens":7,"output_tokens":3}},"timestamp":"%s"}\n' \
            "$tok" "$tag" "$tok" "$tag" "$tok" "$ts" >> "$f"
    }
    write_session "$dir/rvid$tok-main.jsonl" 20 main
    register_fixture "-Users-$RV_USER-rvpath$tok/rvid$tok-main.jsonl"
    local k
    for ((k = 1; k <= extra; k++)); do
        write_session "$dir/rvid$tok-perf$k.jsonl" 1000 "p$k"
        register_fixture "-Users-$RV_USER-rvpath$tok/rvid$tok-perf$k.jsonl"
    done
    local msgs=$(( 20 + extra * 1000 ))
    record "fixtures: 1 privacy session (20 messages streamed twice, 1 unpriced) + $extra timing sessions of 1000 messages, ids unique per file"
    record "expected totals: claude-sonnet-4-5 $msgs messages = $(( msgs * 30 )) tokens ($(( msgs * 10 )) input + $(( msgs * 20 )) output); claude-rvmodel$tok $(( 1 + extra )) messages = $(( (1 + extra) * 10 )) tokens, unpriced"
}

# ---------------------------------------------------------------------------------------------------------------
# #55: one more synthetic session whose records lack ids, so the "Usage may be approximate" note has to appear.
cmd_identity() {
    gate
    local run; run=$(run_dir)
    [ -f "$run/canaries.txt" ] || die "run fixtures first"
    local tok; tok=$(sed -n 's/^id=rvid//p' "$run/canaries.txt")
    local dir="$HOME/.claude/projects/-Users-$RV_USER-rvpath$tok"
    [ -d "$dir" ] && [ -f "$HOME/.claude/projects/$FIXTURE_MARK" ] || die "fixture folder missing"
    local f="$dir/rvid$tok-identity.jsonl" ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    local u='"usage":{"input_tokens":10,"output_tokens":%d,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}'
    {
        # Message id only, streamed twice: one group, incomplete.
        for out in 5 20; do printf '{"type":"assistant","message":{"id":"msg_rvid%s_only","model":"claude-sonnet-4-5",'"$u"'},"timestamp":"%s"}\n' "$tok" "$out" "$ts"; done
        # Request id only, with an empty message id: one group, incomplete.
        printf '{"type":"assistant","requestId":"req_rvid%s_only","message":{"id":"","model":"claude-sonnet-4-5",'"$u"'},"timestamp":"%s"}\n' "$tok" 20 "$ts"
        # Two pairs sharing a message id, then a record with only that id: two identified groups and one ambiguous.
        for r in a b; do printf '{"type":"assistant","requestId":"req_rvid%s_shared_%s","message":{"id":"msg_rvid%s_shared","model":"claude-sonnet-4-5",'"$u"'},"timestamp":"%s"}\n' "$tok" "$r" "$tok" 20 "$ts"; done
        printf '{"type":"assistant","message":{"id":"msg_rvid%s_shared","model":"claude-sonnet-4-5",'"$u"'},"timestamp":"%s"}\n' "$tok" 20 "$ts"
        # Neither id, written twice identically: one group, fingerprinted.
        for k in 1 2; do printf '{"type":"assistant","message":{"model":"claude-sonnet-4-5","content":[{"type":"text","text":"RVCANARY%s reply"}],'"$u"'},"timestamp":"%s"}\n' "$tok" 20 "$ts"; done
    } > "$f"
    register_fixture "${f#"$HOME/.claude/projects/"}"
    record "identity: 8 records (6 groups: 2 identified pairs sharing a message id, 2 by one id, 1 fingerprinted, 1 ambiguous), 180 tokens"
    record "expected: totals grow by 180 claude-sonnet-4-5 tokens; the Token usage card shows \"Usage may be approximate: some records lack identifiers.\"; its help and VoiceOver label start \"Of 27 logged messages from Claude in the last 30 days, 4 were told apart without both a message id and a request id: 2 by one id, 1 with no id, by a fingerprint of timestamp, model and token counts, 1 by an id that more than one message shares\" (23 identified groups with fixtures but no timing sessions; add 1001 per timing session)"
}

cmd_completeness() {
    gate
    local run; run=$(run_dir)
    [ -f "$run/canaries.txt" ] || die "run fixtures first"
    local tok; tok=$(sed -n 's/^id=rvid//p' "$run/canaries.txt")
    local dir="$HOME/.claude/projects/-Users-$RV_USER-rvpath$tok"
    [ -d "$dir" ] && [ -f "$HOME/.claude/projects/$FIXTURE_MARK" ] || die "fixture folder missing"
    local f="$dir/rvid$tok-completeness.jsonl" ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    local m='"model":"claude-sonnet-4-5","content":[{"type":"text","text":"RVCANARY'"$tok"' reply"}]'
    {
        # Cut off mid-record, with its newline: malformed. Its text must not reach the cache.
        printf '{"type":"assistant","timestamp":"%s","requestId":"req_rvid%s_cut","message":{"id":"msg_rvid%s_cut",%s,"usage":{"input_tokens":10,"outp\n' "$ts" "$tok" "$tok" "$m"
        # No usable timestamp: undated.
        printf '{"type":"assistant","timestamp":"not a time","requestId":"req_rvid%s_nots","message":{"id":"msg_rvid%s_nots",%s,"usage":{"input_tokens":10,"output_tokens":5}}}\n' "$tok" "$tok" "$m"
        # Usage that isn't an object: invalid usage, dated.
        printf '{"type":"assistant","timestamp":"%s","requestId":"req_rvid%s_bad","message":{"id":"msg_rvid%s_bad",%s,"usage":"n/a"}}\n' "$ts" "$tok" "$tok" "$m"
        # An output count that isn't a number: 10 tokens counted, the message flawed.
        printf '{"type":"assistant","timestamp":"%s","requestId":"req_rvid%s_flaw","message":{"id":"msg_rvid%s_flaw",%s,"usage":{"input_tokens":10,"output_tokens":"x"}}}\n' "$ts" "$tok" "$tok" "$m"
        # Valid, written with a space after "usage": 30 tokens.
        printf '{"type":"assistant","timestamp":"%s","requestId":"req_rvid%s_space","message":{"id":"msg_rvid%s_space",%s,"usage": {"input_tokens":10,"output_tokens":20}}}\n' "$ts" "$tok" "$tok" "$m"
        # A cache-write total of 10 with a breakdown of 20 + 10 (P9): 10 tier-unresolved, 20 disputed; 32 tokens.
        printf '{"type":"assistant","timestamp":"%s","requestId":"req_rvid%s_p9","message":{"id":"msg_rvid%s_p9",%s,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":10,"cache_creation":{"ephemeral_5m_input_tokens":20,"ephemeral_1h_input_tokens":10}}}}\n' "$ts" "$tok" "$tok" "$m"
        # A user record carrying usage: ignored, not unread.
        printf '{"type":"user","timestamp":"%s","toolUseResult":{"usage":{"input_tokens":999}},"message":{"role":"user","content":"x"}}\n' "$ts"
    } > "$f"
    register_fixture "${f#"$HOME/.claude/projects/"}"
    record "completeness: 7 lines (1 malformed, 1 undated, 1 invalid usage, 1 flawed, 1 spaced, 1 cache-write conflict, 1 user record), 72 tokens"
    record "expected: totals grow by 72 claude-sonnet-4-5 tokens and 3 identified groups; the Token usage card shows \"Some usage records couldn't be read. Totals may be incomplete.\", then \"Some token counts are provisional. Totals may be over- or understated.\" (detail: \"20 cache-write tokens are counted provisionally\"), then any identity note; the cost note under the chart names \"cache writes of uncertain tier or amount for claude-sonnet-4-5\"; its help and VoiceOver label start \"In Claude Code's logs for the last 30 days, 3 records couldn't be read, counting identical lines once: 1 isn't valid JSON, 1 has no usable timestamp, 1 has usage in a form SpanDeck doesn't recognize. 1 message had a token count that isn't a valid number; it was left out and the rest counted. 2 of the unread records have no date, so they may belong to any period.\""
}

# ---------------------------------------------------------------------------------------------------------------
# #5: one more synthetic session with a canary in every sensitive field a transcript can hold, and broken lines that
# carry them. Adds canary kinds to canaries.txt; capture searches for every kind but the model.
cmd_privacy() {
    gate
    local run; run=$(run_dir)
    [ -f "$run/canaries.txt" ] || die "run fixtures first"
    local tok; tok=$(sed -n 's/^id=rvid//p' "$run/canaries.txt")
    local dir="$HOME/.claude/projects/-Users-$RV_USER-rvpath$tok"
    [ -d "$dir" ] && [ -f "$HOME/.claude/projects/$FIXTURE_MARK" ] || die "fixture folder missing"
    grep -q '^secret=' "$run/canaries.txt" || printf 'secret=RVSECRET%s\ncode=RVCODE%s\ntool=RVTOOL%s\nthinking=RVTHINK%s\nbranch=RVBRANCH%s\n' \
        "$tok" "$tok" "$tok" "$tok" "$tok" >> "$run/canaries.txt"
    local f="$dir/rvid$tok-privacy.jsonl" ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    # Credential-shaped but fake: every one contains RVSECRET.
    local creds="sk-ant-RVSECRET$tok AKIARVSECRET$tok ghp_RVSECRET$tok"
    local env='"cwd":"/Users/'"$RV_USER"'/rvpath'"$tok"'","gitBranch":"RVBRANCH'"$tok"'","sessionId":"rvid'"$tok"'-p","uuid":"rvid'"$tok"'-u"'
    {
        printf '{"type":"user",%s,"timestamp":"%s","message":{"role":"user","content":"RVCANARY%s fix func RVCODE%s() { key = %s }"}}\n' "$env" "$ts" "$tok" "$tok" "$creds"
        printf '{"type":"assistant",%s,"timestamp":"%s","requestId":"req_rvid%s_priv","message":{"id":"msg_rvid%s_priv","model":"claude-sonnet-4-5","content":[{"type":"thinking","thinking":"RVTHINK%s"},{"type":"text","text":"RVCODE%s"},{"type":"tool_use","id":"toolu_rvid%s","name":"Bash","input":{"command":"RVTOOL%s cat .env %s"}}],"usage":{"input_tokens":10,"output_tokens":5,"service_tier":"RVSECRET%s"}}}\n' "$env" "$ts" "$tok" "$tok" "$tok" "$tok" "$tok" "$tok" "$creds" "$tok"
        printf '{"type":"user",%s,"timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_rvid%s","content":"RVTOOL%s result %s"}]},"toolUseResult":{"stdout":"RVTOOL%s"}}\n' "$env" "$ts" "$tok" "$tok" "$creds" "$tok"
        printf '{"type":"summary","summary":"RVCANARY%s summary","leafUuid":"rvid%s-u"}\n' "$tok" "$tok"
        printf '{"type":"system",%s,"timestamp":"%s","content":"RVCANARY%s system"}\n' "$env" "$ts" "$tok"
        # Broken lines carrying canaries: malformed, then cut off at the end of the file (pending, no newline).
        printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":1}},"text":"RVSECRET%s RVTOOL%s"\n' "$ts" "$tok" "$tok"
        printf '{"type":"assistant","timestamp":"%s","message":{"text":"RVSECRET%s","usage":{"inp' "$ts" "$tok"
    } > "$f"
    register_fixture "${f#"$HOME/.claude/projects/"}"
    record "privacy: 1 session with secret, code, tool, thinking and branch canaries (5 records, 15 tokens), 1 malformed line and 1 cut-off last line carrying them"
    record "expected: totals grow by 15 claude-sonnet-4-5 tokens and 1 identified group; one more malformed record (a file still being written isn't reported); no secret, code, tool, thinking or branch canary in any file the app writes"
    record "expected with completeness also applied (72 + 15 = 87 tokens, 4 identified groups), the completeness detail reads: \"In Claude Code's logs for the last 30 days, 4 records couldn't be read, counting identical lines once: 2 aren't valid JSON, 1 has no usable timestamp, 1 has usage in a form SpanDeck doesn't recognize. 1 message had a token count that isn't a valid number; it was left out and the rest counted. 3 of the unread records have no date, so they may belong to any period.\""
}

# ---------------------------------------------------------------------------------------------------------------
# Summarizes the usage cache without printing any id, path or value other than counts and the schema version.
inspect_cache() {
    osascript -l JavaScript - "$1" "$2" <<'JS'
function run(argv) {
    ObjC.import('Foundation');
    const text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js;
    const canaries = argv[1].split(',');
    let c; try { c = JSON.parse(text); } catch (e) { return 'cache: not valid JSON'; }
    const out = [];
    out.push('top-level keys: ' + Object.keys(c).sort().join(','));
    out.push('version: ' + c.version);
    const hex32 = /^[0-9a-f]{32}$/;
    for (const k of ['files', 'seen', 'links']) {
        const keys = Object.keys(c[k] || {});
        out.push(k + ': ' + keys.length + ' entries, all 32-hex ids: ' + keys.every(x => hex32.test(x)));
    }
    const marks = Object.values(c.files || {});
    out.push('files: marks with a 32-hex stamp and anchor (#56): ' + marks.filter(m => hex32.test(String(m.stamp)) && hex32.test(String(m.anchor))).length + ' of ' + marks.length
        + ', other fields: ' + ([...new Set(marks.flatMap(m => Object.keys(m)))].filter(k => !['offset', 'stamp', 'anchor'].includes(k)).join(',') || 'none'));
    const targets = Object.values(c.links || {}).map(l => String(l.target));
    out.push('links: all targets 32-hex or "ambiguous": ' + targets.every(t => hex32.test(t) || t === 'ambiguous'));
    const kinds = { identified: 0, incomplete: 0, fingerprinted: 0, ambiguous: 0 };
    for (const h of Object.values(c.identity || {})) for (const k in kinds) kinds[k] += Number(h[k] || 0);
    out.push('identity groups: ' + Object.keys(kinds).map(k => k + '=' + kinds[k]).join(' '));
    const unread = Object.keys(c.unread || {});
    const byKind = {};
    for (const u of Object.values(c.unread || {})) byKind[u.kind] = (byKind[u.kind] || 0) + 1;
    out.push('unread: ' + unread.length + ' entries, all 32-hex ids: ' + unread.every(x => hex32.test(x)) + ', kinds: '
        + (Object.keys(byKind).sort().map(k => k + '=' + byKind[k]).join(' ') || 'none'));
    out.push('flawed groups: ' + Object.values(c.flawed || {}).reduce((a, n) => a + Number(n), 0));
    let unresolved = 0, disputed = 0;
    for (const h of Object.values(c.slots || {})) for (const a of Object.values(h)) {
        unresolved += Number(a.cacheWriteUnresolved || 0); disputed += Number(a.cacheWriteDisputed || 0);
    }
    out.push('cache-write tokens: tier-unresolved=' + unresolved + ' disputed=' + disputed);
    out.push('keyCheck is 32-hex: ' + hex32.test(String(c.keyCheck)));
    out.push('contains "/": ' + text.includes('/'));
    for (const t of canaries) out.push('contains canary ' + t.split('=')[0] + ': ' + text.includes(t.split('=')[1]));
    return out.join('\n');
}
JS
}

cmd_capture() {
    local label=${1:?capture LABEL}
    local run; run=$(run_dir)
    local d="$run/$label"; mkdir -p "$d"
    record "capture $label"
    {
        echo "# Application Support folder and files (mode owner name)"
        if [ -e "$APP_SUPPORT" ]; then
            stat -f '%Sp %Su %N' "$APP_SUPPORT"
            find "$APP_SUPPORT" -mindepth 1 -exec stat -f '%Sp %Su %z bytes %N' {} \; | sed "s|$HOME|~|"
        else echo "absent"; fi
    } > "$d/app-support.txt"
    {
        echo "# Preference keys for $BUNDLE_ID (booleans and numbers only)"
        if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
            defaults read "$BUNDLE_ID" | grep -E '^\s+"?[A-Za-z0-9 ._-]+"? = [-0-9.]+;$' || true
            echo "(other keys, values omitted:)"
            defaults read "$BUNDLE_ID" | grep -vE '= [-0-9.]+;$' | grep -oE '^\s+"?[A-Za-z0-9 ._-]+"? =' || true
        else echo "domain absent"; fi
    } > "$d/preferences.txt"
    changed_files "$run/.start" > "$d/.changed"
    {
        echo "# Files created or modified since preflight: home (privacy-protected folders skipped), user temp and cache"
        echo "# Other processes write here too (macOS services); entries are attributed in the report, not here."
        sed "s|$HOME|~|" "$d/.changed" | sort
    } > "$d/new-files.txt"
    { echo "# Power assertions"; pmset -g assertions | grep -i -E "$APP_NAME|$LEGACY_NAME|Claude Code or Grok|Keep awake" || echo "none from $APP_NAME or $LEGACY_NAME"; } > "$d/assertions.txt"
    {
        echo "# $APP_NAME processes"; ps -o pid,ppid,%cpu,rss,etime,comm -p "$(app_pid)" 2>/dev/null || echo "not running"
        echo "# $LEGACY_NAME processes (legacy, observed only)"; ps -o pid,ppid,%cpu,rss,etime,comm -p "$(legacy_pid)" 2>/dev/null || echo "not running"
    } > "$d/process.txt"
    state_fingerprint > "$d/state.txt"
    if [ -f "$run/canaries.txt" ]; then
        local list; list=$(paste -sd, "$run/canaries.txt")
        {
            echo "# Canary search outside the fixtures (file names only)"
            for kind in $(cut -d= -f1 "$run/canaries.txt" | grep -v '^model$'); do
                local t; t=$(awk -F= -v k=$kind '$1==k{print $2}' "$run/canaries.txt")
                # Only files changed since preflight can contain a canary created after it.
                echo "$kind: $(tr '\n' '\0' < "$d/.changed" | xargs -0 grep -l -F "$t" 2>/dev/null | sed "s|$HOME|~|" | tr '\n' ' ')"
            done
            if [ -f "$APP_SUPPORT/claude-ledger.json" ]; then
                echo "# Usage cache summary"
                inspect_cache "$APP_SUPPORT/claude-ledger.json" "$list"
            fi
        } > "$d/canaries.txt"
    fi
    cat "$d"/*.txt
}

# ---------------------------------------------------------------------------------------------------------------
cmd_launch() {
    gate
    local sha; sha=$(staged)
    launch_app "$SHARED/$sha/$APP_NAME.app" "$APP_NAME" "$BUNDLE_ID" "$sha" "${1:-120}" "${2:-main}"
}

# #11: the staged legacy build (Headroom's identity), monitored the same way. Its forks are watched with the current
# build's procwatch.
cmd_legacy_launch() {
    gate
    local lsha; lsha=$(legacy_staged)
    launch_app "$SHARED/legacy-$lsha/$LEGACY_NAME.app" "$LEGACY_NAME" "$LEGACY_BUNDLE_ID" "$(staged)" "${1:-120}" "legacy-${2:-main}"
}

# launch_app APP NAME BUNDLE_ID PROCWATCH_SHA SECONDS LABEL
launch_app() {
    local app=$1 name=$2 bundle=$3 sha=$4 secs=$5 label=$6
    local run; run=$(run_dir)
    pid_of() { pgrep -x "$name" 2>/dev/null | head -1 || true; }
    [ -z "$(pid_of)" ] || die "$name is already running"
    local d="$run/launch-$label"
    [ ! -e "$d" ] || die "$d exists; give this launch its own label"
    mkdir -p "$d"
    # Unified log for the app's own process: network, CFNetwork, Security framework and ServiceManagement messages.
    # Hostnames are usually redacted as <private>; the count and type of events is what matters.
    log stream --style compact --level debug --predicate \
        'process == "'"$name"'" AND (subsystem BEGINSWITH "com.apple.network" OR subsystem BEGINSWITH "com.apple.CFNetwork" OR subsystem BEGINSWITH "com.apple.security" OR subsystem BEGINSWITH "com.apple.servicemanagement" OR subsystem BEGINSWITH "com.apple.backgroundtaskmanagement")' \
        > "$d/app-log.txt" 2>&1 &
    local logpid=$!
    # Any `security` or `grok` process started on this account while the app runs.
    log stream --style compact --predicate 'process == "security" OR process == "grok"' > "$d/tool-log.txt" 2>&1 &
    local toolpid=$!
    sleep 2
    local t0; t0=$(ms)
    record "launch $label: open $app"
    open -n "$app"
    local pid=""
    for _ in $(seq 1 100); do pid=$(pid_of); [ -n "$pid" ] && break; sleep 0.1; done
    [ -n "$pid" ] || { kill $logpid $toolpid 2>/dev/null; die "app did not start within 10 s"; }
    record "launch: pid $pid after $(( $(ms) - t0 )) ms"
    # Every fork of the app, reported by the kernel (kqueue): see scripts/runtime/procwatch.c. Started right after the
    # pid appears, so a child in the first few milliseconds of launch could precede it; the app starts none then.
    "$SHARED/$sha/procwatch" "$pid" > "$d/forks.txt" 2>&1 &
    local watchpid=$!
    for _ in $(seq 1 20); do grep -q " watching $pid" "$d/forks.txt" && break; sleep 0.1; done
    grep -q " watching $pid" "$d/forks.txt" || record "launch: FAIL, fork monitor did not start: $(head -1 "$d/forks.txt")"
    : > "$d/sockets.txt"; : > "$d/samples.txt"; : > "$d/consent.txt"
    local end=$(( $(date +%s) + secs )) tick=0 consent="" was=""
    while [ "$(date +%s)" -lt "$end" ]; do
        kill -0 "$pid" 2>/dev/null || { record "launch: app exited early"; break; }
        lsof -nP -a -p "$pid" -i 2>/dev/null | tail -n +2 | awk '{print $8, $9, $10}' | sed "s/^/$(now) /" >> "$d/sockets.txt" || true
        echo "$(( $(ms) - t0 )) $(ps -o %cpu=,rss= -p "$pid")" >> "$d/samples.txt"
        # Consent settings every 5 s; a line is written at the start and whenever a value changes.
        if [ $(( tick % 5 )) -eq 0 ]; then
            consent="$bundle: claude.limits.enabled=$(defaults read "$bundle" claude.limits.enabled 2>/dev/null || echo absent) grok.enabled=$(defaults read "$bundle" grok.enabled 2>/dev/null || echo absent)"
            # #11: while SpanDeck runs, also what the legacy domain says (seeded on purpose in the coexistence run).
            [ "$bundle" = "$LEGACY_BUNDLE_ID" ] || consent="$consent | $LEGACY_BUNDLE_ID: claude.limits.enabled=$(defaults read "$LEGACY_BUNDLE_ID" claude.limits.enabled 2>/dev/null || echo absent) grok.enabled=$(defaults read "$LEGACY_BUNDLE_ID" grok.enabled 2>/dev/null || echo absent)"
            [ "$consent" = "$was" ] || { echo "$(now) $consent" >> "$d/consent.txt"; was=$consent; }
        fi
        tick=$(( tick + 1 ))
        sleep 1
    done
    nettop -P -L 1 -x -p "$pid" > "$d/nettop.txt" 2>&1 || echo "nettop unavailable" > "$d/nettop.txt"
    { kill $logpid $toolpid $watchpid; wait $logpid $toolpid $watchpid; } 2>/dev/null || true
    local app_events tool_events
    # Event lines only (the first line of each stream is its filter description).
    app_events=$(tail -n +2 "$d/app-log.txt" | grep -c -E 'nw_|Connection|Task <|SecItem|SecKeychain|SMAppService|register' || true)
    # Any account-wide `security` / `grok` process, not only the app's children; attribute them using forks.txt.
    tool_events=$(tail -n +2 "$d/tool-log.txt" | grep -c -E 'security\[|grok\[' || true)
    local forks; forks=$(grep -c ' fork ' "$d/forks.txt" || true)
    record "launch: watched ${secs}s; child processes (kernel-reported forks): $forks; socket lines: $(wc -l < "$d/sockets.txt" | tr -d ' ')"
    [ "$forks" -eq 0 ] || record "launch: children: $(grep ' fork ' "$d/forks.txt" | awk '{print $5}' | sort | uniq -c | tr '\n' ' ')"
    record "launch: consent over time: $(tr '\n' ';' < "$d/consent.txt")"
    record "launch: app log network/security/login-item events: $app_events; security/grok process log lines: $tool_events"
    awk '{c+=$2; n++; if ($3>m) m=$3} END{if (n) printf "launch: mean CPU %.1f%% over %d samples, peak RSS %d KB\n", c/n, n, m}' "$d/samples.txt" \
        | while read -r line; do record "$line"; done
    if [ "$name" = "$APP_NAME" ]; then echo "Leave the app running for the UI checks in the procedure, then run: $0 quit"
    else echo "Leave the legacy app running if the procedure says so, then run: $0 quit-legacy"; fi
}

# Quitting is done in the app (popover > Quit), which also saves the cache. Scripting it would need an Automation
# permission, and a signal skips the app's quit handler.
cmd_quit() { quit_app "$APP_NAME" "$(app_pid)"; }
cmd_quit_legacy() { quit_app "$LEGACY_NAME" "$(legacy_pid)"; }
quit_app() {
    local name=$1 pid=$2
    [ -n "$pid" ] || { record "quit $name: not running"; return; }
    echo "Quit $name now: click its menu-bar item, then Quit. Waiting up to 60 s..."
    for _ in $(seq 1 600); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then record "quit $name: still running after 60 s"; else record "quit $name: exited"; fi
}

# ---------------------------------------------------------------------------------------------------------------
cmd_snapshot() {
    gate
    local run; run=$(run_dir)
    local sha; sha=$(staged)
    [ -z "$(app_pid)" ] || die "quit the app first"
    local had_support=no; [ -e "$APP_SUPPORT" ] && had_support=yes
    local rel="$run/snapshot-release" dbg="$run/snapshot-debug"
    mkdir -p "$rel" "$dbg"
    local code=0
    "$SHARED/$sha/$APP_NAME.app/Contents/MacOS/$APP_NAME" --snapshot "$rel" > "$run/snapshot-release.out" 2>&1 || code=$?
    record "snapshot release: exit $code (expect 64); files written: $(find "$rel" -type f | wc -l | tr -d ' ') (expect 0)"
    code=0
    "$SHARED/$sha/$APP_NAME-debug" --snapshot "$dbg" > "$run/snapshot-debug.out" 2>&1 || code=$?
    record "snapshot debug: exit $code (expect 0); files: $(cd "$dbg" && ls | tr '\n' ' ')(expect popover.png strip-dark.png strip-light.png)"
    [ -z "$(app_pid)" ] && record "snapshot: no $APP_NAME process left running" || record "snapshot: FAIL, a $APP_NAME process is running"
    local has_support=no; [ -e "$APP_SUPPORT" ] && has_support=yes
    record "snapshot: Application Support existed before: $had_support, after: $has_support"
    echo "Open $dbg/popover.png and check it shows only synthetic data, not the fixture model claude-rvmodel… or any real data."
}

# ---------------------------------------------------------------------------------------------------------------
cmd_summary() {
    local run; run=$(run_dir)
    local sha; sha=$(staged)
    mkdir -p "$RESULTS"; chmod 755 "$RESULTS"
    local out; out="$RESULTS/results-$sha-$(basename "$run").md"
    {
        echo "# Runtime verification results: $(basename "$run")"
        echo; echo "Build: $sha. Account: $(id -un). Sanitized: names, modes, counts, pass/fail only."
        echo; echo '```'; cat "$run/log.txt"; echo '```'
        for f in "$run"/*/*.txt; do
            case "$f" in *app-log.txt|*tool-log.txt) continue ;; esac
            echo; echo "## ${f#$run/}"; echo; echo '```'; head -200 "$f"; echo '```'
        done
        echo; echo "## Log event lines (message types only)"; echo; echo '```'
        for f in "$run"/launch*/app-log.txt "$run"/launch*/tool-log.txt; do
            [ -f "$f" ] && { echo "${f#$run/}: $(wc -l < "$f" | tr -d ' ') lines"; grep -oE '\[[a-zA-Z.]+:[a-zA-Z_]+\]' "$f" | sort | uniq -c | head -40 || true; }
        done
        echo '```'
    } > "$out"
    chmod a+r "$out"
    echo "Wrote $out (no transcript content, credentials or payloads). Check it before sharing."
}

cmd_clean() {
    [ "$(id -un)" = "$RV_USER" ] || die "clean only runs in $RV_USER"
    cmd_quit || true
    echo "Before cleaning: if you enabled Launch at login, turn it off in the app's Settings first. Continue? [y/N]"
    read -r ans; [ "${ans:-n}" = "y" ] || die "cancelled"
    # SpanDeck's state only: legacy (Headroom) state is left alone; `clean-legacy` removes it on request.
    rm -rf "$APP_SUPPORT" "$HOME/Library/Logs/$HOVER_LOG"
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    # cfprefsd may keep an empty file; with the domain deleted, removing it is safe.
    defaults read "$BUNDLE_ID" >/dev/null 2>&1 || rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    rm -rf "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID" "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
    if [ -f "$HOME/.claude/projects/$FIXTURE_MARK" ]; then rm -rf "$HOME/.claude/projects"; rmdir "$HOME/.claude" 2>/dev/null || true; fi
    record "clean: $APP_NAME state and fixtures removed; legacy state and evidence kept in $EVIDENCE_ROOT"
}

# ---------------------------------------------------------------------------------------------------------------
# #11 coexistence. Fingerprints hold names, modes, sizes, modification times and SHA-256 hashes, never contents; for
# preferences, the key names and a hash of the exported domain.
fp_files() { # a folder, or a single file
    [ -e "$1" ] || { echo "  absent"; return; }
    if [ -f "$1" ]; then echo "  ./$(basename "$1") $(stat -f '%Sp %z %m' "$1") $(shasum -a 256 "$1" | cut -d' ' -f1)"; return; fi
    (cd "$1" 2>/dev/null && find . -print | sort | while read -r f; do
        if [ -f "$f" ]; then echo "  $f $(stat -f '%Sp %z %m' "$f") $(shasum -a 256 "$f" | cut -d' ' -f1)"
        else echo "  $f $(stat -f '%Sp' "$f")"; fi
    done)
}
fp_prefs() { # domain
    if defaults read "$1" >/dev/null 2>&1; then
        echo "  keys: $(defaults read "$1" | grep -oE '^ +"?[A-Za-z0-9 ._-]+"? =' | tr -d ' "=' | sort | tr '\n' ' ')"
        echo "  export sha256: $(defaults export "$1" - 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
    else echo "  absent"; fi
}
state_fingerprint() {
    echo "[$APP_NAME] Application Support/$APP_SUPPORT_DIR"; fp_files "$APP_SUPPORT"
    echo "[$APP_NAME] preferences $BUNDLE_ID"; fp_prefs "$BUNDLE_ID"
    echo "[$APP_NAME] log $HOVER_LOG"; fp_files "$HOME/Library/Logs/$HOVER_LOG"
    echo "[legacy] Application Support/Headroom"; fp_files "$LEGACY_SUPPORT"
    echo "[legacy] preferences $LEGACY_BUNDLE_ID"; fp_prefs "$LEGACY_BUNDLE_ID"
    echo "[legacy] log Headroom-hover.log"; fp_files "$LEGACY_LOG"
}
cmd_fingerprint() {
    local label=${1:?fingerprint LABEL}
    local f; f="$(run_dir)/fingerprint-$label.txt"
    [ ! -e "$f" ] || die "$f exists; use a new label"
    state_fingerprint > "$f"
    record "fingerprint $label: $(grep -c '^  \./' "$f" || true) entries"
    cat "$f"
}
cmd_compare() {
    local a=${1:?compare A B} b=${2:?compare A B} run; run=$(run_dir)
    for side in "$APP_NAME" legacy; do
        if diff <(grep -A100000 "^\[$side\]" "$run/fingerprint-$a.txt" | awk -v s="[$side]" 'index($0,"[")==1 && index($0,s)!=1{exit} {print}') \
                <(grep -A100000 "^\[$side\]" "$run/fingerprint-$b.txt" | awk -v s="[$side]" 'index($0,"[")==1 && index($0,s)!=1{exit} {print}') > /dev/null
        then record "compare $a -> $b: $side state unchanged"
        else record "compare $a -> $b: $side state CHANGED"; fi
    done
}
# Consent in the legacy domain: SpanDeck must not inherit it. Never launch the legacy app while it's seeded (it would
# act on it); unseed first.
cmd_seed_legacy_consent() {
    gate
    [ -z "$(legacy_pid)" ] || die "quit the legacy app first"
    defaults write "$LEGACY_BUNDLE_ID" claude.limits.enabled -bool true
    defaults write "$LEGACY_BUNDLE_ID" grok.enabled -bool true
    record "seeded $LEGACY_BUNDLE_ID claude.limits.enabled=1 grok.enabled=1 (expect $APP_NAME to keep both off)"
}
cmd_unseed_legacy_consent() {
    gate
    defaults delete "$LEGACY_BUNDLE_ID" claude.limits.enabled >/dev/null 2>&1 || true
    defaults delete "$LEGACY_BUNDLE_ID" grok.enabled >/dev/null 2>&1 || true
    record "unseeded $LEGACY_BUNDLE_ID consent keys"
}
cmd_clean_legacy() {
    [ "$(id -un)" = "$RV_USER" ] || die "clean-legacy only runs in $RV_USER"
    [ -z "$(legacy_pid)" ] || die "quit the legacy app first"
    echo "Remove this test account's legacy Headroom state (Application Support/Headroom, $LEGACY_BUNDLE_ID preferences, Headroom-hover.log)? [y/N]"
    read -r ans; [ "${ans:-n}" = "y" ] || die "cancelled"
    rm -rf "$LEGACY_SUPPORT" "$LEGACY_LOG"
    defaults delete "$LEGACY_BUNDLE_ID" >/dev/null 2>&1 || true
    defaults read "$LEGACY_BUNDLE_ID" >/dev/null 2>&1 || rm -f "$HOME/Library/Preferences/$LEGACY_BUNDLE_ID.plist"
    record "clean-legacy: test-account legacy state removed"
}

case "${1:-}" in
stage|preflight|fixtures|identity|completeness|privacy|capture|launch|quit|snapshot|summary|clean|fingerprint|compare) c=$1; shift; "cmd_$c" "$@" ;;
stage-legacy|legacy-launch|quit-legacy|seed-legacy-consent|unseed-legacy-consent|clean-legacy) c=${1//-/_}; shift; "cmd_$c" "$@" ;;
*) sed -n '2,32p' "$0"; exit 64 ;;
esac
