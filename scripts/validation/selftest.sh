#!/bin/bash
# Self-test for validate.sh (#94): drives its failure, interruption and cleanup paths in disposable directories under
# /private/tmp, with stubbed system tools. Never touches either real account's SpanDeck, Keychain, preferences,
# launchd or Applications folder, and never launches SpanDeck. The "app" is a tiny program compiled here and named
# SpanDeck, in a folder named SpanDeck.selftest-bundle: nothing macOS treats as an application, so nothing is
# registered with Launch Services, opened, or killed for its signature (a copied system binary would be).
#
#   scripts/validation/selftest.sh            run every scenario; prints PASS/FAIL per assertion; exit 1 on any FAIL
#   KEEP=1 scripts/validation/selftest.sh     keep the sandbox for inspection
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
ROOT=$(mktemp -d /private/tmp/spandeck-validate-selftest.XXXXXX)
ME=$(/usr/bin/id -u)
FAILS=0 PASSES=0

kill_sandbox_processes() { pkill -f "$ROOT/" 2>/dev/null || true; sleep 0.3; pkill -9 -f "$ROOT/" 2>/dev/null || true; }
finish() {
    kill_sandbox_processes
    # Owner-only test folders are made removable again before deleting the sandbox.
    find "$ROOT" -type d -perm 000 -exec chmod 700 {} + 2>/dev/null || true
    if [ "${KEEP:-0}" = 1 ]; then echo "sandbox kept: $ROOT"; else rm -rf "$ROOT"; fi
}
trap finish EXIT

# The fake app: waits until it is signalled. Compiled here (linker-signed), so macOS runs it like any built tool.
mkdir -p "$ROOT/build"
printf '#include <stdlib.h>\n#include <unistd.h>\nint main(int c, char **v) { if (c > 1) { sleep(atoi(v[1])); return 0; } for (;;) pause(); }\n' > "$ROOT/build/fake.c"
clang -O2 -o "$ROOT/build/SpanDeck" "$ROOT/build/fake.c"
FAKE_EXE="$ROOT/build/SpanDeck"

