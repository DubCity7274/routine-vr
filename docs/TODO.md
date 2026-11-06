# To do

## Bugs

- **Black headset at startup** if any button is pressed before the main
  menu has loaded.
- **C.A.T. while crawling** floats in front of the player; in the game it's
  held in the hand (not in use) while crawling.
- **Windows installer** (`install-windows.bat`, `tools/windows/*.ps1`) has
  never been run. Needs a test on a Windows PC.
- **Custom button layout** (`custom_buttons`, off by default) probably
  doesn't work: it reads controller buttons inside the XInput callback,
  where UEVR's reads come back wrong. Rework it like the grips (read on
  the engine tick, or from the incoming XInput bits) or remove it.

## Check in the headset

- **ID on the chest after a new ID card.** The story swaps your ID at one
  point. The mod only unhides the game's own ID card, so it should update,
  but if the game spawns a second card the mod may keep showing the first.
  Look down after the swap; a C.A.T. recording plus Scan body will show
  what changed.
- **Other C.A.T. modules** (Nav, Sec and the ones not unlocked yet): try
  touch-pressing each as they unlock.
- **Hip holster standing** (only tried seated).
- **Inspect with motion hands**: the C.A.T. now stays in the right glove;
  check inspect still behaves.

## Features

- **Left-handed option**: swap the C.A.T. hand and the main (aiming) hand.
  Covers UEVR aim method (left controller), the camera/pointer hook, the
  C.A.T. on the left glove (the skeleton has `Bone_Palm_L_Tool`), touch
  with the right index finger, grips swapped, the thumb wrap mirrored, and
  the holster on the left hip.
- **A use for Y**: inspect is optional now that touch works.
- **A use for LT**: it no longer raises the C.A.T. Idea: Focus, which is on
  the D-pad (awkward on Touch controllers).
- **Terminals by finger**: press them with the right index finger like the
  C.A.T.'s buttons, instead of pointing the laser.
- **Physical interaction**: doors, pickups and switches by hand (roadmap
  in DESIGN.md).
