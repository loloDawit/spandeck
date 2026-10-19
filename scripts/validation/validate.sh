#!/bin/bash
# #94 private-use validation, step 2 of 2: run ONLY while logged in as the dedicated test account (spandecktest).
# Validates the staged candidate in the real app: docs/VALIDATION.md §2 steps A–C. Guided: it does the setup,
# measurements and checks, and asks you to click in the app where a person has to (it never scripts clicks, so it
# needs no Accessibility, Automation or admin rights). Synthetic Claude and Grok fixtures only. Never enables an
# integration, never creates credentials, never sends anything anywhere.
#
#   ./validate.sh run [--screenshots] [--park-existing]   isolation gate, then A, B, C, then the report
#   ./validate.sh report                                  rebuild the report of the last run
#   ./validate.sh cleanup                                 remove this run's app copy, SpanDeck state and fixtures
#
# Evidence: ~/spandeck-validation/<run>/ (kept by cleanup). The sanitized report is also copied to
# /Users/Shared/spandeck-validation-results/ for the owner's normal account. See VALIDATION_RUN.md.
set -euo pipefail
umask 077

PKG=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$PKG/identity.env"
[ -n "${APP_NAME:-}" ] && [ -n "${BUNDLE_ID:-}" ] && [ -n "${APP_SUPPORT_DIR:-}" ] || { echo "identity.env is incomplete"; exit 1; }
pkgval() { sed -n "s/^$1=//p" "$PKG/package.env" | head -1; }
MAIN_USER=$(pkgval main_user)
MAIN_UID=$(pkgval main_uid)
CANDIDATE=$(pkgval candidate_commit)
TEST_USER=${VALIDATE_TEST_USER:-spandecktest}
EVID_ROOT="$HOME/spandeck-validation"
RESULTS=/Users/Shared/spandeck-validation-results
APP_DST="$HOME/Applications/$APP_NAME.app"
APP_SUPPORT="$HOME/Library/Application Support/$APP_SUPPORT_DIR"
PROJECTS="$HOME/.claude/projects"
GROK="$HOME/.grok"
MARK=".spandeck-validation"   # marker file naming the run that created a fixture folder

die() { echo; echo "STOP: $*" >&2; [ -n "${RUN:-}" ] && [ -d "${RUN:-}" ] && echo "$(stamp) STOP $*" >> "$RUN/log.txt"; exit 1; }
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
say() { echo "$(stamp) $*" | tee -a "$RUN/log.txt"; }
# result ID PASS|FAIL|SKIP|INFO "detail": one line per check, the report's table.
result() {
    local detail; detail=$(printf '%s' "$3" | tr '\t\n' '  ')
    printf '%s\t%s\t%s\n' "$1" "$2" "$detail" >> "$RUN/results.tsv"
    printf '  [%s] %s: %s\n' "$2" "$1" "$detail" | tee -a "$RUN/log.txt"
}
# Reads one line from the terminal; stops the run if there is no terminal (it never guesses an answer).
tty_read() { local v; IFS= read -r v < /dev/tty || { echo "STOP: no terminal input" >&2; exit 1; }; printf '%s' "$v"; }
step() { echo; echo "================ $* ================" | tee -a "$RUN/log.txt"; }
pause() { echo; echo ">>> $*"; echo "    Press Return when done."; tty_read >/dev/null; }
# ask ID "question": a y/n observation of the real app, recorded as PASS (y) or FAIL (n). Optional note.
ask() {
    local id=$1 q=$2 a note
    echo; echo "??? $q [y/n]"
    a=$(tty_read)
    while [ "$a" != y ] && [ "$a" != n ]; do echo "    please answer y or n"; a=$(tty_read); done
    if [ "$a" = y ]; then result "$id" PASS "owner observed: $q"; else
        echo "    What did you see? (one line, no personal data)"; note=$(tty_read)
        result "$id" FAIL "owner observed NOT: $q — ${note:-no note}"
    fi
}
# ask_optional ID "question": like ask, but s records SKIP (not tried).
ask_optional() {
    local id=$1 q=$2 a
    echo; echo "??? $q [y/n/s=skip]"
    a=$(tty_read)
    case "$a" in
        y) result "$id" PASS "owner observed: $q" ;;
        n) echo "    What did you see? (one line)"; result "$id" FAIL "owner observed NOT: $q — $(tty_read)" ;;
        *) result "$id" SKIP "not tried" ;;
    esac
}
# This account's SpanDeck only: a copy running in another (fast-switched) session is never picked up.
app_pid() { pgrep -u "$(id -u)" -x "$APP_NAME" 2>/dev/null | head -1 || true; }
sanitize() { sed -e "s|$HOME|~|g" -e "s|/Users/$TEST_USER|~|g" -e "s|$TEST_USER|<test-user>|g" -e "s|$MAIN_USER|<main-user>|g"; }
human_tokens() { awk -v n="$1" 'BEGIN{ if (n>=1e9) printf "%.2fB", n/1e9; else if (n>=1e6) printf "%.1fM", n/1e6; else if (n>=1e3) printf "%.1fK", n/1e3; else printf "%d", n }'; }
current_run() { [ -f "$EVID_ROOT/current" ] && cat "$EVID_ROOT/current" || true; }

