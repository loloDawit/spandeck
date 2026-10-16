#!/bin/bash
# Runtime verification helper for #3 (audit §7 Phase 2). See docs/audits/0003-runtime-verification.md.
#
# Observes a real SpanDeck (Headroom) process in a dedicated, credential-free macOS account. It never reads
# credentials, never creates Keychain items or provider keys, never sends anything anywhere, and needs no admin rights.
#
#   In your normal account (builds only, launches nothing):
#     scripts/runtime-verify.sh stage            build release + debug from a clean checkout, copy to /Users/Shared
#   In the dedicated test account, in this order:
#     scripts/runtime-verify.sh preflight        safety gate; refuses to continue in an unsafe account
#     scripts/runtime-verify.sh fixtures [N]     synthetic transcripts with canaries (+ N extra files for timing)
#     scripts/runtime-verify.sh capture LABEL    record files, modes, preferences, assertions, canary hits
#     scripts/runtime-verify.sh launch SECONDS [LABEL]  launch the app normally; watch processes, sockets, logs
#     scripts/runtime-verify.sh quit             wait for you to quit the app from its menu
#     scripts/runtime-verify.sh snapshot         --snapshot in the release app (must refuse) and the debug binary
#     scripts/runtime-verify.sh summary          write a sanitized summary to /Users/Shared/spandeck-rv-results
#     scripts/runtime-verify.sh clean            remove the app's state and the fixtures (keeps evidence)
#
# Evidence goes to ~/spandeck-rv-evidence/<run>/. It holds file names, modes, counts and pass/fail lines only:
# no transcript content, no preference values other than booleans and numbers, no network payloads.
set -euo pipefail

RV_USER=${RV_USER:-spandecktest}
SHARED=${RV_SHARED:-/Users/Shared/spandeck-rv}
# Written by the test account (the stage folder belongs to the build account); readable by the build account.
RESULTS=${RV_RESULTS:-/Users/Shared/spandeck-rv-results}
BUNDLE_ID=${RV_BUNDLE_ID:-dev.headroom.Headroom}
APP_SUPPORT="$HOME/Library/Application Support/Headroom"
EVIDENCE_ROOT="$HOME/spandeck-rv-evidence"
FIXTURE_MARK=".spandeck-rv-fixtures"
REPO=$(cd "$(dirname "$0")/.." && pwd)

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

