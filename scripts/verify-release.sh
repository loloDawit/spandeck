#!/bin/bash
# Release gate (#11). Refuses a DMG unless it and the SpanDeck.app inside it are signed with SpanDeck's Developer ID
# (Hardened Runtime on the app, secure timestamp), notarized with the ticket stapled, accepted by Gatekeeper as
# "Notarized Developer ID", and universal. These are steps 4-8 of docs/RELEASE_SIGNING.md. release.yml runs it before
# anything is uploaded; a maintainer can run it on a locally signed DMG. Fails closed: when release signing isn't
# configured (no Team ID), nothing passes.
#   SPANDECK_TEAM_ID=<TEAMID> scripts/verify-release.sh build/SpanDeck-<version>.dmg
#   SPANDECK_TEAM_ID=<TEAMID> scripts/verify-release.sh --preflight      configuration only, before a build
# The Team ID isn't a secret; release.yml reads it from the repository variable SPANDECK_TEAM_ID, which isn't set until
# the owner decides who signs (RELEASE_SIGNING.md, decisions 2 and 3). CODESIGN, SPCTL, STAPLER, HDIUTIL and LIPO
# override the tools for scripts/test-verify-release.sh. Exit 0 verified, 1 refused, 64 usage.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=Resources/identity.env
. "$repo/Resources/identity.env"
CODESIGN=${CODESIGN:-codesign} SPCTL=${SPCTL:-spctl} STAPLER=${STAPLER:-xcrun stapler}
HDIUTIL=${HDIUTIL:-hdiutil} LIPO=${LIPO:-lipo}

refuse() { echo "REFUSED: $*" >&2; exit 1; }
[ $# = 1 ] || { echo "usage: SPANDECK_TEAM_ID=<TEAMID> $0 <dmg> | --preflight" >&2; exit 64; }

team=${SPANDECK_TEAM_ID:-}
[ -n "$team" ] || refuse "release signing is not configured: no SPANDECK_TEAM_ID (docs/RELEASE_SIGNING.md, decisions 2 and 3)"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || refuse "SPANDECK_TEAM_ID is not a 10-character Apple Team ID"
if [ "$1" = --preflight ]; then echo "release signing configured for Team ID $team"; exit 0; fi

dmg=$1
[ -f "$dmg" ] || refuse "no DMG at $dmg"

# Checks the output of `codesign -dvv` for a Developer ID signature of this team with a secure timestamp.
developer_id() { # label details
    grep -q '^Authority=Developer ID Application: ' <<< "$2" || refuse "$1 is not signed with a Developer ID Application certificate"
    grep -qx "TeamIdentifier=$team" <<< "$2" || refuse "$1 TeamIdentifier is not $team"
    grep -q '^Timestamp=' <<< "$2" || refuse "$1 has no secure timestamp"
}

# The DMG: signature, notarization ticket, Gatekeeper.
$CODESIGN --verify --strict --verbose=2 "$dmg" > /dev/null 2>&1 || refuse "the DMG's signature doesn't verify"
developer_id "the DMG" "$($CODESIGN -dvv "$dmg" 2>&1)"
$STAPLER validate "$dmg" > /dev/null 2>&1 || refuse "the DMG has no valid notarization ticket stapled"
assessment=$($SPCTL --assess --type open --context context:primary-signature --verbose=4 "$dmg" 2>&1) ||
    refuse "Gatekeeper rejects the DMG"
grep -qx 'source=Notarized Developer ID' <<< "$assessment" || refuse "Gatekeeper doesn't see the DMG as Notarized Developer ID"

# The app inside it, from a read-only mount.
mnt=$(mktemp -d "${TMPDIR:-/tmp}/spandeck-release-gate.XXXXXX")
mounted=0
cleanup() { if [ "$mounted" = 1 ]; then $HDIUTIL detach "$mnt" -quiet || $HDIUTIL detach "$mnt" -force -quiet || true; fi; rmdir "$mnt" 2>/dev/null || true; }
trap cleanup EXIT
$HDIUTIL attach -readonly -nobrowse -noautoopen -mountpoint "$mnt" "$dmg" > /dev/null || refuse "the DMG doesn't mount"
mounted=1
apps=$(find "$mnt" -mindepth 1 -maxdepth 1 -name '*.app' | wc -l | tr -d ' ')
[ "$apps" = 1 ] && [ -d "$mnt/$APP_NAME.app" ] || refuse "the DMG must hold exactly one app, $APP_NAME.app (found $apps)"
app="$mnt/$APP_NAME.app"
$CODESIGN --verify --strict --verbose=2 "$app" > /dev/null 2>&1 || refuse "$APP_NAME.app's signature doesn't verify"
details=$($CODESIGN -dvv "$app" 2>&1)
developer_id "$APP_NAME.app" "$details"
grep -qx "Identifier=$BUNDLE_ID" <<< "$details" || refuse "$APP_NAME.app's bundle id is not $BUNDLE_ID"
grep -q '^CodeDirectory .*flags=0x[0-9a-f]*([^)]*runtime[^)]*)' <<< "$details" || refuse "$APP_NAME.app is not signed with Hardened Runtime"
assessment=$($SPCTL --assess --type execute --verbose=4 "$app" 2>&1) || refuse "Gatekeeper rejects $APP_NAME.app"
grep -qx 'source=Notarized Developer ID' <<< "$assessment" || refuse "Gatekeeper doesn't see $APP_NAME.app as Notarized Developer ID"
archs=$($LIPO -archs "$app/Contents/MacOS/$APP_NAME")
[[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || refuse "$APP_NAME.app is not universal (archs: $archs)"

echo "VERIFIED $(basename "$dmg"): Developer ID $team, notarized, stapled, $archs;" \
    "sha256 $(shasum -a 256 "$dmg" | cut -d' ' -f1), binary sha256 $(shasum -a 256 "$app/Contents/MacOS/$APP_NAME" | cut -d' ' -f1)"
