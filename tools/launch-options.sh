#!/usr/bin/env bash
# Print the Steam launch options for Routine VR.
#
# Use Valve's Proton 11 (or Experimental). Proton-Wineland's DXVK/vkd3d fail
# to create a GPU device whenever a VR runtime is present.
#
# VR_OVERRIDE points Proton's VR setup at xrizer so it detects WiVRn. UEVR
# then talks OpenXR through Proton's wineopenxr (the profile's default), or
# OpenVR through vrclient -> xrizer if you pick OpenVR in the injector.
source "$(dirname "$0")/common.sh"

xrizer="${XRIZER_RUNTIME:-/run/host/usr/lib64/xrizer/runtime}"
injector="$UEVR_DIR/UEVRInjector.exe --attach=$GAME_EXE.exe"

cat <<EOF
Steam -> Routine -> Properties:
  Compatibility:  force "Proton 11.0" (not Wineland)
  Launch Options:

VR_OVERRIDE=$xrizer PROTON_REMOTE_DEBUG_CMD="$injector" %command%

Start WiVRn (and connect the headset) before launching. The injector opens
with the game and injects automatically; leave it on OpenXR.
EOF