ok() { PASSES=$((PASSES + 1)); printf '  PASS  %s\n' "$1"; }
no() { FAILS=$((FAILS + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else no "$what"; fi; }
contains() { grep -qF -- "$2" "$1" 2>/dev/null; }
tree() { [ -e "$1" ] || { echo absent; return; }; (cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 2>/dev/null) | shasum -a 256 | cut -d' ' -f1; }

# ---- one sandbox per scenario
setup() {
    S="$ROOT/$1"; U="$S/Users"; H="$U/spandecktest"; M="$U/mainuser"; P="$S/pkg"; B="$S/stub"; F="$S/fakeapp"
    mkdir -p "$H" "$M/.claude" "$P" "$B" "$F/SpanDeck.selftest-bundle/Contents/MacOS"
    chmod 700 "$H"; echo secret > "$M/.claude/settings.json"; chmod 000 "$M"
    cp "$FAKE_EXE" "$F/SpanDeck.selftest-bundle/Contents/MacOS/SpanDeck"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string io.github.lolodawit.SpanDeck" "$F/SpanDeck.selftest-bundle/Contents/Info.plist" >/dev/null
    cp "$REPO/scripts/validation/validate.sh" "$REPO/Resources/identity.env" "$REPO/scripts/runtime/procwatch.c" "$P/"
    echo "selftest" > "$P/VALIDATION_RUN.md"
    clang -O2 -o "$P/procwatch" "$REPO/scripts/runtime/procwatch.c" 2>/dev/null
    head -c 4096 /dev/urandom > "$P/SpanDeck-1.1.dmg"
    DMG_SHA=$(shasum -a 256 "$P/SpanDeck-1.1.dmg" | cut -d' ' -f1)
    (cd "$P" && shasum -a 256 SpanDeck-1.1.dmg > SHA256SUMS)
    printf 'commit: selftest\nsha256 executable: %s\n' "$(shasum -a 256 "$F/SpanDeck.selftest-bundle/Contents/MacOS/SpanDeck" | cut -d' ' -f1)" > "$P/PROVENANCE.txt"
    printf 'main_user=mainuser\nmain_uid=99999\nstager_uid=%s\ncandidate_commit=selftest\ncandidate_dmg_sha256=%s\npackage_commit=selftest\n' "$ME" "$DMG_SHA" > "$P/package.env"
    repackage
    stubs
    : > "$S/answers"; : > "$S/env"
}
repackage() { (cd "$P" && shasum -a 256 validate.sh procwatch procwatch.c identity.env package.env VALIDATION_RUN.md > PACKAGE.sha256); }
stub() { cat > "$B/$1"; chmod +x "$B/$1"; }
stubs() {
    stub id <<'X'
#!/bin/bash
[ "${1:-}" = -un ] && { echo spandecktest; exit 0; }
exec /usr/bin/id "$@"
X
    stub dscl <<'X'
#!/bin/bash
echo "NFSHomeDirectory: $HOME"
X
    stub dsmemberutil <<'X'
#!/bin/bash
echo "user is not a member of the group"
X
    stub launchctl <<'X'
#!/bin/bash
[ "${1:-}" = getenv ] || exit 0
v="SELFTEST_LAUNCHD_$2"; [ -n "${!v:-}" ] && echo "${!v}"; exit 0
X
    stub security <<'X'
#!/bin/bash
case "${1:-}" in
    list-keychains) echo "    \"$HOME/Library/Keychains/login.keychain-db\"" ;;
    find-generic-password) exit "${SELFTEST_KC_STATUS:-44}" ;;
esac
X
    stub defaults <<'X'
#!/bin/bash
d="$HOME/.selftest-defaults"; f="$d/${2:-x}"
case "${1:-}" in
    read) [ -f "$f" ] || exit 1; if [ -n "${3:-}" ]; then v=$(sed -n "s/^$3=//p" "$f"); [ -n "$v" ] || exit 1; echo "$v"; else cat "$f"; fi ;;
    delete) rm -f "$f" ;;
    write) mkdir -p "$d"; echo "$3=$5" >> "$f" ;;
esac
X
    stub log <<'X'
#!/bin/bash
[ -n "${SELFTEST_LOG_UNAVAILABLE:-}" ] && { echo "log: Must be admin to run 'stream' command"; exit 64; }
echo "Filtering the log data using \"process == security\""
while :; do sleep 1; done
X
    stub open <<'X'
#!/bin/bash
[ -n "${SELFTEST_OPEN_FAIL:-}" ] && exit 1
case "$1" in *.selftest-bundle) ;; *) echo "selftest open stub: refusing $1" >&2; exit 1 ;; esac
nohup "$1/Contents/MacOS/SpanDeck" ${SELFTEST_APP_LIFETIME:-} >/dev/null 2>&1 &
exit 0
X
    stub hdiutil <<'X'
#!/bin/bash
case "${1:-}" in
    attach) [ -n "${SELFTEST_ATTACH_FAIL:-}" ] && { echo "hdiutil: attach failed" >&2; exit 1; }
            for a; do [ "$prev" = -mountpoint ] && m=$a; prev=$a; done; cp -R "$SELFTEST_FAKEAPP" "$m/" ;;
    detach) rm -rf "$2/SpanDeck.selftest-bundle" ;;
esac
X
    stub codesign <<'X'
#!/bin/bash
exit 0
X
    stub lipo <<'X'
#!/bin/bash
echo arm64
X
    stub lsof <<'X'
#!/bin/bash
[ -n "${SELFTEST_LSOF_BLIND:-}" ] && exit 1
exec /usr/sbin/lsof "$@"
X
    stub awk <<'X'
