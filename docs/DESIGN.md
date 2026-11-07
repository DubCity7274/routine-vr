# Design

## Layers

```
 headset runtime       WiVRn / Monado / SteamVR / Oculus
        |
 UEVR (OpenXR|OpenVR)  stereo rendering, 6DoF head, room-scale movement,
        |              aim method, snap turn, d-pad shifting, rumble
        |              -> one action set (/actions/default/in/*) for every runtime
        |
 routine_vr Lua        devices/*.lua   data-only controller layouts
                       input.lua       VR actions -> XInput gamepad state
                       roomscale.lua   height calibration, physical crouch, recenter
                       game.lua        Routine specifics: modes, C.A.T. inspect swap,
                                       hidden meshes, camera-offset guard
                       movement.lua    stick direction, snap turn, cursor mode
                       effects.lua     rpp commands (PPV pak) via PlayerController, vignette cvar
                       laser.lua       capsule laser on the right hand (inspect/always)
                       hands.lua       pawn components -> motion controllers (UObjectHook)
                       ui.lua          own ImGui window, shown while UEVR's menu is open
                                       (Script UI is behind Show Advanced Options)
                       settings.lua    JSON in <profile>/data/routine_vr.json
        |
 ROUTINE               sees an Xbox pad + a VR camera
```

UEVR already hides the runtime from us. Its action paths (`Trigger`, `Grip`,
`AButtonLeft`, `JoystickClick`, ...) are the same under OpenXR and OpenVR, so
"headset support" here means **controller layout**, not runtime code. A device
file is plain data:

```lua
return {
    name = "...",
    buttons  = { A = { "a_r" }, LB = { "grip_l" }, ... },  -- gamepad button -> physical inputs (OR)
    triggers = { LT = { "trigger_l" }, RT = { "trigger_r" } },
    uevr = { VR_ControllerPitchOffset = "-15.000000" },  -- UEVR settings for this hardware
    hand_offset = { rot = {0,0,0}, loc = {0,0,0} },      -- base offset for attached items
}
```

Physical input names are defined once in `devices/init.lua`. Controllers with
touchpads instead of face buttons use the `pad_<dir>_<hand>` inputs: a pad
click plus that pad's axis quadrant. Vive and WMR face buttons work this way.

## Who owns which part of the gamepad state

`input.lua` rebuilds face buttons, bumpers, stick clicks, and triggers from the
layout every poll. It leaves the thumbsticks, START, BACK, and d-pad as UEVR
produced them, because UEVR's snap turn, d-pad shifting, and menu combos act
on those fields. Two exceptions: L3+R3 together is never sent (it's UEVR's menu
toggle), and nothing is added while UEVR's overlay is open. With a real
gamepad and idle motion controllers, the state passes through untouched.

Other modules press buttons with `input.inject(name)` or hide physical inputs
with `input.suppress(name)`. Both last from one engine tick to the next, so a
game that polls XInput more than once per frame sees the same thing each time.

## Movement direction

UEVR's `MovementOrientation` rotates the left stick by the left controller
(or HMD) whenever it differs from `AimMethod`, in every context, menus
included. In a menu that makes "up" follow your hand's yaw. The profile ships
`MovementOrientation = Game`, and `movement.lua` sets the chosen direction
(`move_direction`: aim / left hand / head) through `set_mod_value` only in
gameplay. Gameplay means a local pawn exists and the player controller isn't
showing a mouse cursor. Otherwise it puts the raw stick back.

## Physical crouch

Measured as a head *drop* below the calibrated standing height, not as an
absolute height. This works in OpenVR standing space (y = height above floor)
and in OpenXR LOCAL space (y ≈ 0 at calibration). A hysteresis band stops it
flickering. Standing height follows you up if you stand taller than when you
calibrated.

Toggle-crouch games need care: a single tap per state change desyncs if the
player also presses crouch manually. So in toggle mode the module reads
`ACharacter::bIsCrouched`, taps only when the game's state differs from your
body's, and waits for the flag to react. If the flag never moves after a tap
(the game crouches some other way), it falls back to tapping on physical edges.

## 6DoF hands

