# To do

## Bugs

- **Jittery head tracking** on some launches, cured only by a restart.
  Cause found in UEVR's log: on those launches UEVR warns "the vtable is
  already hooked, maybe previous frame was not rendered?" once a second
  from the first frame (a smooth launch: never). Frame time is the same
  (about 21 ms) either way. It's UEVR's frame tracking, not the mod; the
  panel now says "restart the game" when it sees it. Next: try UEVR's
  Reinitialize Runtime when it happens, and report it to UEVR with the
  logs in ~/.local/share/routine-vr/logs.
- **Recenter at start** doesn't reliably face you toward the splash
  screen: it recenters 4 s into the opening screens and again when the
  main menu first shows, but it still came out wrong. B + Y works.
- **Black headset at startup** if a button was pressed before the main
  menu loaded. Not seen since 0.1.0-beta.1; may have been fixed by the
  input changes, or been a WiVRn/headset issue. Keep an eye out.

## Discord testers

- **Other headsets**: only Quest Touch has been played.
- **Windows installer** (`install-windows.bat`, `tools/windows/*.ps1`) has
  never been run.

## Features

- **Terminals by finger**: press them with the index finger like the
  C.A.T.'s buttons, instead of pointing.
- **Physical interaction**: doors, pickups and switches by hand (roadmap
  in DESIGN.md).
