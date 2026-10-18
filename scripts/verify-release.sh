#!/bin/bash -p
# Release gate (#11). Refuses a DMG unless it and the SpanDeck.app inside it are signed with SpanDeck's Developer ID
# (Hardened Runtime on the app, secure timestamp), notarized with the ticket stapled, accepted by Gatekeeper as
# "Notarized Developer ID", and universal. These are steps 4-8 of docs/RELEASE_SIGNING.md. release.yml runs it before
# anything is uploaded; a maintainer can run it on a locally signed DMG. Fails closed: when release signing isn't
# configured (no Team ID), nothing passes.
#   SPANDECK_TEAM_ID=<TEAMID> scripts/verify-release.sh build/SpanDeck-<version>.dmg
#   SPANDECK_TEAM_ID=<TEAMID> scripts/verify-release.sh --preflight      configuration only, before a build
# The Team ID isn't a secret; release.yml reads it from the repository variable SPANDECK_TEAM_ID, which isn't set until
# the owner decides who signs (RELEASE_SIGNING.md, decisions 2 and 3). On a pass, `sha256=<hex>` of the verified DMG is
# appended to $GITHUB_OUTPUT when set, so the upload step can check it is uploading those bytes.
# The environment can't change what this checks: `bash -p` ignores BASH_ENV and exported functions, PATH is fixed, and
# the tools are absolute paths with no override (scripts/test-verify-release.sh tests a copy with this one line
# rewritten). Exit 0 verified, 1 refused, 64 usage.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
readonly CODESIGN=/usr/bin/codesign SPCTL=/usr/sbin/spctl STAPLER="/usr/bin/xcrun stapler" HDIUTIL=/usr/bin/hdiutil LIPO=/usr/bin/lipo
repo=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=Resources/identity.env
. "$repo/Resources/identity.env"

refuse() { echo "REFUSED: $*" >&2; exit 1; }
[ $# = 1 ] || { echo "usage: SPANDECK_TEAM_ID=<TEAMID> $0 <dmg> | --preflight" >&2; exit 64; }

team=${SPANDECK_TEAM_ID:-}
[ -n "$team" ] || refuse "release signing is not configured: no SPANDECK_TEAM_ID (docs/RELEASE_SIGNING.md, decisions 2 and 3)"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || refuse "SPANDECK_TEAM_ID is not a 10-character Apple Team ID"
if [ "$1" = --preflight ]; then echo "release signing configured for Team ID $team"; exit 0; fi

dmg=$1
[[ "$dmg" == *.dmg && "$dmg" != -* ]] || refuse "the path must name a .dmg file and not start with '-'"
[ ! -L "$dmg" ] || refuse "the DMG is a symlink; pass the file itself"
[ -f "$dmg" ] || refuse "no DMG at $dmg"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
sum=$(sha "$dmg")

# Apple's Developer ID Application requirement for this team: an Apple-anchored chain through the Developer ID CA, a
# Developer ID Application leaf, and the team in the leaf's OU. A self-signed certificate named "Developer ID" fails it.
requirement='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "'"$team"'"'
signed() { $CODESIGN --verify --strict --verbose=2 "--test-requirement==$requirement" "$1" > /dev/null 2>&1; }
# The signature details, as a second, independent reading of the same signature.
developer_id() { # label details
    grep -q '^Authority=Developer ID Application: ' <<< "$2" || refuse "$1 is not signed with a Developer ID Application certificate"
    grep -qxF "TeamIdentifier=$team" <<< "$2" || refuse "$1 TeamIdentifier is not $team"
    grep -q '^Timestamp=' <<< "$2" || refuse "$1 has no secure timestamp"
}

# The DMG: signature, notarization ticket, Gatekeeper.
signed "$dmg" || refuse "the DMG isn't validly signed with SpanDeck's Developer ID ($team)"
details=$($CODESIGN -dvv "$dmg" 2>&1) || refuse "codesign can't read the DMG's signature"
developer_id "the DMG" "$details"
$STAPLER validate "$dmg" > /dev/null 2>&1 || refuse "the DMG has no valid notarization ticket stapled"
assessment=$($SPCTL --assess --type open --context context:primary-signature --verbose=4 "$dmg" 2>&1) ||
    refuse "Gatekeeper rejects the DMG"
grep -qxF 'source=Notarized Developer ID' <<< "$assessment" || refuse "Gatekeeper doesn't see the DMG as Notarized Developer ID"

# The app inside it, from a read-only mount. A mount point is removed only once it is detached and empty.
mnt=$(mktemp -d "${TMPDIR:-/tmp}/spandeck-release-gate.XXXXXX")
cleanup() {
    $HDIUTIL detach "$mnt" -quiet > /dev/null 2>&1 || $HDIUTIL detach "$mnt" -force -quiet > /dev/null 2>&1 || true
    rmdir "$mnt" 2> /dev/null || true
}
trap cleanup EXIT
$HDIUTIL attach -readonly -nobrowse -noautoopen -mountpoint "$mnt" "$dmg" > /dev/null 2>&1 || refuse "the DMG doesn't mount"
apps=$(find "$mnt" -mindepth 1 -maxdepth 1 -name '*.app' | wc -l | tr -d ' ')
app="$mnt/$APP_NAME.app"
if [ "$apps" != 1 ] || { [ ! -e "$app" ] && [ ! -L "$app" ]; }; then
    refuse "the DMG must hold exactly one app, $APP_NAME.app (found $apps)"
fi
if [ -L "$app" ] || [ ! -d "$app" ]; then refuse "$APP_NAME.app in the DMG is a symlink, not the app itself"; fi
signed "$app" || refuse "$APP_NAME.app isn't validly signed with SpanDeck's Developer ID ($team)"
details=$($CODESIGN -dvv "$app" 2>&1) || refuse "codesign can't read $APP_NAME.app's signature"
developer_id "$APP_NAME.app" "$details"
grep -qxF "Identifier=$BUNDLE_ID" <<< "$details" || refuse "$APP_NAME.app's bundle id is not $BUNDLE_ID"
grep -q '^CodeDirectory .*flags=0x[0-9a-f]*([^)]*runtime[^)]*)' <<< "$details" || refuse "$APP_NAME.app is not signed with Hardened Runtime"
assessment=$($SPCTL --assess --type execute --verbose=4 "$app" 2>&1) || refuse "Gatekeeper rejects $APP_NAME.app"
grep -qxF 'source=Notarized Developer ID' <<< "$assessment" || refuse "Gatekeeper doesn't see $APP_NAME.app as Notarized Developer ID"
archs=$($LIPO -archs "$app/Contents/MacOS/$APP_NAME" 2>&1) || refuse "$APP_NAME.app is not universal (lipo: $archs)"
[[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || refuse "$APP_NAME.app is not universal (archs: $archs)"
binary=$(sha "$app/Contents/MacOS/$APP_NAME")

# Every check above read the same bytes, and those are the bytes the upload step must find.
[ "$(sha "$dmg")" = "$sum" ] || refuse "the DMG changed while it was being verified"
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "sha256=$sum" >> "$GITHUB_OUTPUT"; fi
echo "VERIFIED $(basename "$dmg"): Developer ID $team, notarized, stapled, $archs; sha256 $sum, binary sha256 $binary"