#!/bin/bash
if [ -n "${SELFTEST_AWK_FAIL:-}" ]; then for a; do [ "$a" = tag=main ] && exit 1; done; fi
exec /usr/bin/awk "$@"
X
}
answers() { printf '%s\n' "$@" >> "$S/answers"; }
setenv() { echo "$1" >> "$S/env"; }
# run_validate ARGS...: runs the staged copy with a clean environment; output to $S/out.txt; sets RC.
run_validate() {
    local extra=(); while IFS= read -r l; do [ -n "$l" ] && extra+=("$l"); done < "$S/env"
    RC=0
    env -i HOME="$H" PATH="$B:/usr/bin:/bin:/usr/sbin:/sbin" LANG=en_US.UTF-8 TMPDIR="$S" \
        VALIDATE_SELFTEST=1 VALIDATE_USERS_ROOT="$U" VALIDATE_TTY_IN="$S/answers" VALIDATE_WATCH_SECS=3 \
        VALIDATE_BIG_FILES=3 VALIDATE_BIG_MESSAGES=2 SELFTEST_FAKEAPP="$F/SpanDeck.selftest-bundle" "${extra[@]+"${extra[@]}"}" \
        "$P/validate.sh" "$@" >> "$S/out.txt" 2>&1 || RC=$?
    : > "$S/answers"   # each invocation consumes the answers queued for it
}
lastrun() { cat "$H/spandeck-validation/current"; }
report() { echo "$(lastrun)/report.md"; }
watchers_left() { pgrep -f "$ROOT/" 2>/dev/null | while read -r p; do ps -o comm= -p "$p"; done | grep -vc 'SpanDeck$' || true; }
gate_fail() { # scenario expected-check-id
    run_validate run
    check "$1: run stops (exit $RC)" [ "$RC" != 0 ]
    check "$1: verdict NO-GO" contains "$(report)" "**VERDICT: NO-GO"
    check "$1: $2 is FAIL" grep -q "| $2 | FAIL |" "$(report)"
    check "$1: nothing installed" [ ! -e "$H/Applications/SpanDeck.selftest-bundle" ]
    check "$1: no fixtures written" [ ! -e "$H/.claude/projects" ]
    check "$1: run not left active" [ ! -f "$(lastrun)/.active" ]
}

echo "== gate failures: each must stop before anything is installed, with a NO-GO verdict"
setup g-main-reachable; chmod 755 "$M"; answers "$DMG_SHA" n; gate_fail g-main-reachable P2.main-home
setup g-leftover-state; mkdir -p "$H/Library/Application Support/SpanDeck"; echo keep > "$H/Library/Application Support/SpanDeck/claude-ledger.json"
    before=$(tree "$H/Library/Application Support/SpanDeck"); answers "$DMG_SHA" n; gate_fail g-leftover-state P5.clean-slate
    answers y; run_validate cleanup
    check "g-leftover-state: cleanup leaves pre-existing SpanDeck state untouched" [ "$(tree "$H/Library/Application Support/SpanDeck")" = "$before" ]
    check "g-leftover-state: cleanup says it never launched" contains "$S/out.txt" "never launched SpanDeck"
setup g-launchd-redirect; setenv "SELFTEST_LAUNCHD_CLAUDE_CONFIG_DIR=$M/.claude"; answers "$DMG_SHA" n; gate_fail g-launchd-redirect P3.environment
setup g-symlink; ln -s "$M/.claude" "$H/innocent-link"; answers "$DMG_SHA" n; gate_fail g-symlink P3.links
setup g-keychain-error; setenv SELFTEST_KC_STATUS=51; answers "$DMG_SHA" n; gate_fail g-keychain-error P4.claude-item
    check "g-keychain-error: failed lookup reported as not shown, not as absent" contains "$(report)" "absence not shown"
