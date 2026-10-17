#!/bin/bash
# Checks SpanDeck's identity before anything is built or packaged (#11, review of e39f9c5): Info.plist and every
# AppIdentity constant in Sources/Headroom/Identity.swift must say exactly what Resources/identity.env says. Each
# constant must be declared once, as an exact line, and AppIdentity must not be extended elsewhere, so a stale value
# can't hide behind a matching substring. build.sh runs this first; scripts/test-identity-check.sh tests it.
#   scripts/check-identity.sh [repository root]
set -euo pipefail
root=${1:-$(cd "$(dirname "$0")/.." && pwd)}
# shellcheck source=../Resources/identity.env
. "$root/Resources/identity.env"
fail() { echo "identity check: $*" >&2; exit 1; }

plist() { /usr/libexec/PlistBuddy -c "Print $1" "$root/Resources/Info.plist" 2>/dev/null || true; }
for key in CFBundleName CFBundleDisplayName CFBundleExecutable; do
    [ "$(plist "$key")" = "$APP_NAME" ] || fail "Info.plist $key is not $APP_NAME"
done
[ "$(plist CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "Info.plist CFBundleIdentifier is not $BUNDLE_ID"

swift="$root/Sources/Headroom/Identity.swift"
[ -f "$swift" ] || fail "no Sources/Headroom/Identity.swift"
others=$(grep -rlE 'extension +AppIdentity|enum +AppIdentity' "$root/Sources" | grep -vxF "$swift" || true)
[ -z "$others" ] || fail "AppIdentity is declared or extended outside Identity.swift: $others"
constant() { # name value
    local n; n=$(grep -cE "static +(let|var) +$1\b" "$swift" || true)
    [ "$n" = 1 ] || fail "AppIdentity.$1 is declared $n times (expected 1)"
    grep -qxF "    static let $1 = \"$2\"" "$swift" || fail "AppIdentity.$1 isn't \"$2\""
}
constant name "$APP_NAME"
constant bundleID "$BUNDLE_ID"
constant supportFolder "$APP_SUPPORT_DIR"
constant hoverLog "$HOVER_LOG"
echo "identity check: $APP_NAME, $BUNDLE_ID, Application Support/$APP_SUPPORT_DIR, $HOVER_LOG"
