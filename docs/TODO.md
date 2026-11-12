# To do

## Bugs

- **Jittery head tracking** on some launches, cured only by a restart.
  Cause found in UEVR's log: on those launches UEVR warns "the vtable is
  already hooked, maybe previous frame was not rendered?" once a second
  from the first frame (a smooth launch: never). Frame time is the same
  (about 21 ms) either way. It's UEVR's frame tracking, not the mod; the
  panel now says "restart the game" when it sees it. UEVR's Reinitialize
  Runtime crashes the game every time, jittery or not. Next: report it to
  UEVR with the logs in ~/.local/share/routine-vr/logs.
- **Recenter at start** doesn't reliably face you toward the splash
  screen (minor: B + Y works, and a splash-skip mod avoids it).
- **D3D11 crash on the RHI thread** (`DXGI_ERROR_INVALID_CALL`,
  D3D11Query.cpp:366). Same stack on Nov 2, Nov 8 and twice on Nov 9, so it
  predates motion hands. Repeats as the fish cutscene starts (chapter 4,
  loading the ASN save); that scene passed once with Proton logging on.
  Not tied to UEVR's frame-sync warning: one crash had it, one didn't.
  Suspect: the switch to 2D screen mode as a video cutscene starts (cutscene
  mode, now off by default; no repeat since).
- **Windows and manual installs** don't get the `data/uevr_log.txt` link, so
  no headset auto-detect or frame-sync warning there yet.
- **Crash entering the living quarters** (chapter 4, after the terminal
  video): one-off, gone after reloading. Unreal's report is an access
  violation on a worker thread with only game code on the stack, and no
  symbols to name it. Watch for a repeat at the same spot.
- **Black headset at startup** if a button was pressed before the main
  menu loaded. Not seen since 0.1.0-beta.1; may have been fixed by the
  input changes, or been a WiVRn/headset issue. Keep an eye out.

## Check

- **Easier grabbing** (`grab.lua`): confirmed on papers and a battery. Still
  to try: doors and other kinds of interactable, and a terminal with items
  behind it (those must not take the trigger). `data/routine_vr_notes.json`
  logs each press.

## Discord testers

- **Other headsets**: only Quest Touch has been played.
- **Windows installer** (`install-windows.bat`, `tools/windows/*.ps1`) has
  never been run.

## Features

- **Terminals by finger**: press them with the index finger like the
  C.A.T.'s buttons, instead of pointing.
- **Physical interaction**: doors, pickups and switches by hand (roadmap
  in DESIGN.md).
