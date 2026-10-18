#!/bin/bash
# Tests the release gate (#11), scripts/verify-release.sh. Fake codesign, spctl, stapler, hdiutil and lipo (through the
# script's tool overrides) give each way a DMG can fall short: the gate must refuse every one, and pass only a
# Developer ID signed, hardened, timestamped, notarized and stapled universal app. A real ad-hoc DMG, built with the real
# tools from a copy of /usr/bin/true, is the control that the gate refuses what build.sh produces today. Nothing is
# signed with a real identity, notarized, installed or launched. Run: scripts/test-verify-release.sh
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
gate="$repo/scripts/verify-release.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/spandeck-release-gate-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=Resources/identity.env
. "$repo/Resources/identity.env"
TEAM=ABCDE12345
pass=0 fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
ko() { echo "FAIL $*"; fail=$((fail + 1)); }

# Fake tools. FAKE names the scenario; each fake behaves like the real tool for a good release unless FAKE says otherwise.
bin="$tmp/bin"
mkdir -p "$bin"
cat > "$bin/codesign" <<EOF
#!/bin/bash
target="\${@: -1}"
case "\$1" in
--verify) [ "\$FAKE" = bad-verify ] && { echo "\$target: invalid signature (code or signature have been modified)" >&2; exit 1; }; exit 0 ;;
-dvv) ;;
*) exit 2 ;;
esac
dmg=0; case "\$target" in *.dmg) dmg=1 ;; esac
adhoc=0
{ [ "\$FAKE" = adhoc ] || { [ "\$FAKE" = app-adhoc ] && [ \$dmg = 0 ]; }; } && adhoc=1
if [ \$dmg = 1 ]; then echo "Identifier=$APP_NAME-1.1"; else
  echo "Executable=\$target/Contents/MacOS/$APP_NAME"
  [ "\$FAKE" = wrong-id ] && echo "Identifier=dev.headroom.Headroom" || echo "Identifier=$BUNDLE_ID"
fi
if [ \$adhoc = 1 ]; then
  echo "CodeDirectory v=20400 size=1000 flags=0x2(adhoc) hashes=20+7 location=embedded"
  echo "Signature=adhoc"; echo "TeamIdentifier=not set"; exit 0
