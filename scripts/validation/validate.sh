#!/bin/bash
# shellcheck disable=SC2088  # "~/..." strings are messages for the reader, not paths
# #94 private-use validation, step 2 of 2: run ONLY while logged in as the dedicated test account (spandecktest).
# Validates the staged candidate in the real app: docs/VALIDATION.md §2 steps A–C. Guided: it does the setup,
# measurements and checks, and asks you to click in the app where a person has to (it never scripts clicks, so it
# needs no Accessibility, Automation or admin rights). Synthetic Claude and Grok fixtures only. Never enables an
# integration, never creates credentials, never sends anything anywhere.
#
#   ./validate.sh run [--screenshots] [--park-existing]   isolation gate, then A, B, C, then the report
#   ./validate.sh report                                  rebuild the report (and verdict) of the last run
#   ./validate.sh cleanup                                 remove only what the last run created; restore parked folders
#
# Evidence: ~/spandeck-validation/<run>/ (kept by cleanup). The sanitized report is also copied to
# /Users/Shared/spandeck-validation-results/ for the owner's normal account. See VALIDATION_RUN.md.
#
# Result statuses: PASS (verified), FAIL (verified problem), INCONCLUSIVE (the evidence was insufficient: never a
# PASS), SKIP (not done), INFO (context). VERDICT is GO only for a complete run with no FAIL, no INCONCLUSIVE and no
# skipped required check; anything else is NO-GO, with the reason.
set -euo pipefail
umask 077

PKG=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$PKG/identity.env"
[ -n "${APP_NAME:-}" ] && [ -n "${BUNDLE_ID:-}" ] && [ -n "${APP_SUPPORT_DIR:-}" ] || { echo "identity.env is incomplete"; exit 1; }
pkgval() { sed -n "s/^$1=//p" "$PKG/package.env" | head -1; }
MAIN_USER=$(pkgval main_user)
MAIN_UID=$(pkgval main_uid)
STAGER_UID=$(pkgval stager_uid)
CANDIDATE=$(pkgval candidate_commit)
[ -n "$MAIN_USER" ] && [ -n "$MAIN_UID" ] && [ -n "$STAGER_UID" ] || { echo "package.env is incomplete; restage"; exit 1; }

