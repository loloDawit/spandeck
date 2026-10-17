#!/bin/bash
# Installs a built SpanDeck.app (#11). Names come from Resources/identity.env. It only ever replaces an app whose bundle
# id is SpanDeck's, only quits processes named exactly like SpanDeck's executable, and never touches any other app,
# including upstream Headroom, or any app's data.
#   scripts/install-app.sh build/SpanDeck.app
# Environment: INSTALL_DIR (default /Applications), NO_LAUNCH=1 to skip launching (tests).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../Resources/identity.env
. "$here/Resources/identity.env"

src=${1:?usage: install-app.sh <built app>}
dest_dir=${INSTALL_DIR:-/Applications}
target="$dest_dir/$APP_NAME.app"
bundle_id() { /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || true; }
refuse() { echo "install-app: $*. Nothing was changed." >&2; exit 1; }

[ -d "$src" ] || refuse "$src is not an app"
[ "$(basename "$src")" = "$APP_NAME.app" ] || refuse "$src is not $APP_NAME.app"
[ "$(bundle_id "$src")" = "$BUNDLE_ID" ] || refuse "$src is not $BUNDLE_ID"
[ -x "$src/Contents/MacOS/$APP_NAME" ] || refuse "$src has no $APP_NAME executable"
if [ -e "$target" ] || [ -L "$target" ]; then
    [ ! -L "$target" ] || refuse "$target is a link"
    [ "$(bundle_id "$target")" = "$BUNDLE_ID" ] || refuse "$target exists and isn't $BUNDLE_ID"
fi

# Quit a running SpanDeck: exact process name only, never a pattern.
pkill -x "$APP_NAME" 2>/dev/null || true
sleep "${QUIT_WAIT:-0.5}"
rm -rf "$target"
cp -R "$src" "$dest_dir/"
echo "Installed $target ($BUNDLE_ID)"
if [ "${NO_LAUNCH:-0}" != 1 ]; then open "$target"; echo "Launched $target"; fi
