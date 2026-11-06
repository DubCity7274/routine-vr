# Routine VR

Room-scale, 6DoF VR for **ROUTINE** (Lunar Software, Unreal Engine 5.5), built on
[UEVR](https://github.com/praydog/UEVR). Quest 3/3S first, with other headsets
added as small layout files.

What it adds on top of plain UEVR:

| Feature | How |
|---|---|
| 6DoF head + room-scale walking | UEVR `RoomscaleMovement` with collision sweep (your real steps move the pawn, walls stop you) |
| Aim with your right hand | `AimMethod = Right Controller`, decoupled pitch, left-hand-relative movement |
| Physical crouch | Duck in real life and the game crouches. Stays in sync with the game's `bIsCrouched` when it can read it |
| Game menu | Tap Y (sends Start; Y no longer inspects, switchable in the panel) |
| Recenter | Hold B + Y for 3 s (works in menus), or the panel button: recenters the view, resets the standing origin, recalibrates your height |
| C.A.T. in your hand | The C.A.T. follows the right controller and moves to the left hand while you inspect it. Other parts can be attached in the panel |
| Cutscenes and menus | Pre-rendered cutscenes on a flat 2D screen, menus with plain aim; gameplay switches back automatically |
| Per-headset layouts | `devices/*.lua`: Quest Touch, Index, Pico, WMR, Vive wands |
| Comfort | Fisheye lens, film grain, sharpen, vignette, motion blur, DoF, chromatic aberration, and lens flares off (switchable in the panel; fisheye/grain/sharpen need the PPV pak mod) |
| Laser pointer | From the right hand while inspecting the C.A.T. (or always), so you can see what you're clicking |
| Terminals | Point with your right hand (the laser shows the exact line) and pull the trigger |

## What's in this repo

- `profile/Routine-Win64-Shipping/`: the UEVR profile (config and Lua
  scripts). This is the mod.
- `install-linux.sh` / `uninstall-linux.sh` and `install-windows.bat` /
  `uninstall-windows.bat`: copy the profile into UEVR's profile folder and
  take it out again. Installing merges into an existing UEVR `config.txt`
  and backs the original up; uninstalling puts it back. Your Routine VR
  settings are kept unless you ask to remove them.
- `tools/`: the scripts behind those, plus Linux setup helpers.
- `tests/run_tests.lua`: offline tests against a fake UEVR API.

Not included (get them from their authors):

- [UEVR](https://github.com/praydog/UEVR) (the nightly builds are used).
- KeinZantezuken's **PPV/SML** pak mod from Nexus Mods (optional, removes
  the fisheye, grain and sharpen effects; Routine VR drives its `rpp`
  console commands). Download its zip and pass it to the installer.

## Manual install (no installer)

Each release has a `routine-vr-<version>-profile.zip` with just the mod: a
`Routine-Win64-Shipping` folder (UEVR's profile for the game).

- **Windows:** extract it into `%APPDATA%\UnrealVRMod\`, so you end up with
  `%APPDATA%\UnrealVRMod\Routine-Win64-Shipping\config.txt` and `scripts\`.
- **Linux (Proton):** extract it into
  `<Steam library>/steamapps/compatdata/606160/pfx/drive_c/users/steamuser/AppData/Roaming/UnrealVRMod/`.

If you already have a UEVR profile for Routine, back up its `config.txt`
first: the zip's `config.txt` replaces it (the installers merge instead).
To remove a manual install, delete `scripts\routine_vr`,
`scripts\routine_vr.lua` and `user_script.txt` from that folder (and
restore your `config.txt` backup).

## Headsets and controllers

The controller layout is picked automatically from the headset name UEVR
logs at startup; you can choose one by hand in the panel's Controllers
section. Layouts: Meta Quest / Rift (Touch), Valve Index (also Bigscreen
Beyond, Varjo, Pimax), Pico, Windows Mixed Reality (Reverb and others), HTC
Vive wands (Vive Focus, XR Elite and Cosmos use the Touch layout).

With UEVR's default buttons (the default), UEVR maps every controller
itself, so buttons work on any of them. The layout covers the mod's own
reads (recenter chord, finger curl) and, on OpenVR only, a per-controller
aim pitch fix. Under OpenXR (the default) all controllers share the same
grip and aim poses, so the glove alignment carries over between them.

Only the Quest 3 has been tested so far. Controllers without B/Y recenter
with both stick/pad clicks held for 3 seconds instead of B + Y.

## Install on Windows

1. Install UEVR and its requirements (see the UEVR page).
2. Double-click `install-windows.bat`. To add the PPV pak mod as well, drag
   its zip onto `install-windows.bat` instead.
3. Start Routine, then inject with UEVR's injector as usual, using OpenXR.

To remove it, run `uninstall-windows.bat` (it also removes the PPV files).
To delete your Routine VR settings too, run
`powershell -ExecutionPolicy Bypass -File tools\windows\uninstall.ps1 -RemoveSettings`.

## Install on Linux (Steam, Proton, WiVRn)

Run on the host, not in a toolbox, from this folder:

```bash
./install-linux.sh --full
```

`--full` downloads the latest UEVR nightly (checksum-verified) to
`~/.local/share/routine-vr/uevr`, installs the .NET 6 Desktop Runtime into
Routine's prefix with protontricks (native or Flatpak), installs the profile,
and prints the launch options. Without `--full` it only installs the profile.
Add `--ppv path/to/PPV-....zip` to install the PPV pak mod too.

In Steam → Routine → Properties:

- **Compatibility:** force **Proton 11.0** (or Proton Experimental). Don't use
  Proton-Wineland: with a VR runtime present, its DXVK/vkd3d require
  `VK_WINE_openxr_device_extensions`, which its Wine won't offer on the GPU, so
  the game dies with "A D3D11-compatible GPU is required".
- **Launch Options:** what the installer prints, for example:

```
VR_OVERRIDE=/run/host/usr/lib64/xrizer/runtime PROTON_REMOTE_DEBUG_CMD="$HOME/.local/share/routine-vr/uevr/UEVRInjector.exe --attach=Routine-Win64-Shipping.exe" %command%
```

To remove it: `./uninstall-linux.sh` (add `--remove-settings` to delete your
Routine VR settings too), then clear the launch options.

Then:

1. Start WiVRn and connect the Quest.
2. Launch Routine from Steam. The UEVR injector opens with it and attaches by itself.
3. Leave the injector on **OpenXR** (UEVR → Proton's wineopenxr → WiVRn).
   `VR_OVERRIDE` is still needed so Proton's VR setup finds WiVRn through xrizer.
4. UEVR's own menu starts closed (the profile sets "Remember Menu State" with the menu closed). Click both sticks to open or close it.
   While it's open, it takes the sticks and buttons and the game gets nothing.
5. Load into the game and stand up straight for 3 seconds (height
   auto-calibrates). To recenter, hold B + Y for 3 seconds (both
   controllers buzz), or press **Recenter + recalibrate now** in the
   Routine VR panel.

Pre-rendered cutscenes play on a flat screen in front of you. That's normal
for UEVR: videos aren't rendered in 3D.

## Hands

The C.A.T. is attached to your right hand out of the box. Two things go on
the controller: the pawn's `CameraComponent`, which is where Routine points
and clicks from (and where the laser starts), and the C.A.T. itself, listed
as `C.A.T.`. To adjust the C.A.T., click both thumbsticks to open the UEVR
overlay. The **Routine VR** window opens beside UEVR's own window. In
**Hands (6DoF)**, expand `C.A.T.` and move the sliders. Leave
`CameraComponent` at zero unless the pointer feels off your hand.

The C.A.T. is only on your hand while you hold LT or inspect it, so letting
go of LT puts it away. Its inspect pose (left hand, side buttons toward you)
has its own sliders at the top of **Hands (6DoF)**.

**Touch:** with the C.A.T. out, a small dot marks your left fingertip.
Touch one of the C.A.T.'s side buttons to press it (the left controller
buzzes). No need to inspect. The dot's position has sliders in the
**Touch** section, which also counts presses and shows any error.

**Raising the C.A.T.:** hold LT, or hold the right grip. In the panel's
**C.A.T.** section the grip can be switched to press-to-toggle, **grip at
right hip** (reach to your hip and grip to draw it, like a holster; the
controller buzzes when your hand is there) or off.
Lean (needed in the tutorial) is on the **left grip** in gameplay, since
Routine has no use for LB; menus still get LB. The C.A.T.'s
precise-aim turn, which turned the view slowly while it was out, is
replaced by a steady turn (speed slider in the **C.A.T.** section).

Other parts can be attached the same way: **Rescan pawn**, then **R** or **L**
next to a component.

Attachments are saved by component name in
`<profile>/data/routine_vr.json` and re-applied after level loads.

UEVR's built-in **UObjectHook** tab does the same job with more knobs. Use it
if a part needs something the panel lacks.

## Default controls (Quest Touch, right-handed)

Buttons go through UEVR's own controller mapping; the mod adds a few
controls on top. Left-handed mode (panel, C.A.T. section) swaps the hands:
the C.A.T., aiming and grip-raise move to the left hand, touch and lean to
the right, and the left trigger becomes interact.

| Quest | Does |
|---|---|
| Right trigger | Interact / click (point with your right hand) |
| Right grip | Raise the C.A.T. (hold; toggle or hip-draw in the panel) |
| Left index finger | Press the C.A.T.'s side buttons by touching them |
| Left trigger | Focus (the game's D-pad up) |
| Left grip | Lean |
| Left X | Crouch |
| Right B | Interact |
| Tap Y | Game menu (Start) |
| Hold B + Y, 3 s | Recenter |
| Left stick click | Sprint |
| Left stick | Move toward where you look (raw stick in menus) |
| Right stick | Smooth turn (left/right only; look up and down with your head) |
| Both stick clicks | UEVR menu |

With motion hands on, the C.A.T. hangs on your hip when it's put away (so
it's out of the way when crawling); its position has sliders in the
Motion hands section.

## Terminals and aiming

Your right hand is the game's camera direction: interaction traces, the
crosshair's real target, and the flashlight all follow it, not your head.
To use a terminal, point your right controller at it (the laser shows the
exact line) and press the right trigger.

## Adding a headset

Copy `profile/Routine-Win64-Shipping/scripts/routine_vr/devices/quest_touch.lua`,
edit the `buttons`/`triggers` tables, add the id to `M.order` in
`devices/init.lua`, then run `tools/install-profile.sh`. See
[docs/DESIGN.md](docs/DESIGN.md).

## Resetting

Every UEVR setting and the mod's own settings live in the profile folder.
To start over, move that folder aside and reinstall:

```bash
P=~/.local/share/Steam/steamapps/compatdata/606160/pfx/drive_c/users/steamuser/AppData/Roaming/UnrealVRMod/Routine-Win64-Shipping
mkdir -p ~/.local/share/routine-vr/backups && mv "$P" ~/.local/share/routine-vr/backups/profile-$(date +%Y%m%d-%H%M%S)
./tools/install-profile.sh   # from this folder
```

Don't hold the right trigger while UEVR's menu is open. In UEVR that turns
the sticks into camera-offset controls. The mod puts the offsets back to 0
every half second, but it's still disorienting.

## Credits

- The community UEVR profile for Routine showed the `CameraComponent`
  attachment, the C.A.T. inspect swap, the cutscene detection, and the
  meshes to hide. Its libraries (`uevr_utils` and friends) credit markmon,
  Pande4360, Rusty Gere and lobotomy.
- KeinZantezuken's PPV/SML pak mod provides the `rpp` commands that switch
  off the fisheye, grain, and sharpen. The laser pointer uses the same
  capsule-component approach as the community profile's interaction laser
  (credited there as inspired by Gwizdek).

## Development

```bash
tools/install-profile.sh
```

copies the profile into the prefix. Keys in the repo's `config.txt` overwrite
the same keys in the installed one. Every other key UEVR wrote is kept, and
so is `data/` (your Routine VR settings and hand attachments).

Offline tests run the mod's Lua against a fake UEVR API:

```bash
lua tests/run_tests.lua
```

Any Lua 5.3+ works. On this machine:
`LD_LIBRARY_PATH=/run/host/usr/lib64 /run/host/usr/bin/luatex --luaonly tests/run_tests.lua`.

## Status

Written against UEVR nightly 01143's Lua API and Routine build 22236094.
The mod's logic passes the offline tests (94). First in-headset run, on
Proton 11 + OpenXR + WiVRn (Quest 3S): the game injects and loads in. That
run found the menu-stick rotation and stereo flicker fixed above. Second
run: Native Stereo is clean and buttons mostly work. Terminal cursors and
hand attachments are still unverified. See
[docs/DESIGN.md](docs/DESIGN.md#known-unknowns).

## License

MIT, see `LICENSE`. UEVR and the PPV/SML pak mod are separate projects under
their own terms and are not included.
