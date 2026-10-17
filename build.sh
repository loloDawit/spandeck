#!/bin/bash
# Builds SpanDeck.app as a universal (Apple Silicon + Intel) binary. Names come from Resources/identity.env (#11); the
# Swift module is still called Headroom internally. SpanDeck is a fork of Headroom and never touches Headroom's app or its
# data.
#   ./build.sh            build build/SpanDeck.app
#   ./build.sh install    build, then scripts/install-app.sh: replace /Applications/SpanDeck.app and launch it
#   ./build.sh dmg        build and package build/SpanDeck-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=Resources/identity.env
. Resources/identity.env

plist() { /usr/libexec/PlistBuddy -c "Print $1" Resources/Info.plist; }
# Info.plist must say what identity.env says.
for key in CFBundleName CFBundleDisplayName CFBundleExecutable; do
    [ "$(plist "$key")" = "$APP_NAME" ] || { echo "Info.plist $key is not $APP_NAME" >&2; exit 1; }
done
[ "$(plist CFBundleIdentifier)" = "$BUNDLE_ID" ] || { echo "Info.plist CFBundleIdentifier is not $BUNDLE_ID" >&2; exit 1; }
VERSION=$(plist CFBundleShortVersionString)

swift build -c release --arch arm64 --arch x86_64 --product "$APP_NAME"
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signature. For a notarized release, sign with a Developer ID instead:
#   codesign --force --options runtime --sign "Developer ID Application: ..." "$APP"
codesign --force --sign - "$APP"
echo "Built $APP ($VERSION, $BUNDLE_ID, $(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"

case "${1:-}" in
install)
    scripts/install-app.sh "$APP"
    ;;
dmg)
    DMG="build/$APP_NAME-$VERSION.dmg"
    STAGE=build/dmg
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "Packaged $DMG ($(du -h "$DMG" | cut -f1))"
    ;;
esac
