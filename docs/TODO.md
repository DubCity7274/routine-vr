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
- **D3D11 crash on the RHI thread** (`DXGI_ERROR_INVALID_CALL`,
  D3D11Query.cpp:366). Same stack on Nov 2, Nov 8 and twice on Nov 9, so it
  predates motion hands. Repeats as the fish cutscene starts (chapter 4,
  loading the ASN save); that scene passed once with Proton logging on.
  Not tied to UEVR's frame-sync warning: one crash had it, one didn't.
  Suspect: the switch to 2D screen mode as a video cutscene starts (see Check).
- **Windows and manual installs** don't get the `data/uevr_log.txt` link, so
  no headset auto-detect or frame-sync warning there yet.
- **Crash entering the living quarters** (chapter 4, after the terminal
  video): one-off, gone after reloading. Unreal's report is an access
  violation on a worker thread with only game code on the stack, and no
  symbols to name it. Watch for a repeat at the same spot.
- **Papers are tiny in your hand** when you pick one up to read. Not a
  blocker: pressing interact again shows the text on the HUD. Probably the
  game's first-person scaling of held items (the C.A.T. had the same kind
  of scale).
- **Black headset at startup** if a button was pressed before the main
  menu loaded. Not seen since 0.1.0-beta.1; may have been fixed by the
  input changes, or been a WiVRn/headset issue. Keep an eye out.

## Check

- **C.A.T. after the Ward wake-up**: zero size and the chest position are
  fixed (confirmed in the headset). It still looked off in the hand until a
  reload: the gloves copy the arm pose once when built, so built during the
  wake-up on the floor that pose stuck. They now rebuild once the game's
  arms settle into a different hold. Check it at that wake-up.
- **Cutscene mode is off by default** now (Comfort). With it off the fish
  cutscene got through; with it on it crashed twice, and it stuck on at a
  save projector. Keep an eye on whether cutscenes behave without it.

## Discord testers

- **Other headsets**: only Quest Touch has been played.
- **Windows installer** (`install-windows.bat`, `tools/windows/*.ps1`) has
  never been run.

## Features

- **Easier grabbing**: items can be hard to pick up because your hand has
  to point at them almost exactly. Make the hand's interaction area bigger
  or more forgiving.
- **Terminals by finger**: press them with the index finger like the
  C.A.T.'s buttons, instead of pointing.
- **Physical interaction**: doors, pickups and switches by hand (roadmap
  in DESIGN.md).
