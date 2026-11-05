#!/usr/bin/env bash
# Install KeinZantezuken's PPV + SML pak mod into Routine's ~mods folder.
#
# Routine VR uses its console commands ("rpp fisheye 0", ...) to remove the
# fisheye, grain and sharpen post-process effects, which the mod's Lua can't
# reach on its own. Only the .pak/.ucas/.utoc files are copied.
#
#   tools/install-pak-mods.sh [path/to/PPV-*.zip]
#   tools/install-pak-mods.sh --uninstall
set -euo pipefail
source "$(dirname "$0")/common.sh"

compat="$(find_compatdata)" || { echo "Routine (app $APPID) not found in any Steam library." >&2; exit 1; }
mods="$(game_dir "$compat")/Routine/Content/Paks/~mods"
[ -d "$(dirname "$mods")" ] || { echo "No Paks folder at $(dirname "$mods")" >&2; exit 1; }

files=(PPV.pak PPV.ucas PPV.utoc SML.pak SML.ucas SML.utoc)

if [ "${1:-}" = "--uninstall" ]; then
    for f in "${files[@]}"; do rm -fv "$mods/$f"; done
    rmdir "$mods" 2>/dev/null || true
    exit 0
fi

zip="${1:-}"
if [ -z "$zip" ]; then
    zip="$(ls "$REPO_DIR"/PPV-*.zip 2>/dev/null | head -1 || true)"
fi
[ -f "$zip" ] || { echo "PPV zip not found. Pass its path: $0 path/to/PPV-....zip" >&2; exit 1; }

mkdir -p "$mods"
python3 -I - "$zip" "$mods" "${files[@]}" <<'PY'
import os, sys, zipfile
zip_path, dest, *wanted = sys.argv[1:]
with zipfile.ZipFile(zip_path) as z:
    names = {os.path.basename(n): n for n in z.namelist()}
    missing = [w for w in wanted if w not in names]
    if missing:
        sys.exit(f"missing from zip: {', '.join(missing)}")
    for w in wanted:
        with z.open(names[w]) as src, open(os.path.join(dest, w), "wb") as out:
            out.write(src.read())
        print(f"installed {w}")
PY
echo "Pak mods installed to: $mods"
