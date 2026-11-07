# To do

## Bugs

- **Jittery head tracking** now and then, cured only by restarting the
  game. Cause unknown; the panel's top line and the recorder now show the
  frame time to see whether the game is slowing down.
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
