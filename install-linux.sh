#!/usr/bin/env bash
# Routine VR for Linux (Steam + Proton). Run from anywhere.
#
#   ./install-linux.sh                 profile only (UEVR already set up)
#   ./install-linux.sh --full          also download UEVR and install .NET into the prefix
#   ./install-linux.sh --ppv PATH.zip  also install the PPV/SML pak mod from its Nexus zip
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
full=0
ppv=""
while [ $# -gt 0 ]; do
    case "$1" in
        --full) full=1 ;;
        --ppv) ppv="${2:?--ppv needs the path to the PPV zip}"; shift ;;
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ "$full" = 1 ]; then
    "$here/tools/setup-uevr.sh"
else
    "$here/tools/install-profile.sh"
    "$here/tools/launch-options.sh"
fi
if [ -n "$ppv" ]; then
    "$here/tools/install-pak-mods.sh" "$ppv"
fi