# Self-test mode (scripts/validation/selftest.sh) runs every path against disposable directories with stubbed system
# tools. It is only accepted with a temporary HOME, is labelled SELF-TEST everywhere, and never writes to
# /Users/Shared. Outside it, none of the VALIDATE_* overrides below has any effect.
TEST_USER=spandecktest
if [ "${VALIDATE_SELFTEST:-0}" = 1 ]; then
    case "$HOME" in /private/var/folders/*|/var/folders/*|/private/tmp/*|/tmp/*) ;; *) echo "self-test needs a temporary HOME"; exit 1 ;; esac
    MODE=SELF-TEST
    USERS_ROOT=${VALIDATE_USERS_ROOT:?}
    TTY_IN=${VALIDATE_TTY_IN:?}; TTY_OUT=/dev/null
    WATCH_SECS=${VALIDATE_WATCH_SECS:-3}; REFRESH_WAIT=1; DIAG_WAIT=1; QUIT_WAIT=5
    BIG_FILES=${VALIDATE_BIG_FILES:-3}; BIG_MESSAGES=${VALIDATE_BIG_MESSAGES:-2}
    RESULTS="$HOME/results"
    # Never a real-looking app in a self-test: macOS registers *.app folders and may try to open them.
    APP_DIR="$APP_NAME.selftest-bundle"
else
    MODE=VALIDATION
    USERS_ROOT=/Users
    TTY_IN=/dev/tty; TTY_OUT=/dev/tty
    WATCH_SECS=60; REFRESH_WAIT=15; DIAG_WAIT=60; QUIT_WAIT=60
    BIG_FILES=5000; BIG_MESSAGES=40
    RESULTS=/Users/Shared/spandeck-validation-results
    APP_DIR="$APP_NAME.app"
fi
EVID_ROOT="$HOME/spandeck-validation"
APP_DST="$HOME/Applications/$APP_DIR"
APP_SUPPORT="$HOME/Library/Application Support/$APP_SUPPORT_DIR"
PROJECTS="$HOME/.claude/projects"
GROK="$HOME/.grok"
MARK=".spandeck-validation"   # marker file naming the run that created a fixture folder
# Checks that may be skipped or unavailable without blocking a GO (still reported).
OPTIONAL_IDS=" B6.voiceover A2.log-stream "
# Every check a GO needs, each recorded as exactly PASS. One that is missing (never ran) is a NO-GO.
REQUIRED_IDS="P1.user P1.distinct P1.admin P1.home P2.main-home P3.environment P3.links P4.keychain P4.claude-item
 P4.credentials P5.clean-slate P5.disk P6.dmg-sha256 P6.sha256sums P6.package P6.quarantine P6.package-owner
 P7.login-items A1.install A1.keychain-api A2.processes A2.network A2.keychain A2.consent A2.keychain-prompt
 A3.not-found A3.limits-off B5.start B5.mode B5.disclosure B2.totals B2.unpriced B2.incremental B1.popover B3.quit
 B3.quit-during-index B3.relaunch-totals B3.quit-after-index B3.exact B3.cache-privacy B4.rebuilt B5.export-privacy
 B5.export-keys B3.shutdown-time B5.export-kinds B5.delete C1.login-on C1.login-off C.final-quit B4.exact
 C2.no-egress C2.integrations-off"

die() { echo; echo "STOP: $*" >&2; [ -n "${RUN:-}" ] && [ -d "${RUN:-}" ] && echo "$(stamp) STOP $*" >> "$RUN/log.txt"; exit 1; }
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
say() { echo "$(stamp) $*" | tee -a "$RUN/log.txt"; }
# result ID PASS|FAIL|INCONCLUSIVE|SKIP|INFO "detail": one line per check, the report's table.
result() {
    local detail; detail=$(printf '%s' "$3" | tr '\t\n' '  ')
    printf '%s\t%s\t%s\n' "$1" "$2" "$detail" >> "$RUN/results.tsv"
    printf '  [%s] %s: %s\n' "$2" "$1" "$detail" | tee -a "$RUN/log.txt"
}
# Terminal input on fd 3, opened once per command; no input stops the run (an answer is never guessed).
open_tty() { exec 3<"$TTY_IN"; }
tty_read() { local v; IFS= read -r v <&3 || { echo "STOP: no terminal input" >&2; exit 1; }; printf '%s' "$v"; }
step() { echo; echo "================ $* ================" | tee -a "$RUN/log.txt"; }
pause() { echo; echo ">>> $*"; echo "    Press Return when done."; tty_read >/dev/null; }
# ask ID "question": a y/n observation of the real app, recorded as PASS (y) or FAIL (n), with a note for n.
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
sanitize() { sed -e "s|$HOME|~|g" -e "s|$USERS_ROOT/$TEST_USER|~|g" -e "s|$TEST_USER|<test-user>|g" -e "s|$MAIN_USER|<main-user>|g"; }
human_tokens() { awk -v n="$1" 'BEGIN{ if (n>=1e9) printf "%.2fB", n/1e9; else if (n>=1e6) printf "%.1fM", n/1e6; else if (n>=1e3) printf "%.1fK", n/1e3; else printf "%d", n }'; }
current_run() { [ -f "$EVID_ROOT/current" ] && cat "$EVID_ROOT/current" || true; }
# Content hash of a bundle: every regular file's path and SHA-256, and every link's path and target, in order.
tree_hash() {
    (cd "$1" && { find . -type f -print0 | sort -z | xargs -0 shasum -a 256; find . -type l | sort | while read -r l; do echo "link $l -> $(readlink "$l")"; done; }) | shasum -a 256 | cut -d' ' -f1
}
# Creates a folder and any missing parents, recording each folder it created, so cleanup removes only those (and only
# when empty). Never reuses a path that exists as something other than a folder.
mkdir_tracked() {
    local target=$1 parts=() p
    p=$target
    while [ ! -d "$p" ]; do
        [ ! -e "$p" ] && [ ! -L "$p" ] || die "$(echo "$p" | sanitize) exists and is not a folder; nothing was overwritten"
        parts=("$p" "${parts[@]+"${parts[@]}"}"); p=$(dirname "$p")
    done
    for p in "${parts[@]+"${parts[@]}"}"; do mkdir "$p"; echo "$p" >> "$RUN/.created"; done
}

# ------------------------------------------------------------------------------------------------- isolation gate
# Every check must pass, or nothing is installed, written or launched (verdict NO-GO).
gate() {
    step "P. Isolation and package gate"
    local fail=0
    pass() { result "$1" PASS "$2"; }
    bad() { result "$1" FAIL "$2"; fail=1; }

    [ "$MODE" = VALIDATION ] || result P0.mode INFO "SELF-TEST with disposable directories and stubbed system tools: NOT a validation of SpanDeck"
    pass P1.user "running as $TEST_USER (uid $(id -u))"
    [ "$MAIN_USER" != "$TEST_USER" ] && [ "$(id -u)" != "$MAIN_UID" ] \
        && pass P1.distinct "main account is a different user (uid $MAIN_UID)" || bad P1.distinct "main account not distinct"
    if dsmemberutil checkmembership -U "$TEST_USER" -G admin 2>/dev/null | grep -q "is a member"; then bad P1.admin "$TEST_USER is an administrator"
    else pass P1.admin "$TEST_USER is not an administrator"; fi
    local dshome; dshome=$(dscl . -read "/Users/$TEST_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)
    [ "$HOME" = "$dshome" ] && [ "$HOME" = "$USERS_ROOT/$TEST_USER" ] && pass P1.home "HOME is the account's home" \
        || bad P1.home "HOME is not the account's home ($(echo "${dshome:-unknown}" | sanitize))"

    # The main account must be unreachable: not listable, not traversable, and none of its sensitive paths readable.
    local mh="$USERS_ROOT/$MAIN_USER" reach="" p
    # It must exist (stat needs no access to its contents), or "unreachable" would be shown about nothing.
    [ -e "$mh" ] || bad P2.main-home-exists "the main account's home ($USERS_ROOT/<main-user>) doesn't exist: wrong package.env? Unreachability not shown"
    ls "$mh" >/dev/null 2>&1 && reach="$reach listable"
    [ -x "$mh" ] && reach="$reach traversable"
    for p in .claude .claude.json .claude/projects .claude/settings.json .config .config/claude .codex .codex/auth.json \
             .codex/sessions .grok .zshrc .ssh Library Library/Keychains "Library/Application Support" \
             "Library/Application Support/$APP_SUPPORT_DIR" "Library/Application Support/Headroom" Library/Preferences; do
        { [ -r "$mh/$p" ] || [ -x "$mh/$p" ]; } && reach="$reach ~/$p"
    done
    [ -z "$reach" ] && pass P2.main-home "main account's home is neither listable nor traversable; no sensitive path reachable" \
        || bad P2.main-home "main account reachable:$reach"

    # Redirects: shell and launchd environments (apps started with `open` get launchd's), then symlinks.
    local v envbad="" lv sv
    while IFS= read -r v; do envbad="$envbad ${v%%=*}"; done < <(env | grep -F "$USERS_ROOT/$MAIN_USER" || true)
    for v in CLAUDE_CONFIG_DIR CODEX_HOME XDG_CONFIG_HOME XDG_DATA_HOME CFFIXED_USER_HOME HOME GROK_HOME; do
        lv=$(launchctl getenv "$v" 2>/dev/null || true)
        [ -z "$lv" ] || [[ "$lv" == "$HOME" || "$lv" == "$HOME/"* ]] || envbad="$envbad launchd:$v"
        sv=${!v:-}
        [ -z "$sv" ] || [[ "$sv" == "$HOME" || "$sv" == "$HOME/"* ]] || envbad="$envbad shell:$v"
    done
    [ -z "$envbad" ] && pass P3.environment "no shell or launchd variable points outside this home" \
        || bad P3.environment "variables pointing outside this home:$envbad"
    local links outside=0 total=0 tgt
    links=$(find "$HOME" -xdev \( -path "$HOME/Library/Containers" -o -path "$HOME/Library/Group Containers" \
        -o -path "$HOME/Library/Mail" -o -path "$HOME/Library/Messages" -o -path "$HOME/Library/Safari" \
        -o -path "$HOME/Library/Biome" -o -path "$HOME/Library/Metadata" -o -path "$HOME/Library/Trial" \
        -o -path "$HOME/Library/Application Support/com.apple.TCC" -o -path "$EVID_ROOT" \) -prune -o -type l -print 2>/dev/null || true)
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        total=$((total + 1))
        tgt=$(readlink "$p" || true)
        case "$tgt" in /*) ;; *) tgt="$(dirname "$p")/$tgt" ;; esac
        [[ "$tgt" == "$USERS_ROOT/$MAIN_USER"* || "$tgt" == "/Users/$MAIN_USER"* ]] && { outside=$((outside + 1)); echo "  link into main account: $(echo "$p" | sanitize)" >> "$RUN/log.txt"; }
    done <<< "$links"
    for p in "$HOME/.claude" "$PROJECTS" "$GROK" "$HOME/.config" "$HOME/Applications" "$APP_SUPPORT" \
             "$HOME/Library/Preferences/$BUNDLE_ID.plist" "$EVID_ROOT"; do
        [ -L "$p" ] && { outside=$((outside + 1)); echo "  path this run uses is a link: $(echo "$p" | sanitize)" >> "$RUN/log.txt"; }
    done
    [ "$outside" = 0 ] && pass P3.links "no symlink into the main account; no path this run uses is a link ($total links checked)" \
        || bad P3.links "$outside link(s) into the main account or at paths this run uses (see log)"

    # Keychain: this account's own keychains only (an unreadable list is not a pass), and no Claude Code item.
    local kc kcbad="" kcn=0
    while IFS= read -r kc; do
        kc=$(echo "$kc" | tr -d ' "'); [ -n "$kc" ] || continue; kcn=$((kcn + 1))
        [[ "$kc" == "$HOME/Library/Keychains/"* ]] || kcbad="$kcbad $kc"
    done < <(security list-keychains -d user 2>/dev/null || true)
    if [ "$kcn" = 0 ]; then bad P4.keychain "the user keychain list couldn't be read: separation not shown"
    elif [ -n "$kcbad" ]; then bad P4.keychain "keychain outside this home:$(echo "$kcbad" | sanitize)"
    else pass P4.keychain "all $kcn user keychain(s) are this account's own"; fi
    local rc=0; security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 || rc=$?
    case $rc in
        44) pass P4.claude-item "no Claude Code Keychain item (attribute lookup only; 'not found')" ;;
        0) bad P4.claude-item "a Claude Code Keychain item exists in this account" ;;
        *) bad P4.claude-item "the Keychain lookup failed (status $rc): absence not shown" ;;
    esac
    local cred credbad=""
    for cred in .claude/.credentials.json .grok/auth.json .codex/auth.json .config/claude/projects .grok/bin/grok; do
        [ -e "$HOME/$cred" ] || [ -L "$HOME/$cred" ] && credbad="$credbad ~/$cred"
    done
    [ -z "$credbad" ] && pass P4.credentials "no Claude, Grok or Codex credential or CLI in this account" || bad P4.credentials "present:$credbad"

    # A clean slate for SpanDeck: state from anywhere else is never mixed in, and never deleted by this tool.
    local slate=""
    [ -z "$(app_pid)" ] || slate="$slate running"
    [ ! -e "$APP_SUPPORT" ] && [ ! -L "$APP_SUPPORT" ] || slate="$slate app-support"
    ! defaults read "$BUNDLE_ID" >/dev/null 2>&1 || slate="$slate preferences"
    [ ! -e "$APP_DST" ] && [ ! -L "$APP_DST" ] || slate="$slate ~/Applications/$APP_NAME.app"
    [ -z "$slate" ] && pass P5.clean-slate "no SpanDeck process, state, preferences or app copy in this account" \
        || bad P5.clean-slate "leftover SpanDeck:$slate (not created by this tool: remove it by hand, see VALIDATION_RUN.md)"
    [ ! -e "/Applications/$APP_NAME.app" ] || result P5.system-app INFO "/Applications/$APP_NAME.app exists (not ours, left alone; this run launches ~/Applications/$APP_NAME.app by path)"
    if [ -e "$PROJECTS" ] && [ -n "$(find "$PROJECTS" -mindepth 1 -maxdepth 1 2>/dev/null)" ] && [ "$PARK" != 1 ]; then
        bad P5.transcripts "~/.claude/projects already has entries; rerun with --park-existing to set them aside for this run (restored by cleanup)"
    fi
    { [ ! -e "$GROK" ] && [ ! -L "$GROK" ]; } || [ "$PARK" = 1 ] || bad P5.grok "~/.grok exists; rerun with --park-existing"
    if [ "$PARK" = 1 ]; then
        for p in "$HOME/.claude" "$GROK"; do
            { [ -e "$p.parked-$RUN_ID" ] || [ -L "$p.parked-$RUN_ID" ]; } && bad P5.park "$(echo "$p" | sanitize).parked-$RUN_ID already exists"
        done
    fi
    local free_kb; free_kb=$(df -k "$HOME" | awk 'NR==2{print $4}')
    [ "${free_kb:-0}" -ge 3000000 ] && pass P5.disk "$(( free_kb / 1048576 )) GB free (the large batches need up to ~1.5 GB)" \
        || bad P5.disk "only $(( ${free_kb:-0} / 1024 )) MB free; the large batches need ~1.5 GB"

    # Package: the DMG must have the SHA-256 you typed (from #94), and the package files their recorded hashes.
    local dmg="" got=""
    dmg=$(find "$PKG" -maxdepth 1 -name '*.dmg' -type f 2>/dev/null | head -1 || true)
    [ -n "$dmg" ] && got=$(shasum -a 256 "$dmg" 2>/dev/null | cut -d' ' -f1 || true)
    [ -n "$dmg" ] && [ "$got" = "$EXPECTED" ] && pass P6.dmg-sha256 "DMG SHA-256 $got matches the value given" \
        || bad P6.dmg-sha256 "DMG SHA-256 ${got:-missing} != expected $EXPECTED"
    (cd "$PKG" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1) && pass P6.sha256sums "SHA256SUMS verifies" || bad P6.sha256sums "SHA256SUMS does not verify"
    (cd "$PKG" && shasum -a 256 -c PACKAGE.sha256 >/dev/null 2>&1) && pass P6.package "package files match PACKAGE.sha256" || bad P6.package "package files changed since staging"
    [ "$(pkgval candidate_dmg_sha256)" = "$EXPECTED" ] || bad P6.package-env "package.env names a different DMG"
    if [ -z "$dmg" ]; then bad P6.quarantine "no DMG to check"
    elif xattr "$dmg" 2>/dev/null | grep -q com.apple.quarantine; then bad P6.quarantine "the DMG is quarantined; do not bypass Gatekeeper, restage it"
    else pass P6.quarantine "no quarantine attribute (no Gatekeeper bypass needed)"; fi
    local foreign; foreign=$(find "$PKG" -mindepth 1 \( -type l -o ! -type f -o ! -user "$STAGER_UID" \) 2>/dev/null | wc -l | tr -d ' ')
    [ "$foreign" = 0 ] && pass P6.package-owner "package entries are plain files owned by the staging account" \
        || bad P6.package-owner "$foreign package entries are links, folders or owned by someone else"

    echo; echo "Manual: System Settings > General > Login Items & Extensions. Is $APP_NAME listed? [y/n]"
    local li; li=$(tty_read)
    case "$li" in
        n) pass P7.login-items "$APP_NAME not in Login Items (owner observation)" ;;
        *) bad P7.login-items "$APP_NAME listed in Login Items, or no clear answer" ;;
    esac
    local hour; hour=$(date +%H)
    { [ "$hour" -ge 23 ] || [ "$hour" -lt 1 ]; } && result P7.clock INFO "within an hour of local midnight: 'Today' checks may roll over; consider running later"

    if [ $fail != 0 ]; then
        rm -f "$RUN/.active"; cmd_report >/dev/null 2>&1 || true
        die "isolation or package gate failed: VERDICT NO-GO. Nothing was installed or launched. Report: $RUN/report.md"
    fi
    touch "$RUN/.gate-passed"
    say "gate passed"
}

# ------------------------------------------------------------------------------------------------- fixtures
# Synthetic transcripts in folders this run creates (a folder that exists already stops the run; nothing is reused or
# overwritten), each marked with the run id before anything is written in it. Messages are streamed twice (same
# message id and request id; counted once), plus one unpriced model. Grok: one session with two turns.
TOK=""
fixture_dir() { echo "$PROJECTS/-Users-$TEST_USER-spandeck-validation-$TOK"; }
new_fixture_dir() { # path
    [ ! -e "$1" ] && [ ! -L "$1" ] || die "$(echo "$1" | sanitize) already exists; nothing was overwritten"
    mkdir_tracked "$(dirname "$1")"
    mkdir "$1"; echo "run=$RUN_ID" > "$1/$MARK"
}
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
    new_fixture_dir "$d"
    claude_messages "$d/main.jsonl" main 1 20
    printf '{"type":"assistant","requestId":"req_val%s_x","message":{"id":"msg_val%s_x","model":"claude-valmodel%s","usage":{"input_tokens":7,"output_tokens":3}},"timestamp":"%s"}\n' \
        "$TOK" "$TOK" "$TOK" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >> "$d/main.jsonl"
    local g="$GROK/sessions/spandeck-validation-$TOK" now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    new_fixture_dir "$g"
    mkdir "$g/s1"
    printf '{"turns":[{"endedAt":"%s","inputTokens":100,"outputTokens":50,"cachedReadTokens":0,"cacheCreationTokens":0,"modelCalls":1,"costUsdTicks":2500000000,"totalTokens":150,"primaryModelId":"grok-val"},{"endedAt":"%s","inputTokens":100,"outputTokens":50,"cachedReadTokens":0,"cacheCreationTokens":0,"modelCalls":1,"costUsdTicks":2500000000,"totalTokens":151,"primaryModelId":"grok-val"}]}\n' "$now" "$now" > "$g/s1/usage.json"
}
# A project folder of its own (like Claude Code's, two levels below ~/.claude/projects), written while the app is quit,
# so the next launch's first full scan indexes it with progress in the footer.
write_big_fixtures() { # files messages-per-file tag
    local d; d="$(fixture_dir)-$3" k
    new_fixture_dir "$d"
    for ((k = 1; k <= $1; k++)); do claude_messages "$d/s$k.jsonl" "$3f$k" 1 "$2" 400; done
}

# ------------------------------------------------------------------------------------------------- app control
# Background watchers are registered as "pid start-time" and stopped on exit, interrupt or cleanup. The start time
# doesn't change when the process execs, and a reused pid has a different one, so no stale pid is ever signalled.
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' '_' || true; }
register_watcher() { echo "$1 $(proc_start "$1")" >> "$RUN/.watchers"; }
stop_watchers() {
    [ -n "${RUN:-}" ] && [ -f "$RUN/.watchers" ] || return 0
    local pid started
    while read -r pid started; do
        [ -n "$pid" ] && [ -n "$started" ] && [ "$(proc_start "$pid")" = "$started" ] && kill "$pid" 2>/dev/null || true
    done < "$RUN/.watchers"
    : > "$RUN/.watchers"
}
on_exit() {
    local rc=$?
    stop_watchers
    if [ -n "${MOUNTED:-}" ] && [ -d "$MOUNTED" ]; then hdiutil detach "$MOUNTED" >/dev/null 2>&1 || true; fi
    # A run that stopped for any reason still gets its report, and its verdict says why (never silently).
    if [ "${IN_RUN:-0}" = 1 ] && [ "$rc" != 0 ] && [ -n "${RUN:-}" ] && [ -d "$RUN" ]; then
        echo "$(stamp) run stopped (exit $rc) before completing" >> "$RUN/log.txt"
        cmd_report >/dev/null 2>&1 || true
        echo "VERDICT: NO-GO (the run stopped before completing; report: $RUN/report.md). Run ./validate.sh cleanup next."
    fi
}
trap on_exit EXIT
trap 'echo; echo "Interrupted. Run ./validate.sh cleanup when ready."; exit 130' INT TERM

# launch LABEL: open the installed copy and watch it until it exits. Each monitor records whether it actually
# observed the process, so missing evidence is reported as INCONCLUSIVE, never as an absence.
launch() {
    local label=$1 t0 pid=""
    [ -z "$(app_pid)" ] || die "$APP_NAME is already running"
    local w="$RUN/watch-$label"; mkdir -p "$w"
    log stream --style compact --predicate 'process == "security" OR process == "grok"' > "$w/tool-log.txt" 2>&1 &
    register_watcher $!
    sleep 1
    touch "$RUN/.launched"   # from here on, SpanDeck state in this account is this run's (the gate saw none)
    t0=$(ms)
    open "$APP_DST" || die "open failed for the installed app"
    for _ in $(seq 1 150); do pid=$(app_pid); [ -n "$pid" ] && break; sleep 0.1; done
    [ -n "$pid" ] || die "$APP_NAME did not start within 15 s"
    echo "$pid" > "$w/.pid"
    say "launch $label: pid after $(( $(ms) - t0 )) ms"
    "$PKG/procwatch" "$pid" > "$w/forks.txt" 2>&1 &
    register_watcher $!
    local _i; for _i in $(seq 1 30); do grep -q " watching $pid\$" "$w/forks.txt" 2>/dev/null && break; sleep 0.1; done
    grep -q " watching $pid\$" "$w/forks.txt" 2>/dev/null && touch "$w/.procwatch-ok" || say "launch $label: fork monitor did not attach"
    ( while kill -0 "$pid" 2>/dev/null; do
          out=$(lsof -nP -p "$pid" 2>/dev/null || true)
          if [ -n "$out" ]; then
              echo ok >> "$w/lsof-samples.txt"
              echo "$out" | awk 'NR>1 && ($5=="IPv4" || $5=="IPv6") {print $5, $8, $9}' >> "$w/sockets.txt"
          else echo fail >> "$w/lsof-samples.txt"; fi
          echo "$(stamp) $(ps -o %cpu=,rss= -p "$pid" 2>/dev/null)" >> "$w/samples.txt"
          sleep 2
      done ) &
    register_watcher $!
}
# Evidence for one launch: "forks sockets tools procwatch_ok lsof_ok lsof_fail log_ok"
launch_evidence() {
    local w="$RUN/watch-$1" f s t pw lo lf lg
    f=$(grep -c ' fork ' "$w/forks.txt" 2>/dev/null || true)
    s=$( [ -f "$w/sockets.txt" ] && wc -l < "$w/sockets.txt" | tr -d ' ' || true)
    t=$(tail -n +2 "$w/tool-log.txt" 2>/dev/null | grep -cE 'security\[|grok\[' || true)
    pw=0; [ -f "$w/.procwatch-ok" ] && pw=1
    lo=$(grep -c '^ok$' "$w/lsof-samples.txt" 2>/dev/null || true); lf=$(grep -c '^fail$' "$w/lsof-samples.txt" 2>/dev/null || true)
    lg=0; head -1 "$w/tool-log.txt" 2>/dev/null | grep -q '^Filtering the log data' && lg=1
    echo "${f:-0} ${s:-0} ${t:-0} $pw ${lo:-0} ${lf:-0} $lg"
}
# C2: across every launch, absence counts only where the monitors observed the launch. Per-launch sample counts are
# in the detail; limits: the fork monitor attaches just after the app starts, and lsof sees sockets open at a sample.
egress_result() {
    local w label f s t pw lo lf lg tf=0 ts=0 blind="" counts=""
    for w in "$RUN"/watch-*; do
        [ -d "$w" ] || continue
        label=${w##*/watch-}
        read -r f s t pw lo lf lg <<< "$(launch_evidence "$label")"
        tf=$(( tf + f )); ts=$(( ts + s )); counts="$counts $label:${lo}/$(( lo + lf ))"
        [ "$pw" = 1 ] || blind="$blind $label:fork-monitor"
        lsof_enough "$lo" "$lf" 1 || blind="$blind $label:lsof"
    done
    if [ -z "$counts" ]; then result C2.no-egress INCONCLUSIVE "no launch was monitored"
    elif [ $tf != 0 ] || [ $ts != 0 ]; then result C2.no-egress FAIL "child processes $tf, socket observations $ts"
    elif [ -n "$blind" ]; then result C2.no-egress INCONCLUSIVE "no child process or socket seen, but monitoring was missing for:$blind"
    else result C2.no-egress PASS "no child process in any launch (fork monitor attached each time); no socket seen in lsof samples per launch (seen/taken):$counts"; fi
}
# lsof coverage is enough when it saw the process in at least `min` samples and in 90 % of them.
lsof_enough() { [ "$1" -ge "$3" ] && [ $(( $1 * 10 )) -ge $(( ($1 + $2) * 9 )) ]; }
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
    { echo; echo ">>> $2"; echo "    With the popover open, press Return and click Quit right away."; } > "$TTY_OUT"
    tty_read >/dev/null
    wait_exit "$label" "$QUIT_WAIT"
}

