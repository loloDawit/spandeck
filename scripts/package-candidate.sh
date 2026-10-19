#!/bin/bash
# Private-use build candidate (#94): a universal, ad-hoc-signed SpanDeck.app and DMG from a clean, committed tree, with
# a provenance record and SHA-256 sums. NOT a release: not Developer ID signed or notarized, so scripts/verify-release.sh
# refuses it by design. It never installs, launches or quits anything. It writes only build/ (and .build/, SwiftPM's cache).
#   scripts/package-candidate.sh            test (serial, as in CI), build, package, record
#   scripts/package-candidate.sh --no-test  skip the test run (the provenance says so)
# Output: build/candidate/<commit>/ with SpanDeck-<version>.dmg, PROVENANCE.txt and SHA256SUMS.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=Resources/identity.env
. Resources/identity.env

run_tests=1
case "${1:-}" in
    "") ;;
    --no-test) run_tests=0 ;;
    *) echo "usage: scripts/package-candidate.sh [--no-test]" >&2; exit 64 ;;
esac

# Only a committed tree: the provenance names a commit, so the bytes must come from it. Untracked files under the
# folders that are built or packaged count too (SwiftPM compiles any .swift file under Sources).
if [ -n "$(git status --porcelain --untracked-files=no)" ] \
    || [ -n "$(git status --porcelain --untracked-files=all -- Sources Resources Package.swift build.sh scripts)" ]; then
    echo "package-candidate: uncommitted changes, or untracked files in Sources, Resources or scripts; commit or remove them" >&2
    exit 1
fi
commit=$(git rev-parse HEAD)
short=${commit:0:7}
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
build_number=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)
minimum=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" Resources/Info.plist)

tests="not run (--no-test)"
if [ $run_tests = 1 ]; then
    log=build/candidate-test-$short.log
    mkdir -p build
    if ! swift test --no-parallel >"$log" 2>&1; then
        echo "package-candidate: tests failed (log: $log)" >&2
        tail -5 "$log" >&2
        exit 1
    fi
    tests=$(grep -E "Test run with .* (passed|failed)" "$log" | tail -1 | sed 's/^[^A-Za-z]*//' || true)
    tests=${tests:-"passed (summary line not found in $log)"}
fi

./build.sh dmg >/dev/null
app=build/$APP_NAME.app
dmg=build/$APP_NAME-$version.dmg
bin=$app/Contents/MacOS/$APP_NAME
[ -d "$app" ] && [ -f "$dmg" ] || { echo "package-candidate: build.sh produced no app or DMG" >&2; exit 1; }

out=build/candidate/$short
rm -rf "$out"
mkdir -p "$out"
cp "$dmg" "$out/"
dmg_sum=$(shasum -a 256 "$out/$(basename "$dmg")" | cut -d' ' -f1)
bin_sum=$(shasum -a 256 "$bin" | cut -d' ' -f1)
archs=$(lipo -archs "$bin")
# The deployment target each slice was built for (LC_BUILD_VERSION minos).
minos=$(for a in $archs; do printf '%s=%s ' "$a" "$(vtool -arch "$a" -show-build "$bin" 2>/dev/null | awk '/minos/{print $2; exit}')"; done)
signature=$(codesign -dv "$app" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier)=' | tr '\n' ' ')
gate=$(SPANDECK_TEAM_ID= scripts/verify-release.sh "$out/$(basename "$dmg")" 2>&1 >/dev/null | head -1 || true)

# Machine and toolchain facts only: no user, host or path.
cat >"$out/PROVENANCE.txt" <<EOF
SpanDeck private-use build candidate (#94) — NOT a release
commit:            $commit
tree:              clean (no uncommitted changes; no untracked files in Sources, Resources, scripts)
version:           $version ($build_number)
bundle id:         $BUNDLE_ID
architectures:     $archs
minimum macOS:     Info.plist $minimum; binary $minos
signature:         $signature
notarized:         no (ad-hoc signature; Gatekeeper treats it as a local build)
release gate:      $gate
tests:             $tests
built on:          macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)
toolchain:         $(swift --version 2>/dev/null | head -1)
xcode:             $(xcodebuild -version 2>/dev/null | head -1)
built at (UTC):    $(date -u +%Y-%m-%dT%H:%M:%SZ)
sha256 dmg:        $dmg_sum
sha256 executable: $bin_sum
EOF
(cd "$out" && shasum -a 256 "$(basename "$dmg")" >SHA256SUMS)
echo "Candidate: $out"
cat "$out/PROVENANCE.txt"
