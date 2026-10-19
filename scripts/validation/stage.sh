#!/bin/bash
# #94 private-use validation, step 1 of 2: run in YOUR NORMAL ACCOUNT. Copies an already-built candidate and the
# validation tools into /Users/Shared so the dedicated test account can use them without any access to this account.
# It builds only the small fork monitor (procwatch); it never launches SpanDeck, reads no transcripts or credentials,
# and writes nothing outside /Users/Shared/spandeck-validation/<commit>/ (and build/ for procwatch).
#
#   scripts/validation/stage.sh <candidate-commit> <expected-dmg-sha256>
#
# <candidate-commit> names build/candidate/<commit>/ from scripts/package-candidate.sh. The expected SHA-256 comes
# from the readiness report on #94, not from the folder, so a swapped DMG is caught here and again in the test account.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=../../Resources/identity.env
. Resources/identity.env

die() { echo "STOP: $*" >&2; exit 1; }
[ $# = 2 ] || die "usage: scripts/validation/stage.sh <candidate-commit> <expected-dmg-sha256>"
commit=$1 want=$2
[[ "$commit" =~ ^[0-9a-f]{7,40}$ ]] || die "candidate commit must be hex"
[[ "$want" =~ ^[0-9a-f]{64}$ ]] || die "expected SHA-256 must be 64 lowercase hex characters"
src=build/candidate/${commit:0:7}
dmg=$src/$APP_NAME-$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist).dmg
[ -f "$dmg" ] && [ -f "$src/PROVENANCE.txt" ] && [ -f "$src/SHA256SUMS" ] || die "no candidate in $src (run scripts/package-candidate.sh at $commit)"
got=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
[ "$got" = "$want" ] || die "DMG SHA-256 is $got, expected $want"
grep -q "^commit: *${commit}" "$src/PROVENANCE.txt" || die "PROVENANCE.txt doesn't name commit $commit"

dest=/Users/Shared/spandeck-validation/${commit:0:7}
[ ! -e "$dest" ] || die "$dest exists; remove it first (rm -rf \"$dest\") to restage"
mkdir -p build/validation
clang -Wall -Wextra -O2 -o build/validation/procwatch scripts/runtime/procwatch.c
mkdir -p "$dest"
chmod 755 /Users/Shared/spandeck-validation
cp "$dmg" "$src/PROVENANCE.txt" "$src/SHA256SUMS" "$dest/"
cp scripts/validation/validate.sh scripts/runtime/procwatch.c build/validation/procwatch Resources/identity.env \
    docs/VALIDATION_RUN.md "$dest/"
# The test account checks this account is unreachable; it needs the name, nothing else.
{
    echo "main_user=$(id -un)"
    echo "main_uid=$(id -u)"
    echo "stager_uid=$(id -u)"
    echo "candidate_commit=$(sed -n 's/^commit: *//p' "$src/PROVENANCE.txt")"
    echo "candidate_dmg_sha256=$want"
    echo "package_commit=$(git rev-parse HEAD)"
    echo "package_tree_clean=$([ -z "$(git status --porcelain --untracked-files=no -- scripts docs Resources)" ] && echo yes || echo no)"
    echo "staged_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$dest/package.env"
(cd "$dest" && shasum -a 256 validate.sh procwatch procwatch.c identity.env package.env VALIDATION_RUN.md > PACKAGE.sha256)
chmod 755 "$dest" "$dest/validate.sh" "$dest/procwatch"
chmod 644 "$dest"/*.dmg "$dest"/*.txt "$dest"/*.env "$dest"/*.md "$dest"/*.c "$dest/SHA256SUMS" "$dest/PACKAGE.sha256"
mkdir -p /Users/Shared/spandeck-validation-results && chmod 1777 /Users/Shared/spandeck-validation-results
echo "Staged $dest (nothing launched):"
ls -l "$dest"
echo
echo "validate.sh SHA-256 (compare with the reviewed file): $(shasum -a 256 scripts/validation/validate.sh | cut -d' ' -f1)"
echo "Next: log in as spandecktest and follow $dest/VALIDATION_RUN.md"
