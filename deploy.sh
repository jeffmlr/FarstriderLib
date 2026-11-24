#!/bin/bash
# Install the addon into each game client's AddOns folder that exists (retail,
# and Forever under _forever_), as upstream's packager builds it: every line
# marked REMOVE_LINE is dropped, and so is each file that only such a line loads
# (the debug logger and debug tools), and the "-- local _, Name = ..." lines the
# repo keeps commented for its debug build are switched on. The repo itself never
# lives in the game folder, and a plain copy of it is a debug build: don't
# install it that way. (The TOC's UNCOMMENT_NEXT_LINE is left alone.)
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/"
WOW="${WOW_DIR:-/Applications/World of Warcraft}"
TARGETS=()
for client in _retail_ _forever_; do
    [ -d "$WOW/$client" ] && TARGETS+=("$WOW/$client/Interface/AddOns/FarstriderLib/")
done

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
rsync -a \
    --exclude '.git' --exclude '.gitignore' --exclude '.DS_Store' --exclude '.vscode' \
    --exclude '.claude' --exclude '.agents' --exclude 'tests' --exclude 'deploy.sh' --exclude 'CLAUDE.md' \
    "$SRC" "$STAGE/"

# Files that a REMOVE_LINE <Script> line loads go first, then the marked lines.
while IFS= read -r xml; do
    grep 'REMOVE_LINE' "$xml" | sed -n "s/.*file=[\"']\([^\"']*\)[\"'].*/\1/p" | tr '\\' '/' |
        while IFS= read -r file; do rm -f "$(dirname "$xml")/$file"; done
done < <(find "$STAGE" -name '*.xml')
find "$STAGE" \( -name '*.lua' -o -name '*.xml' -o -name '*.toc' \) -exec perl -ni -e 'print unless /REMOVE_LINE/' {} +
find "$STAGE" -name '*.lua' -exec perl -pi -e 's/^-- (local _, \w+ = \.\.\.)$/$1/' {} +

# The game reads AddOns at login and /reload. rsync writes each file under a
# temporary name and renames it into place, so a running client never sees a
# half-written file: /reload picks the copy up. A Lua file new to the TOC is
# the exception (the client lists AddOn files at start-up), so that needs a
# restart; this says so when the TOC changed.
RUNNING=0
pgrep -f "Contents/MacOS/World of Warcraft" >/dev/null && RUNNING=1
TOC_CHANGED=0

for dst in "${TARGETS[@]}"; do
    mkdir -p "$dst"
    if ! cmp -s "$STAGE/FarstriderLib.toc" "$dst/FarstriderLib.toc"; then TOC_CHANGED=1; fi
    rsync -a --delete "$STAGE/" "$dst"
    echo "deployed to $dst"
done

if [ "$RUNNING" = 1 ]; then
    if [ "$TOC_CHANGED" = 1 ]; then
        echo "The game is running and FarstriderLib.toc changed: restart the game to load it."
    else
        echo "The game is running: type /reload to load it."
    fi
fi
