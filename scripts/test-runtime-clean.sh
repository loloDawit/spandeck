#!/bin/bash
# Tests runtime-verify.sh's fixture cleanup (#11, review of e39f9c5) in a scratch home, with stand-ins for `defaults`
# and `dsmemberutil` so this account's preferences and groups aren't touched. `clean` deletes only files registered
# by the script, and nothing else; an old marker without a registry is refused with a read-only inventory;
# `clean-fixtures-legacy` deletes only Run 3-shaped synthetic fixtures after confirmation and refuses anything else.
# Neither ever removes ~/.claude/projects wholesale or touches evidence. Run: scripts/test-runtime-clean.sh
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/spandeck-clean-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
me=$(id -un)
mkdir -p "$tmp/bin"
printf '#!/bin/bash\nexit 1\n' > "$tmp/bin/defaults"
printf '#!/bin/bash\necho "%s is not a member of the group admin"\n' "$me" > "$tmp/bin/dsmemberutil"
chmod +x "$tmp/bin/defaults" "$tmp/bin/dsmemberutil"
pass=0 fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
ko() { echo "FAIL $*"; fail=$((fail + 1)); }
H="$tmp/home"; P="$H/.claude/projects"
RV() { HOME="$H" RV_USER="$me" RV_SHARED="$tmp/shared" PATH="$tmp/bin:$PATH" "$repo/scripts/runtime-verify.sh" "$@"; }
setup() { # a home with a registered run and evidence
    rm -rf "$H"; mkdir -p "$H/spandeck-rv-evidence/run1" "$tmp/shared"
    touch "$H/spandeck-rv-evidence/run1/.preflight-ok" "$H/spandeck-rv-evidence/run1/keep-me.txt"
    echo "$H/spandeck-rv-evidence/run1" > "$H/spandeck-rv-evidence/current"; echo x > "$tmp/shared/current"
}
files() { (cd "$H" && find . \( -type f -o -type l \) | sort); }
tok=0123456789ab d="-Users-$me-rvpath$tok"

# 1. A registered run: `clean` removes the registered fixtures only.
setup; RV fixtures 0 > /dev/null; RV completeness > /dev/null
reg=$(sed -n 's/^file=//p' "$P/.spandeck-rv-fixtures" | head -1); dir=${reg%/*}
echo '{"stray":1}' > "$P/$dir/not-registered.jsonl"; echo note > "$P/$dir/notes.txt"
echo "y" | RV clean > "$tmp/out.txt" 2>&1 || true
left=$(files)
grep -q "not-registered.jsonl" <<< "$left" && grep -q "notes.txt" <<< "$left" && ok "clean keeps an unregistered transcript and a sentinel" || ko "clean removed unregistered files: $left"
grep -q -- "-main.jsonl\|-completeness.jsonl" <<< "$left" && ko "clean left registered fixtures" || ok "clean removed the registered fixtures"
grep -q "keep-me.txt" <<< "$left" && [ -d "$P" ] && ok "evidence and ~/.claude/projects kept" || ko "evidence or projects removed"

# 2. An old (Run 3) marker with no registry: `clean` refuses, deletes nothing, and lists what's there.
setup; mkdir -p "$P/$d"; : > "$P/.spandeck-rv-fixtures"
for k in main identity completeness privacy; do echo "{\"x\":\"rvid$tok RVCANARY$tok\"}" > "$P/$d/rvid$tok-$k.jsonl"; done
before=$(files)
if echo "y" | RV clean > "$tmp/out.txt" 2>&1; then ko "clean ran with an old marker"; else ok "clean refused an old marker"; fi
[ "$(files)" = "$before" ] && ok "nothing deleted" || ko "files changed"
grep -q "rvid$tok-main.jsonl" "$tmp/out.txt" && ok "inventory listed" || ko "no inventory: $(cat "$tmp/out.txt")"

# 3. clean-fixtures-legacy: declining deletes nothing; confirming deletes exactly the Run 3 fixtures.
run3() { setup; mkdir -p "$P/$d"; : > "$P/.spandeck-rv-fixtures"
    for k in main identity completeness privacy perf1; do echo "{\"x\":\"rvid$tok RVCANARY$tok\"}" > "$P/$d/rvid$tok-$k.jsonl"; done; }
run3; before=$(files)
echo "n" | RV clean-fixtures-legacy > "$tmp/out.txt" 2>&1 || true
[ "$(files)" = "$before" ] && ok "clean-fixtures-legacy: declining deletes nothing" || ko "declining changed files"
echo "y" | RV clean-fixtures-legacy > "$tmp/out.txt" 2>&1 || true
[ -d "$P" ] && [ ! -e "$P/$d" ] && [ ! -e "$P/.spandeck-rv-fixtures" ] && ok "clean-fixtures-legacy removed the Run 3 fixtures" || ko "fixtures left: $(files)"
grep -q "keep-me.txt" <<< "$(files)" && ok "evidence kept" || ko "evidence removed"

# 4. clean-fixtures-legacy refuses anything not positively a Run 3 fixture, deleting nothing.
legacy_refuses() { # label, then a setup command run in $P
    setup; mkdir -p "$P/$d"; : > "$P/.spandeck-rv-fixtures"
    echo "{\"x\":\"rvid$tok\"}" > "$P/$d/rvid$tok-main.jsonl"
    (cd "$P" && eval "$2")
    local b; b=$(files)
    if echo "y" | RV clean-fixtures-legacy > "$tmp/out.txt" 2>&1; then ko "$1: not refused"
    elif [ "$(files)" = "$b" ]; then ok "$1: refused, nothing deleted"; else ko "$1: refused but files changed"; fi
}
legacy_refuses "an unexpected file" "echo x > '$d/notes.txt'"
legacy_refuses "a transcript in another project folder" "mkdir -p ./-Users-$me-real-project && echo '{}' > ./-Users-$me-real-project/s.jsonl"
legacy_refuses "a fixture name without its token" "echo '{\"x\":1}' > '$d/rvid$tok-privacy.jsonl'"
legacy_refuses "a symlink" "ln -s /etc/hosts '$d/rvid$tok-identity.jsonl'"
legacy_refuses "a registered (new) marker" "echo run=run1 > .spandeck-rv-fixtures"
setup; mkdir -p "$tmp/elsewhere/$d"; mkdir -p "$H/.claude"; ln -s "$tmp/elsewhere" "$P"; : > "$tmp/elsewhere/.spandeck-rv-fixtures"
if echo "y" | RV clean-fixtures-legacy > "$tmp/out.txt" 2>&1; then ko "projects folder as a link: not refused"; else ok "projects folder as a link: refused"; fi
if echo "y" | RV clean > "$tmp/out.txt" 2>&1; then ko "clean with projects as a link: not refused"; else ok "clean with projects as a link: refused"; fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