setup g-credential; mkdir -p "$H/.codex"; echo '{}' > "$H/.codex/auth.json"; answers "$DMG_SHA" n; gate_fail g-credential P4.credentials
setup g-wrong-sha; answers "$(printf '0%.0s' $(seq 64))" n; gate_fail g-wrong-sha P6.dmg-sha256
setup g-tampered; echo "// tampered" >> "$P/procwatch.c"; answers "$DMG_SHA" n; gate_fail g-tampered P6.package
setup g-quarantine; xattr -w com.apple.quarantine "0081;00000000;Safari;" "$P/SpanDeck-1.1.dmg"; answers "$DMG_SHA" n; gate_fail g-quarantine P6.quarantine
setup g-login-unclear; answers "$DMG_SHA" maybe; gate_fail g-login-unclear P7.login-items
setup g-no-tty; answers "$DMG_SHA"; run_validate run
    check "g-no-tty: no terminal answer stops the run" [ "$RC" != 0 ]
    check "g-no-tty: says so" contains "$S/out.txt" "no terminal input"
    check "g-no-tty: nothing installed" [ ! -e "$H/Applications/SpanDeck.selftest-bundle" ]

echo "== failure after installation, with parked data; cleanup removes only what the run made"
setup a-open-fails; setenv SELFTEST_OPEN_FAIL=1
    mkdir -p "$H/.claude/projects/real-project" "$H/.grok/sessions/x"; echo "pre-existing transcript" > "$H/.claude/projects/real-project/s.jsonl"
    echo "grok data" > "$H/.grok/sessions/x/usage.json"; mkdir -p "$H/Applications"; echo "other app" > "$H/Applications/Other.txt"
    c0=$(tree "$H/.claude"); g0=$(tree "$H/.grok"); a0=$(tree "$H/Applications")
    answers "$DMG_SHA" n; run_validate run --park-existing
    check "a-open-fails: run stops (exit $RC)" [ "$RC" != 0 ]
    check "a-open-fails: app was installed before the failure" [ -d "$H/Applications/SpanDeck.selftest-bundle" ]
    check "a-open-fails: originals parked" [ -d "$H/.claude.parked-$(basename "$(lastrun)")" ]
    answers y; run_validate cleanup
    check "a-open-fails: installed copy removed (hash matched)" [ ! -e "$H/Applications/SpanDeck.selftest-bundle" ]
    check "a-open-fails: pre-existing ~/Applications content untouched" [ "$(tree "$H/Applications")" = "$a0" ]
    check "a-open-fails: ~/.claude restored byte for byte" [ "$(tree "$H/.claude")" = "$c0" ]
    check "a-open-fails: ~/.grok restored byte for byte" [ "$(tree "$H/.grok")" = "$g0" ]
    check "a-open-fails: no parked copy left" [ -z "$(find "$H" -maxdepth 1 -name '*.parked-*')" ]
    check "a-open-fails: verdict NO-GO (incomplete)" contains "$(report)" "run incomplete"
setup a-modified-app; setenv SELFTEST_OPEN_FAIL=1; answers "$DMG_SHA" n; run_validate run
    echo "changed" >> "$H/Applications/SpanDeck.selftest-bundle/Contents/Info.plist"; answers y; run_validate cleanup
    check "a-modified-app: a changed app copy is kept, not removed" [ -d "$H/Applications/SpanDeck.selftest-bundle" ]
    check "a-modified-app: and reported as KEPT" contains "$S/out.txt" "differs from what this run installed"
setup a-replaced-app; setenv SELFTEST_OPEN_FAIL=1; answers "$DMG_SHA" n; run_validate run
    rm -rf "$H/Applications/SpanDeck.selftest-bundle"; mkdir -p "$H/Applications/SpanDeck.selftest-bundle"; echo user > "$H/Applications/SpanDeck.selftest-bundle/mine"
    answers y; run_validate cleanup
    check "a-replaced-app: a different app at the same path is kept" [ -f "$H/Applications/SpanDeck.selftest-bundle/mine" ]