# ------------------------------------------------------------------------------------------------- isolation gate
# Every check must pass, or nothing is installed, written or launched.
gate() {
    step "P. Isolation and package gate"
    local fail=0
    pass() { result "$1" PASS "$2"; }
    bad() { result "$1" FAIL "$2"; fail=1; }

    [ "$(id -un)" = "$TEST_USER" ] || { echo "Running as $(id -un), not $TEST_USER. Nothing was done."; exit 1; }
    pass P1.user "running as $TEST_USER (uid $(id -u))"
    [ -n "$MAIN_USER" ] && [ "$MAIN_USER" != "$TEST_USER" ] && [ "$(id -u)" != "$MAIN_UID" ] \
        && pass P1.distinct "main account is a different user (uid $MAIN_UID)" || bad P1.distinct "main account not distinct"
    if dsmemberutil checkmembership -U "$TEST_USER" -G admin | grep -q "is a member"; then bad P1.admin "$TEST_USER is an administrator"
    else pass P1.admin "$TEST_USER is not an administrator"; fi
    local dshome; dshome=$(dscl . -read "/Users/$TEST_USER" NFSHomeDirectory | awk '{print $2}')
    [ "$HOME" = "$dshome" ] && [ "$HOME" = "/Users/$TEST_USER" ] && pass P1.home "HOME is the account's home" \
        || bad P1.home "HOME ($HOME) is not /Users/$TEST_USER ($dshome)"

    # The main account must be unreachable: not listable, not traversable, and none of its sensitive paths readable.
    local mh="/Users/$MAIN_USER" reach=""
    ls "$mh" >/dev/null 2>&1 && reach="$reach listable"
    [ -x "$mh" ] && reach="$reach traversable"
    local p
    for p in .claude .claude.json .claude/projects .claude/settings.json .config .config/claude .codex .codex/auth.json \
             .codex/sessions .grok .zshrc .ssh Library Library/Keychains "Library/Application Support" \
             "Library/Application Support/$APP_SUPPORT_DIR" "Library/Application Support/Headroom" Library/Preferences; do
        { [ -r "$mh/$p" ] || [ -x "$mh/$p" ]; } && reach="$reach ~$MAIN_USER/$p"
    done
    [ -z "$reach" ] && pass P2.main-home "main account's home is neither listable nor traversable; no sensitive path reachable" \
        || bad P2.main-home "main account reachable:$(echo "$reach" | sed "s|$MAIN_USER|<main-user>|g")"

    # Redirects: shell and launchd environments (apps started with `open` get launchd's), then symlinks.
    local v envbad=""
    while IFS= read -r v; do envbad="$envbad ${v%%=*}"; done < <(env | grep -F "/Users/$MAIN_USER" || true)
    for v in CLAUDE_CONFIG_DIR CODEX_HOME XDG_CONFIG_HOME XDG_DATA_HOME CFFIXED_USER_HOME HOME GROK_HOME; do
        local lv; lv=$(launchctl getenv "$v" 2>/dev/null || true)
        [ -z "$lv" ] || [[ "$lv" == "$HOME"* ]] || envbad="$envbad launchd:$v"
        local sv=${!v:-}
        [ -z "$sv" ] || [[ "$sv" == "$HOME"* ]] || envbad="$envbad shell:$v"
    done
    [ -z "$envbad" ] && pass P3.environment "no shell or launchd variable points outside this home" \
        || bad P3.environment "variables pointing outside this home:$envbad"
    local links outside=0 total=0
    links=$(find "$HOME" -xdev \( -path "$HOME/Library/Containers" -o -path "$HOME/Library/Group Containers" \
        -o -path "$HOME/Library/Mail" -o -path "$HOME/Library/Messages" -o -path "$HOME/Library/Safari" \
        -o -path "$HOME/Library/Biome" -o -path "$HOME/Library/Metadata" -o -path "$HOME/Library/Trial" \
        -o -path "$HOME/Library/Application Support/com.apple.TCC" -o -path "$EVID_ROOT" \) -prune -o -type l -print 2>/dev/null || true)
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        total=$((total + 1))
        local tgt; tgt=$(cd "$(dirname "$p")" 2>/dev/null && /bin/realpath "$p" 2>/dev/null || readlink "$p")
        [[ "$tgt" == "/Users/$MAIN_USER"* ]] && { outside=$((outside + 1)); echo "  link into main account: $(echo "$p" | sanitize)" >> "$RUN/log.txt"; }
    done <<< "$links"
    for p in "$HOME/.claude" "$PROJECTS" "$GROK" "$HOME/.config" "$HOME/Applications" "$APP_SUPPORT" \
             "$HOME/Library/Preferences/$BUNDLE_ID.plist"; do
        [ -L "$p" ] && { outside=$((outside + 1)); echo "  path SpanDeck uses is a link: $(echo "$p" | sanitize)" >> "$RUN/log.txt"; }
    done
    [ "$outside" = 0 ] && pass P3.links "no symlink into the main account; no SpanDeck path is a link ($total links checked)" \
        || bad P3.links "$outside link(s) into the main account or at SpanDeck paths (see log)"

    # Keychain: this account's own keychains only, and no Claude Code item (attributes only, never the secret).
    local kc kcbad=""
    while IFS= read -r kc; do kc=$(echo "$kc" | tr -d ' "'); [ -n "$kc" ] && [[ "$kc" != "$HOME/Library/Keychains/"* ]] && kcbad="$kcbad $kc"; done \
        < <(security list-keychains -d user 2>/dev/null; security default-keychain -d user 2>/dev/null)
    [ -z "$kcbad" ] && pass P4.keychain "user keychains are this account's own" || bad P4.keychain "keychain outside this home:$(echo "$kcbad" | sanitize)"
    if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then bad P4.claude-item "a Claude Code Keychain item exists in this account"
    else pass P4.claude-item "no Claude Code Keychain item (attribute lookup only)"; fi
    local cred credbad=""
    for cred in .claude/.credentials.json .grok/auth.json .codex/auth.json .config/claude/projects .grok/bin/grok; do
        [ -e "$HOME/$cred" ] && credbad="$credbad ~/$cred"
    done
    [ -z "$credbad" ] && pass P4.credentials "no Claude, Grok or Codex credential or CLI in this account" || bad P4.credentials "present:$credbad"

    # A clean slate for SpanDeck (state from an earlier run must be cleaned first, never mixed in).
    local slate=""
    [ -z "$(app_pid)" ] || slate="$slate running"
    [ ! -e "$APP_SUPPORT" ] || slate="$slate app-support"
    ! defaults read "$BUNDLE_ID" >/dev/null 2>&1 || slate="$slate preferences"
    [ ! -e "$APP_DST" ] || slate="$slate ~/Applications/$APP_NAME.app"
    [ -z "$slate" ] && pass P5.clean-slate "no SpanDeck process, state, preferences or app copy in this account" \
        || bad P5.clean-slate "leftover SpanDeck:$slate (not created by this tool: remove it by hand, see VALIDATION_RUN.md)"
    [ ! -e "/Applications/$APP_NAME.app" ] || result P5.system-app INFO "/Applications/$APP_NAME.app exists (not ours, left alone; this run launches ~/Applications/$APP_NAME.app by path)"
    if [ -e "$PROJECTS" ] && [ -n "$(find "$PROJECTS" -mindepth 1 -maxdepth 1 2>/dev/null)" ] && [ "${PARK:-0}" != 1 ]; then
        bad P5.transcripts "$HOME/.claude/projects already has entries; rerun with --park-existing to set them aside for this run (restored by cleanup)"
    fi
    [ ! -e "$GROK" ] || [ "${PARK:-0}" = 1 ] || bad P5.grok "$HOME/.grok exists; rerun with --park-existing"

    # Package: the DMG must have the SHA-256 you typed (from #94), and the package files their recorded hashes.
    local dmg="" got=""
    dmg=$(find "$PKG" -maxdepth 1 -name '*.dmg' -type f 2>/dev/null | head -1 || true)
    [ -n "$dmg" ] && got=$(shasum -a 256 "$dmg" 2>/dev/null | cut -d' ' -f1 || true)
    [ -n "$dmg" ] && [ "$got" = "$EXPECTED" ] && pass P6.dmg-sha256 "DMG SHA-256 $got matches the value given" \
        || bad P6.dmg-sha256 "DMG SHA-256 ${got:-missing} != expected $EXPECTED"
    (cd "$PKG" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1) && pass P6.sha256sums "SHA256SUMS verifies" || bad P6.sha256sums "SHA256SUMS does not verify"
    (cd "$PKG" && shasum -a 256 -c PACKAGE.sha256 >/dev/null 2>&1) && pass P6.package "package files match PACKAGE.sha256" || bad P6.package "package files changed since staging"
    [ "$(pkgval candidate_dmg_sha256)" = "$EXPECTED" ] || bad P6.package-env "package.env names a different DMG"
    if [ -n "$dmg" ] && xattr "$dmg" 2>/dev/null | grep -q com.apple.quarantine; then bad P6.quarantine "the DMG is quarantined; do not bypass Gatekeeper, restage it"
    else pass P6.quarantine "no quarantine attribute (no Gatekeeper bypass needed)"; fi
    local bad_files; bad_files=$(find "$PKG" -mindepth 1 \( -type l -o ! -user "$MAIN_USER" \) 2>/dev/null | wc -l | tr -d ' ')
    [ "$bad_files" = 0 ] && pass P6.package-owner "package files are plain files owned by the staging account" || bad P6.package-owner "$bad_files package entries are links or owned by someone else"

    echo; echo "Manual: System Settings > General > Login Items & Extensions. Is $APP_NAME listed? [y/n]"
    local li; li=$(tty_read)
    [ "$li" = y ] && bad P7.login-items "$APP_NAME already listed in Login Items" || pass P7.login-items "$APP_NAME not in Login Items (owner observation)"
    local free_kb; free_kb=$(df -k "$HOME" | awk 'NR==2{print $4}')
    [ "${free_kb:-0}" -ge 3000000 ] && pass P5.disk "$(( free_kb / 1048576 )) GB free (the large batches need up to ~1.5 GB)" \
        || bad P5.disk "only $(( ${free_kb:-0} / 1024 )) MB free; the large batches need ~1.5 GB"
    local hour; hour=$(date +%H)
    { [ "$hour" -ge 23 ] || [ "$hour" -lt 1 ]; } && result P7.clock INFO "within an hour of local midnight: 'Today' checks may roll over; consider running later"

    if [ $fail != 0 ]; then rm -f "$RUN/.active"; cmd_report >/dev/null 2>&1 || true
        die "isolation or package gate failed: nothing was installed or launched. Report: $RUN/report.md"; fi
    say "gate passed"
}