app_pid() { pgrep -x Headroom 2>/dev/null | head -1 || true; }

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
    swift build
    local dest="$SHARED/$sha"
    mkdir -p "$dest"
    rm -rf "$dest/Headroom.app"
    cp -R build/Headroom.app "$dest/"
    cp .build/debug/Headroom "$dest/Headroom-debug"
    clang -Wall -Wextra -O2 -o "$dest/procwatch" scripts/runtime/procwatch.c
    cp scripts/runtime-verify.sh "$dest/runtime-verify.sh"
    chmod -R a+rX "$SHARED"
    {
        echo "commit: $sha"
        echo "staged: $(now)"
        echo "release: ./build.sh (swift build -c release, universal, ad-hoc signed)"
        echo "debug: swift build (debug, $(uname -m))"
        echo "swift: $(swift --version 2>&1 | head -1)"
        echo "xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
        echo "macos: $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
        echo "release archs: $(lipo -archs "$dest/Headroom.app/Contents/MacOS/Headroom")"
        echo "release sha256: $(shasum -a 256 "$dest/Headroom.app/Contents/MacOS/Headroom" | cut -d' ' -f1)"
        echo "debug sha256: $(shasum -a 256 "$dest/Headroom-debug" | cut -d' ' -f1)"
        echo "procwatch sha256: $(shasum -a 256 "$dest/procwatch" | cut -d' ' -f1) (scripts/runtime/procwatch.c)"
        echo "signature: $(codesign -dv "$dest/Headroom.app" 2>&1 | grep -E '^(Signature|TeamIdentifier|CodeDirectory)' | tr '\n' ' ')"
    } > "$dest/manifest.txt"
    echo "$sha" > "$SHARED/current"
    cat "$dest/manifest.txt"
    echo "Staged in $dest. Nothing was launched."
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
    only_fixtures() { absent "$HOME/.claude/projects" || [ -f "$HOME/.claude/projects/$FIXTURE_MARK" ]; }
    manifest_ok() {
        local want; want=$(awk '/^release sha256:/{print $3}' "$SHARED/$sha/manifest.txt")
        [ "$want" = "$(shasum -a 256 "$SHARED/$sha/Headroom.app/Contents/MacOS/Headroom" | cut -d' ' -f1)" ]
    }
    not_quarantined() { ! xattr -r "$SHARED/$sha/Headroom.app" 2>/dev/null | grep -q com.apple.quarantine; }

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
    check "~/.claude/projects absent or synthetic fixtures only" only_fixtures
    check "no Headroom process running" no_running
    check "no /Applications/Headroom.app" absent /Applications/Headroom.app
    check "no ~/Applications/Headroom.app" absent "$HOME/Applications/Headroom.app"
    check "fresh: no ~/Library/Application Support/Headroom" absent "$APP_SUPPORT"
    check "fresh: no preferences for $BUNDLE_ID" absent "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    check "staged app matches its manifest hash" manifest_ok
    check "staged app has no quarantine attribute (no Gatekeeper bypass needed)" not_quarantined
    echo
    echo "Manual check: System Settings > General > Login Items & Extensions. Is Headroom listed anywhere? [y/N]"
    read -r ans
    if [ "${ans:-n}" = "y" ]; then record "FAIL preflight: Headroom already listed in Login Items"; fail=1
    else record "PASS preflight: Headroom not listed in Login Items (owner observation)"; fi
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
    [ -e "$projects" ] && [ ! -f "$projects/$FIXTURE_MARK" ] && die "$projects has non-fixture content"
    local tok; tok=$(uuidgen | tr -d '-' | tr 'A-F' 'a-f' | cut -c1-12)
    mkdir -p "$projects"; touch "$projects/$FIXTURE_MARK"
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
    local k
    for ((k = 1; k <= extra; k++)); do write_session "$dir/rvid$tok-perf$k.jsonl" 1000 "p$k"; done
    local msgs=$(( 20 + extra * 1000 ))
    record "fixtures: 1 privacy session (20 messages streamed twice, 1 unpriced) + $extra timing sessions of 1000 messages, ids unique per file"
    record "expected totals: claude-sonnet-4-5 $msgs messages = $(( msgs * 30 )) tokens ($(( msgs * 10 )) input + $(( msgs * 20 )) output); claude-rvmodel$tok $(( 1 + extra )) messages = $(( (1 + extra) * 10 )) tokens, unpriced"
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
    for (const k of ['files', 'seen']) {
        const keys = Object.keys(c[k] || {});
        out.push(k + ': ' + keys.length + ' entries, all 32-hex ids: ' + keys.every(x => hex32.test(x)));
    }
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
    { echo "# Power assertions"; pmset -g assertions | grep -i -E 'headroom|Claude Code or Grok|Keep awake' || echo "none from Headroom"; } > "$d/assertions.txt"
    { echo "# Headroom processes"; ps -o pid,ppid,%cpu,rss,etime,comm -p "$(app_pid)" 2>/dev/null || echo "not running"; } > "$d/process.txt"
    if [ -f "$run/canaries.txt" ]; then
        local list; list=$(paste -sd, "$run/canaries.txt")
        {
            echo "# Canary search outside the fixtures (file names only)"
            for kind in content path id; do
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
    local secs=${1:-120} label=${2:-main}
    local run; run=$(run_dir)
    local sha; sha=$(staged)
    local app="$SHARED/$sha/Headroom.app"
    [ -z "$(app_pid)" ] || die "Headroom is already running"
    local d="$run/launch-$label"
    [ ! -e "$d" ] || die "$d exists; give this launch its own label"
    mkdir -p "$d"
    # Unified log for the app's own process: network, CFNetwork, Security framework and ServiceManagement messages.
    # Hostnames are usually redacted as <private>; the count and type of events is what matters.
    log stream --style compact --level debug --predicate \
        'process == "Headroom" AND (subsystem BEGINSWITH "com.apple.network" OR subsystem BEGINSWITH "com.apple.CFNetwork" OR subsystem BEGINSWITH "com.apple.security" OR subsystem BEGINSWITH "com.apple.servicemanagement" OR subsystem BEGINSWITH "com.apple.backgroundtaskmanagement")' \
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
    for _ in $(seq 1 100); do pid=$(app_pid); [ -n "$pid" ] && break; sleep 0.1; done
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
            consent="claude.limits.enabled=$(defaults read "$BUNDLE_ID" claude.limits.enabled 2>/dev/null || echo absent) grok.enabled=$(defaults read "$BUNDLE_ID" grok.enabled 2>/dev/null || echo absent)"
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
    echo "Leave the app running for the UI checks in the procedure, then run: $0 quit"
}

# Quitting is done in the app (popover > Quit), which also saves the cache. Scripting it would need an Automation
# permission, and a signal skips the app's quit handler.
cmd_quit() {
    local pid; pid=$(app_pid)
    [ -n "$pid" ] || { record "quit: not running"; return; }
    echo "Quit the app now: click its menu-bar item, then Quit. Waiting up to 60 s..."
    for _ in $(seq 1 600); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then record "quit: still running after 60 s"; else record "quit: exited"; fi
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
    "$SHARED/$sha/Headroom.app/Contents/MacOS/Headroom" --snapshot "$rel" > "$run/snapshot-release.out" 2>&1 || code=$?
    record "snapshot release: exit $code (expect 64); files written: $(find "$rel" -type f | wc -l | tr -d ' ') (expect 0)"
    code=0
    "$SHARED/$sha/Headroom-debug" --snapshot "$dbg" > "$run/snapshot-debug.out" 2>&1 || code=$?
    record "snapshot debug: exit $code (expect 0); files: $(cd "$dbg" && ls | tr '\n' ' ')(expect popover.png strip-dark.png strip-light.png)"
    [ -z "$(app_pid)" ] && record "snapshot: no Headroom process left running" || record "snapshot: FAIL, a Headroom process is running"
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
    rm -rf "$APP_SUPPORT"
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID" "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
    if [ -f "$HOME/.claude/projects/$FIXTURE_MARK" ]; then rm -rf "$HOME/.claude/projects"; rmdir "$HOME/.claude" 2>/dev/null || true; fi
    record "clean: app state and fixtures removed; evidence kept in $EVIDENCE_ROOT"
}

case "${1:-}" in
stage|preflight|fixtures|capture|launch|quit|snapshot|summary|clean) c=$1; shift; "cmd_$c" "$@" ;;
*) sed -n '2,20p' "$0"; exit 64 ;;
esac
