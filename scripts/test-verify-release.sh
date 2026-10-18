#!/bin/bash
# Tests the release gate (#11), scripts/verify-release.sh. Nothing is signed with a real identity, notarized, published,
# installed or launched.
#   - Fake tools: a copy of the gate whose one tool line points at fake codesign, spctl, stapler, hdiutil and lipo gives
#     each way a DMG can fall short; the gate must refuse every one and pass only a Developer ID signed, hardened,
#     timestamped, notarized, stapled universal app.
#   - The real gate, with the real tools, on a real ad-hoc DMG (built from a copy of /usr/bin/true): it must refuse it
#     as is, and also when the environment offers fake tools (tool variables, PATH) or a BASH_ENV that exits 0.
# Run: scripts/test-verify-release.sh
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
gate="$repo/scripts/verify-release.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/spandeck-release-gate-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=Resources/identity.env
. "$repo/Resources/identity.env"
TEAM=ABCDE12345
# The Developer ID Application requirement the gate must test (leaf and intermediate are Apple's Developer ID OIDs).
REQ='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "'
TOOLS='readonly CODESIGN=/usr/bin/codesign SPCTL=/usr/sbin/spctl STAPLER="/usr/bin/xcrun stapler" HDIUTIL=/usr/bin/hdiutil LIPO=/usr/bin/lipo'
pass=0 fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
ko() { echo "FAIL $*"; fail=$((fail + 1)); }

# The production gate names its tools by absolute path on one line, with no override.
if grep -qxF "$TOOLS" "$gate" && [ "$(grep -c '^readonly CODESIGN=' "$gate")" = 1 ]; then ok "gate uses fixed tool paths"
else ko "gate's tool line isn't exactly: $TOOLS"; fi
if head -1 "$gate" | grep -qx '#!/bin/bash -p'; then ok "gate runs in privileged mode (no BASH_ENV, no imported functions)"
else ko "gate's first line isn't #!/bin/bash -p"; fi
if grep -qF "$REQ" "$gate"; then ok "gate tests the Developer ID requirement"; else ko "gate doesn't contain the Developer ID requirement"; fi

# Fake tools. FAKE names the scenario; each fake behaves like the real tool for a good release unless FAKE says otherwise.
bin="$tmp/bin"
mkdir -p "$bin"
printf '%s%s"' "$REQ" "$TEAM" > "$tmp/requirement"
cat > "$bin/codesign" <<EOF
#!/bin/bash
target="\${@: -1}"
case "\$1" in
--verify)
  [ "\$FAKE" = bad-verify ] && { echo "\$target: invalid signature (code or signature have been modified)" >&2; exit 1; }
  req=; for a in "\$@"; do case "\$a" in --test-requirement=*) req=\${a#--test-requirement=} ;; esac; done
  [ "\$req" = "=\$(cat "$tmp/requirement")" ] || { echo "\$target: wrong or missing requirement: \$req" >&2; exit 1; }
  [ "\$FAKE" = self-signed ] && { echo "test-requirement: code failed to satisfy specified code requirement(s)" >&2; exit 3; }
  exit 0 ;;
-dvv) ;;
*) exit 2 ;;
esac
dmg=0; case "\$target" in *.dmg) dmg=1 ;; esac
adhoc=0
{ [ "\$FAKE" = adhoc ] || { [ "\$FAKE" = app-adhoc ] && [ \$dmg = 0 ]; }; } && adhoc=1
if [ \$dmg = 1 ]; then echo "Identifier=$APP_NAME-1.1"; else
  echo "Executable=\$target/Contents/MacOS/$APP_NAME"
  case "\$FAKE" in
  wrong-id) echo "Identifier=dev.headroom.Headroom" ;;
  dotted-id) echo "Identifier=${BUNDLE_ID//./X}" ;;
  *) echo "Identifier=$BUNDLE_ID" ;;
  esac
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
cat > "$bin/xcrun" <<EOF
#!/bin/bash
[ "\$1" = stapler ] && { shift; exec "$bin/stapler" "\$@"; }
exit 2
EOF
cat > "$bin/hdiutil" <<EOF
#!/bin/bash
case "\$1" in
attach)
  img="\${@: -1}"
  while [ \$# -gt 0 ]; do [ "\$1" = -mountpoint ] && { mnt="\$2"; break; }; shift; done
  case "\$FAKE" in
  attach-fail) echo "hdiutil: attach failed - image not recognized" >&2; exit 1 ;;
  no-app) exit 0 ;;
  app-symlink) mkdir -p "$tmp/elsewhere/$APP_NAME.app/Contents/MacOS"; ln -s "$tmp/elsewhere/$APP_NAME.app" "\$mnt/$APP_NAME.app"; exit 0 ;;
  mutate) printf 'swapped' >> "\$img" ;;
  esac
  mkdir -p "\$mnt/$APP_NAME.app/Contents/MacOS"; printf 'binary' > "\$mnt/$APP_NAME.app/Contents/MacOS/$APP_NAME"
  ln -s /Applications "\$mnt/Applications"
  [ "\$FAKE" = two-apps ] && mkdir -p "\$mnt/Other.app/Contents/MacOS"
  exit 0 ;;