# ------------------------------------------------------------------------------------------------- fixtures
# Synthetic transcripts in this run's own folders, each marked with the run id. Messages are streamed twice (same
# message id and request id; counted once), plus one unpriced model. Grok: one session with two turns.
TOK=""
fixture_dir() { echo "$PROJECTS/-Users-$TEST_USER-spandeck-validation-$TOK"; }
claude_messages() { # file tag first last [pad-bytes]
    local f=$1 tag=$2 a=$3 b=$4 pad=${5:-0} ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    awk -v tag="$tag" -v tok="$TOK" -v a="$a" -v b="$b" -v ts="$ts" -v pad="$pad" 'BEGIN{
        p = ""; for (i = 0; i < pad; i++) p = p "x";
        for (i = a; i <= b; i++) {
            printf "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"VALCANARY%s prompt %d\"},\"timestamp\":\"%s\"}\n", tok, i, ts;
            printf "{\"type\":\"assistant\",\"requestId\":\"req_val%s_%s_%d\",\"message\":{\"id\":\"msg_val%s_%s_%d\",\"model\":\"claude-sonnet-4-5\",\"content\":[{\"type\":\"text\",\"text\":\"VALCANARY%s %s\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}},\"timestamp\":\"%s\"}\n", tok, tag, i, tok, tag, i, tok, p, ts;
            printf "{\"type\":\"assistant\",\"requestId\":\"req_val%s_%s_%d\",\"message\":{\"id\":\"msg_val%s_%s_%d\",\"model\":\"claude-sonnet-4-5\",\"content\":[{\"type\":\"text\",\"text\":\"VALCANARY%s %s\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":20,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}},\"timestamp\":\"%s\"}\n", tok, tag, i, tok, tag, i, tok, p, ts;
        }}' >> "$f"
}
write_small_fixtures() {
    local d; d=$(fixture_dir)
    mkdir -p "$d"; echo "run=$(basename "$RUN")" > "$PROJECTS/$MARK"; echo "run=$(basename "$RUN")" > "$d/$MARK"
    claude_messages "$d/main.jsonl" main 1 20
    printf '{"type":"assistant","requestId":"req_val%s_x","message":{"id":"msg_val%s_x","model":"claude-valmodel%s","usage":{"input_tokens":7,"output_tokens":3}},"timestamp":"%s"}\n' \
        "$TOK" "$TOK" "$TOK" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >> "$d/main.jsonl"
    local g="$GROK/sessions/spandeck-validation-$TOK/s1" now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "$g"; echo "run=$(basename "$RUN")" > "$GROK/$MARK"
    printf '{"turns":[{"endedAt":"%s","inputTokens":100,"outputTokens":50,"cachedReadTokens":0,"cacheCreationTokens":0,"modelCalls":1,"costUsdTicks":2500000000,"totalTokens":150,"primaryModelId":"grok-val"},{"endedAt":"%s","inputTokens":100,"outputTokens":50,"cachedReadTokens":0,"cacheCreationTokens":0,"modelCalls":1,"costUsdTicks":2500000000,"totalTokens":151,"primaryModelId":"grok-val"}]}\n' "$now" "$now" > "$g/usage.json"
}
# A project folder of its own (like Claude Code's, two levels below ~/.claude/projects), written while the app is quit,
# so the next launch's first full scan indexes it with progress in the footer.
write_big_fixtures() { # files messages-per-file tag
    local d; d="$(fixture_dir)-$3" k
    mkdir -p "$d"; echo "run=$(basename "$RUN")" > "$d/$MARK"
    for ((k = 1; k <= $1; k++)); do claude_messages "$d/s$k.jsonl" "$3f$k" 1 "$2" 400; done
}