# ------------------------------------------------------------------------------------------------- analysis (JXA)
# Sums of the usage cache (Claude): tokens, version, and whether it contains a path or a canary.
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
    [ "$SHOTS" = 1 ] || return 0
    echo "    Screenshot: drag a box around the open popover (Esc to skip)."
    screencapture -i -x "$RUN/screenshots/$1.png" 2>/dev/null || true
    [ -s "$RUN/screenshots/$1.png" ] && say "screenshot $1.png" || say "screenshot $1 skipped"
}
consent_now() { echo "claude.limits.enabled=$(defaults read "$BUNDLE_ID" claude.limits.enabled 2>/dev/null || echo absent) grok.enabled=$(defaults read "$BUNDLE_ID" grok.enabled 2>/dev/null || echo absent)"; }
consent_off() { [[ "$1" =~ ^claude.limits.enabled=(absent|0)\ grok.enabled=(absent|0)$ ]]; }

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
    [ -z "$(current_run)" ] || [ ! -f "$(current_run)/.active" ] || [ -f "$(current_run)/.cleaned" ] || { echo "A run is still active: $(current_run). Run ./validate.sh cleanup first."; exit 1; }
    open_tty
    echo "Type the candidate DMG SHA-256 from the #94 readiness report (64 hex characters):"
    EXPECTED=$(tty_read | tr -d ' ' | tr 'A-F' 'a-f')
    [[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] || { echo "Not a SHA-256. Nothing was done."; exit 1; }
    [ ! -L "$EVID_ROOT" ] || { echo "$EVID_ROOT is a link. Nothing was done."; exit 1; }
    RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
    RUN="$EVID_ROOT/$RUN_ID"
    [ ! -e "$RUN" ] || { echo "$RUN exists. Nothing was done."; exit 1; }
    mkdir -p "$RUN/screenshots"; chmod 700 "$EVID_ROOT"
    echo "$RUN" > "$EVID_ROOT/current"; touch "$RUN/.active"; IN_RUN=1
    echo "$MODE" > "$RUN/.mode"
    printf 'ID\tRESULT\tDETAIL\n' > "$RUN/results.tsv"
    say "run $RUN_ID ($MODE): candidate $CANDIDATE, package $(pkgval package_commit), macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m), $(sysctl -n hw.ncpu) cores"
    gate
    TOK=$(uuidgen | tr -d '-' | tr 'A-F' 'a-f' | cut -c1-12); echo "tok=$TOK" > "$RUN/.tok"

    # Parking: the intent is recorded before each move, so an interruption at any point can be undone by cleanup.
    if [ "$PARK" = 1 ]; then
        local p
        for p in "$HOME/.claude" "$GROK"; do
            [ -e "$p" ] || [ -L "$p" ] || continue
            echo "$p" >> "$RUN/.parked"
            mv "$p" "$p.parked-$RUN_ID"
            echo "$(tree_hash "$p.parked-$RUN_ID") $p" >> "$RUN/.parked-hashes"
            say "parked $(echo "$p" | sanitize) for this run (restored by cleanup)"
        done
    fi

    # ---- A. Default launch on the candidate
    step "A. Install and default launch"
    local mnt="$RUN/.mnt"; mkdir "$mnt"; mkdir_tracked "$HOME/Applications"
    hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$(find "$PKG" -maxdepth 1 -name '*.dmg' -type f | head -1)" >/dev/null
    MOUNTED=$mnt
    local bid; bid=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$mnt/$APP_DIR/Contents/Info.plist" 2>/dev/null || true)
    [ "$bid" = "$BUNDLE_ID" ] || die "the DMG's app is not $BUNDLE_ID"
    # The exact bytes are recorded before the copy, so cleanup can tell this run's copy from anything else.
    local src_tree; src_tree=$(tree_hash "$mnt/$APP_DIR")
    echo "tree=$src_tree" > "$RUN/.installing"
    [ ! -e "$APP_DST" ] && [ ! -L "$APP_DST" ] || die "~/Applications/$APP_NAME.app appeared after the gate; nothing was overwritten"
    ditto "$mnt/$APP_DIR" "$APP_DST"
    hdiutil detach "$mnt" >/dev/null; MOUNTED=""; rmdir "$mnt"
    [ "$(tree_hash "$APP_DST")" = "$src_tree" ] || die "the installed copy differs from the DMG's app"
    mv "$RUN/.installing" "$RUN/.installed"
    local exe_sha want_exe; exe_sha=$(shasum -a 256 "$APP_DST/Contents/MacOS/$APP_NAME" | cut -d' ' -f1)
    want_exe=$(sed -n 's/^sha256 executable: *//p' "$PKG/PROVENANCE.txt")
    [ -n "$want_exe" ] && [ "$exe_sha" = "$want_exe" ] && result A1.install PASS "installed ~/Applications/$APP_NAME.app; executable SHA-256 matches PROVENANCE; bundle hash recorded" \
        || die "installed executable SHA-256 doesn't match PROVENANCE"
    codesign --verify --strict "$APP_DST" 2>/dev/null && result A1.signature INFO "ad-hoc signature valid on disk ($(lipo -archs "$APP_DST/Contents/MacOS/$APP_NAME" 2>/dev/null || echo '?'))" \
        || result A1.signature FAIL "codesign --verify failed"
    # Static: an in-process Keychain read needs the Security framework's item APIs; none may be imported.
    local nmout secsyms; nmout=$(nm -u "$APP_DST/Contents/MacOS/$APP_NAME" 2>/dev/null || true)
    if [ -z "$nmout" ]; then result A1.keychain-api INCONCLUSIVE "couldn't list the binary's imported symbols"
    else
        secsyms=$(echo "$nmout" | grep -cE '_SecItem|_SecKeychain|_SecAccess' || true)
        [ "$secsyms" = 0 ] && result A1.keychain-api PASS "the binary imports no Keychain API (SecItem/SecKeychain/SecAccess): an in-process Keychain read is impossible" \
            || result A1.keychain-api FAIL "the binary imports $secsyms Keychain API symbol(s)"
    fi
    touch "$RUN/.before-launch"
    launch A
    echo "    Watching the first launch for $WATCH_SECS s: don't click anything yet."
    sleep "$WATCH_SECS"
    local ev f s t pw lo lf lg
    ev=$(launch_evidence A); read -r f s t pw lo lf lg <<< "$ev"
    local alive=1; { kill -0 "$(cat "$RUN/watch-A/.pid")" 2>/dev/null && ! grep -q ' exit$' "$RUN/watch-A/forks.txt"; } || alive=0
    if [ "$pw" != 1 ]; then result A2.processes INCONCLUSIVE "the fork monitor didn't attach: child processes not observed"
    elif [ "$alive" != 1 ] && [ "$f" = 0 ]; then result A2.processes INCONCLUSIVE "the app exited during the watch window: the whole window wasn't observed"
    elif [ "$f" = 0 ]; then result A2.processes PASS "no child process (kernel fork monitor attached for the whole window)"
    else result A2.processes FAIL "$f child process(es): $(grep ' fork ' "$RUN/watch-A/forks.txt" | awk '{print $NF}' | sort -u | tr '\n' ' ')"; fi
    local min=$(( WATCH_SECS / 4 )); [ $min -ge 1 ] || min=1
    if [ "$s" != 0 ]; then result A2.network FAIL "$s socket observation(s)"
    elif lsof_enough "$lo" "$lf" "$min"; then result A2.network PASS "no network socket ($lo lsof samples saw the process, $lf missed)"
    else result A2.network INCONCLUSIVE "lsof saw the process in only $lo sample(s) ($lf missed): network absence not shown"; fi
    if [ "$pw" = 1 ] && [ "$f" = 0 ] && [ "$alive" = 1 ] && grep -q '^A1.keychain-api	PASS' "$RUN/results.tsv"; then
        result A2.keychain PASS "no Keychain access: no Keychain API in the binary, and no security (or any) child process"
    elif [ "$f" != 0 ] && grep ' fork ' "$RUN/watch-A/forks.txt" | grep -q security; then result A2.keychain FAIL "a security process was started"
    else result A2.keychain INCONCLUSIVE "the static check or the fork monitor is missing: Keychain absence not shown"; fi
    if [ "$lg" != 1 ]; then result A2.log-stream INFO "supplementary: log stream unavailable to this account (A2.keychain and A2.processes don't depend on it)"
    elif [ "$t" = 0 ]; then result A2.log-stream PASS "supplementary: no security or grok process anywhere in this account (log stream)"
    else result A2.log-stream FAIL "$t security/grok log line(s) in this account"; fi
    local consent; consent=$(consent_now)
    consent_off "$consent" && result A2.consent PASS "integrations off: $consent" || result A2.consent FAIL "$consent"
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
    local _t; for _t in $(seq 1 "$DIAG_WAIT"); do [ -f "$APP_SUPPORT/diagnostics.json" ] && break; sleep 1; done
    if [ -f "$APP_SUPPORT/diagnostics.json" ]; then
        result B5.start PASS "diagnostics.json created after Start"
        [ "$(stat -f %Lp "$APP_SUPPORT/diagnostics.json")" = 600 ] && result B5.mode PASS "diagnostics file is 0600" || result B5.mode FAIL "diagnostics file mode $(stat -f %Lp "$APP_SUPPORT/diagnostics.json")"
    else result B5.start FAIL "no diagnostics.json $DIAG_WAIT s after Start"; fi
    ask B5.disclosure "The disclosure card explained what is recorded, that nothing is uploaded, the 24 h and 7 day limits, before starting"

    write_small_fixtures
    say "fixtures: 20 messages streamed twice + 1 unpriced model (Claude: 610 tokens), Grok 2 turns (300 tokens)"
    echo "    Waiting $REFRESH_WAIT s for a refresh (every 10 s)…"; sleep "$REFRESH_WAIT"
    pause "Open the popover. Wait until the footer says 'Usage updated …'."
    screenshot B2-first-totals
    ask B2.totals "The Claude row's Today value starts with 610 and the Grok row's with 300; the card header says 'Claude + Grok'"
    ask B2.unpriced "A note names claude-valmodel… as having no price, and Claude costs show ≥ (not \$0)"
    claude_messages "$(fixture_dir)/main.jsonl" main 21 30
    echo "    Appended 10 messages (and repeated none). Waiting $REFRESH_WAIT s…"; sleep "$REFRESH_WAIT"
    ask B2.incremental "Without reopening anything, the Claude row's Today value now starts with 910 (it grew once, not twice)"
    pause "Now open and close the popover 10 times at a normal pace (click, look, click). Leave it closed."
    ask B1.popover "Every open showed the content promptly with no visible hitch or blank frame, and every close was clean"

    # B3: a normal quit, then quit during the first index of a large batch, then relaunch.
    local q0; q0=$(quit_app A "Open the popover and click Quit (a normal quit).")
    [ "$q0" != timeout ] && result B3.quit PASS "normal quit exited ${q0} ms after Return" || die "SpanDeck didn't quit within $QUIT_WAIT s of Return"
    local big_files=$BIG_FILES big_msgs=$BIG_MESSAGES attempt=0 quit_ms="" got=n
    while [ $attempt -lt 3 ]; do
        attempt=$((attempt + 1))
        echo "    Writing synthetic batch $attempt ($big_files files x $big_msgs messages; about a minute) while SpanDeck is quit..."
        write_big_fixtures "$big_files" "$big_msgs" "b$attempt"
        say "big batch $attempt written"
        launch "B3-try$attempt"
        echo "    SpanDeck is starting. Within a few seconds the popover footer shows 'Indexing Claude logs n/N'."
        quit_ms=$(quit_app "B3-try$attempt" "Open the popover. While the footer shows 'Indexing Claude logs ...', click Quit.")
        [ "$quit_ms" != timeout ] || die "SpanDeck didn't quit within $QUIT_WAIT s of Return"
        echo "??? Did you click Quit while 'Indexing Claude logs' was showing? [y/n]"; got=$(tty_read)
        [ "$got" = y ] && break
        [ $attempt -lt 3 ] && echo "    No problem: another batch is written and SpanDeck relaunched for the next try."
    done
    if [ "$got" = y ]; then
        result B3.quit-during-index PASS "quit while indexing; exited ${quit_ms} ms after Return (includes your click). The app's own quit time is checked from diagnostics (B3.shutdown-time)"
    else result B3.quit-during-index SKIP "indexing wasn't caught in $attempt attempts"; fi
    local expected_total=$(( 910 + attempt * big_files * big_msgs * 30 ))
    launch B3
    pause "Wait until the footer shows 'Usage updated …' (the index resumes; it can take a minute). Then open the popover."
    screenshot B3-after-relaunch
    ask B3.relaunch-totals "The Claude row's Today value is $(human_tokens $expected_total) (all synthetic messages, none twice)"
    local q2; q2=$(quit_app B3 "Click Quit in the popover.")
    [ "$q2" != timeout ] && result B3.quit-after-index PASS "quit exited ${q2} ms after Return" || result B3.quit-after-index FAIL "quit didn't finish in $QUIT_WAIT s"
    local cs; cs=$(cache_summary)
    echo "$cs" > "$RUN/cache-after-B3.txt"
    [[ "$cs" == *"tokens=$expected_total "* ]] && result B3.exact PASS "usage cache holds exactly $expected_total Claude tokens (every message once)" \
        || result B3.exact FAIL "cache summary: $cs (expected tokens=$expected_total)"
    [[ "$cs" == *"has_slash=false has_content_canary=false has_id_canary=false"* ]] && result B3.cache-privacy PASS "cache holds no path, transcript text or message id" \
        || result B3.cache-privacy FAIL "cache summary: $cs"

    # B4: corrupt cache while quit (SpanDeck's own file in this account, created by this run).
    [ -f "$APP_SUPPORT/claude-ledger.json" ] && [ ! -L "$APP_SUPPORT/claude-ledger.json" ] || die "no usage cache to corrupt"
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
            || result B5.export-privacy FAIL "$(head -1 "$RUN/diagnostics-summary.txt")"
        grep -q '^KEYS ok' "$RUN/diagnostics-summary.txt" && result B5.export-keys PASS "export has only the documented keys" || result B5.export-keys FAIL "$(grep '^KEYS' "$RUN/diagnostics-summary.txt" || echo 'no KEYS line')"
        local k missing=""
        for k in launch firstUsage popoverOpen refresh cacheSave shutdown sessionResume process; do
            grep -q "^KIND ${k}[: ]" "$RUN/diagnostics-summary.txt" || missing="$missing $k"
        done
        local smax; smax=$(sed -n 's/^KIND shutdown[^ ]* count=[0-9]* ms\[n=[0-9]* median=[0-9.]* p95=[0-9.]* max=\([0-9.]*\)\].*/\1/p' "$RUN/diagnostics-summary.txt" | sort -n | tail -1)
        if [ -n "$smax" ]; then
            awk -v m="$smax" 'BEGIN{exit !(m <= 5500)}' && result B3.shutdown-time PASS "longest quit, measured by the app (request to reply): ${smax} ms (cap 5 s)" \
                || result B3.shutdown-time FAIL "longest quit, measured by the app: ${smax} ms (cap 5 s)"
        else result B3.shutdown-time INCONCLUSIVE "no shutdown event in the export"; fi
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
    egress_result
    consent=$(consent_now)
    local rc=0; security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 || rc=$?
    if ! consent_off "$consent" || [ -e "$GROK/auth.json" ] || [ $rc = 0 ]; then result C2.integrations-off FAIL "$consent; grok key $([ -e "$GROK/auth.json" ] && echo present || echo absent); Claude item $([ $rc = 0 ] && echo present || echo absent)"
    elif [ $rc != 44 ]; then result C2.integrations-off INCONCLUSIVE "consent off, but the Keychain lookup failed (status $rc)"
    else result C2.integrations-off PASS "consent never given ($consent); no Grok key; no Claude Keychain item"; fi
    changed_since "$RUN/.before-launch" > "$RUN/all-changed-files.txt"
    touch "$RUN/.complete"
    rm -f "$RUN/.active"
    cmd_report
    echo; echo "Done. Review the report, then run: ./validate.sh cleanup"
}

