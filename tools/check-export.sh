#!/usr/bin/env bash
# Verify the Godot export in server/public/game/ was built from the CURRENT source.
# Run from the repo root before every push:  ./tools/check-export.sh
set -u
GAME="server/public/game"
fail=0
if [ ! -f "$GAME/index.pck" ] || [ ! -f "$GAME/index.html" ]; then
  echo "FAIL: no export at $GAME — export from Godot first (Project → Export → Web)."
  exit 1
fi
name=$(grep -oE '<title>[^<]*</title>' "$GAME/index.html" | sed 's/<[^>]*>//g' | sed 's/ (DEBUG)//')
want=$(grep -oE 'config/name="[^"]*"' client/project.godot | cut -d'"' -f2)
if [ "$name" != "$want" ]; then
  echo "FAIL: export says '$name' but project.godot says '$want' — the export is STALE."
  echo "      Re-export from Godot: Project → Export → Web → Export Project."
  fail=1
fi
if [ -d .git ]; then
  newest=$(find client \( -name '*.gd' -o -name '*.tscn' -o -name 'project.godot' \) -newer "$GAME/index.pck" 2>/dev/null | head -3)
  if [ -n "$newest" ]; then
    echo "FAIL: these are newer than the export — re-export before pushing:"
    echo "$newest" | sed 's/^/        /'
    fail=1
  fi
fi
[ "$fail" -eq 0 ] && echo "OK: export matches source ('$name')."
exit "$fail"