detach) [ "\$FAKE" = detach-fail ] && exit 1; find "\$2" -mindepth 1 -delete; exit 0 ;;  # like unmounting: the folder is empty again
esac
exit 2
EOF
cat > "$bin/lipo" <<'EOF'
#!/bin/bash
case "$FAKE" in
arm-only) echo "arm64"; exit 0 ;;
lipo-fail) echo "lipo: can't figure out the architecture type of: ${@: -1}" >&2; exit 1 ;;
esac
echo "x86_64 arm64"
EOF
chmod +x "$bin"/*

# A copy of the gate with the tool line pointed at the fakes; everything else is the production script.
mkdir -p "$tmp/gate/scripts" "$tmp/gate/Resources"
cp "$repo/Resources/identity.env" "$tmp/gate/Resources/"
fakes="readonly CODESIGN=$bin/codesign SPCTL=$bin/spctl STAPLER=$bin/stapler HDIUTIL=$bin/hdiutil LIPO=$bin/lipo"
while IFS= read -r line; do
    if [ "$line" = "$TOOLS" ]; then printf '%s\n' "$fakes"; else printf '%s\n' "$line"; fi
done < "$gate" > "$tmp/gate/scripts/verify-release.sh"
chmod +x "$tmp/gate/scripts/verify-release.sh"
grep -qxF "$fakes" "$tmp/gate/scripts/verify-release.sh" || { echo "FAIL could not point the gate copy at the fakes"; exit 1; }
faked="$tmp/gate/scripts/verify-release.sh"

dmg="$tmp/$APP_NAME-1.1.dmg"
fresh_dmg() { printf 'not really a disk image' > "$dmg"; }
fresh_dmg
mkdir -p "$tmp/tmpdir"

run_gate() { # scenario team args...
    local scenario=$1 team=$2; shift 2
    fresh_dmg
    env FAKE="$scenario" SPANDECK_TEAM_ID="$team" TMPDIR="$tmp/tmpdir" GITHUB_OUTPUT="${OUT:-}" "$faked" "$@" > "$tmp/out.txt" 2>&1
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
expect_refused "path that isn't a .dmg" "path" good "$TEAM" "$tmp/out.txt"
expect_refused "path that looks like an option" "path" good "$TEAM" "-v.dmg"
ln -sf "$dmg" "$tmp/link.dmg"
expect_refused "DMG given as a symlink" "symlink" good "$TEAM" "$tmp/link.dmg"
expect_refused "invalid DMG signature" "Developer ID" bad-verify "$TEAM" "$dmg"
expect_refused "signature that fails the Developer ID requirement" "Developer ID" self-signed "$TEAM" "$dmg"
expect_refused "ad-hoc DMG" "Developer ID Application" adhoc "$TEAM" "$dmg"
expect_refused "another team's signature" "TeamIdentifier" wrong-team "$TEAM" "$dmg"
expect_refused "no secure timestamp" "timestamp" no-timestamp "$TEAM" "$dmg"
expect_refused "notarization ticket not stapled" "stapled" unstapled "$TEAM" "$dmg"
expect_refused "Gatekeeper rejects the DMG" "Gatekeeper" spctl-reject "$TEAM" "$dmg"
expect_refused "Developer ID but not notarized" "Notarized Developer ID" not-notarized "$TEAM" "$dmg"
expect_refused "DMG that doesn't mount" "mount" attach-fail "$TEAM" "$dmg"
expect_refused "DMG without the app" "exactly one" no-app "$TEAM" "$dmg"
expect_refused "DMG with two apps" "exactly one" two-apps "$TEAM" "$dmg"
expect_refused "app that is a symlink out of the image" "symlink" app-symlink "$TEAM" "$dmg"
expect_refused "signed DMG holding an ad-hoc app" "Developer ID Application" app-adhoc "$TEAM" "$dmg"
expect_refused "app without Hardened Runtime" "Hardened Runtime" no-runtime "$TEAM" "$dmg"
expect_refused "app with another bundle id" "bundle id" wrong-id "$TEAM" "$dmg"
expect_refused "bundle id matched only as a pattern" "bundle id" dotted-id "$TEAM" "$dmg"
expect_refused "single-architecture app" "universal" arm-only "$TEAM" "$dmg"
expect_refused "lipo can't read the binary" "universal" lipo-fail "$TEAM" "$dmg"
expect_refused "DMG changed while it was being verified" "changed" mutate "$TEAM" "$dmg"
if run_gate good "$TEAM" > /dev/null 2>&1; then ko "no arguments: gate passed"; else ok "no arguments: refused"; fi
if run_gate good "$TEAM" "$dmg" "$dmg"; then ko "two DMGs: gate passed"; else ok "two DMGs: refused"; fi

# The verified hash goes to GITHUB_OUTPUT, for the upload step to check; only after a pass.
OUT="$tmp/github-output"
: > "$OUT"; run_gate good "$TEAM" "$dmg" || true
want="sha256=$(/usr/bin/shasum -a 256 "$dmg" | cut -d' ' -f1)"
if [ "$(cat "$OUT")" = "$want" ]; then ok "a pass writes the DMG's hash to GITHUB_OUTPUT"; else ko "GITHUB_OUTPUT after a pass: '$(cat "$OUT")', want '$want'"; fi
: > "$OUT"; run_gate adhoc "$TEAM" "$dmg" || true
if [ ! -s "$OUT" ]; then ok "a refusal writes nothing to GITHUB_OUTPUT"; else ko "GITHUB_OUTPUT after a refusal: $(cat "$OUT")"; fi
OUT=
if run_gate detach-fail "$TEAM" "$dmg"; then ok "a failed detach doesn't change a pass"; else ko "detach-fail: $(cat "$tmp/out.txt")"; fi
left=$(find "$tmp/tmpdir" -mindepth 1 -maxdepth 1 -name 'spandeck-release-gate.*' | wc -l | tr -d ' ')
# detach-fail leaves its (fake) mount point by design: only an unmounted, empty folder is removed.
if [ "$left" -le 1 ]; then ok "mount points removed after every other run ($left left, from detach-fail)"; else ko "$left mount points left"; fi

# Real tools, real gate. An ad-hoc signed app in a real DMG, as ./build.sh dmg makes today.
app="$tmp/real/$APP_NAME.app"
mkdir -p "$app/Contents/MacOS"
cp /usr/bin/true "$app/Contents/MacOS/$APP_NAME"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleExecutable</key><string>%s</string></dict></plist>\n' \
    "$BUNDLE_ID" "$APP_NAME" > "$app/Contents/Info.plist"
codesign --force --sign - "$app" 2>/dev/null
real_dmg="$tmp/real/$APP_NAME-1.1.dmg"
hdiutil create -volname "$APP_NAME test" -srcfolder "$tmp/real" -fs HFS+ -format UDZO -ov "$real_dmg" > /dev/null
real() { # label reason [env assignments...]
    local label=$1 reason=$2; shift 2
    if env "$@" SPANDECK_TEAM_ID="$TEAM" "$gate" "$real_dmg" > "$tmp/out.txt" 2>&1; then ko "$label: gate passed: $(cat "$tmp/out.txt")"
    elif grep -q "REFUSED.*$reason" "$tmp/out.txt"; then ok "$label (real tools): $(grep REFUSED "$tmp/out.txt" | head -1)"
    else ko "$label: refused for another reason (expected '$reason'): $(cat "$tmp/out.txt")"; fi
}
real "real unsigned DMG of an ad-hoc app" "Developer ID"
codesign --force --sign - "$real_dmg" 2>/dev/null
real "real ad-hoc signed DMG" "Developer ID"
# The environment can't substitute tools or code: fakes that would pass, offered three ways.
real "tool variables pointing at passing fakes" "Developer ID" FAKE=good CODESIGN="$bin/codesign" SPCTL="$bin/spctl" \
    STAPLER="$bin/stapler" HDIUTIL="$bin/hdiutil" LIPO="$bin/lipo"
real "PATH offering passing fakes" "Developer ID" FAKE=good PATH="$bin:$PATH"
printf 'echo "VERIFIED (BASH_ENV)"; exit 0\n' > "$tmp/bash_env"
real "BASH_ENV that exits 0" "Developer ID" BASH_ENV="$tmp/bash_env"
# The requirement is valid syntax: real codesign evaluates it (and the ad-hoc app fails it) rather than rejecting it.
if out=$(/usr/bin/codesign --verify --strict "--test-requirement==${REQ}$TEAM\"" "$app" 2>&1); then ko "ad-hoc app satisfied the requirement"
elif grep -q "failed to satisfy" <<< "$out"; then ok "real codesign evaluates the requirement: $(tail -1 <<< "$out")"
else ko "real codesign didn't evaluate the requirement: $out"; fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