echo "== failure during fixture creation, then new data appears before cleanup"
setup f-fixture-fails; setenv SELFTEST_AWK_FAIL=1
    mkdir -p "$H/.claude/projects/real"; echo "original" > "$H/.claude/projects/real/a.jsonl"; c0=$(tree "$H/.claude")
    # gate, A2 prompt, popover, two observations, close, start diagnostics, disclosure
    answers "$DMG_SHA" n y "" y y "" "" y; run_validate run --park-existing
    check "f-fixture-fails: run stops during fixtures (exit $RC)" [ "$RC" != 0 ]
    id=$(basename "$(lastrun)")
    check "f-fixture-fails: the fixture folder was created and marked" [ -n "$(find "$H/.claude/projects" -name .spandeck-validation 2>/dev/null)" ]
    kill_sandbox_processes   # the person quits the app
    echo "new user data" > "$H/.claude/notes.txt"
    answers y; run_validate cleanup
    check "f-fixture-fails: marked fixtures removed" [ -z "$(find "$H/.claude" -name '*spandeck-validation*' 2>/dev/null)" ]
    check "f-fixture-fails: new data written meanwhile is kept" [ "$(cat "$H/.claude/notes.txt")" = "new user data" ]
    check "f-fixture-fails: parked original not merged or overwritten" [ "$(tree "$H/.claude.parked-$id")" = "$c0" ]
    check "f-fixture-fails: conflict reported as KEPT" contains "$S/out.txt" "exists again, so the parked original stays"
    check "f-fixture-fails: no watcher left running" [ "$(watchers_left)" = 0 ]

echo "== insufficient monitoring: never a PASS"
setup m-blind; setenv SELFTEST_LSOF_BLIND=1; setenv SELFTEST_LOG_UNAVAILABLE=1
    printf '#!/bin/bash\nwhile :; do sleep 1; done\n' > "$P/procwatch"; chmod +x "$P/procwatch"; repackage
    answers "$DMG_SHA" n; run_validate run      # stops at the first observation prompt (no more answers)
    check "m-blind: a stopped run writes its report by itself" [ -f "$(report)" ]
    check "m-blind: and says NO-GO (stopped)" contains "$S/out.txt" "VERDICT: NO-GO (the run stopped before completing"
    run_validate report
    r=$(report)
    check "m-blind: processes INCONCLUSIVE without a fork monitor" grep -q "| A2.processes | INCONCLUSIVE |" "$r"
    check "m-blind: network INCONCLUSIVE without lsof coverage" grep -q "| A2.network | INCONCLUSIVE |" "$r"
    check "m-blind: Keychain INCONCLUSIVE without the fork monitor" grep -q "| A2.keychain | INCONCLUSIVE |" "$r"
    check "m-blind: no PASS for any of them" sh -c "! grep -E '\\| A2\\.(processes|network|keychain) \\| PASS' '$r'"
    check "m-blind: verdict NO-GO naming INCONCLUSIVE" contains "$r" "INCONCLUSIVE (evidence insufficient)"
    kill_sandbox_processes; answers y; run_validate cleanup
setup m-symbols; printf '#!/bin/bash\nexit 0\n' > "$B/nm"; chmod +x "$B/nm"
    answers "$DMG_SHA" n; run_validate run; run_validate report
    check "m-symbols: no symbol list is INCONCLUSIVE, not PASS" grep -q "| A1.keychain-api | INCONCLUSIVE |" "$(report)"
    kill_sandbox_processes; answers y; run_validate cleanup
setup m-watched; answers "$DMG_SHA" n; run_validate run; run_validate report
    check "m-watched: with real monitors, processes PASS" grep -q "| A2.processes | PASS |" "$(report)"
    check "m-watched: with real monitors, network PASS" grep -q "| A2.network | PASS |" "$(report)"
    check "m-watched: Keychain PASS needs static + fork evidence" grep -q "| A2.keychain | PASS |" "$(report)"
    check "m-watched: still NO-GO (self-test, incomplete)" contains "$(report)" "**VERDICT: NO-GO"
    kill_sandbox_processes; answers y; run_validate cleanup

