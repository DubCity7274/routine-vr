#!/usr/bin/env bash
# Remove Routine VR (and the PPV/SML pak mod, if installed) on Linux.
#
#   ./uninstall-linux.sh                    keep your Routine VR settings
#   ./uninstall-linux.sh --remove-settings  remove them too
#
# UEVR itself (~/.local/share/routine-vr/uevr) and the .NET runtime in the
# prefix are left in place; remove the Steam launch options by hand.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
"$here/tools/uninstall-profile.sh" "$@"
"$here/tools/install-pak-mods.sh" --uninstall || true
echo "Remember to clear Routine's Steam launch options."
