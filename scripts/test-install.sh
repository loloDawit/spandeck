#!/bin/bash
# Tests scripts/install-app.sh with synthetic installations (#11): a fake upstream Headroom.app beside SpanDeck.app in a
# temporary install folder, and stand-ins for pkill and open that only record their arguments. Nothing real is quit,
# installed, launched or removed. Run: scripts/test-install.sh
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
. "$repo/Resources/identity.env"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/spandeck-install-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/Applications" "$tmp/build"
for tool in pkill open; do
    printf '#!/bin/bash\necho "%s $*" >> "%s/calls.txt"\n' "$tool" "$tmp" > "$tmp/bin/$tool"; chmod +x "$tmp/bin/$tool"
done
touch "$tmp/calls.txt"
pass=0 fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
ko() { echo "FAIL $*"; fail=$((fail + 1)); }

# make_app <dir> <name> <bundle id> <payload>
make_app() {
    mkdir -p "$1/$2.app/Contents/MacOS"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $3" -c "Add :CFBundleExecutable string $2" "$1/$2.app/Contents/Info.plist" >/dev/null
    printf '#!/bin/sh\n# %s\n' "$4" > "$1/$2.app/Contents/MacOS/$2"; chmod +x "$1/$2.app/Contents/MacOS/$2"
}
tree() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256; find . -print | sort) 2>/dev/null | shasum -a 256; }
install() { PATH="$tmp/bin:$PATH" INSTALL_DIR="$tmp/Applications" NO_LAUNCH=${NO_LAUNCH-1} QUIT_WAIT=0 \
    "$repo/scripts/install-app.sh" "$@" > "$tmp/out.txt" 2>&1; }

# Upstream Headroom installed, with its own data next to it; an older SpanDeck installed.
make_app "$tmp/Applications" Headroom dev.headroom.Headroom "upstream headroom"
make_app "$tmp/Applications" "$APP_NAME" "$BUNDLE_ID" "old spandeck"
make_app "$tmp/build" "$APP_NAME" "$BUNDLE_ID" "new spandeck"
headroom=$(tree "$tmp/Applications/Headroom.app")

# 1. Replaces SpanDeck, quits only SpanDeck by exact name, doesn't launch with NO_LAUNCH=1.
: > "$tmp/calls.txt"
if install "$tmp/build/$APP_NAME.app"; then ok "installs over an older $APP_NAME.app"; else ko "install failed: $(cat "$tmp/out.txt")"; fi
grep -q "new spandeck" "$tmp/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME" && ok "$APP_NAME.app replaced" || ko "$APP_NAME.app not replaced"
[ "$(cat "$tmp/calls.txt")" = "pkill -x $APP_NAME" ] && ok "only 'pkill -x $APP_NAME' ran" || ko "calls: $(cat "$tmp/calls.txt")"
[ "$(tree "$tmp/Applications/Headroom.app")" = "$headroom" ] && ok "Headroom.app unchanged" || ko "Headroom.app changed"

# 2. Launches only the installed SpanDeck when asked.
: > "$tmp/calls.txt"
NO_LAUNCH=0 install "$tmp/build/$APP_NAME.app"
[ "$(cat "$tmp/calls.txt")" = "$(printf 'pkill -x %s\nopen %s' "$APP_NAME" "$tmp/Applications/$APP_NAME.app")" ] \
    && ok "launch opens only $APP_NAME.app" || ko "calls: $(cat "$tmp/calls.txt")"

# 3-6. Refusals: nothing quit, nothing changed.
refused() { # label, then the install arguments
    local label=$1; shift
    local before; before=$(tree "$tmp/Applications"); : > "$tmp/calls.txt"
    if install "$@"; then ko "$label: not refused"; return; fi
    [ "$(tree "$tmp/Applications")" = "$before" ] && [ ! -s "$tmp/calls.txt" ] && ok "$label: refused, nothing changed or quit" \
        || ko "$label: refused but something changed (calls: $(cat "$tmp/calls.txt"))"
}
make_app "$tmp/other" Headroom dev.headroom.Headroom "would replace headroom"
refused "a Headroom.app as the source" "$tmp/other/Headroom.app"
make_app "$tmp/wrongid" "$APP_NAME" dev.headroom.Headroom "spandeck name, headroom id"
refused "a $APP_NAME.app with Headroom's bundle id" "$tmp/wrongid/$APP_NAME.app"
rm -rf "$tmp/Applications/$APP_NAME.app"; make_app "$tmp/Applications" "$APP_NAME" com.example.Other "a foreign app"
refused "an installed $APP_NAME.app that isn't $BUNDLE_ID" "$tmp/build/$APP_NAME.app"
rm -rf "$tmp/Applications/$APP_NAME.app"; ln -s "$tmp/Applications/Headroom.app" "$tmp/Applications/$APP_NAME.app"
refused "an installed $APP_NAME.app that is a link (to Headroom.app)" "$tmp/build/$APP_NAME.app"
[ "$(tree "$tmp/Applications/Headroom.app")" = "$headroom" ] && ok "Headroom.app still unchanged at the end" || ko "Headroom.app changed"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
