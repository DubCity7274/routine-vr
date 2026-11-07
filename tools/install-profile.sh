#!/usr/bin/env bash
# Copy the UEVR profile into Routine's Proton prefix.
#
# config.txt is merged, not replaced: keys set in the repo's config.txt win,
# every other key UEVR wrote (its own defaults, your in-headset tweaks to
# settings the profile doesn't manage) is kept. The profile's data/ folder
# (Routine VR settings, hand attachments) and uobjecthook/ are left alone.
# The first install backs up the original config.txt for the uninstaller.
set -euo pipefail
source "$(dirname "$0")/common.sh"

compat="$(find_compatdata)" || { echo "Routine (app $APPID) not found in any Steam library." >&2; exit 1; }
[ -d "$compat/pfx" ] || { echo "No Proton prefix at $compat yet. Launch Routine once, then rerun." >&2; exit 1; }

src="$REPO_DIR/profile/$GAME_EXE"
dest="$(profile_dir "$compat")"
mkdir -p "$dest"

# First install: remember UEVR's own config.txt (or that there was none) so
# tools/uninstall-profile.sh can put things back exactly.
if [ ! -f "$dest/.routine-vr-installed" ]; then
    if [ -f "$dest/config.txt" ]; then
        cp "$dest/config.txt" "$dest/config.txt.pre-routine-vr"
        echo "config=backed-up" > "$dest/.routine-vr-installed"
    else
        echo "config=created" > "$dest/.routine-vr-installed"
    fi
fi

# Test builds before 0.1.0-beta.5 shipped UEVR binding files that put stick touch
# on the thumbrest action, which turned on UEVR's D-pad shifting: take them
# out again (and put back any the player had).
for b in "$dest"/_interaction_profiles_*.json; do
    [ -f "$b" ] || continue
    if grep -q '"_routine_vr"' "$b"; then rm -f "$b"; echo "Removed old binding file $(basename "$b")."; fi
done
for b in "$dest"/_interaction_profiles_*.json.pre-routine-vr; do
    [ -f "$b" ] || continue
    mv "$b" "${b%.pre-routine-vr}"
done

rsync -a --exclude config.txt "$src/" "$dest/"

if [ -f "$dest/config.txt" ]; then
    tmp="$(mktemp)"
    # Repo keys first (they win), then existing keys the repo doesn't set.
    # UEVR writes CRLF, so normalise every line to that.
    awk -F= 'BEGIN { ORS = "\r\n" }
        { sub(/\r$/, "") }
        NR==FNR { if (NF) { seen[$1]=1; print }; next }
        NF && !($1 in seen)' \
        "$src/config.txt" "$dest/config.txt" > "$tmp"
    mv "$tmp" "$dest/config.txt"
    echo "Merged profile settings into existing config.txt."
else
    cp "$src/config.txt" "$dest/config.txt"
fi

echo "Installed profile to:"
echo "  $dest"
