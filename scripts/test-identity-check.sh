#!/bin/bash
# Tests the build-time identity check (#11, review of e39f9c5): scripts/check-identity.sh compares Info.plist and every
# AppIdentity constant in Sources/Headroom/Identity.swift with Resources/identity.env, and build.sh runs it before
# compiling. Works on copies in a temporary folder; the checkout isn't changed. Run: scripts/test-identity-check.sh
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/spandeck-identity-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
ko() { echo "FAIL $*"; fail=$((fail + 1)); }
fresh() { # a minimal copy of the checkout: what build.sh and the check read
    rm -rf "$tmp/r"; mkdir -p "$tmp/r/Resources" "$tmp/r/Sources/Headroom" "$tmp/r/scripts"
    cp "$repo/Resources/identity.env" "$repo/Resources/Info.plist" "$repo/Resources/AppIcon.icns" "$tmp/r/Resources/"
    cp "$repo/Sources/Headroom/Identity.swift" "$tmp/r/Sources/Headroom/"
    cp "$repo/build.sh" "$tmp/r/"; cp "$repo/scripts/check-identity.sh" "$tmp/r/scripts/" 2>/dev/null || true
}
check() { "$tmp/r/scripts/check-identity.sh" "$tmp/r" > "$tmp/out.txt" 2>&1; }
expect_fail() { # label, then a mutation run in $tmp/r
    fresh; (cd "$tmp/r" && eval "$2")
    if check; then ko "$1: check passed"; else ok "$1: check refused ($(head -1 "$tmp/out.txt"))"; fi
}
fresh
if check; then ok "the checkout's identity passes"; else ko "the checkout's identity fails: $(cat "$tmp/out.txt")"; fi
expect_fail "supportFolder alone changed" "sed -i '' 's/static let supportFolder = \"SpanDeck\"/static let supportFolder = \"Headroom\"/' Sources/Headroom/Identity.swift"
expect_fail "bundleID alone changed" "sed -i '' 's/io.github.lolodawit.SpanDeck\"/dev.headroom.Headroom\"/' Sources/Headroom/Identity.swift"
expect_fail "a second name declaration" "printf 'extension AppIdentity {\\n    static let name = \"SpanDeck\"\\n}\\n' >> Sources/Headroom/Identity.swift"
expect_fail "a declaration missing" "sed -i '' '/static let hoverLog = /d' Sources/Headroom/Identity.swift"
expect_fail "Info.plist CFBundleName drifted" "/usr/libexec/PlistBuddy -c 'Set :CFBundleName Headroom' Resources/Info.plist"
# build.sh stops before compiling or packaging: no swift build runs and nothing is created under build/.
fresh; (cd "$tmp/r" && sed -i '' 's/static let supportFolder = "SpanDeck"/static let supportFolder = "Headroom"/' Sources/Headroom/Identity.swift)
mkdir -p "$tmp/bin"; printf '#!/bin/bash\necho swift >> "%s/swift-called"\nexit 1\n' "$tmp" > "$tmp/bin/swift"; chmod +x "$tmp/bin/swift"
if (cd "$tmp/r" && PATH="$tmp/bin:$PATH" ./build.sh dmg) > "$tmp/out.txt" 2>&1; then ko "build.sh dmg passed with a drifted identity"
elif [ -e "$tmp/swift-called" ] || [ -e "$tmp/r/build" ]; then ko "build.sh refused only after compiling or creating build/"
else ok "build.sh dmg refused before compiling; no build/ created"; fi
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
