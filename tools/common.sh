#!/usr/bin/env bash
# Shared paths for the Routine VR tools.

APPID=606160
GAME_EXE=Routine-Win64-Shipping
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TOOLS_DIR")"
UEVR_DIR="${UEVR_DIR:-$HOME/.local/share/routine-vr/uevr}"

# Find the Steam library holding Routine and its Proton prefix.
find_compatdata() {
    local roots=("$HOME/.local/share/Steam" "$HOME/.steam/steam")
    local vdf lib
    for root in "${roots[@]}"; do
        vdf="$root/steamapps/libraryfolders.vdf"
        [ -f "$vdf" ] || continue
        while IFS= read -r lib; do
            if [ -f "$lib/steamapps/appmanifest_$APPID.acf" ]; then
                echo "$lib/steamapps/compatdata/$APPID"
                return 0
            fi
        done < <(sed -n 's/^\s*"path"\s*"\(.*\)"/\1/p' "$vdf")
    done
    return 1
}

profile_dir() {
    echo "$1/pfx/drive_c/users/steamuser/AppData/Roaming/UnrealVRMod/$GAME_EXE"
}

# <library>/steamapps/compatdata/<appid> -> <library>/steamapps/common/Routine
game_dir() {
    echo "$(dirname "$(dirname "$1")")/common/Routine"
}