# ------------------------------------------------------------------------------------------------- app control
# Background watchers are registered as "pid command" and stopped on exit, interrupt or cleanup; a pid is only
# signalled if it still runs the command it was registered with (no stale pid is ever killed).
register_watcher() { echo "$1 $(ps -o comm= -p "$1" 2>/dev/null | awk '{print $1}')" >> "$RUN/.watchers"; }
stop_watchers() {
    [ -n "${RUN:-}" ] && [ -f "$RUN/.watchers" ] || return 0
    local pid comm
    while read -r pid comm; do
        [ -n "$pid" ] && [ "$(ps -o comm= -p "$pid" 2>/dev/null | awk '{print $1}')" = "$comm" ] && kill "$pid" 2>/dev/null || true
    done < "$RUN/.watchers"
    : > "$RUN/.watchers"
}
on_exit() {
    stop_watchers
    if [ -n "${MOUNTED:-}" ] && [ -d "$MOUNTED" ]; then hdiutil detach "$MOUNTED" >/dev/null 2>&1 || true; fi
}
trap on_exit EXIT
trap 'echo; echo "Interrupted. Run ./validate.sh cleanup when ready."; exit 130' INT TERM

# launch LABEL: open the installed copy; watch it until it exits (forks, sockets, security/grok processes).
launch() {
    local label=$1 t0 pid=""
    [ -z "$(app_pid)" ] || die "$APP_NAME is already running"
    local w="$RUN/watch-$label"; mkdir -p "$w"
    log stream --style compact --predicate 'process == "security" OR process == "grok"' > "$w/tool-log.txt" 2>&1 &
    register_watcher $!
    sleep 1
    t0=$(ms)
    open "$APP_DST"
    for _ in $(seq 1 150); do pid=$(app_pid); [ -n "$pid" ] && break; sleep 0.1; done
    [ -n "$pid" ] || die "$APP_NAME did not start within 15 s"
    echo "$pid" > "$w/.pid"
    say "launch $label: pid after $(( $(ms) - t0 )) ms"
    "$PKG/procwatch" "$pid" > "$w/forks.txt" 2>&1 &
    register_watcher $!
    ( while kill -0 "$pid" 2>/dev/null; do
          lsof -nP -a -p "$pid" -i 2>/dev/null | tail -n +2 | awk '{print $8, $9}' >> "$w/sockets.txt" || true
          echo "$(stamp) $(ps -o %cpu=,rss= -p "$pid" 2>/dev/null)" >> "$w/samples.txt"
          sleep 2
      done ) &
    register_watcher $!
}
# wait_exit LABEL SECONDS: wait for the app to exit; prints the ms from the call to the exit, or "timeout".
wait_exit() {
    local w="$RUN/watch-$1" pid; pid=$(cat "$w/.pid" 2>/dev/null || true)
    local t0; t0=$(ms)
    for _ in $(seq 1 $(( $2 * 10 ))); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then echo timeout; return; fi
    echo $(( $(ms) - t0 ))
    stop_watchers
}
# Quitting is done by you in the app (popover > Quit): that runs SpanDeck's own quit path (#86). A signal wouldn't.
quit_app() { # label prompt -> echoes ms from Return to exit
    local label=$1
    { echo; echo ">>> $2"; echo "    With the popover open, press Return and click Quit right away."; } > /dev/tty
    tty_read >/dev/null
    wait_exit "$label" 60
}

# ------------------------------------------------------------------------------------------------- analysis (JXA)
# Sums of the usage cache (Claude): tokens per model kind, version, and whether it contains a path or a canary.
cache_summary() {
    [ -f "$APP_SUPPORT/claude-ledger.json" ] || { echo "absent"; return; }
    osascript -l JavaScript - "$APP_SUPPORT/claude-ledger.json" "$TOK" <<'JS'
function run(argv) {
    ObjC.import('Foundation');
    const s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
    if (!s) return 'unreadable';
    const text = s.js; let c;
    try { c = JSON.parse(text); } catch (e) { return 'invalid-json'; }
    let tokens = 0;
    for (const h of Object.values(c.slots || {})) for (const a of Object.values(h))
        tokens += Number(a.input||0) + Number(a.output||0) + Number(a.cacheWrite5m||0) + Number(a.cacheWrite1h||0) + Number(a.cacheRead||0) + Number(a.cacheWriteUnresolved||0);
    return ['version=' + c.version, 'tokens=' + tokens, 'has_slash=' + text.includes('/'),
            'has_content_canary=' + text.includes('VALCANARY'), 'has_id_canary=' + text.includes('msg_val' + argv[1])].join(' ');
}
JS
}
# Checks and summarizes a diagnostics export: allowed keys and labels only, no identifying strings; per-kind stats.
diag_summary() {
    osascript -l JavaScript - "$1" "$HOME" "$TEST_USER" "$MAIN_USER" "$TOK" <<'JS'
function run(argv) {
    ObjC.import('Foundation');
    const s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
    if (!s) return 'ERROR unreadable';
    const text = s.js; let j;
    try { j = JSON.parse(text); } catch (e) { return 'ERROR invalid-json'; }
    const out = [];
    const leaks = [argv[1], argv[2], argv[3], 'VALCANARY', argv[4], 'claude-valmodel', '/Users/'].filter(n => n && text.includes(n));
    out.push('LEAKS ' + (leaks.length ? leaks.length + ' identifying string(s)' : 'none'));
    const allowed = new Set(['t', 'kind', 'detail', 'ms', 'bytes', 'cpuPercent', 'footprintMB']);
    const ev = (j.session && j.session.events) || [];
    const extra = new Set();
    for (const e of ev) for (const k of Object.keys(e)) if (!allowed.has(k)) extra.add(k);
    out.push('KEYS ' + (extra.size ? 'unexpected: ' + [...extra].join(',') : 'ok'));
    out.push('TOPLEVEL ' + Object.keys(j).sort().join(',') + ' | ENV ' + Object.keys(j.environment || {}).sort().join(','));
    const by = {};
    for (const e of ev) { const k = e.kind + (e.detail ? ':' + e.detail : ''); (by[k] = by[k] || []).push(e); }
    const st = xs => { if (!xs.length) return 'n=0'; const s = xs.slice().sort((a, b) => a - b);
        const q = p => s[Math.min(s.length - 1, Math.ceil(p * s.length) - 1)];
        return 'n=' + s.length + ' median=' + q(0.5).toFixed(1) + ' p95=' + q(0.95).toFixed(1) + ' max=' + s[s.length - 1].toFixed(1); };
    for (const k of Object.keys(by).sort()) {
        const xs = by[k];
        let line = 'KIND ' + k + ' count=' + xs.length;
        const m = xs.map(e => e.ms).filter(x => typeof x === 'number'); if (m.length) line += ' ms[' + st(m) + ']';
        const b = xs.map(e => e.bytes).filter(x => typeof x === 'number'); if (b.length) line += ' bytes_max=' + Math.max(...b);
        const f = xs.map(e => e.footprintMB).filter(x => typeof x === 'number'); if (f.length) line += ' footprintMB[' + st(f) + ']';
        const c = xs.map(e => e.cpuPercent).filter(x => typeof x === 'number'); if (c.length) line += ' cpu%[' + st(c) + ']';
        out.push(line);
    }
    out.push('DROPPED ' + ((j.session && j.session.dropped) || 0));
    return out.join('\n');
}
JS
}
# Files this account changed since a marker, outside the evidence, fixtures and privacy-protected folders.
changed_since() {
    find "$HOME" \( -path "$EVID_ROOT" -o -path "$PROJECTS" -o -path "$GROK" -o -path "$HOME/.Trash" -o -path "$HOME/Desktop" \
        -o -path "$HOME/Documents" -o -path "$HOME/Downloads" -o -path "$HOME/Pictures" -o -path "$HOME/Movies" -o -path "$HOME/Music" \
        -o -path "$HOME/Library/Containers" -o -path "$HOME/Library/Group Containers" -o -path "$HOME/Library/Mail" \
        -o -path "$HOME/Library/Messages" -o -path "$HOME/Library/Safari" -o -path "$HOME/Library/Biome" -o -path "$HOME/Library/Metadata" \
        -o -path "$HOME/Library/Trial" -o -path "$HOME/Library/Application Support/com.apple.TCC" \) -prune \
        -o -type f -newer "$1" -print 2>/dev/null | sanitize | sort || true
}
screenshot() { # name
    [ "${SHOTS:-0}" = 1 ] || return 0
    echo "    Screenshot: drag a box around the open popover (Esc to skip)."
    screencapture -i -x "$RUN/screenshots/$1.png" 2>/dev/null || true
    [ -s "$RUN/screenshots/$1.png" ] && say "screenshot $1.png" || say "screenshot $1 skipped"
}