echo "== interrupted run"
setup i-interrupt; setenv VALIDATE_WATCH_SECS=30
    answers "$DMG_SHA" n
    ( run_validate run ) & bg=$!
    for _ in $(seq 1 100); do [ -f "$H/spandeck-validation/current" ] && [ -f "$(lastrun)/watch-A/.pid" ] && break; sleep 0.2; done
    sleep 1
    vpid=$(pgrep -f "$P/validate.sh run" | head -1 || true)
    [ -n "$vpid" ] && kill -TERM "$vpid"
    wait $bg 2>/dev/null || true; sleep 1
    check "i-interrupt: interrupted run says how to clean up" contains "$S/out.txt" "Interrupted. Run ./validate.sh cleanup"
    check "i-interrupt: watchers stopped on interrupt" [ "$(watchers_left)" = 0 ]
    answers y; run_validate cleanup
    check "i-interrupt: cleanup refuses while the app runs" contains "$S/out.txt" "Quit SpanDeck from its popover first"
    kill_sandbox_processes; answers y; run_validate cleanup
    check "i-interrupt: then removes the app copy" [ ! -e "$H/Applications/SpanDeck.selftest-bundle" ]
    check "i-interrupt: run no longer active" [ ! -f "$(lastrun)/.active" ]
setup i-park-half; mkdir -p "$H/.claude"; echo x > "$H/.claude/keep"
    # An interruption right after the intent was recorded but before the move: cleanup must not invent a restore.
    r="$H/spandeck-validation/20000101T000000Z"; mkdir -p "$r"; echo "$r" > "$H/spandeck-validation/current"
    echo VALIDATION > "$r/.mode"; printf 'ID\tRESULT\tDETAIL\n' > "$r/results.tsv"; : > "$r/log.txt"; echo "$H/.claude" > "$r/.parked"
    answers y; run_validate cleanup
    check "i-park-half: original left in place" [ "$(cat "$H/.claude/keep")" = x ]
    check "i-park-half: reported as never moved" contains "$S/out.txt" "was never moved"

echo "== more failure and cleanup paths"
setup e-app-dies; setenv SELFTEST_APP_LIFETIME=1; answers "$DMG_SHA" n; run_validate run
    check "e-app-dies: an app that exits mid-window is not a PASS for processes" grep -q "| A2.processes | INCONCLUSIVE |" "$(report)"
    check "e-app-dies: nor for Keychain" sh -c "! grep -q '| A2.keychain | PASS |' '$(report)'"
    answers y; run_validate cleanup
setup e-attach-fails; setenv SELFTEST_ATTACH_FAIL=1; mkdir -p "$H/Applications"; echo mine > "$H/Applications/note"; a0=$(tree "$H/Applications")
    answers "$DMG_SHA" n; run_validate run
    check "e-attach-fails: stops with a NO-GO report" contains "$(report)" "**VERDICT: NO-GO"
    check "e-attach-fails: nothing installed" [ ! -e "$H/Applications/SpanDeck.selftest-bundle" ]
    answers y; run_validate cleanup
    check "e-attach-fails: pre-existing ~/Applications untouched" [ "$(tree "$H/Applications")" = "$a0" ]