Routine's component names aren't known ahead of time: they're in IoStore
assets, and nothing has been dumped from a live session yet. So `hands.lua`
lists the pawn's `SceneComponent`s (`K2_GetComponentsByClass`) and the UI lets
you assign them to hands at runtime. Assignments persist by FName and are
re-applied when the pawn's address changes, plus a full rescan every 5 s
(the C.A.T. may be spawned onto the pawn later). Offsets are UE rotators
(converted with `FRotator::Quaternion()`'s formula) plus centimetres.

Once good names and offsets are known for Routine, put them in
`settings.defaults.attachments` so new installs start with working hands.

## UEVR API quirks

- `uevr.params.vr.get_mod_value` throws (sol: "caught (...) exception") in
  the build in use (1.05+195). An uncaught throw aborts the whole
  `on_pre_engine_tick` callback, including every module after the
  thrower. Never call it. Write values blind (camera-offset guard) and
  restore known values (terminal mode restores AimMethod 2). The test
  fake throws too.
- UObjectHook motion-controller offsets are in UEVR's glm VR space
  (x right, y up, z backward), and the rotation is applied as
  `hand * inverse(offset)`. Passing Unreal axes made the first laser
  rotate about the vertical axis and stay upright. `hands.lua` converts
  (`rotator_to_offset_quat`, `location_to_offset`). Settings stay in
  Unreal terms.
- `imgui.collapsing_header` takes no flags, so sections can't default to
  open. The panel uses plain headings instead.

## Known unknowns

These need the first in-headset session:

- **Rendering method.** Settled: *Native Stereo*. *Synchronized Sequential*
  (skip draw) gave double vision with the eyes swapping on the first run.
- **A / trigger not selecting in the main menu** (first run). Action mapping
  and state reads are clean in the log. Suspects: UEVR's overlay was open
  (it swallows input), or the menu wants a cursor click. The panel's
  *Use Routine VR button layout* checkbox tells our layer apart from UEVR's.
- **Routine's gamepad bindings.** The pak's input config wasn't extracted.
  Defaults assume the usual Xbox layout. Set the crouch button and any remaps
  in the panel.
- **Component names** for the C.A.T., flashlight, and arms (see above).
- **Interactive screens.** The terminal cursor follows the camera, which
  with right-controller aim is the right hand. Once the C.A.T. is owned, RT
  raises it instead of clicking. Terminal mode sends RT as X (Interact),
  zeroes the right stick, and turns snap turn off. Whether X clicks
  terminals is unverified. The proper fix is a WidgetInteractionComponent
  on the hand (uevrlib's interaction.lua), see Toward native VR.
- **Recenter chord removed.** Holding both grips recentered, but in the
  tutorial holding right grip alone (Lean) kept recentering. The left grip
  probably registers light pressure from holding the controller.
  Recenter is now only the panel button.
- **Fisheye.** Zeroing `WeightedBlendables` weights on PostProcessVolumes
  and the camera found nothing in game. The effects probably come through a
  camera modifier. Now handled by the PPV/SML pak's `rpp fisheye|grain|sharpen 0`
  cheat commands (plus `rpp colorg 0.0`). Typed in the game console they
  work. Sent via `PlayerController:ConsoleCommand` from Lua they did not.
  Now sent via `KismetSystemLibrary.ExecuteConsoleCommand(pc, cmd, pc)`,
  with errors shown in the panel. UEVR's `execute_command` is
  `UEngine::Exec`, which doesn't reach cheat extensions.
- **Laser.** A `CapsuleComponent` added to the pawn with
  `uevr.api:add_component_by_class`, collision off, on the right hand via
  UObjectHook with pitch -90 so its Z axis runs along the controller.
  hands.lua now only detaches what it attached, so it leaves the laser alone.
  First in-game try: visible and pink, but upright (the axes bug above,
  now fixed). Second try: pointing right, but the interaction point sat
  about 30 cm off the hand, because the C.A.T. was placed by offsetting
  the CameraComponent (glm 3, -15, 30, from the community profile) and
  Routine traces from that camera. Layout 2 (settings.migrate): the camera
  sits on the controller with no offset, the C.A.T. actor's RootComponent
  is hooked on its own (like the community attachments lib), the laser
  copies the camera's placement so it draws the real ray, and inspect
  moves only the C.A.T. to the left hand. Third try: pointer and C.A.T.
  placement felt right, but the hook kept the C.A.T. raised all the time
  (terminals stopped working) and the inspect pose showed the screen, not
  the buttons. Now hands.set_active() hooks the C.A.T. only while LT > 40
  or inspecting, saving the root's RelativeLocation/Rotation before the
  hook and writing it back after; inspect uses settings.cat_inspect (left
  hand, yaw -90). Side buttons still didn't click. The panel's C.A.T.
  recorder (probe.lua) writes data/routine_vr_probe.json with the C.A.T.,
  pawn and controller properties and their changes over 40 s, to find out
  how the game drives raise/inspect/buttons before building on it.
  Result (2026-11-04): the side buttons did work all along; the laser was
  just drawn ~18 cm below Routine's real ray. Calibrated against a
  terminal: laser_forward -14.4, laser_up 18.3 (now the defaults). The
  game's centre dot shows the hit and grows an outer ring over anything
  interactable. Right stick up/down tilted that dot and the HUD away from
  the head, so it's zeroed in gameplay (lock_stick_pitch).

### What the recorder found (for touch interaction)

- C.A.T.: `Routine_CAT_C > RoutineGameCAT > RoutineGameEquipment`. Side
  buttons are `Routine_InteractComponent_C` (Interact_Pow, _Wifi, _Nav,
  _Amp, _Sec, _Deg), each under a `BoxComponent` collider (Box_PowCol,
  Box_WifiCol, ...) on the C.A.T.'s SkeletalMeshComponent. Also
  Box_InteractCATBlock / Box_InteractWorldBlock, a WidgetComponent and
  native POV/Mode/Deadzone/Render/Trace components; CATAimDegrees,
  InspectViewRotation, RelativeTransformCache.
- Pawn: `Routine_PlayerPawn_C > RoutineGamePlayerPawn > Character`;
  CameraComponent sits under a LeanComponent and carries a
  WidgetInteractionComponent and the player light.
- No bool flips on raise (LT) were seen in the polled number/bool props;
  raise shows only as pawn.TurnMult easing to 1.0.
- Touch plan: each frame, test the left controller's position against the
  Box_*Col extents (or overlap a small sphere on the left hand), and when
  inside, fire that Interact_* component's interact the same way the
  centre-dot click does. That needs the interact function name next
  (dump Routine_InteractComponent_C's functions with the recorder).
- Built (touch.lua): a 1 cm SphereComponent on the left hand as the
  fingertip (touch_forward/touch_up), tested every frame while the C.A.T.
  is out against each Box_*Col (oriented box from K2_GetComponentLocation/
  Rotation and GetScaledBoxExtent, grown by the fingertip radius).
  Entering a box buzzes the left controller and, once
  settings.touch_press_function is set, calls that function on the
  matching Interact_* component. The recorder now dumps the interact
  component's functions with parameters and watches each button's
  number/bool properties, to pick that function.
- Second recording: Routine_InteractComponent_C > RoutineGameInteractComponent
  > BillboardComponent. Its own API: bEnabled, bHiddenInteract, Distance,
  OnInteract / OnCanInteract (multicast delegates), SetEnabled, IsEnabled,
  Interact, CanInteract, HasInteractionChild, GetInteractionChild,
  GetInteractionDistance. Parameter lists came back empty (UFunction
  get_child_properties gave nothing), so press() calls Interact(pawn) and
  falls back to Interact(). Clicking Amp with the dot flipped its bEnabled
  false then true ~0.2 s later; touch skips disabled buttons and has a
  0.4 s cooldown. The left-hand buzz fired on every button, including the
  two module slots not unlocked yet.
- Third try: Interact() from a left-hand touch with LT held (not
  inspecting) did nothing: no error, no bEnabled flip. Likely Routine
  only accepts side-button input while inspecting. Inspect now keeps the
  C.A.T. in the right hand by default (cat_inspect, layout 2 migration) so
  the left hand can touch it there; the panel offers the old left-hand
  pose for pointing with the right hand. The recorder now logs presses
  and errors, writes a line whenever touch state changes, and keeps the
  previous recording as routine_vr_probe_prev.json.
- Fourth try: the recorder showed every press failing with "Invalid
  argument type for struct property", both with the pawn and with no
  arguments, so Interact() takes a struct (inspect wasn't the blocker;
  the LT attempt failed the same way unseen). press() now reads the
  UFunction's parameters (class:find_function, get_child_properties,
  property flags, get_struct), builds a StructObject per struct param
  with hit-result fields (ImpactPoint/Location = fingertip, Component =
  the button's box, Actor = pawn) and skips the return value. The panel
  and recorder show the real signature.
- Fifth try: signature is Interact(InteractAction: StructProperty), but
  FProperty:get_struct() gives nothing in this build (get_struct exists on
  StructObject values only), so no argument was built. touch.find_struct()
  now scans ScriptStruct objects for names containing "interact" and picks
  the shortest one containing the parameter name; its fields are listed
  in the signature, and object fields named like interactor/instigator/
  pawn/actor/player get the pawn, *component* fields the button.
- Working (2026-11-04): struct RoutineInteractAction. Touch presses work
  with the C.A.T. just raised (LT), no inspect needed; locked modules (Nav,
  Sec) don't respond. Inspect is back to the left hand (layout 3).
- Right grip raises the C.A.T. (cat_grip hold/toggle/off) by forcing LT in
  the XInput state after any mapping, and drops the grip's RB (lean).
- The C.A.T.'s aim deadzone turns the view while it's out (hand aim is
  rarely centred); its DeadzoneComponent's tick is switched off while
  raised (stop_cat_aim_turn). Untested; the recorder now dumps the
  DeadzoneComponent and POVComponent if it needs another approach.
- Lean is required by the tutorial. With the right grip raising the
  C.A.T., lean moves to the left grip in gameplay (lean_left_grip): LB is
  dropped and RB sent while the left grip is held. Routine doesn't use LB.
- Headset test: grip raised the C.A.T., but the right grip still leaned,
  the left grip didn't, and turning with the C.A.T. out stayed slow and
  ramping. Every XInput edit outside the custom layout sat behind
  vr.is_using_controllers() (also the likely reason the old terminal RT->X
  swap did nothing). The overrides (force LT, drop RB, left-grip lean,
  stick pitch, C.A.T. turn) now run regardless of that check, keyed on the
  VR grips actually held, and write state.Gamepad directly. The
  Controllers panel shows an input check (UEVR gate, RB from UEVR / sent,
  LT and stick X sent) and the recorder logs it.
- Next recording: the gate passed ("ready, using controllers"), LT 255
  and stick X 0 reached the game, but RB came in and went out on while
  the right grip held the C.A.T. up. vr.is_action_active reads false
  inside on_xinput_get_state, so the grips are read on the engine tick
  (game.update_grip -> input.right_grip/left_grip) and the callback uses
  those. The custom button layout (custom_buttons) reads is_held inside
  the callback too, so it's probably broken the same way; it's off by
  default.
- Slow turn with the C.A.T. out is Routine's precise-aim turn, not the
  DeadzoneComponent tick (switching that off changed nothing; removed).
  While raised the stick X is zeroed for the game and the mod turns with
  PlayerController:AddYawInput at cat_turn_speed (120 deg/s default).
  In game that didn't turn at all (Routine likely ignores look input while
  aiming). The turn now checks itself: after 20 deg asked for, if the
  pawn turned (in the stick's direction) less than 30% of it, it moves on:
  AddYawInput -> SetControlRotation -> "game" (stick handed back to
  Routine's slow aim turn). The method in use shows in the C.A.T. panel
  and the recorder.
  Next recording: add_yaw and set_rotation were both judged failed within
  ~3 s and it fell back to the game, whose aim mode only rotates within
  the aim box and then stops. Now: add_yaw first calls
  ResetIgnoreLookInput (Routine likely ignores look input while aiming),
  the check measures the camera manager's view yaw rather than the pawn
  (which may not follow while aiming), and a third method rotates the
  pawn's RootComponent like the community profile.
- Lean still not removed: recorder showed RB in and out both on with the
  grip raising the C.A.T. The stick-X block does reach the game (it
  stopped turning entirely), so XInput edits work in general. Recorder
  now logs the tick-read right grip, the clear flag and wButtons
  in / after clear / out to find which step fails.
  Result: wButtons 512 -> cleared to 0 -> 512 out. The clear worked; the
  left-grip lean step put RB back, because is_action_active for the left
  grip read true while only the right grip was held (and false while the
  left was). Grips are now taken from UEVR's own mapping in the incoming
  state (LB = left grip, RB = right grip).
- Turning: add_yaw (with ResetIgnoreLookInput), set_rotation and
  rotate_body all failed against the camera manager's view yaw. New first
  method "vr_view" turns UEVR's rotation offset (vr.get/set_rotation_offset,
  the recenter yaw) by a glm yaw quaternion, outside the game entirely;
  trusted unless it errors. cat_turn_reverse flips it if the sign is off.
  Headset: turning works, but the character keeps facing the old way, so
  after a C.A.T.-out 180 forward reads as backward (sprint only works
  backwards). The view turn (game.view_turn) is now handed to the
  character when the C.A.T. is lowered: SetControlRotation by the amount
  and the offset turned back in the same frame; 3 frames later the game's
  actual turn is measured and any shortfall put back on the view. If the
  game ignored it, the next handover tries AddYawInput, and no retry
  happens until the C.A.T. is raised again (no flicker). Recentering
  clears view_turn.
  Headset: every handover measured 0 deg for both SetControlRotation and
  AddYawInput, even with the C.A.T. lowered. Routine's pawn has native
  ViewComponent/ControlComponent; only the right stick turns it. The
  handover now pushes the right stick for the player (input.inject_rx)
  and turns the VR offset back by what the game turned each frame, so the
  world holds still. Which yaw follows the game (camera manager, control
  rotation, actor) is picked from the first 8 frames by most movement; a
  reversed response flips the push. The recorder logs all three yaws.
  Headset: the handover turned the character ~150 deg (actor yaw follows;
  camera and control readings didn't read at all), then hung with 5 deg
  left: the push had eased to ~25%, inside Routine's stick deadzone, and
  inject_rx stayed set forever, overriding the player's stick (no turning
  after; strafing also broke, likely the same cause). Now: push never
  below 45%, done (and start) at 5 deg, stop if the reading stalls for 20
  frames, and the player's own stick (>30%) ends it at once.
  Headset: works (after a short wait, forward and sprint are right), but
  the view jittered during the catch-up, the catch-up runs at the game's
  stick turn speed, and sprint doesn't work while the C.A.T. is out. The
  correction now happens in on_early_calculate_stereo_view_offset (eye 0)
  using actor yaw from the first frame, so it lands in the same frame the
  game turned. Speed and C.A.T.-out sprint need the body turned
  instantly: the recorder now dumps the pawn's native ViewComponent and
  ControlComponent (properties incl. rotators/vectors, and functions) to
  find a facing value to write directly. If none, another way of turning
  the camera is needed.
  Found: RoutineGameViewComponent has GetViewRotation / SetViewRotation /
  AddViewRotation (plus Add/RemoveViewExpanse, likely the C.A.T. aim box,
  and view target locks); RoutineGameControlComponent only manages input
  interfaces. Turning order is now view_rotation (Get/SetViewRotation,
  checked against actor yaw) -> vr_view -> game, and every handover first
  tries SetViewRotation by the whole amount (the stereo-view correction
  absorbs the jump in the same frame), with the stick push as backup.
  The add_yaw / set_rotation / rotate_body methods were removed.
- Occasional small snaps on lowering: some handovers had picked the
  camera manager reading, which reads only sometimes and follows hand aim.
  Only actor yaw is used now.
- B + Y still did nothing: right B may arrive as X under UEVR's mapping;
  the chord now accepts Y with B or X, and the recorder logs the raw
  incoming buttons and recenter progress.
- Headset (2026-11-05): view_rotation confirmed. Turning and sprinting
  with the C.A.T. out and lowering it are seamless, no jitter or snap.
  B + Y: in ~370 samples no face button (A/B/X/Y) ever appeared in the
  incoming XInput state, only RB and stick clicks. The chord now also
  accepts UEVR's direct reads of b_r and b_l, runs before the headset
  check, and the recorder logs both sources. Confirmed working in the
  menu and in game: the direct reads are what catch it.
- Hold B + Y did nothing in the main menu: it used per-hand VR action
  reads like the grips. It now reads B/Y from the buttons UEVR sends
  (input.xi_in, captured before any mapping).
- Known bug for later: input before the main menu loads can leave the
  headset black.
- Hold B + Y for recenter_hold (3 s) recenters, in menus too, since the
  main menu often starts behind the player.
- Hip holster (hip.lua, cat_grip = "hip"): the holster centre is placed
  from the HMD pose each frame (hip_drop below, hip_side right, hip_back
  behind, along head yaw only) in UEVR tracking space; the grip must close
  within hip_radius of it, then the C.A.T. stays out while held. A light
  buzz marks entering the holster. Assumes tracking space faces -z with x
  right (as UObjectHook offsets do); the sliders cover it if not.
- Motion hands (next): Routine has no first-person hands, and the
  community profile ships uevrlib's hands toolkit but no hands config for
  Routine. Hands would have to come from the character's body mesh
  (CharacterMesh0 and its skeletal children, which the mod hides today):
  a copy posed to the controllers, everything but the hands/forearms
  hidden, as uevrlib's hands.createFromConfig does. Touch would then move
  from the fingertip dot to the real index finger.
  Step 1 (body.lua): panel "Scan body" writes data/routine_vr_body.json
  (each skeletal mesh on the pawn: parent, socket, asset, anim instance,
  visibility/owner-no-see flags, all bone names); "Show body" unhides
  them (and owner-no-see off) to look at in the headset.
  Scan result: CharacterMesh0 (RoutineGameTriMeshComponent,
  SK_Player_Default, anim Routine_PlayerAnimBlueprint_C) with two
  skeletal children: SK_Player_Default_Body and SK_Player_Default_Arms
  (anim Routine_PlayerAnimBlueprint_Arms_C). All share one 82-bone
  skeleton: Bone_Arm_L/R_{Collarbone, Upperarm_01/02, Forearm_01-03,
  Palm, Thumb_01-03, Finger_A-D_01-03}, Bone_Palm_L/R_Tool/Strap, legs,
  spine, Bone_Camera, sockets. Shown in the headset: a full spacesuit;
  the right arm stretches toward the C.A.T. we moved to the hand.
- Motion hands v1 (motion_hands.lua): a PoseableMeshComponent on the pawn
  given the arms asset (SetSkinnedAssetAndUpdate) and its materials,
  CopyPoseFromSkeletalComponent once for natural fingers, Bone_Pelvis
  scaled to 0.001 in component space (collapses the whole body), then
  each frame both palms set in world space to SceneComponent markers
  hooked on the controllers plus per-hand offsets (hand_right/hand_left).
  A palm set in world space gets the local scale that undoes the
  collapse, so only the hands and fingers show. Touch uses the left
  Finger_A_03 bone position when hands are shown. Next: finger curl from
  grip/trigger, hands holding the C.A.T. properly.
  First headset try: only two hair-thin lines from the head to the
  controllers. SetBoneLocation/RotationByName keep the bone's existing
  (collapsed) scale, so the hands were tiny and only wrist triangles
  stretched to the collapse point showed. Now each palm also gets
  SetBoneScaleByName(1, component space), and Forearm_01-03 are placed
  rigidly behind the palm using their palm-relative transforms read from
  the copied game pose (parents before the palm).
  Second try: gloves and sleeves at the controllers, lined up by the user
  (right rot 0.5/2.1/157.3 loc -3/3/0.9, left rot 0.5/-2.1/21.1 loc
  -6.2/-3/0.9, now the defaults; the left palm mirrors with 180 - roll,
  which the mirror button now uses). Left-finger touch pressed C.A.T.
  buttons. The upper arm still stretched back to the collapsed body when
  the hands moved out: Collarbone and Upperarm_01/02 are now placed at the
  elbow (Forearm_01's spot) at 0.001 scale, so the sleeve ends there.
  Third try: looks right; sleeves now end at the elbow. The user's goal:
  arms attached to a visible body (the ID on the chest is needed in the
  story). Order chosen: fingers + C.A.T. grip first, since both are
  palm-relative and survive the arm/body IK unchanged.
- Fingers: each frame every finger bone (Thumb, Finger_A-D, 01-03) is
  placed from its palm-down chain using the game's live arms animation
  (GetSocketTransform(bone, RTS_ParentBoneSpace) on the hidden arms mesh,
  kept ticking with VisibilityBasedAnimTickOption = 0; fallback: the copied
  pose), times a curl about finger_axis (panel: axis X/Y/Z, per-hand flip,
  curl preview). Curl: index = trigger (analog, before force_lt), B-D =
  grip (LB/RB from UEVR), thumb = thumbrest/A/B direct reads. While the
  C.A.T. is in the right glove that hand uses the game pose only.
- C.A.T. in the glove: while raised with hands on, game.cat_on_glove stops
  the controller hook (hands.lua restores its relative transform), then the
  C.A.T. root is attached to the poseable at its original AttachSocketName
  with KeepRelative, so it sits in the glove as the game places it; put
  away, it goes back to the game's arms mesh. Home compared by address.
  Headset: curl direction right with the default axis Z, no flips. But
  the game's live pose curled both hands when the right grip raised the
  C.A.T. and differed per hand, and the right thumb sank into the C.A.T.
  Now finger rest poses come from the mesh's reference pose (read before
  CopyPoseFromSkeletalComponent; symmetric), the game's live pose is used
  only for the right hand's fingers A-D while the C.A.T. is in the glove,
  and the thumb always uses the reference pose plus thumb input.
- Next headset check: left relaxed pose perfect, right still pre-curled:
  the arms mesh's reference pose has the right hand modelled around the
  C.A.T. Right finger rest rotations now copy the left's (offsets kept;
  right_rest_from_left), which works because the skeleton mirrors local
  axes. The right grip curled both hands because of a Lua "a and b or c"
  with b false in curl_targets: the left hand read the right grip.
  Copying rotations straight across was wrong (fingers bunched, thumb
  folded in, right grip bent downward): the right side's frames aren't
  plain mirrors. Now the left hand's reference transforms are mirrored in
  component space: reflect across the plane with normal = left->right
  Upperarm_01 (mirror_q = M R M), then times C = inv(mirror(L upperarm))
  * R upperarm, the skeleton's right-side frame correction; right finger
  locals are taken from those mirrored transforms. Confirmed: both hands relax
  and curl alike. Holding the C.A.T. the right thumb pointed out at the
  screen; it now takes the mesh's modelled right thumb (kept before the
  mirror, since the mesh poses the right hand around the C.A.T.) plus
  thumb_wrap from the panel. The wrap only bends the joints ("up and
  down"); thumb_swing_1/2 rotate Thumb_01 about the two non-bend axes
  (x60 deg) to move it out and around the grip. Tuned in the headset: wrap
  -0.31, swing 0.67 / 0.48 (now the defaults).
- Body, step 1 (show_body): hide_clutter leaves the pawn.Mesh child whose
  asset is SK_Player_Default_Body visible (owner-no-see off) with
  HideBoneByName("Bone_Neck") so the head/neck don't block the view;
  the arms child stays hidden (the gloves replace it), the helmet stays
  hidden, and the ID card is shown again (the story has you look at it).
  Headset: "basically perfect off the bat"; the chest ID is visible.
- Arms, step 2 (arm_ik): two-bone IK per side. Shoulder = the body mesh's
  Bone_Arm_X_Upperarm_01 world position; wrist = the palm at the
  controller; l1/l2 = game-pose distances Upperarm_01->Forearm_01 and
  Forearm_01->Palm; pole = down + 0.5 outward (pawn right vector) - 0.3
  forward. Upper arm = game-pose shoulder->elbow direction swung onto the
  solved one (shortest arc) times its game-pose rotation (mesh rotation
  included); Upperarm_02 follows in its frame. Forearm = rigid-to-palm
  rotation (keeps hand twist) swung to run elbow->wrist; Forearm_02/03
  follow. Collarbone is shrunk at the shoulder (the body draws it).
  Errors fall back to the floating forearm (shown in the panel).
  Headset: tracks well and lines up, but (1) past the model's reach the
  wrist stretched endlessly, (2) the shoulder/elbow wrung inside out when
  the arm rotated, (3) the shoulder opening showed. Now: the arm lengthens
  up to 1.5x to reach (bone offsets scaled); the upper arm starts from the
  body's live Upperarm_01 rotation (GetSocketTransform world) swung onto
  the solved line; the forearm hinges on the upper arm (game-pose
  relative) and is swung to the wrist, with the hand's twist about the
  forearm axis spread 1/3, 2/3 over Forearm_02/03; the Collarbone takes
  the body's live collarbone transform at full scale. Confirmed in the headset:
  arms, shoulders and body join and track, joints flex without breaking.
- LT no longer raises the C.A.T. by default (lt_raises_cat): game.raised
  ignores it and input.lua zeroes LT for the game unless forced by grip.
- To do: while crawling the C.A.T. shows in front of the player; in game
  it's held in the hand (not in use) while crawling.
- **Head bob / camera animation.** If the game's camera shake fights the HMD,
  find the camera-shake cvar or component in UEVR's console/UObjectHook and add
  it to `user_script.txt`.

## Toward native VR

The community profile sits on uevrlib (`uevr_utils`, `hands`, `animation`,
`attachments`, `reticule`, `interaction`). The parts worth taking, in order:

1. **Reticule / interaction laser.** Project the game's
   `RUI_Player_Crosshair` widget where the right hand points (uevrlib's
   `reticule.lua`), so you can see what you'll interact with. This also
   makes terminals work by pointing instead of cursor mode.
2. **Motion hands.** Replace "attach the camera component" with real hand
   meshes: uevrlib's `hands.lua` spawns poseable copies of the first-person
   arms, driven by the controllers, with finger poses from
   grip/trigger/thumb touch (`animation.lua`, `hands_config.lua`). That
   needs Routine's arm skeletal mesh and bone names, read with uevrlib's
   dev tools (`uevr_dev.lua`) in a live session.
3. **Physical interaction.** Doors, buttons, and terminal screens as
   things you touch, through `interaction.lua`'s mesh and widget hit
   testing.

uevrlib is the basis here, not a dependency to copy wholesale. Its modules
are large and generic, so port the pieces with tests, the way game.lua and
effects.lua were.

## UEVR quirk: require only works while the script loads

UEVR only finds the mod's files during the script's first run; a
require from a callback fails ("module not found", searching the game's
Binaries folder). A late require("routine_vr.version") in ui.draw blanked
the whole panel in 0.1.0-beta.1, and the controller layouts were loaded
on demand too (auto-detect or a manual pick would silently fall back to
Touch). Everything is now required at load, devices/init.lua preloads
every layout, and the tests make any later require of a routine_vr module
fail.

## Headset support and releases (beta prep)

- devices.read_system_name() reads UEVR's log.txt (via io under %APPDATA%,
  falling back to fs.read("../log.txt")) for "OpenXR system Name: ...";
  devices.from_system_name() maps it to a layout (PATTERNS, first match).
  settings.device = "auto" (default; old saved "quest_touch" migrates);
  input.tick_detect() retries every 2 s for a minute because UEVR starts
  OpenXR after the scripts load.
- VR_ControllerPitchOffset from a layout is applied only under OpenVR;
  OpenXR's grip/aim poses are uniform across controllers, so it's 0 there
  and the glove alignment carries over. Layouts can carry a glove
  adjustment (zero today) for future per-controller calibrations.
- Layouts without B/Y list recenter chords (Vive, WMR: both stick/pad
  clicks).
- version.lua holds the version (panel title, release names).
  tools/make-release.sh builds dist/routine-vr-<v>.zip (git archive of
  HEAD) and dist/routine-vr-<v>-profile.zip (just the profile folder).

## Late-game save findings

- The C.A.T. screen renders in both eyes early in the game but only the
  left eye in the end-game save (Native Stereo). Synchronized Sequential
  shows it in both eyes but breaks the mod's hands (stuck at the crotch)
  and shows the helmet, so it isn't an option. Next to try: UEVR's
  VR_NativeStereoFix: confirmed, it puts the screen in both eyes; now on
  in the profile's config.txt (with Same Pass).
- A helmet showed in the hand again in that save: hide_camera_children()
  now hides every visible child of the CameraComponent except lights and
  the WidgetInteraction, every check.
- Y opens the game's menu (y_opens_menu): Y is kept from the game and a
  tap (< 0.4 s, B not held) sends Start for 0.12 s; the B + Y recenter
  chord and long holds send nothing. Read with is_held on the tick.

## Cleanup, left-handed mode, Focus, hip holster

- Removed the custom button layout (custom_buttons, remaps) and terminal
  mode (it depended on the layout's RT->X swap). UEVR's mapping passes
  through; injected buttons (physical crouch) are now OR'd in
  apply_overrides.
- handed.lua: settings.handedness. Left-handed: AimMethod 3, the camera
  and C.A.T. hooks on the left hand (overrides), inspect mirrored to the
  right hand, the left grip (LB bit) raises the C.A.T., the right grip is
  lean natively, touch/fingertip on the right hand, triggers swapped (left
  index = RT), hip holster on the left, the C.A.T. on the left glove at
  the game socket with _R_ -> _L_ (the left hand closes its fingers since
  the game only animates a right-hand grip).
- lt_focus: the off-hand trigger sends D-pad up (Focus) when it isn't
  raising the C.A.T.
- C.A.T. place state (motion_hands): glove while raised, holster (snapped
  to the body's Bone_Pelvis plus cat_holster_<hand> offset) while put away
  with motion hands on, else home. Each move first restores the C.A.T.'s
  original relative offset (saved with its home), so offsets don't leak.

## Body follows the head

The character only turned with the stick, so physically turning left the
body, shoulders and hip holster facing the old way. game.head_yaw() is the
head's yaw relative to the character: the HMD pose times UEVR's rotation
offset (the same composition turn_view relies on), forward = -z. Past
body_follow_deadzone the character turns toward the head via the view
component (capped at body_follow_speed), and on_stereo_view turns the VR
offset back by the character's measured yaw change in the same frame, so
the view holds still. Off while the right stick is in use and during a
C.A.T. handover. Confirmed in the headset: the new ID card shows on the
chest; standing, the holster felt right at 0.27 m (now the default).


## Thumbs, and the left-hand reads

- UEVR has no thumbstick-touch action. Binding stick touch onto the
  thumbrest-touch actions (via `_interaction_profiles_*.json` overrides)
  worked but turned on UEVR's D-pad shifting (right thumbrest + left stick
  = D-pad), so the left stick stopped moving you. Removed; the installer
  deletes those files. A thumb now counts as down when its stick is pushed,
  or on the thumbrest or a face button (touch or press).
- Every left-hand action read was the right controller's: input.lua's
  `source()` used `hand == "left" and left() or right()`, and under OpenXR
  UEVR numbers the left hand 0, which reaches Lua as nil, so it fell
  through to the right source. Fixed (also in the touch and hip haptics).
  Hand-specific actions are read from both sides, each in its own pcall;
  errors and the source handles show under Advanced -> Input check.
