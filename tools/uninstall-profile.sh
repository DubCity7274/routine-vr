#!/usr/bin/env bash
# Remove the Routine VR profile from Routine's Proton prefix.
#
# Deletes the mod's scripts and user_script.txt, and puts config.txt back as
# it was before the first install (restored from config.txt.pre-routine-vr,
# or removed if the mod created it). Your Routine VR settings in data/ are
# kept unless you pass --remove-settings. UEVR's own files are left alone.
#
#   tools/uninstall-profile.sh [--remove-settings]
set -euo pipefail
source "$(dirname "$0")/common.sh"

compat="$(find_compatdata)" || { echo "Routine (app $APPID) not found in any Steam library." >&2; exit 1; }
dest="$(profile_dir "$compat")"
[ -d "$dest" ] || { echo "No UEVR profile at $dest: nothing to remove."; exit 0; }

rm -rf "$dest/scripts/routine_vr" "$dest/scripts/routine_vr.lua"
rmdir "$dest/scripts" 2>/dev/null || true
rm -f "$dest/user_script.txt"
# The mod's UEVR binding files; any the player had before come back.
for b in "$dest"/_interaction_profiles_*.json; do
    [ -f "$b" ] || continue
    if grep -q '"_routine_vr"' "$b"; then rm -f "$b"; fi
done
for b in "$dest"/_interaction_profiles_*.json.pre-routine-vr; do
    [ -f "$b" ] || continue
    mv "$b" "${b%.pre-routine-vr}"
    echo "Restored your $(basename "${b%.pre-routine-vr}")."
done

marker="$dest/.routine-vr-installed"
if [ -f "$dest/config.txt.pre-routine-vr" ]; then
    mv "$dest/config.txt.pre-routine-vr" "$dest/config.txt"
    echo "Restored your original config.txt."
elif grep -q "config=created" "$marker" 2>/dev/null; then
    rm -f "$dest/config.txt"
    echo "Removed config.txt (the mod created it; UEVR makes a fresh one)."
else
    echo "No config.txt backup found; left config.txt as it is."
fi
rm -f "$marker"

if [ "${1:-}" = "--remove-settings" ]; then
    rm -f "$dest"/data/routine_vr*.json
    rmdir "$dest/data" 2>/dev/null || true
    echo "Removed Routine VR settings and recordings."
fi

echo "Routine VR removed from:"
echo "  $dest"