# ------------------------------------------------------------------------------------------------- report
# The verdict: GO only for a complete run whose gate passed, with no FAIL, no INCONCLUSIVE and no skipped required
# check. Anything else is NO-GO, with every reason.
verdict() {
    local r=""
    [ -f "$RUN/.gate-passed" ] || r="$r; isolation or package gate failed or didn't finish"
    [ -f "$RUN/.complete" ] || r="$r; run incomplete"
    local fails inconc skips missing="" id
    for id in $REQUIRED_IDS; do
        [ "$(awk -F'\t' -v i="$id" 'NR>1 && $1==i {s=$2} END{print s}' "$RUN/results.tsv")" = PASS ] \
            || [ -n "$(awk -F'\t' -v i="$id" 'NR>1 && $1==i' "$RUN/results.tsv")" ] || missing="$missing $id"
    done
    [ -z "$missing" ] || r="$r; required checks missing (never ran):$missing"
    fails=$(awk -F'\t' 'NR>1 && $2=="FAIL"{printf " %s", $1}' "$RUN/results.tsv")
    inconc=$(awk -F'\t' 'NR>1 && $2=="INCONCLUSIVE"{printf " %s", $1}' "$RUN/results.tsv")
    skips=$(awk -F'\t' -v opt="$OPTIONAL_IDS" 'NR>1 && $2=="SKIP" && index(opt, " " $1 " ")==0 {printf " %s", $1}' "$RUN/results.tsv")
    [ -z "$fails" ] || r="$r; FAIL:$fails"
    [ -z "$inconc" ] || r="$r; INCONCLUSIVE (evidence insufficient):$inconc"
    [ -z "$skips" ] || r="$r; required checks skipped:$skips"
    if [ "$(cat "$RUN/.mode" 2>/dev/null)" != VALIDATION ]; then echo "NO-GO — SELF-TEST, not a validation${r}"
    elif [ -z "$r" ]; then echo "GO for main-account testing (all required checks verified)"
    else echo "NO-GO${r}"; fi
}
cmd_report() {
    RUN=${RUN:-$(current_run)}; [ -n "$RUN" ] && [ -d "$RUN" ] || { echo "No run found."; exit 1; }
    local out="$RUN/report.md" n v
    v=$(verdict)
    {
        echo "# SpanDeck private-use validation: $(basename "$RUN")"
        echo
        echo "**VERDICT: $v**"
        echo
        [ "$(cat "$RUN/.mode" 2>/dev/null)" = VALIDATION ] || echo "> SELF-TEST with disposable directories and stubbed tools. This is NOT a validation of SpanDeck."
        echo "- Candidate: \`$CANDIDATE\` (DMG SHA-256 \`$(pkgval candidate_dmg_sha256)\`); package \`$(pkgval package_commit)\`"
        echo "- Account: <test-user>; macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
        printf -- "- Counts:"
        for n in PASS FAIL INCONCLUSIVE SKIP INFO; do printf ' %s %s' "$(awk -F'\t' -v s=$n 'NR>1 && $2==s' "$RUN/results.tsv" | wc -l | tr -d ' ')" "$n"; done
        echo ". Synthetic fixtures only; no integration enabled."
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
        if [ -f "$RUN/all-changed-files.txt" ]; then head -80 "$RUN/all-changed-files.txt"; elif [ -f "$RUN/A-changed-files.txt" ]; then head -80 "$RUN/A-changed-files.txt"; else echo none; fi
        echo '```'
        if [ -f "$RUN/cleanup.txt" ]; then echo; echo "## Cleanup"; echo; echo '```'; sanitize < "$RUN/cleanup.txt"; echo '```'; fi
        echo; echo "## Log"; echo; echo '```'; sanitize < "$RUN/log.txt"; echo '```'
    } > "$out"
    mkdir -p "$RESULTS" 2>/dev/null || true
    if [ -w "$RESULTS" ]; then
        cp "$out" "$RESULTS/report-$(basename "$RUN").md" && chmod 644 "$RESULTS/report-$(basename "$RUN").md"
        echo "Report: $out (copy in $RESULTS; screenshots stay in $RUN/screenshots)"
    else echo "Report: $out ($RESULTS isn't writable; copy it by hand)"; fi
    echo "VERDICT: $v"
}

