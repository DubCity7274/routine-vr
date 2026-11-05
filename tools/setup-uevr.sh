#!/usr/bin/env bash
# One-time setup on the host (not inside a container):
#   1. download the latest UEVR nightly to $UEVR_DIR
#   2. install the .NET 6 Desktop Runtime the injector needs into Routine's prefix
#   3. install the profile
#   4. print the Steam launch options
set -euo pipefail
source "$(dirname "$0")/common.sh"

DOTNET_VER=6.0.36
DOTNET_URL="https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/$DOTNET_VER/windowsdesktop-runtime-$DOTNET_VER-win-x64.exe"
CACHE="$HOME/.cache/routine-vr"
mkdir -p "$CACHE" "$UEVR_DIR"

need() { command -v "$1" >/dev/null || { echo "Missing '$1'. $2" >&2; exit 1; }; }
need curl ""
need unzip ""
need sha256sum ""
need rsync ""

compat="$(find_compatdata)" || { echo "Routine (app $APPID) not found in any Steam library." >&2; exit 1; }
[ -d "$compat/pfx" ] || { echo "Launch Routine once so Proton creates its prefix, then rerun." >&2; exit 1; }

echo "== UEVR nightly"
api="https://api.github.com/repos/praydog/UEVR-nightly/releases/latest"
tag="$(curl -fsSL "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$tag" ] || { echo "Could not read the latest UEVR nightly tag." >&2; exit 1; }
base="https://github.com/praydog/UEVR-nightly/releases/download/$tag"
if [ "$(cat "$UEVR_DIR/.tag" 2>/dev/null)" != "$tag" ]; then
    curl -fL -o "$CACHE/uevr.zip" "$base/uevr.zip"
    curl -fsSL -o "$CACHE/uevr.zip.sha256" "$base/uevr.zip.sha256"
    # The release's checksum file has CRLF line endings.
    expected="$(tr -d '\r' < "$CACHE/uevr.zip.sha256" | awk '{print tolower($1)}')"
    actual="$(sha256sum "$CACHE/uevr.zip" | awk '{print $1}')"
    [ "$expected" = "$actual" ] || { echo "uevr.zip checksum mismatch" >&2; exit 1; }
    rm -rf "$UEVR_DIR" && mkdir -p "$UEVR_DIR"
    unzip -q "$CACHE/uevr.zip" -d "$UEVR_DIR"
    echo "$tag" > "$UEVR_DIR/.tag"
    echo "Installed $tag to $UEVR_DIR"
else
    echo "Already on $tag"
fi

echo "== .NET $DOTNET_VER Desktop Runtime in the Routine prefix"
if ls "$compat/pfx/drive_c/Program Files/dotnet/shared/Microsoft.WindowsDesktop.App/" 2>/dev/null | grep -q '^6\.'; then
    echo "Already installed"
else
    if command -v protontricks-launch >/dev/null; then
        launch=(protontricks-launch)
    elif flatpak info com.github.Matoking.protontricks >/dev/null 2>&1; then
        launch=(flatpak run --command=protontricks-launch com.github.Matoking.protontricks)
    else
        echo "Missing protontricks. Install it (dnf install protontricks, or the Flatpak)." >&2
        exit 1
    fi
    [ -f "$CACHE/dotnet-$DOTNET_VER.exe" ] || curl -fL -o "$CACHE/dotnet-$DOTNET_VER.exe" "$DOTNET_URL"
    # Stage the installer inside the prefix: the Flatpak sandbox can always
    # see the Steam library, but not necessarily ~/.cache.
    staged="$compat/pfx/drive_c/routine-vr-dotnet-$DOTNET_VER.exe"
    cp "$CACHE/dotnet-$DOTNET_VER.exe" "$staged"
    "${launch[@]}" --appid "$APPID" "$staged" /install /quiet /norestart
    rm -f "$staged"
fi

echo "== Profile"
"$TOOLS_DIR/install-profile.sh"

echo
"$TOOLS_DIR/launch-options.sh"