# ------------------------------------------------------------------------------------------------- the run
cmd_run() {
    EXPECTED=""; SHOTS=0; PARK=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --screenshots) SHOTS=1 ;;
            --park-existing) PARK=1 ;;
            *) echo "usage: ./validate.sh run [--screenshots] [--park-existing]"; exit 64 ;;
        esac; shift
    done
    [ "$(id -un)" = "$TEST_USER" ] || { echo "Running as $(id -un), not $TEST_USER. Nothing was done."; exit 1; }
    [ -z "$(current_run)" ] || [ ! -f "$(current_run)/.active" ] || { echo "A run is still active: $(current_run). Run ./validate.sh cleanup first."; exit 1; }
    echo "Type the candidate DMG SHA-256 from the #94 readiness report (64 hex characters):"
    EXPECTED=$(tty_read | tr -d ' ' | tr 'A-F' 'a-f')
    [[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] || { echo "Not a SHA-256. Nothing was done."; exit 1; }
    RUN="$EVID_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$RUN/screenshots"; chmod 700 "$EVID_ROOT"
    echo "$RUN" > "$EVID_ROOT/current"; touch "$RUN/.active"
    printf 'ID\tRESULT\tDETAIL\n' > "$RUN/results.tsv"
    say "run $(basename "$RUN"): candidate $CANDIDATE, package $(pkgval package_commit), macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m), $(sysctl -n hw.ncpu) cores"
    gate
    TOK=$(uuidgen | tr -d '-' | tr 'A-F' 'a-f' | cut -c1-12); echo "tok=$TOK" > "$RUN/.tok"

    if [ "$PARK" = 1 ]; then
        for p in "$HOME/.claude" "$GROK"; do
            [ -e "$p" ] || continue
            mv "$p" "$p.parked-$(basename "$RUN")"; echo "$p" >> "$RUN/.parked"
            say "parked $(echo "$p" | sanitize) for this run (restored by cleanup)"
        done
    fi

    # ---- A. Default launch on the candidate
    step "A. Install and default launch"
    local mnt="$RUN/.mnt"; mkdir -p "$mnt" "$HOME/Applications"
    hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$(find "$PKG" -maxdepth 1 -name '*.dmg' -type f | head -1)" >/dev/null
    MOUNTED=$mnt
    local bid; bid=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$mnt/$APP_NAME.app/Contents/Info.plist")
    [ "$bid" = "$BUNDLE_ID" ] || { hdiutil detach "$mnt" >/dev/null; die "DMG app is $bid, not $BUNDLE_ID"; }
    ditto "$mnt/$APP_NAME.app" "$APP_DST"
    hdiutil detach "$mnt" >/dev/null; MOUNTED=""; rmdir "$mnt"
    echo "run=$(basename "$RUN")" > "$RUN/.installed"
    local exe_sha want_exe; exe_sha=$(shasum -a 256 "$APP_DST/Contents/MacOS/$APP_NAME" | cut -d' ' -f1)
    want_exe=$(sed -n 's/^sha256 executable: *//p' "$PKG/PROVENANCE.txt")
    [ "$exe_sha" = "$want_exe" ] && result A1.install PASS "installed ~/Applications/$APP_NAME.app; executable SHA-256 matches PROVENANCE" \
        || die "installed executable SHA-256 $exe_sha != PROVENANCE $want_exe"
    codesign --verify --strict "$APP_DST" 2>/dev/null && result A1.signature INFO "ad-hoc signature valid on disk ($(lipo -archs "$APP_DST/Contents/MacOS/$APP_NAME"))" \
        || result A1.signature FAIL "codesign --verify failed"
    touch "$RUN/.before-launch"
    launch A
    echo "    Watching the first launch for 60 s: don't click anything yet."
    sleep 60
    local wA="$RUN/watch-A" forks sockets tools
    forks=$(grep -c ' fork ' "$wA/forks.txt" || true); sockets=$( [ -f "$wA/sockets.txt" ] && wc -l < "$wA/sockets.txt" | tr -d ' ' || true)
    tools=$(tail -n +2 "$wA/tool-log.txt" | grep -cE 'security\[|grok\[' || true)
    head -1 "$wA/tool-log.txt" | grep -q '^Filtering the log data' || tools=unavailable
    [ "${forks:-0}" = 0 ] && result A2.processes PASS "no child process (kernel-reported forks: 0)" || result A2.processes FAIL "$forks child process(es): $(grep ' fork ' "$wA/forks.txt" | awk '{print $NF}' | sort -u | tr '\n' ' ')"
    [ "${sockets:-0}" = 0 ] && result A2.network PASS "no network socket in 60 s (lsof every 2 s)" || result A2.network FAIL "$sockets socket observation(s)"
    case "$tools" in
        0) result A2.keychain-tools PASS "no security or grok process on this account while running (log stream)" ;;
        unavailable) result A2.keychain-tools INFO "log stream unavailable to this account; covered by the fork monitor (A2.processes)" ;;
        *) result A2.keychain-tools FAIL "$tools security/grok log line(s)" ;;
    esac
    local consent; consent="claude.limits.enabled=$(defaults read "$BUNDLE_ID" claude.limits.enabled 2>/dev/null || echo absent) grok.enabled=$(defaults read "$BUNDLE_ID" grok.enabled 2>/dev/null || echo absent)"
    [[ "$consent" =~ ^claude.limits.enabled=(absent|0)\ grok.enabled=(absent|0)$ ]] && result A2.consent PASS "integrations off: $consent" || result A2.consent FAIL "$consent"
    changed_since "$RUN/.before-launch" > "$RUN/A-changed-files.txt"
    result A2.files INFO "$(wc -l < "$RUN/A-changed-files.txt" | tr -d ' ') files changed in this home during first launch (list: A-changed-files.txt; macOS services write here too)"
    ask A2.keychain-prompt "No Keychain or permission dialog appeared"
    pause "Click the SpanDeck item in the menu bar to open the popover. Look at the Token usage card."
    screenshot A3-no-transcripts
    ask A3.not-found "The usage card says 'No Claude Code transcripts found…' and shows -- tiles, NOT 0 / \$0.00"
    ask A3.limits-off "The Claude Code card shows plan limits OFF with an 'Enable Claude plan limits' button (do NOT press it)"
    pause "Close the popover (click the menu-bar item again)."

    # ---- B. Everyday use
    step "B. Everyday use"
    pause "Open the popover > Settings (gear) > 'Start diagnostic session…'. Read the card, then click 'Start diagnostic session'. Close the popover."
    local _t; for _t in $(seq 1 60); do [ -f "$APP_SUPPORT/diagnostics.json" ] && break; sleep 1; done
    if [ -f "$APP_SUPPORT/diagnostics.json" ]; then
        result B5.start PASS "diagnostics.json created after Start (mode $(stat -f %Sp "$APP_SUPPORT/diagnostics.json"), folder $(stat -f %Sp "$APP_SUPPORT"))"
        [ "$(stat -f %Lp "$APP_SUPPORT/diagnostics.json")" = 600 ] && result B5.mode PASS "diagnostics file is 0600" || result B5.mode FAIL "diagnostics file mode $(stat -f %Lp "$APP_SUPPORT/diagnostics.json")"
    else result B5.start FAIL "no diagnostics.json 60 s after Start"; fi
    ask B5.disclosure "The disclosure card explained what is recorded, that nothing is uploaded, the 24 h and 7 day limits, before starting"

    write_small_fixtures
    say "fixtures: 20 messages streamed twice + 1 unpriced model (Claude: 610 tokens), Grok 2 turns (300 tokens)"
    echo "    Waiting 15 s for a refresh (every 10 s)…"; sleep 15
    pause "Open the popover. Wait until the footer says 'Usage updated …'."
    screenshot B2-first-totals
    ask B2.totals "The Claude row's Today value starts with 610 and the Grok row's with 300; the card header says 'Claude + Grok'"
    ask B2.unpriced "A note names claude-valmodel… as having no price, and Claude costs show ≥ (not \$0)"
    claude_messages "$(fixture_dir)/main.jsonl" main 21 30
    echo "    Appended 10 messages (and repeated none). Waiting 15 s…"; sleep 15
    ask B2.incremental "Without reopening anything, the Claude row's Today value now starts with 910 (it grew once, not twice)"
    pause "Now open and close the popover 10 times at a normal pace (click, look, click). Leave it closed."
    ask B1.popover "Every open showed the content promptly with no visible hitch or blank frame, and every close was clean"

    # B3: a normal quit, then quit during the first index of a large batch, then relaunch.
    local q0; q0=$(quit_app A "Open the popover and click Quit (a normal quit).")
    [ "$q0" != timeout ] && result B3.quit PASS "normal quit exited ${q0} ms after Return" || die "SpanDeck didn't quit within 60 s of Return"
    local big_files=${VALIDATE_BIG_FILES:-5000} big_msgs=${VALIDATE_BIG_MESSAGES:-40} attempt=0 quit_ms="" got=n
    while [ $attempt -lt 3 ]; do
        attempt=$((attempt + 1))
        echo "    Writing synthetic batch $attempt ($big_files files x $big_msgs messages; about a minute) while SpanDeck is quit..."
        write_big_fixtures "$big_files" "$big_msgs" "b$attempt"
        say "big batch $attempt written"
        launch "B3-try$attempt"
        echo "    SpanDeck is starting. Within a few seconds the popover footer shows 'Indexing Claude logs n/...'."
        quit_ms=$(quit_app "B3-try$attempt" "Open the popover. While the footer shows 'Indexing Claude logs ...', click Quit.")
        [ "$quit_ms" != timeout ] || die "SpanDeck didn't quit within 60 s of Return"
        echo "??? Did you click Quit while 'Indexing Claude logs' was showing? [y/n]"; got=$(tty_read)
        [ "$got" = y ] && break
        [ $attempt -lt 3 ] && echo "    No problem: another batch is written and SpanDeck relaunched for the next try."
    done
    if [ "$got" = y ]; then
        result B3.quit-during-index PASS "quit while indexing; exited ${quit_ms} ms after Return (includes your click). The app's own quit time is checked from diagnostics (B3.shutdown-time)"
    else result B3.quit-during-index SKIP "indexing wasn't caught in $attempt attempts"; fi
    local expected_big=$(( attempt * big_files * big_msgs * 30 )) expected_total
    expected_total=$(( 910 * 1 + expected_big ))
    launch B3
    pause "Wait until the footer shows 'Usage updated …' (the index resumes; it can take a minute). Then open the popover."
    screenshot B3-after-relaunch
    ask B3.relaunch-totals "The Claude row's Today value is $(human_tokens $expected_total) (all synthetic messages, none twice)"
    local q2; q2=$(quit_app B3 "Click Quit in the popover.")
    [ "$q2" != timeout ] && result B3.quit-after-index PASS "quit exited ${q2} ms after Return" || result B3.quit-after-index FAIL "quit didn't finish in 60 s"
    local cs; cs=$(cache_summary)
    echo "$cs" > "$RUN/cache-after-B3.txt"
    [[ "$cs" == *"tokens=$expected_total "* ]] && result B3.exact PASS "usage cache holds exactly $expected_total Claude tokens (every message once)" \
        || result B3.exact FAIL "cache summary: $cs (expected tokens=$expected_total)"
    [[ "$cs" == *"has_slash=false has_content_canary=false has_id_canary=false"* ]] && result B3.cache-privacy PASS "cache holds no path, transcript text or message id" \
        || result B3.cache-privacy FAIL "cache summary: $cs"

    # B4: corrupt cache while quit.
    printf '{corrupt by validate.sh' > "$APP_SUPPORT/claude-ledger.json"
    say "cache overwritten with garbage while SpanDeck was quit"
    launch B4
    pause "Wait until the footer shows 'Usage updated …' (it rebuilds from the transcripts). Then open the popover."
    ask B4.rebuilt "The Claude row's Today value is again $(human_tokens $expected_total), and nothing looked broken"

    # B5: export, stop, delete.
    pause "Settings > 'Export diagnostics…'. Save it as: $RUN/diagnostics-export.json  (Cmd-Shift-G in the panel, paste the folder)."
    if [ -f "$RUN/diagnostics-export.json" ]; then
        diag_summary "$RUN/diagnostics-export.json" > "$RUN/diagnostics-summary.txt"
        grep -q '^LEAKS none' "$RUN/diagnostics-summary.txt" && result B5.export-privacy PASS "export holds no path, user name, canary or model name" \
            || result B5.export-privacy FAIL "$(grep '^LEAKS' "$RUN/diagnostics-summary.txt")"
        grep -q '^KEYS ok' "$RUN/diagnostics-summary.txt" && result B5.export-keys PASS "export has only the documented keys" || result B5.export-keys FAIL "$(grep '^KEYS' "$RUN/diagnostics-summary.txt")"
        local k missing=""
        for k in launch firstUsage popoverOpen refresh cacheSave shutdown sessionResume process; do
            grep -q "^KIND ${k}[: ]" "$RUN/diagnostics-summary.txt" || missing="$missing $k"
        done
        local smax; smax=$(sed -n 's/^KIND shutdown[^ ]* count=[0-9]* ms\[n=[0-9]* median=[0-9.]* p95=[0-9.]* max=\([0-9.]*\)\].*/\1/p' "$RUN/diagnostics-summary.txt" | sort -n | tail -1)
        if [ -n "$smax" ]; then
            awk -v m="$smax" 'BEGIN{exit !(m <= 5500)}' && result B3.shutdown-time PASS "longest quit, measured by the app (request to reply): ${smax} ms (cap 5 s)" \
                || result B3.shutdown-time FAIL "longest quit, measured by the app: ${smax} ms (cap 5 s)"
        else result B3.shutdown-time FAIL "no shutdown event in the export"; fi
        [ -z "$missing" ] && result B5.export-kinds PASS "export has launch, firstUsage, popoverOpen, refresh, cacheSave, shutdown, sessionResume, process" \
            || result B5.export-kinds FAIL "missing kinds:$missing"
    else result B5.export FAIL "no export at the path given"; fi
    pause "Settings > 'Stop diagnostic session'. Then Settings > 'Delete diagnostic data'. Close the popover."
    sleep 2
    [ ! -e "$APP_SUPPORT/diagnostics.json" ] && result B5.delete PASS "diagnostics.json removed by Delete" || result B5.delete FAIL "diagnostics.json still present after Delete"
    ask_optional B6.voiceover "VoiceOver (Cmd-F5 on, open the popover, move over the usage notes and the limits card, Cmd-F5 off): the notes read sensibly"

    # ---- C. Integrations stay off; login item round trip
    step "C. Integrations"
    pause "Settings > turn ON 'Launch at login'. Then look at System Settings > General > Login Items & Extensions."
    ask C1.login-on "SpanDeck is listed under Login Items"
    pause "Back in SpanDeck: Settings > turn OFF 'Launch at login'. Check Login Items again."
    ask C1.login-off "SpanDeck is no longer listed"
    local q3; q3=$(quit_app B4 "Click Quit in the popover (final quit).")
    [ "$q3" != timeout ] && result C.final-quit PASS "final quit exited ${q3} ms after Return" || result C.final-quit FAIL "final quit didn't finish"
    cs=$(cache_summary); echo "$cs" > "$RUN/cache-final.txt"
    [[ "$cs" == *"version=7 tokens=$expected_total "* ]] && result B4.exact PASS "rebuilt cache is version 7 with exactly $expected_total tokens" \
        || result B4.exact FAIL "final cache: $cs (expected version=7 tokens=$expected_total)"
    local all_forks=0 all_socks=0 all_tools=0 w
    for w in "$RUN"/watch-*; do
        local f1 s1 t1
        f1=$(grep -c ' fork ' "$w/forks.txt" 2>/dev/null || true)
        s1=$( [ -f "$w/sockets.txt" ] && wc -l < "$w/sockets.txt" | tr -d ' ' || true)
        t1=$(tail -n +2 "$w/tool-log.txt" 2>/dev/null | grep -cE 'security\[|grok\[' || true)
        all_forks=$(( all_forks + ${f1:-0} )); all_socks=$(( all_socks + ${s1:-0} )); all_tools=$(( all_tools + ${t1:-0} ))
    done
    [ $all_forks = 0 ] && [ $all_socks = 0 ] && [ $all_tools = 0 ] \
        && result C2.no-egress PASS "across every launch: 0 child processes, 0 sockets, 0 security/grok processes" \
        || result C2.no-egress FAIL "forks $all_forks, sockets $all_socks, security/grok lines $all_tools"
    consent="claude.limits.enabled=$(defaults read "$BUNDLE_ID" claude.limits.enabled 2>/dev/null || echo absent) grok.enabled=$(defaults read "$BUNDLE_ID" grok.enabled 2>/dev/null || echo absent)"
    [[ "$consent" =~ ^claude.limits.enabled=(absent|0)\ grok.enabled=(absent|0)$ ]] && [ ! -e "$GROK/auth.json" ] \
        && ! security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 \
        && result C2.integrations-off PASS "consent never given ($consent), no credential created" || result C2.integrations-off FAIL "$consent"
    changed_since "$RUN/.before-launch" > "$RUN/all-changed-files.txt"
    rm -f "$RUN/.active"
    cmd_report
    echo; echo "Done. Review the report, then run: ./validate.sh cleanup"
}