setup e-parked-changed; setenv SELFTEST_OPEN_FAIL=1; mkdir -p "$H/.claude/projects/p"; echo one > "$H/.claude/projects/p/a.jsonl"
    answers "$DMG_SHA" n; run_validate run --park-existing; id=$(basename "$(lastrun)")
    echo two > "$H/.claude.parked-$id/projects/p/a.jsonl"
    answers y; run_validate cleanup
    check "e-parked-changed: restored into the empty place" [ "$(cat "$H/.claude/projects/p/a.jsonl")" = two ]
    check "e-parked-changed: reported as changed while parked" contains "$S/out.txt" "contents changed while parked"
    mkdir -p "$H/Library/Application Support/SpanDeck"; echo later > "$H/Library/Application Support/SpanDeck/later-use"
    answers y; run_validate cleanup
    check "e-parked-changed: a second cleanup does nothing" contains "$S/out.txt" "already cleaned up; nothing was done"
    check "e-parked-changed: data created after the first cleanup is kept" [ -f "$H/Library/Application Support/SpanDeck/later-use" ]
setup e-foreign-fixture; setenv SELFTEST_OPEN_FAIL=1; answers "$DMG_SHA" n; run_validate run
    mkdir -p "$H/.claude/projects/-Users-spandecktest-spandeck-validation-other"; echo "run=someone-else" > "$H/.claude/projects/-Users-spandecktest-spandeck-validation-other/.spandeck-validation"
    mkdir -p "$H/.claude/projects/-Users-spandecktest-spandeck-validation-unmarked"
    answers y; run_validate cleanup
    check "e-foreign-fixture: a folder marked by another run is kept" [ -d "$H/.claude/projects/-Users-spandecktest-spandeck-validation-other" ]
    check "e-foreign-fixture: an unmarked look-alike folder is kept" [ -d "$H/.claude/projects/-Users-spandecktest-spandeck-validation-unmarked" ]
setup e-no-main-home; chmod 700 "$M"; rm -rf "$M"; answers "$DMG_SHA" n; gate_fail e-no-main-home P2.main-home-exists

echo "== egress aggregation (C2)"
setup c2-rules
    r="$H/spandeck-validation/c"; mkdir -p "$r"; : > "$r/log.txt"; printf 'ID\tRESULT\tDETAIL\n' > "$r/results.tsv"
    c2() { # dir-setup... -> C2 status
        rm -rf "$r"/watch-*; printf 'ID\tRESULT\tDETAIL\n' > "$r/results.tsv"; "$@"
        (cd "$P" && VALIDATE_SOURCE_ONLY=1 HOME="$H" bash -c '. ./validate.sh; RUN='"$r"'; egress_result >/dev/null; awk -F"\t" "NR==2{print \$2}" "$RUN/results.tsv"')
    }
    good() { mkdir -p "$r/watch-$1"; touch "$r/watch-$1/.procwatch-ok"; printf 'ok\nok\nok\n' > "$r/watch-$1/lsof-samples.txt"; : > "$r/watch-$1/forks.txt"; }
    none() { :; }
    forked() { good A; echo "t fork child 9 /usr/bin/security" > "$r/watch-A/forks.txt"; }
    socket() { good A; echo "IPv4 TCP 1.2.3.4:443" > "$r/watch-A/sockets.txt"; }
    blind() { good A; good B; rm "$r/watch-B/.procwatch-ok"; }
    nolsof() { good A; printf 'fail\nfail\n' > "$r/watch-A/lsof-samples.txt"; }
    allgood() { good A; good B3; }
    check "c2-rules: no launch monitored -> INCONCLUSIVE" [ "$(c2 none)" = INCONCLUSIVE ]
    check "c2-rules: a security child process -> FAIL" [ "$(c2 forked)" = FAIL ]
    check "c2-rules: a socket -> FAIL" [ "$(c2 socket)" = FAIL ]
    check "c2-rules: a launch without the fork monitor -> INCONCLUSIVE" [ "$(c2 blind)" = INCONCLUSIVE ]
    check "c2-rules: a launch lsof never saw -> INCONCLUSIVE" [ "$(c2 nolsof)" = INCONCLUSIVE ]
    check "c2-rules: every launch observed, nothing seen -> PASS" [ "$(c2 allgood)" = PASS ]

