#!/usr/bin/env bash
# Build the release zips in dist/ from the last commit (uncommitted changes
# are left out, so a release is always reproducible from git):
#
#   routine-vr-<version>-profile.zip   just the mod: a Routine-Win64-Shipping/
#                                      folder to extract into UEVR's profiles
#                                      folder (no installer needed)
#   routine-vr-<version>.zip           everything: installers, tools, docs,
#                                      tests and the profile
#
# The version comes from profile/.../scripts/routine_vr/version.lua.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

git diff --quiet HEAD -- || echo "Note: uncommitted changes are not included in the release."
version="$(git show HEAD:profile/Routine-Win64-Shipping/scripts/routine_vr/version.lua | sed -n 's/^return "\(.*\)"/\1/p')"
[ -n "$version" ] || { echo "Couldn't read the version from version.lua." >&2; exit 1; }

mkdir -p dist
full="dist/routine-vr-$version.zip"
prof="dist/routine-vr-$version-profile.zip"
rm -f "$full" "$prof"

git archive --format=zip --prefix="routine-vr-$version/" -o "$full" HEAD
# Just the profile, with the folder name UEVR expects at the top.
git archive --format=zip --prefix="Routine-Win64-Shipping/" -o "$prof" HEAD:profile/Routine-Win64-Shipping

echo "Built:"
ls -l "$full" "$prof"
