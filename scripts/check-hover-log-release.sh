#!/bin/bash
# Audit 0007, P2 (#68): the hover debug log (the `debugHover` lookup and the file writer, `HoverDebugLog`) is compiled
# only into debug builds. Refuses <binary> if, for any of its architectures, the symbol table has a HoverDebugLog symbol
# or a HoverController member whose name starts with `debug`. A binary whose symbol table doesn't list HoverController
# (stripped, or not SpanDeck) is refused too, so the check can't pass by seeing nothing. build.sh runs this on the
# packaged binary; scripts/test-hover-log-release.sh tests it.
#   scripts/check-hover-log-release.sh <binary>
set -euo pipefail
bin=${1:?usage: check-hover-log-release.sh <binary>}
for arch in $(lipo -archs "$bin"); do
    syms=$(nm -arch "$arch" "$bin")
    if ! grep -q '15HoverControllerC' <<<"$syms"; then
        echo "$bin ($arch): no HoverController symbols, so the hover log can't be checked"
        exit 1
    fi
    if found=$(grep -E 'HoverDebugLog|15HoverControllerC[0-9]+debug' <<<"$syms"); then
        echo "$bin ($arch): the hover debug log is compiled in ($(wc -l <<<"$found" | tr -d ' ') symbols, release builds must have none):"
        head -3 <<<"$found" | swift demangle
        exit 1
    fi
done
echo "No hover debug log in $bin ($(lipo -archs "$bin"))"