echo "== verdict rules (report only)"
setup v-rules
    r="$H/spandeck-validation/v"; mkdir -p "$r"; : > "$r/log.txt"
    vt() { # mode gate complete rows... -> verdict line
        rm -f "$r/.gate-passed" "$r/.complete"; echo "$1" > "$r/.mode"; [ "$2" = 1 ] && touch "$r/.gate-passed"; [ "$3" = 1 ] && touch "$r/.complete"
        shift 3; printf 'ID\tRESULT\tDETAIL\n' > "$r/results.tsv"; for row; do printf '%s\n' "$row" | tr '|' '\t' >> "$r/results.tsv"; done
        (cd "$P" && VALIDATE_SOURCE_ONLY=1 HOME="$H" bash -c '. ./validate.sh; RUN='"$r"'; verdict')
    }
    mapfile_req=$(cd "$P" && VALIDATE_SOURCE_ONLY=1 HOME="$H" bash -c '. ./validate.sh; echo $REQUIRED_IDS')
    allpass=(); for id in $mapfile_req; do allpass+=("$id|PASS|x"); done
    v=$(vt VALIDATION 1 1 "${allpass[@]}" "B6.voiceover|SKIP|x" "A2.log-stream|INFO|x"); [[ "$v" == GO* ]] && ok "v-rules: every required check PASS -> GO (optional skip allowed)" || no "v-rules: expected GO, got: $v"
    v=$(vt VALIDATION 1 1 "${allpass[@]:1}"); [[ "$v" == NO-GO*missing* ]] && ok "v-rules: a required check that never ran -> NO-GO" || no "v-rules: missing required gave: $v"
    v=$(vt VALIDATION 1 1 "A|PASS|x"); [[ "$v" == NO-GO* ]] && ok "v-rules: a few PASS rows alone are never GO" || no "v-rules: partial rows gave: $v"
    v=$(vt VALIDATION 1 1 "A|PASS|x" "B|INCONCLUSIVE|x"); [[ "$v" == NO-GO*INCONCLUSIVE* ]] && ok "v-rules: any INCONCLUSIVE -> NO-GO" || no "v-rules: INCONCLUSIVE gave: $v"
    v=$(vt VALIDATION 1 1 "A|PASS|x" "B3.quit-during-index|SKIP|x"); [[ "$v" == NO-GO*skipped* ]] && ok "v-rules: required SKIP -> NO-GO" || no "v-rules: required SKIP gave: $v"
    v=$(vt VALIDATION 1 1 "A|FAIL|x"); [[ "$v" == NO-GO*FAIL* ]] && ok "v-rules: any FAIL -> NO-GO" || no "v-rules: FAIL gave: $v"
    v=$(vt VALIDATION 1 0 "A|PASS|x"); [[ "$v" == NO-GO*incomplete* ]] && ok "v-rules: incomplete -> NO-GO" || no "v-rules: incomplete gave: $v"
    v=$(vt VALIDATION 0 1 "A|PASS|x"); [[ "$v" == NO-GO*gate* ]] && ok "v-rules: gate not passed -> NO-GO" || no "v-rules: no gate gave: $v"
    v=$(vt SELF-TEST 1 1 "A|PASS|x"); [[ "$v" == NO-GO*SELF-TEST* ]] && ok "v-rules: a self-test is never GO" || no "v-rules: self-test gave: $v"

echo "== self-test mode is refused outside a temporary home"
RC=0; env -i HOME="$HOME" PATH=/usr/bin:/bin VALIDATE_SELFTEST=1 VALIDATE_USERS_ROOT=/x VALIDATE_TTY_IN=/dev/null \
    "$ROOT/v-rules/pkg/validate.sh" report > "$ROOT/refuse.txt" 2>&1 || RC=$?
check "self-test refused with a real HOME" grep -q "self-test needs a temporary HOME" "$ROOT/refuse.txt"

echo
echo "selftest: $PASSES passed, $FAILS failed"
[ "$FAILS" = 0 ]