fi
if [ \$dmg = 1 ] || [ "\$FAKE" = no-runtime ]; then flags="0x0(none)"; else flags="0x10000(runtime)"; fi
echo "CodeDirectory v=20500 size=1000 flags=\$flags hashes=20+7 location=embedded"
echo "Authority=Developer ID Application: Example Maintainer ($TEAM)"
echo "Authority=Developer ID Certification Authority"
echo "Authority=Apple Root CA"
[ "\$FAKE" = no-timestamp ] || echo "Timestamp=17 Oct 2026 at 10:00:00"
[ "\$FAKE" = wrong-team ] && echo "TeamIdentifier=ZZZZZ99999" || echo "TeamIdentifier=$TEAM"
EOF
cat > "$bin/spctl" <<'EOF'
#!/bin/bash
target="${@: -1}"
case "$FAKE" in
spctl-reject) echo "$target: rejected"; echo "source=no usable signature"; exit 3 ;;
not-notarized) echo "$target: accepted"; echo "source=Developer ID"; exit 0 ;;
esac
echo "$target: accepted"; echo "source=Notarized Developer ID"
EOF
cat > "$bin/stapler" <<'EOF'
#!/bin/bash
[ "$FAKE" = unstapled ] && { echo "${@: -1} does not have a ticket stapled to it."; exit 65; }
echo "The validate action worked!"
EOF
cat > "$bin/hdiutil" <<EOF
#!/bin/bash
case "\$1" in
attach)
  while [ \$# -gt 0 ]; do [ "\$1" = -mountpoint ] && { mnt="\$2"; break; }; shift; done
  [ "\$FAKE" = no-app ] && exit 0
  mkdir -p "\$mnt/$APP_NAME.app/Contents/MacOS"; printf 'binary' > "\$mnt/$APP_NAME.app/Contents/MacOS/$APP_NAME"
  ln -s /Applications "\$mnt/Applications"
  [ "\$FAKE" = two-apps ] && mkdir -p "\$mnt/Other.app/Contents/MacOS"
  exit 0 ;;
detach) exit 0 ;;
esac
exit 2
EOF
cat > "$bin/lipo" <<'EOF'
#!/bin/bash
[ "$FAKE" = arm-only ] && { echo "arm64"; exit 0; }
echo "x86_64 arm64"
EOF
chmod +x "$bin"/*
dmg="$tmp/$APP_NAME-1.1.dmg"
printf 'not really a disk image' > "$dmg"

run_gate() { # scenario team args...
    local scenario=$1 team=$2; shift 2
    env FAKE="$scenario" SPANDECK_TEAM_ID="$team" CODESIGN="$bin/codesign" SPCTL="$bin/spctl" STAPLER="$bin/stapler" \
        HDIUTIL="$bin/hdiutil" LIPO="$bin/lipo" "$gate" "$@" > "$tmp/out.txt" 2>&1
}
expect_pass() { # label scenario team args...
    local label=$1; shift
    if run_gate "$@"; then ok "$label: $(tail -1 "$tmp/out.txt")"; else ko "$label: refused: $(cat "$tmp/out.txt")"; fi
}
expect_refused() { # label reason scenario team args...
    local label=$1 reason=$2; shift 2
    if run_gate "$@"; then ko "$label: gate passed"
    elif grep -q "REFUSED.*$reason" "$tmp/out.txt"; then ok "$label: $(grep REFUSED "$tmp/out.txt" | head -1)"
    else ko "$label: refused for another reason (expected '$reason'): $(cat "$tmp/out.txt")"; fi
}

expect_pass "signed, notarized, stapled universal app (positive control)" good "$TEAM" "$dmg"
expect_pass "preflight with a Team ID" good "$TEAM" --preflight
expect_refused "Team ID not configured" "not configured" good "" "$dmg"
expect_refused "preflight without a Team ID" "not configured" good "" --preflight
expect_refused "malformed Team ID" "Team ID" good "abc" "$dmg"
expect_refused "missing DMG" "no DMG" good "$TEAM" "$tmp/absent.dmg"
expect_refused "invalid DMG signature" "signature" bad-verify "$TEAM" "$dmg"
expect_refused "ad-hoc DMG" "Developer ID Application" adhoc "$TEAM" "$dmg"
expect_refused "another team's signature" "TeamIdentifier" wrong-team "$TEAM" "$dmg"
expect_refused "no secure timestamp" "timestamp" no-timestamp "$TEAM" "$dmg"
expect_refused "notarization ticket not stapled" "stapled" unstapled "$TEAM" "$dmg"
expect_refused "Gatekeeper rejects the DMG" "Gatekeeper" spctl-reject "$TEAM" "$dmg"
expect_refused "Developer ID but not notarized" "Notarized Developer ID" not-notarized "$TEAM" "$dmg"
expect_refused "DMG without the app" "exactly one" no-app "$TEAM" "$dmg"
expect_refused "DMG with two apps" "exactly one" two-apps "$TEAM" "$dmg"
expect_refused "signed DMG holding an ad-hoc app" "Developer ID Application" app-adhoc "$TEAM" "$dmg"
expect_refused "app without Hardened Runtime" "Hardened Runtime" no-runtime "$TEAM" "$dmg"
expect_refused "app with another bundle id" "bundle id" wrong-id "$TEAM" "$dmg"
expect_refused "single-architecture app" "universal" arm-only "$TEAM" "$dmg"
if run_gate good "$TEAM" > /dev/null 2>&1; then ko "no arguments: gate passed"; else ok "no arguments: refused"; fi

# Control with the real tools: an ad-hoc signed app in a real DMG, like ./build.sh dmg makes today, must be refused.
app="$tmp/real/$APP_NAME.app"
mkdir -p "$app/Contents/MacOS"
cp /usr/bin/true "$app/Contents/MacOS/$APP_NAME"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleExecutable</key><string>%s</string></dict></plist>\n' \
    "$BUNDLE_ID" "$APP_NAME" > "$app/Contents/Info.plist"
codesign --force --sign - "$app" 2>/dev/null
hdiutil create -volname "$APP_NAME test" -srcfolder "$tmp/real" -fs HFS+ -format UDZO -ov "$tmp/real.dmg" > /dev/null
real() { # label reason
    if SPANDECK_TEAM_ID="$TEAM" "$gate" "$tmp/real.dmg" > "$tmp/out.txt" 2>&1; then ko "$1: gate passed"
    elif grep -q "REFUSED.*$2" "$tmp/out.txt"; then ok "$1 (real tools): $(grep REFUSED "$tmp/out.txt" | head -1)"
    else ko "$1: refused for another reason (expected '$2'): $(cat "$tmp/out.txt")"; fi
}
real "real unsigned DMG of an ad-hoc app" "signature doesn't verify"
# Signed ad hoc, the DMG's signature verifies, so the gate has to read real codesign output to refuse it.
codesign --force --sign - "$tmp/real.dmg" 2>/dev/null
real "real ad-hoc signed DMG" "Developer ID Application"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
