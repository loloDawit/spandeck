#!/bin/bash
# Tests the release hover-log check (audit 0007, P2, #68) on real builds: scripts/check-hover-log-release.sh must refuse
# the debug binary, where the log is compiled in, and a stripped copy, where it can't see; and it must pass the
# single-arch release binary and the universal one build.sh packages. Builds into .build like swift build does; the app
# isn't packaged, installed or launched. Run: scripts/test-hover-log-release.sh
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/spandeck-hover-log-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=Resources/identity.env
. Resources/identity.env
pass=0 fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
ko() { echo "FAIL $*"; fail=$((fail + 1)); }
check() { scripts/check-hover-log-release.sh "$1" > "$tmp/out.txt" 2>&1; }
expect_pass() { if check "$2"; then ok "$1: $(tail -1 "$tmp/out.txt")"; else ko "$1: $(cat "$tmp/out.txt")"; fi; }
expect_fail() { if check "$2"; then ko "$1: check passed"; else ok "$1: refused ($(head -1 "$tmp/out.txt"))"; fi; }

swift build --product "$APP_NAME" > /dev/null
debug=$(swift build --show-bin-path)/$APP_NAME
swift build -c release --product "$APP_NAME" > /dev/null
release=$(swift build -c release --show-bin-path)/$APP_NAME
swift build -c release --arch arm64 --arch x86_64 --product "$APP_NAME" > /dev/null
universal=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME

expect_fail "debug build (positive control)" "$debug"
expect_pass "release build" "$release"
expect_pass "universal release build, as build.sh packages it" "$universal"
cp "$universal" "$tmp/stripped"; strip "$tmp/stripped" 2>/dev/null
expect_fail "stripped binary" "$tmp/stripped"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