# ------------------------------------------------------------------------------------------------- report
cmd_report() {
    RUN=${RUN:-$(current_run)}; [ -n "$RUN" ] && [ -d "$RUN" ] || { echo "No run found."; exit 1; }
    local out="$RUN/report.md" pass fail
    pass=$(awk -F'\t' '$2=="PASS"' "$RUN/results.tsv" | wc -l | tr -d ' ')
    fail=$(awk -F'\t' '$2=="FAIL"' "$RUN/results.tsv" | wc -l | tr -d ' ')
    {
        echo "# SpanDeck private-use validation: $(basename "$RUN")"
        echo
        echo "- Candidate: \`$CANDIDATE\` (DMG SHA-256 \`$(pkgval candidate_dmg_sha256)\`); package \`$(pkgval package_commit)\`"
        echo "- Account: <test-user>; macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
        echo "- **$pass PASS, $fail FAIL** (SKIP and INFO lines listed too). Synthetic fixtures only; no integration enabled."
        echo
        echo "| Check | Result | Detail |"; echo "|---|---|---|"
        tail -n +2 "$RUN/results.tsv" | sanitize | awk -F'\t' '{gsub(/\|/,"/",$3); printf "| %s | %s | %s |\n", $1, $2, $3}'
        echo
        echo "## Diagnostics (from the app's own export)"; echo; echo '```'
        if [ -f "$RUN/diagnostics-summary.txt" ]; then cat "$RUN/diagnostics-summary.txt"; else echo "no export"; fi
        echo '```'
        echo; echo "## Process samples (CPU %, RSS KB every 2 s, per launch)"; echo; echo '```'
        for w in "$RUN"/watch-*; do
            [ -f "$w/samples.txt" ] && awk -v l="$(basename "$w")" 'NF>=3{c+=$2; n++; if ($3>m) m=$3} END{if (n) printf "%s: %d samples, mean CPU %.2f%%, peak RSS %d KB\n", l, n, c/n, m}' "$w/samples.txt"
        done
        echo '```'
        echo; echo "## Files changed in the test home during the run (names only)"; echo; echo '```'
        head -80 "$RUN/all-changed-files.txt" 2>/dev/null || head -80 "$RUN/A-changed-files.txt" 2>/dev/null || echo none
        echo '```'
        echo; echo "## Log"; echo; echo '```'; sanitize < "$RUN/log.txt"; echo '```'
    } > "$out"
    mkdir -p "$RESULTS" 2>/dev/null || true
    if [ -w "$RESULTS" ]; then
        cp "$out" "$RESULTS/report-$(basename "$RUN").md" && chmod 644 "$RESULTS/report-$(basename "$RUN").md"
        echo "Report: $out (copy in $RESULTS for your main account; screenshots stay in $RUN/screenshots)"
    else echo "Report: $out ($RESULTS isn't writable; copy it by hand)"; fi
}

