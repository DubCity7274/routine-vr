# To do

## Bugs

- **Black headset at startup** if a button was pressed before the main
  menu loaded. Not seen since 0.1.0-beta.1; may have been fixed by the
  input changes, or been a WiVRn/headset issue. Keep an eye out.
- **Windows installer** (`install-windows.bat`, `tools/windows/*.ps1`) has
  never been run. Needs a test on a Windows PC.

## Check in the headset

- **Y menu**: Y is now read from the buttons the game receives (the direct
  read was always false); check a tap opens the menu.
- **Inspect with motion hands**: the C.A.T. stays in the glove; check
  inspect still behaves.
- **LT is Focus**: check what Focus does in the game.
- **Other headsets**: only Quest Touch has been played.

## Features

- **Terminals by finger**: press them with the index finger like the
  C.A.T.'s buttons, instead of pointing.
- **Physical interaction**: doors, pickups and switches by hand (roadmap
  in DESIGN.md).