# ------------------------------------------------------------------------------------------------- cleanup
# Removes only what the last run created, each item verified first; anything that doesn't match is kept and reported.
# Never overwrites or merges: a parked folder is restored only into an empty place. Keeps the evidence.
cmd_cleanup() {
    [ "$(id -un)" = "$TEST_USER" ] || { echo "Running as $(id -un), not $TEST_USER. Nothing was done."; exit 1; }
    RUN=$(current_run); [ -n "$RUN" ] && [ -d "$RUN" ] || { echo "No run recorded; nothing to clean."; exit 0; }
    local id; id=$(basename "$RUN")
    # Once only: after a cleanup, anything SpanDeck-related in this account is no longer this run's.
    [ ! -f "$RUN/.cleaned" ] || { echo "Run $id was already cleaned up; nothing was done (see $RUN/cleanup.txt)."; exit 0; }
    if [ -n "$(app_pid)" ]; then echo "Quit SpanDeck from its popover first (Settings > turn off Launch at login if on). Nothing was done."; exit 1; fi
    open_tty
    echo "Cleanup removes only what run $id created and can verify: its app copy (exact bundle hash), SpanDeck's state"
    echo "in THIS account if the run launched the app, its marked fixture folders, and empty folders it created."
    echo "Parked folders are put back. Evidence in $RUN is kept. Continue? [y/N]"
    [ "$(tty_read)" = y ] || { echo "Cancelled. Nothing was done."; exit 1; }
    stop_watchers
    local log="$RUN/cleanup.txt" kept=0
    echo "cleanup $(stamp)" >> "$log"
    note() { echo "$*" | tee -a "$log"; }
    keep() { note "KEPT: $*"; kept=$((kept + 1)); }

    # The app copy: removed only if it is byte-for-byte what this run installed.
    local rec=""; [ -f "$RUN/.installed" ] && rec="$RUN/.installed"; [ -z "$rec" ] && [ -f "$RUN/.installing" ] && rec="$RUN/.installing"
    if [ -n "$rec" ] && { [ -e "$APP_DST" ] || [ -L "$APP_DST" ]; }; then
        local want; want=$(sed -n 's/^tree=//p' "$rec")
        if [ ! -L "$APP_DST" ] && [ -d "$APP_DST" ] && [ -n "$want" ] && [ "$(tree_hash "$APP_DST")" = "$want" ]; then
            rm -rf "$APP_DST"; note "removed ~/Applications/$APP_NAME.app (bundle hash matched this run's install)"
        else keep "~/Applications/$APP_NAME.app differs from what this run installed (changed or replaced); not removed"; fi
    elif [ -e "$APP_DST" ]; then note "~/Applications/$APP_NAME.app was not installed by this run; left alone"; fi

    # SpanDeck's state: created by this run only if it launched the app after the gate found none.
    if [ -f "$RUN/.launched" ] && [ -f "$RUN/.gate-passed" ]; then
        if [ -L "$APP_SUPPORT" ]; then keep "SpanDeck's Application Support folder is a link"
        else rm -rf "$APP_SUPPORT"; note "removed SpanDeck's Application Support folder (created by this run)"; fi
        defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
        defaults read "$BUNDLE_ID" >/dev/null 2>&1 || rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
        rm -rf "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID" "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
        note "removed SpanDeck's preferences and caches in this account (created by this run)"
    else note "this run never launched SpanDeck: SpanDeck's state, if any, is left alone"; fi

    # Fixture folders: only those carrying this run's marker, and not links.
    local d
    for d in "$PROJECTS"/-Users-"$TEST_USER"-spandeck-validation-* "$GROK"/sessions/spandeck-validation-*; do
        [ -e "$d" ] || [ -L "$d" ] || continue
        if [ -d "$d" ] && [ ! -L "$d" ] && grep -qx "run=$id" "$d/$MARK" 2>/dev/null; then rm -rf "$d"; note "removed fixtures $(basename "$d")"
        else keep "$(echo "$d" | sanitize) is not marked with this run"; fi
    done
    # Folders this run created, newest first, only when empty.
    if [ -f "$RUN/.created" ]; then
        local c
        while IFS= read -r c; do
            [ -d "$c" ] && [ ! -L "$c" ] || continue
            if rmdir "$c" 2>/dev/null; then note "removed empty folder $(echo "$c" | sanitize)"
            else keep "$(echo "$c" | sanitize) (created by this run) now holds other data"; fi
        done < <(tail -r "$RUN/.created")
    fi
    # Parked folders: back only into an empty place, never merged or overwritten.
    if [ -f "$RUN/.parked" ]; then
        local p
        while IFS= read -r p; do
            if [ -e "$p.parked-$id" ] || [ -L "$p.parked-$id" ]; then
                if [ -e "$p" ] || [ -L "$p" ]; then
                    keep "$(echo "$p" | sanitize) exists again, so the parked original stays at $(echo "$p.parked-$id" | sanitize): merge or move it by hand"
                else
                    mv "$p.parked-$id" "$p"
                    local was; was=$(awk -v p="$p" '$2==p{print $1}' "$RUN/.parked-hashes" 2>/dev/null | tail -1)
                    if [ -z "$was" ]; then keep "restored $(echo "$p" | sanitize); contents not verified (no hash was recorded)"
                    elif [ "$(tree_hash "$p")" != "$was" ]; then keep "restored $(echo "$p" | sanitize), but its contents changed while parked"
                    else note "restored $(echo "$p" | sanitize) (contents unchanged)"; fi
                fi
            elif [ -e "$p" ]; then note "$(echo "$p" | sanitize) is in place (it was never moved)"
            else keep "$(echo "$p" | sanitize) was recorded for parking but neither it nor its parked copy exists"; fi
        done < "$RUN/.parked"
    fi
    rm -f "$RUN/.active"; touch "$RUN/.cleaned"
    cmd_report >/dev/null 2>&1 || true
    if [ "$kept" = 0 ]; then echo "Cleanup done. Evidence kept: $RUN"
    else echo "Cleanup done with $kept item(s) KEPT for you to review (see above and $log). Evidence kept: $RUN"; fi
}

# Reviewers can load the functions without running anything: VALIDATE_SOURCE_ONLY=1 . ./validate.sh
[ "${VALIDATE_SOURCE_ONLY:-0}" = 1 ] && return 0 2>/dev/null
case "${1:-}" in
    run) shift; cmd_run "$@" ;;
    report) cmd_report ;;
    cleanup) cmd_cleanup ;;
    *) sed -n '2,18p' "$0"; exit 64 ;;
esac