# ------------------------------------------------------------------------------------------------- cleanup
# Removes only what this tool created: the app copy it installed, SpanDeck's state in this account, and fixture
# folders carrying this run's marker. Restores parked folders. Keeps the evidence.
cmd_cleanup() {
    [ "$(id -un)" = "$TEST_USER" ] || { echo "Running as $(id -un), not $TEST_USER. Nothing was done."; exit 1; }
    RUN=$(current_run); [ -n "$RUN" ] && [ -d "$RUN" ] || { echo "No run recorded; nothing to clean."; exit 0; }
    local id; id=$(basename "$RUN")
    if [ -n "$(app_pid)" ]; then echo "Quit SpanDeck from its popover first (Settings > turn off Launch at login if on)."; exit 1; fi
    echo "Cleanup removes: ~/Applications/$APP_NAME.app (if this run installed it), SpanDeck's Application Support folder and"
    echo "preferences in THIS account, and fixture folders marked with run $id. Evidence in $RUN is kept. Continue? [y/N]"
    [ "$(tty_read)" = y ] || { echo "Cancelled."; exit 1; }
    stop_watchers
    if [ -f "$RUN/.installed" ] && [ -d "$APP_DST" ] && [ ! -L "$APP_DST" ] \
        && [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_DST/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ]; then
        rm -rf "$APP_DST"; echo "removed ~/Applications/$APP_NAME.app"
    fi
    # SpanDeck's state only if this run installed and launched it: the gate required a clean slate first, so the state
    # is this run's. After a failed gate nothing of SpanDeck's is touched.
    if [ -f "$RUN/.installed" ]; then
        [ -L "$APP_SUPPORT" ] || rm -rf "$APP_SUPPORT"
        defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
        defaults read "$BUNDLE_ID" >/dev/null 2>&1 || rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
        rm -rf "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID" "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
        echo "removed SpanDeck's state in this account (created by this run)"
    else echo "this run installed nothing: SpanDeck's state, if any, is left alone"; fi
    local d
    for d in "$PROJECTS"/-Users-"$TEST_USER"-spandeck-validation-*; do
        [ -d "$d" ] && [ ! -L "$d" ] && grep -qx "run=$id" "$d/$MARK" 2>/dev/null && { rm -rf "$d"; echo "removed fixtures $(basename "$d")"; }
    done
    for d in "$GROK"/sessions/spandeck-validation-*; do [ -d "$d" ] && [ ! -L "$d" ] && grep -qx "run=$id" "$GROK/$MARK" 2>/dev/null && rm -rf "$d"; done
    grep -qx "run=$id" "$PROJECTS/$MARK" 2>/dev/null && rm -f "$PROJECTS/$MARK"
    grep -qx "run=$id" "$GROK/$MARK" 2>/dev/null && rm -f "$GROK/$MARK"
    rmdir "$GROK/sessions" "$GROK" "$PROJECTS" "$HOME/.claude" 2>/dev/null || true
    if [ -f "$RUN/.parked" ]; then
        while IFS= read -r p; do
            if [ -e "$p.parked-$id" ] && [ ! -e "$p" ]; then mv "$p.parked-$id" "$p"; echo "restored $(echo "$p" | sanitize)"
            elif [ -e "$p.parked-$id" ]; then echo "WARNING: $(echo "$p" | sanitize) exists again, so the parked copy stays at $(echo "$p.parked-$id" | sanitize); merge or move it by hand"; fi
        done < "$RUN/.parked"
    fi
    rm -f "$RUN/.active"
    echo "Cleanup done. Evidence kept: $RUN"
}

# Reviewers can load the functions without running anything: VALIDATE_SOURCE_ONLY=1 . ./validate.sh
[ "${VALIDATE_SOURCE_ONLY:-0}" = 1 ] && return 0 2>/dev/null
case "${1:-}" in
    run) shift; cmd_run "$@" ;;
    report) cmd_report ;;
    cleanup) cmd_cleanup ;;
    *) sed -n '2,14p' "$0"; exit 64 ;;
esac
