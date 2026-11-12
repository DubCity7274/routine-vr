-- Offline tests: runs the mod's Lua against a fake UEVR API.
-- Usage (any Lua 5.3+):  lua tests/run_tests.lua   (from the repo root)

local root = arg[0]:match("(.*)/tests/") or "."
package.path = root .. "/profile/Routine-Win64-Shipping/scripts/?.lua;"
    .. root .. "/profile/Routine-Win64-Shipping/scripts/?/init.lua;" .. package.path

---------------------------------------------------------------------------
-- Fake UEVR environment
---------------------------------------------------------------------------

XINPUT_GAMEPAD_DPAD_UP = 0x0001
XINPUT_GAMEPAD_DPAD_DOWN = 0x0002
XINPUT_GAMEPAD_DPAD_LEFT = 0x0004
XINPUT_GAMEPAD_DPAD_RIGHT = 0x0008
XINPUT_GAMEPAD_START = 0x0010
XINPUT_GAMEPAD_BACK = 0x0020
XINPUT_GAMEPAD_LEFT_THUMB = 0x0040
XINPUT_GAMEPAD_RIGHT_THUMB = 0x0080
XINPUT_GAMEPAD_LEFT_SHOULDER = 0x0100
XINPUT_GAMEPAD_RIGHT_SHOULDER = 0x0200
XINPUT_GAMEPAD_A = 0x1000
XINPUT_GAMEPAD_B = 0x2000
XINPUT_GAMEPAD_X = 0x4000
XINPUT_GAMEPAD_Y = 0x8000

local function struct(fields)
    return { new = function() local t = {} for k, v in pairs(fields) do t[k] = v end return t end }
end
UEVR_Vector2f = struct { x = 0, y = 0 }
UEVR_Vector3f = struct { x = 0, y = 0, z = 0 }
UEVR_Quaternionf = struct { w = 1, x = 0, y = 0, z = 0 }

local fake = {
    held = {},              -- [path .. "|" .. hand] = true
    axis = { left = { 0, 0 }, right = { 0, 0 } },
    head_y = 1.70,
    using_controllers = true,
    drawing_ui = false,
    recentered = 0,
    standing_origin = nil,
    mod_values = { VR_AimMethod = "2" },
    pawn = nil,
    mc_states = {},
    commands = {},
    objects = {},
    object_lists = {},
}

local SRC = { left = 11, right = 22 }
local function hand_of(src) return src == SRC.left and "left" or "right" end

local vr = {
    is_runtime_ready = function() return true end,
    is_hmd_active = function() return true end,
    is_using_controllers = function() return fake.using_controllers end,
    get_hmd_index = function() return 0 end,
    get_pose = function(i, pos, rot)
        local p = fake.poses and fake.poses[i]
        if p then
            pos.x, pos.y, pos.z = p.pos[1], p.pos[2], p.pos[3]
            if rot then rot.w, rot.x, rot.y, rot.z = p.rot[1], p.rot[2], p.rot[3], p.rot[4] end
        else
            pos.x, pos.y, pos.z = 0, fake.head_y, 0
            if rot then rot.w, rot.x, rot.y, rot.z = 1, 0, 0, 0 end
        end
    end,
    get_right_controller_index = function() return 2 end,
    get_left_joystick_source = function() return SRC.left end,
    get_right_joystick_source = function() return SRC.right end,
    get_action_handle = function(path) return path end,
    is_action_active = function(h, src) return fake.held[h .. "|" .. hand_of(src)] == true end,
    get_joystick_axis = function(src, out)
        local a = fake.axis[hand_of(src)]
        out.x, out.y = a[1], a[2]
    end,
    trigger_haptic_vibration = function() end,
    recenter_view = function() fake.recentered = fake.recentered + 1 end,
    set_standing_origin = function(v) fake.standing_origin = { v.x, v.y, v.z } end,
    set_mod_value = function(k, v) fake.mod_values[k] = v end,
    -- Throws in the real UEVR build in use (sol "caught (...) exception").
    get_mod_value = function(k) error("get_mod_value is broken in this UEVR build") end,
}

local callbacks = {}
uevr = {
    params = { vr = vr, functions = { is_drawing_ui = function() return fake.drawing_ui end } },
    api = {
        get_local_pawn = function(self, i) return fake.pawn end,
        get_player_controller = function(self, i) return fake.pc end,
        find_uobject = function(self, name)
            local o = { name = name }
            if name == "Class /Script/Engine.KismetSystemLibrary" then
                o.get_class_default_object = function() return fake.kismet end
            end
            return o
        end,
        execute_command = function(self, cmd) fake.commands[#fake.commands + 1] = cmd end,
    },
    sdk = { callbacks = setmetatable({}, { __index = function(_, name)
        return function(fn) callbacks[name] = fn end
    end }) },
}

UEVR_UObjectHook = {
    activate = function() end,
    get_or_add_motion_controller_state = function(obj)
        local st = fake.mc_states[obj] or {}
        fake.mc_states[obj] = st
        return {
            set_hand = function(_, h) st.hand = h end,
            set_rotation_offset = function(_, q) st.rot = q end,
            set_location_offset = function(_, v) st.loc = v end,
            set_permanent = function(_, p) st.permanent = p end,
        }
    end,
    remove_motion_controller_state = function(obj) fake.mc_states[obj] = nil end,
    get_first_object_by_class = function(cls, _) return fake.objects[cls.name] end,
    get_objects_by_class = function(cls, _) return fake.object_lists[cls.name] or {} end,
    set_disabled = function(v) fake.uobjecthook_disabled = v end,
}

local saved_json = {}
json = {
    load_file = function(name) return saved_json[name] end,
    dump_file = function(name, t) saved_json[name] = t end,
}

imgui = setmetatable({}, { __index = function(_, name)
    return function(label, value) return false, value end
end })

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local P = "/actions/default/in/"
local function hold(action, hand, on) fake.held[P .. action .. "|" .. hand] = on or nil end
local function release_all() fake.held = {} fake.axis = { left = { 0, 0 }, right = { 0, 0 } } end

local function poll(start_bits)
    local state = { Gamepad = { wButtons = start_bits or 0, bLeftTrigger = 0, bRightTrigger = 0,
                                sThumbLX = 0, sThumbLY = 0, sThumbRX = 0, sThumbRY = 0 } }
    callbacks.on_xinput_get_state(0, 0, state)
    return state.Gamepad
end

local function tick(seconds, step)
    step = step or (1 / 72)
    local t = 0
    while t < seconds do
        callbacks.on_pre_engine_tick(nil, step)
        t = t + step
    end
end

local function has(gp, bit) return gp.wButtons & bit ~= 0 end

local failures, passes = 0, 0
local function check(cond, msg)
    if cond then passes = passes + 1 else failures = failures + 1 print("FAIL: " .. msg) end
end

---------------------------------------------------------------------------
-- Load the mod
---------------------------------------------------------------------------

local real_print = print
print = function() end
dofile(root .. "/profile/Routine-Win64-Shipping/scripts/routine_vr.lua")

-- Like UEVR: the mod's own modules can only be required while the script
-- is first loading. A require of one not loaded by now fails (in the game
-- it broke the whole panel).
local real_require = require
require = function(name)
    if type(name) == "string" and name:find("^routine_vr") and package.loaded[name] == nil then
        error("module '" .. name .. "' not found (required after load; UEVR can't find it then)")
    end
    return real_require(name)
end
print = real_print

local settings = require("routine_vr.settings")
local input = require("routine_vr.input")
local roomscale = require("routine_vr.roomscale")
local movement = require("routine_vr.movement")
local hands = require("routine_vr.hands")

for _, name in ipairs { "on_pre_engine_tick", "on_xinput_get_state", "on_frame", "on_script_reset" } do
    check(callbacks[name] ~= nil, "registered " .. name)
end
check(fake.mod_values.VR_ControllerPitchOffset == "0.000000", "quest layout pushes its UEVR overrides")

local d = settings.defaults
check(d.snap_turn == false and d.move_direction == "head" and d.physical_crouch == true,
    "defaults: smooth turn, head movement, physical crouch on")

check(d.lt_raises_cat == false and d.cat_grip == "hip", "defaults: the C.A.T. is drawn from the hip with the grip, LT doesn't raise it")
check(d.crouch_button == "B" and d.crouch_drop == 0.25 and d.remove_sharpen == false and d.laser == "off",
    "defaults: crouch on B (UEVR sends left X as B), 25 cm duck, the game's sharpen kept, laser off")
check(d.device == "auto", "defaults: controller layout auto-detected")

-- The behaviour tests below exercise the non-default options.
settings.data.lt_raises_cat = true -- many tests raise the C.A.T. with LT (off by default)
settings.data.cat_grip = "off"   -- layout tests expect the grips as LB/RB; grip-raise and
settings.data.lean_button = "off"     -- lean has its own tests
settings.data.y_opens_menu = false   -- the layout tests expect Y to reach the game
settings.data.move_direction = "left_hand"
settings.data.snap_turn = true
settings.data.physical_crouch = true
settings.data.cutscene_mode = true    -- the mode tests exercise it (off by default)
settings.data.crouch_button = "B"   -- the crouch tests watch B
settings.data.remove_sharpen = true -- the effects test checks all three rpp commands
settings.data.laser_length = 100.0  -- the laser tests measure a 1 m beam

---------------------------------------------------------------------------
-- UEVR's own button mapping passes through (only the mod's edits change it)
---------------------------------------------------------------------------

tick(0.1)
release_all()
local gp = poll(XINPUT_GAMEPAD_A | XINPUT_GAMEPAD_START | XINPUT_GAMEPAD_RIGHT_SHOULDER)
check(gp.wButtons == XINPUT_GAMEPAD_A | XINPUT_GAMEPAD_START | XINPUT_GAMEPAD_RIGHT_SHOULDER,
    "UEVR's mapping reaches the game untouched")
input.inject("B")
gp = poll(0)
check(has(gp, XINPUT_GAMEPAD_B), "a button pressed by the mod for a frame (inject) reaches the game")
input.begin_frame()

---------------------------------------------------------------------------
-- Movement orientation: raw stick in menus, chosen direction in gameplay
---------------------------------------------------------------------------

release_all()
fake.pawn, fake.pc = nil, nil
tick(0.6)
check(fake.mod_values.VR_MovementOrientation == "0", "no pawn (main menu): raw stick")

fake.pawn = { get_address = function() return 0x900 end, K2_GetComponentsByClass = function() return {} end }
fake.pc = { bShowMouseCursor = false }
tick(0.6)
check(fake.mod_values.VR_MovementOrientation == "3", "gameplay: stick follows left hand")

fake.pc.bShowMouseCursor = true
tick(0.6)
check(fake.mod_values.VR_MovementOrientation == "0", "cursor shown (terminal/pause): raw stick")

fake.pc.bShowMouseCursor = false
settings.data.move_direction = "head"
tick(0.6)
check(fake.mod_values.VR_MovementOrientation == "1", "head direction choice applied in gameplay")
settings.data.move_direction = "left_hand"
fake.pawn, fake.pc = nil, nil
tick(0.6)

---------------------------------------------------------------------------
-- Snap turn: off in menus, on in gameplay when the setting is on
---------------------------------------------------------------------------

release_all()
check(fake.mod_values.VR_SnapTurn == "false", "no pawn (menu): snap turn off")

fake.pawn = { get_address = function() return 0x900 end, K2_GetComponentsByClass = function() return {} end }
fake.pc = { bShowMouseCursor = false }
tick(0.6)
check(fake.mod_values.VR_SnapTurn == "true", "gameplay: snap turn on")
settings.data.snap_turn = false
tick(0.6)
check(fake.mod_values.VR_SnapTurn == "false", "snap turn setting off respected")
settings.data.snap_turn = true
fake.pawn, fake.pc = nil, nil
tick(0.6)

---------------------------------------------------------------------------
-- Physical crouch (toggle, edge mode: pawn has no bIsCrouched)
---------------------------------------------------------------------------

release_all()
roomscale.reset()
fake.pawn = nil
fake.head_y = 1.70
tick(3.5)
check(roomscale.standing_y and math.abs(roomscale.standing_y - 1.70) < 1e-6, "auto-calibrates standing height")

local function crouch_taps(seconds)
    local taps, prev = 0, false
    local t = 0
    while t < seconds do
        callbacks.on_pre_engine_tick(nil, 1 / 72)
        local down = has(poll(), XINPUT_GAMEPAD_B)
        if down and not prev then taps = taps + 1 end
        prev = down
        t = t + 1 / 72
    end
    return taps, prev
end

fake.head_y = 1.30
local taps, still = crouch_taps(1.0)
check(roomscale.crouched, "head drop of 0.40 m counts as crouched")
check(taps == 1 and not still, "one crouch tap on entering crouch (got " .. taps .. ")")

fake.head_y = 1.40   -- drop 0.30: inside hysteresis band, stays crouched
taps = crouch_taps(0.5)
check(roomscale.crouched and taps == 0, "hysteresis band holds crouch without taps")

fake.head_y = 1.68
taps = crouch_taps(1.0)
check(not roomscale.crouched and taps == 1, "one tap on standing back up")

fake.head_y = 1.85
tick(0.1)
check(math.abs(roomscale.standing_y - 1.85) < 1e-6, "standing height follows player up")

---------------------------------------------------------------------------
-- Physical crouch synced to bIsCrouched
---------------------------------------------------------------------------

roomscale.reset()
local pawn = { bIsCrouched = false, get_address = function() return 0x1000 end,
               K2_GetComponentsByClass = function() return {} end }
fake.pawn = pawn
fake.head_y = 1.70
tick(3.5)

-- Game flips its flag when it sees a B press.
local function sync_run(seconds)
    local taps, prev = 0, false
    local t = 0
    while t < seconds do
        callbacks.on_pre_engine_tick(nil, 1 / 72)
        local down = has(poll(), XINPUT_GAMEPAD_B)
        if down and not prev then taps = taps + 1 pawn.bIsCrouched = not pawn.bIsCrouched end
        prev = down
        t = t + 1 / 72
    end
    return taps
end

fake.head_y = 1.25
check(sync_run(1.5) == 1 and pawn.bIsCrouched, "synced mode: one tap, game crouched")

pawn.bIsCrouched = false  -- player pressed crouch manually and stood up in-game
check(sync_run(1.5) == 1 and pawn.bIsCrouched, "synced mode: re-syncs after manual uncrouch")

fake.head_y = 1.70
check(sync_run(1.5) == 1 and not pawn.bIsCrouched, "synced mode: stands back up")

-- Hold mode
settings.data.crouch_mode = "hold"
fake.head_y = 1.20
tick(0.1)
check(has(poll(), XINPUT_GAMEPAD_B), "hold mode holds crouch button while crouched")
fake.head_y = 1.70
tick(0.1)
check(not has(poll(), XINPUT_GAMEPAD_B), "hold mode releases when standing")
settings.data.crouch_mode = "toggle"

-- The game's own crouch: the pawn's Crouch()/UnCrouch() (Routine crouches
-- the standard Unreal way), no button pressed.
roomscale.reset()
local cpawn = { bIsCrouched = false, get_address = function() return 0x1001 end,
                K2_GetComponentsByClass = function() return {} end }
function cpawn:Crouch() self.bIsCrouched = true end
function cpawn:UnCrouch() self.bIsCrouched = false end
fake.pawn = cpawn
fake.head_y = 1.70
tick(3.5)
fake.head_y = 1.25
local pressed = 0
for _ = 1, 72 do
    callbacks.on_pre_engine_tick(nil, 1 / 72)
    if has(poll(), XINPUT_GAMEPAD_B) then pressed = pressed + 1 end
end
check(cpawn.bIsCrouched and pressed == 0 and roomscale.crouch_method == "game crouch",
    "ducking crouches through the game's own Crouch(), no button")
fake.head_y = 1.70
tick(0.5)
check(not cpawn.bIsCrouched, "standing up uncrouches the same way")
-- A Crouch() that does nothing: the button takes over.
roomscale.reset()
function cpawn:Crouch() end
function cpawn:UnCrouch() end
cpawn.bIsCrouched = false
tick(3.5)
fake.head_y = 1.25
local taps_after = 0
local prev_b = false
for _ = 1, 144 do
    callbacks.on_pre_engine_tick(nil, 1 / 72)
    local down = has(poll(), XINPUT_GAMEPAD_B)
    if down and not prev_b then taps_after = taps_after + 1 end
    prev_b = down
end
check(taps_after >= 1 and roomscale.crouch_method:find("button", 1, true),
    "game crouch has no effect: falls back to the crouch button")
fake.head_y = 1.70
tick(1.0)
fake.pawn = nil

---------------------------------------------------------------------------
-- Grips no longer recenter (chord removed); recenter is the panel button
---------------------------------------------------------------------------

release_all()
local before = fake.recentered
hold("Grip", "left", true)
hold("Grip", "right", true)
tick(1.5)
gp = poll(XINPUT_GAMEPAD_LEFT_SHOULDER | XINPUT_GAMEPAD_RIGHT_SHOULDER)
check(has(gp, XINPUT_GAMEPAD_LEFT_SHOULDER) and has(gp, XINPUT_GAMEPAD_RIGHT_SHOULDER),
    "both grips reach the game as LB/RB (grip features off)")
check(fake.recentered == before, "holding both grips doesn't recenter")
roomscale.recenter()
check(fake.recentered == before + 1 and fake.standing_origin ~= nil, "panel recenter resets view and origin")
release_all()

---------------------------------------------------------------------------
-- Comfort effects: rpp commands via the player controller, vignette cvar
---------------------------------------------------------------------------

local effects = require("routine_vr.effects")
local function ran(cmd)
    for _, c in ipairs(fake.commands) do if c == cmd then return true end end
    return false
end
local pc_cmds = {}
local function pc_ran(cmd)
    for _, c in ipairs(pc_cmds) do if c == cmd then return true end end
    return false
end
local saved_pc = fake.pc
fake.pc = { bShowMouseCursor = false }
fake.kismet = { ExecuteConsoleCommand = function(self, ctx, cmd, pc)
    assert(pc == fake.pc and ctx == fake.pc, "console command needs the player controller")
    pc_cmds[#pc_cmds + 1] = cmd
end }
fake.commands = {}
effects.reset()
effects.apply_all(false)
check(pc_ran("rpp fisheye 0") and pc_ran("rpp grain 0") and pc_ran("rpp sharpen 0"),
    "fisheye, grain and sharpen removed through the player controller console")
check(not ran("rpp fisheye 0"), "rpp commands not sent through engine exec (cheat commands need the PC)")
check(pc_ran("rpp colorg 0.0"), "color grading removed (rpp colorg 0.0)")
check(ran("r.Tonemapper.Quality 0"), "vignette removed via tonemapper quality")
pc_cmds = {}
effects.apply_all(false)
check(#pc_cmds == 0, "unchanged settings aren't re-sent")
effects.apply_all(true)
check(pc_ran("rpp fisheye 0"), "forced pass (periodic) re-sends for new levels")
pc_cmds, fake.commands = {}, {}
settings.data.remove_fisheye = false
settings.data.remove_vignette = false
effects.apply_all(false)
check(pc_ran("rpp fisheye 1") and not pc_ran("rpp grain 1"), "unticking fisheye restores only fisheye")
check(ran("r.Tonemapper.Quality 5"), "unticking vignette restores the tonemapper")
check(effects.status == "PPV mod: loaded", "status reports the PPV mod when its class is found")
settings.data.remove_fisheye, settings.data.remove_vignette = true, true
effects.apply_all(false)
fake.pc = saved_pc

---------------------------------------------------------------------------
-- Game modes, C.A.T. inspect, camera offset guard
---------------------------------------------------------------------------

local game = require("routine_vr.game")
release_all()
local menu_pawn = { get_address = function() return 0xA00 end, K2_GetComponentsByClass = function() return {} end,
                    get_full_name = function() return "BP_Menu_Main_Pawn_C /Game/Maps/Menu_Main.Pawn" end }
fake.pawn, fake.pc = menu_pawn, { bShowMouseCursor = false }
tick(0.6)
check(game.mode == "menu" and fake.mod_values.VR_AimMethod == "0", "main menu pawn: menu mode, plain aim")
check(fake.mod_values.VR_MovementOrientation == "0", "main menu (has a pawn) still gets the raw stick")
check(fake.uobjecthook_disabled == true, "attachments off in menus")
-- At the start: once on the opening screens (the "press any button"
-- splash: no pawn yet) after they've been up 4 s, then once more when the
-- main menu first shows (the menus used to be behind you every start).
roomscale.reset_start_recenter()
fake.pawn = nil
local rc_before = fake.recentered
roomscale.standing_y = roomscale.standing_y or 1.70
tick(2.0)
check(fake.recentered == rc_before, "splash screen: not in the first seconds (it went off during loading)")
tick(2.5)
check(fake.recentered == rc_before + 1 and roomscale.start_recenter_done, "splash screen up 4 s: recentered on its own")
fake.pawn = menu_pawn
tick(1.5)
check(fake.recentered == rc_before + 2, "main menu first shows: recentered once more")
tick(3.0)
check(fake.recentered == rc_before + 2, "...and no more after that")

local cam = {}
local hidden = {}
local child = { SetVisibility = function(self, v) hidden.child = not v end }
local game_pawn = { get_address = function() return 0xB00 end,
                    get_full_name = function() return "BP_Player_C /Game/Maps/Facility.Player" end,
                    Mesh = { AttachChildren = { child } },
                    K2_GetComponentsByClass = function() return { cam } end }
cam.get_fname = function() return { to_string = function() return "CameraComponent" end } end
cam.get_class = function() return { get_fname = function() return { to_string = function() return "RoutineGameCameraComponent" end } end } end
fake.pawn = game_pawn
local CINE = "WidgetBlueprintGeneratedClass /Game/UI/Game/Cine/RUI_Cine_Video.RUI_Cine_Video_C"
local cine_widget = { on_screen = true }
function cine_widget:IsInViewport() return self.on_screen end
function cine_widget:IsVisible() return true end
fake.object_lists = fake.object_lists or {}
fake.object_lists[CINE] = { cine_widget }
tick(0.6)
check(game.mode == "cutscene" and fake.mod_values.VR_2DScreenMode == "true", "cine video widget: 2D screen cutscene")
-- The video ended but the game kept its widget (after a load / new game):
-- off screen, so it's gameplay, not a stuck cutscene.
cine_widget.on_screen = false
tick(0.6)
check(game.mode == "game", "video widget left over off screen: back to gameplay (not stuck in cutscene)")
-- Cutscene mode is off by default: a video playing changes nothing.
check(settings.defaults.cutscene_mode == false, "defaults: no cutscene mode")
settings.data.cutscene_mode = false
cine_widget.on_screen = true
tick(0.6)
check(game.mode == "game" and fake.mod_values.VR_2DScreenMode == "false", "cutscene mode off: a video keeps gameplay mode and VR view")
settings.data.cutscene_mode = true
cine_widget.on_screen = false
tick(0.6)
-- Shown inside another widget rather than on the viewport: still a cutscene.
cine_widget.GetParent = function() return {} end
tick(0.6)
check(game.mode == "cutscene", "video widget inside another widget: still a cutscene")
cine_widget.GetParent = nil
fake.object_lists[CINE] = nil
local cat_root = { RelativeLocation = { X = 30, Y = 0, Z = -20 }, RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 } }
local input_mod = require("routine_vr.input")
local light = { Intensity = 0 }
fake.objects = { ["Class /Script/Routine.RoutineGameCAT"] = { Pointlight_InspectCAT = light, RootComponent = cat_root } }
tick(1.2)
check(game.mode == "game" and fake.mod_values.VR_AimMethod == "2" and fake.mod_values.VR_2DScreenMode == "false",
    "gameplay mode: right-hand aim, 3D")
check(fake.uobjecthook_disabled == false, "attachments on in gameplay")
check(hidden.child, "body-mesh attachments hidden")
-- Anything visible under the camera floats in your hand: hidden, lights kept.
local function cam_child(cls)
    local c = { vis = true }
    function c:get_class() return { get_fname = function() return { to_string = function() return cls end } end } end
    function c:IsVisible() return self.vis end
    function c:SetVisibility(v) self.vis = v end
    return c
end
local helmet2, light2 = cam_child("SkeletalMeshComponent"), cam_child("Routine_PlayerSpecularComponent_C")
light2.get_class = function() return { get_fname = function() return { to_string = function() return "PointLightComponent" end } end } end
cam.AttachChildren = { helmet2, light2 }
game_pawn.CameraComponent = cam
tick(0.6)
check(helmet2.vis == false and light2.vis == true, "late-game helmet under the camera hidden; the player's light kept")
cam.AttachChildren = nil
-- With show_body, the suit's body mesh stays (head hidden), the rest goes.
local body_child = { SkeletalMesh = { get_full_name = function() return "SkeletalMesh /Game/Art/3D/Character/Player/Default/Model/SK_Player_Default_Body.SK_Player_Default_Body" end } }
function body_child:SetVisibility(v) self.visible = v end
function body_child:SetOwnerNoSee(v) self.owner_no_see = v end
function body_child:HideBoneByName(b) self.hidden_bone = b end
game_pawn.Mesh.AttachChildren = { child, body_child }
settings.data.show_body = true
game.rehide_body()
tick(0.6)
check(body_child.visible == true and body_child.owner_no_see == false and body_child.hidden_bone == "Bone_Neck" and hidden.child,
    "show body: the suit's body visible with its head hidden, other parts (arms) still hidden")
settings.data.show_body = false
game.rehide_body()
tick(0.6)
check(body_child.visible == false, "show body off: hidden again")
game_pawn.Mesh.AttachChildren = { child }
local cl = fake.mc_states[cam] and fake.mc_states[cam].loc
check(fake.mc_states[cam].hand == 1 and cl.x == 0 and cl.y == 0 and cl.z == 0,
    "CameraComponent (interaction origin) right on the right controller")
check(fake.mc_states[cat_root] == nil, "C.A.T. lowered (no LT): left to the game, so it can be put away")
input_mod.left_trigger = 255
tick(0.1)
check(fake.mc_states[cat_root] and fake.mc_states[cat_root].hand == 1, "LT held: C.A.T. actor root on the right hand on its own")
cat_root.RelativeLocation.X = 99 -- what UObjectHook does while attached
input_mod.left_trigger = 0
tick(0.1)
check(fake.mc_states[cat_root] == nil and cat_root.RelativeLocation.X == 30 and cat_root.RelativeLocation.Z == -20,
    "LT released: unhooked and back to the game's own relative pose")

-- Right grip raises the C.A.T. (sends LT, drops the grip's RB)
local yaw_in = 0
local pawn_yaw = 0
fake.pc = fake.pc or {}
fake.pc.AddYawInput = function(self, v) yaw_in = yaw_in + v; pawn_yaw = pawn_yaw + v end
fake.pawn.K2_GetActorRotation = function() return { Pitch = 0, Yaw = pawn_yaw, Roll = 0 } end
local saved_snap = settings.data.snap_turn
settings.data.snap_turn = false
fake.using_controllers = false -- the overrides no longer depend on UEVR's "using controllers"
settings.data.cat_grip = "hold"
hold("Grip", "right", true)
tick(0.1)
local gp = poll(XINPUT_GAMEPAD_RIGHT_SHOULDER)
check(game.raised and fake.mc_states[cat_root] ~= nil, "hold grip: C.A.T. out")
check(gp.bLeftTrigger == 255 and not has(gp, XINPUT_GAMEPAD_RIGHT_SHOULDER), "grip sends LT and no RB (lean)")
check(input_mod.diag.rb_in == true and input_mod.diag.rb_out == false and input_mod.diag.lt_out == 255,
    "input check shows RB in/out and LT sent")
fake.using_controllers = true
-- In the real game is_action_active reads false inside the XInput callback:
-- the grip state read on the tick has to carry it.
local real_active = uevr.params.vr.is_action_active
uevr.params.vr.is_action_active = function() return false end
gp = poll(XINPUT_GAMEPAD_RIGHT_SHOULDER)
check(not has(gp, XINPUT_GAMEPAD_RIGHT_SHOULDER), "RB dropped using the tick's grip state, not a read in the callback")
uevr.params.vr.is_action_active = real_active

-- Routine's own view component turns the character (honoured only when
-- view_works says so).
local view_works = function() return true end
fake.pawn.ViewComponent = {
    GetViewRotation = function() return { Pitch = 0, Yaw = pawn_yaw, Roll = 0 } end,
    SetViewRotation = function(self, r) if view_works() then pawn_yaw = r.Yaw end end,
}
fake.axis.right = { 1.0, 0 }
local start_yaw = pawn_yaw
tick(1.0)
local st = { Gamepad = { wButtons = 0, bLeftTrigger = 0, bRightTrigger = 0, sThumbLX = 0, sThumbLY = 0, sThumbRX = 32767, sThumbRY = 0 } }
callbacks.on_xinput_get_state(0, 0, st)
check(st.Gamepad.sThumbRX == 0, "C.A.T. out: stick X hidden from the game's slow aim turn")
check(math.abs((pawn_yaw - start_yaw) - settings.data.cat_turn_speed) < 3 and game.view_turn == 0,
    "C.A.T. out: the character itself turns at the set speed (view component), no view offset")
check(game.turn_method_name() == "view_rotation (works)", "turn check: view component confirmed when the character turns")

-- View component ignored while the C.A.T. is out: UEVR rotation offset.
view_works = function() return not game.raised end
local off = { w = 1, x = 0, y = 0, z = 0 }
uevr.params.vr.get_rotation_offset = function(q) q.w, q.x, q.y, q.z = off.w, off.x, off.y, off.z end
uevr.params.vr.set_rotation_offset = function(q) off = { w = q.w, x = q.x, y = q.y, z = q.z } end
game.reset_turn_check()
fake.axis.right = { 1.0, 0 }
tick(0.3)
check(game.turn_method_name() == "vr_view (works)", "view component does nothing with the C.A.T. out: falls back to the VR view")
off = { w = 1, x = 0, y = 0, z = 0 }
game.view_turn = 0
tick(0.5)
local turned_deg = math.deg(2 * math.atan(math.abs(off.y), off.w))
check(math.abs(turned_deg - 0.5 * settings.data.cat_turn_speed) < 3,
    "C.A.T. out: turns the VR view (UEVR rotation offset) at the set speed")
check(off.y < 0, "pushing right turns the offset about -y (glm), like a UE yaw to the right")
-- Stick handover tests: the view component turns nothing here.
view_works = function() return false end
-- Lowering the C.A.T. hands the view turn to the character by pushing
-- the stick; the fake game turns 2 deg per frame at full stick.
fake.axis.right = { 0, 0 }
fake.pc.GetControlRotation = nil
-- Like Routine, the fake game ignores the stick inside a 25% deadzone.
local function game_turn(rx, dir)
    local v = rx / 32767
    if math.abs(v) < 0.25 then return 0 end
    return v * 2 * (dir or 1)
end
-- One frame as UEVR runs it: engine tick, the game reads the pad and
-- turns, then the stereo view is calculated (both eyes).
local function stereo()
    callbacks.on_early_calculate_stereo_view_offset(nil, 0, 100, nil, nil, false)
    callbacks.on_early_calculate_stereo_view_offset(nil, 1, 100, nil, nil, false)
end
local function game_frames(n, turns)
    for _ = 1, n do
        callbacks.on_pre_engine_tick(nil, 1 / 72)
        local g = poll()
        if turns then pawn_yaw = pawn_yaw + game_turn(g.sThumbRX) end
        stereo()
    end
end
local yaw_before = pawn_yaw
local turned_view = game.view_turn
hold("Grip", "right", false)
-- The view the player sees = character yaw + view offset; it must stay put
-- every frame while the character turns underneath (no jitter).
local function seen() return pawn_yaw + game.view_turn end
local seen_start, worst = seen(), 0
for _ = 1, 200 do
    game_frames(1, true)
    worst = math.max(worst, math.abs(seen() - seen_start))
end
check(worst < 0.01, "handover: the view holds still every frame while the character turns (no jitter)")
local off_deg = math.deg(2 * math.atan(math.abs(off.y), off.w))
check(math.abs((pawn_yaw - yaw_before) - turned_view) < 5 and off_deg < 5 and math.abs(game.view_turn) < 5,
    "C.A.T. lowered: stick pushed (past the game's deadzone) until the character has caught up; view offset back to ~0")
check(game.last_handover and game.last_handover:find("done", 1, true) and input_mod.inject_rx == nil,
    "handover reports done and lets go of the stick")

-- The game doesn't turn: give up, keep the view's turn, no retry until the next raise.
hold("Grip", "right", true)
fake.axis.right = { 1.0, 0 }
tick(0.5)
fake.axis.right = { 0, 0 }
hold("Grip", "right", false)
local vt = game.view_turn
game_frames(30, false)
check(game.last_handover:find("didn't turn", 1, true) and math.abs(game.view_turn - vt) < 0.01 and input_mod.inject_rx == nil,
    "game doesn't turn: handover stops, view keeps its turn")
game_frames(30, true)
check(math.abs(game.view_turn - vt) < 0.01, "no retry until the C.A.T. comes out again")

-- Stick turns the game the other way: the handover flips.
hold("Grip", "right", true); tick(0.1); hold("Grip", "right", false)
local yb = pawn_yaw
for _ = 1, 300 do
    callbacks.on_pre_engine_tick(nil, 1 / 72)
    local g = poll()
    pawn_yaw = pawn_yaw + game_turn(g.sThumbRX, -1)
    stereo()
end
check(math.abs(game.view_turn) < 5 and math.abs((pawn_yaw - yb) - vt) < 5 and input_mod.inject_rx == nil,
    "reversed stick: handover flips, finishes and lets go")

-- The player's own stick always wins.
hold("Grip", "right", true); fake.axis.right = { 1.0, 0 }; tick(0.5); fake.axis.right = { 0, 0 }
hold("Grip", "right", false)
game_frames(12, true)
fake.axis.right = { -0.8, 0 }
game_frames(2, true)
check(input_mod.inject_rx == nil and game.last_handover:find("took the stick", 1, true), "touching the right stick ends the handover")
fake.axis.right = { 0, 0 }

-- The game stops turning part way: let go instead of holding the stick forever.
hold("Grip", "right", true); fake.axis.right = { 1.0, 0 }; tick(0.5); fake.axis.right = { 0, 0 }
hold("Grip", "right", false)
local frames_turning = 0
for _ = 1, 200 do
    callbacks.on_pre_engine_tick(nil, 1 / 72)
    local g = poll()
    frames_turning = frames_turning + 1
    if frames_turning < 15 then pawn_yaw = pawn_yaw + game_turn(g.sThumbRX) end
    stereo()
end
check(input_mod.inject_rx == nil and game.last_handover:find("stopped turning", 1, true), "game stops turning: handover lets go of the stick")

view_works = function() return not game.raised end
-- View component works once the C.A.T. is lowered: the handover is instant
-- and the view holds still.
hold("Grip", "right", true); fake.axis.right = { 1.0, 0 }; tick(0.5); fake.axis.right = { 0, 0 }
local vt0 = game.view_turn
local seen0 = pawn_yaw + game.view_turn
hold("Grip", "right", false)
game_frames(1, false)
check(math.abs(game.view_turn) < 1 and math.abs((pawn_yaw + game.view_turn) - seen0) < 0.01 and math.abs(vt0) > 30,
    "lowered: character turned at once through its view component, view unchanged")
game_frames(12, false)
check(input_mod.inject_rx == nil and game.last_handover:find("done", 1, true), "instant handover: no stick push needed")

local function near(a, b) return a ~= nil and math.abs(a - b) < 1e-3 end
-- Body follows the head: head turned 90 deg right, dead zone 35 deg. The
-- character turns the other 55 deg; the VR view holds still.
off = { w = 1, x = 0, y = 0, z = 0 }
view_works = function() return true end
settings.data.body_follow, settings.data.body_follow_deadzone, settings.data.body_follow_speed = true, 35, 180
fake.poses = { [0] = { pos = { 0, 1.7, 0 }, rot = { math.cos(math.rad(45)), 0, -math.sin(math.rad(45)), 0 } } }
check(near(game.head_yaw(), 90), "head turned 90 deg right reads as +90")
local yaw0 = pawn_yaw
local function off_yaw() return -math.deg(2 * math.atan(off.y, off.w)) end
local seen0 = pawn_yaw + off_yaw()
local worst_seen = 0
for _ = 1, 72 do
    game_frames(1, false)
    worst_seen = math.max(worst_seen, math.abs((pawn_yaw + off_yaw()) - seen0))
end
check(near(pawn_yaw - yaw0, 55), "the character turns toward the head, up to the dead zone")
check(worst_seen < 0.01, "the view holds still every frame while the body follows")
check(near(game.head_yaw(), 35), "the head ends up the dead zone from the body")
-- The game turns the character itself (onto a ladder): the view goes with
-- it, nothing is undone, and nothing keeps turning (the old spin).
local seen1 = pawn_yaw + off_yaw()
pawn_yaw = pawn_yaw + 30
game_frames(1, false)
check(near((pawn_yaw + off_yaw()) - seen1, 30), "a turn the game makes isn't undone on the view")
local settled = pawn_yaw
game_frames(72, false)
check(near(pawn_yaw, settled), "...and the body doesn't start turning on its own (no spin)")
-- Leaning (RB sent): body follow pauses.
fake.poses = { [0] = { pos = { 0, 1.7, 0 }, rot = { math.cos(math.rad(45)), 0, -math.sin(math.rad(45)), 0 } } }
input_mod.diag.rb_out = true
local lean_yaw = pawn_yaw
callbacks.on_pre_engine_tick(nil, 1 / 72)
check(near(pawn_yaw, lean_yaw) and not game.follow_active, "leaning: body follow pauses")
input_mod.diag.rb_out = false
fake.poses = { [0] = { pos = { 0, 1.7, 0 }, rot = { 1, 0, 0, 0 } } }
game_frames(72, false)
fake.axis.right = { 1.0, 0 }
local before_turn = pawn_yaw
game_frames(1, false)
fake.axis.right = { 0, 0 }
check(game.follow_active == false, "using the stick: body follow steps aside")
fake.poses = nil
settings.data.body_follow = false
game.clear_view_turn()
hold("Grip", "right", true)
fake.axis.right = { 1.0, 0 }
uevr.params.vr.get_rotation_offset, uevr.params.vr.set_rotation_offset = nil, nil
game.reset_turn_check()

-- Nothing turns (no view component, no rotation offset): stick to the game.
fake.pawn.ViewComponent = nil
game.reset_turn_check()
tick(1.5)
local st2 = { Gamepad = { wButtons = 0, bLeftTrigger = 0, bRightTrigger = 0, sThumbLX = 0, sThumbLY = 0, sThumbRX = 32767, sThumbRY = 0 } }
callbacks.on_xinput_get_state(0, 0, st2)
check(game.turn_method_name():find("game", 1, true) and st2.Gamepad.sThumbRX == 32767,
    "nothing turns: stick handed back to the game, so turning never stops")
game.reset_turn_check()
fake.axis.right = { 0, 0 }

hold("Grip", "right", false)
tick(0.1)
gp = poll()
check(not game.raised and gp.bLeftTrigger == 0 and input_mod.block_turn == false, "grip released: C.A.T. away, game turns again")
settings.data.stop_cat_aim_turn = false
input_mod.left_trigger = 255
tick(0.1)
check(input_mod.block_turn == false, "C.A.T. turn fix can be switched off")
input_mod.left_trigger = 0
settings.data.snap_turn = saved_snap
settings.data.stop_cat_aim_turn = true
settings.data.cat_grip = "toggle"
hold("Grip", "right", true); tick(0.1); hold("Grip", "right", false); tick(0.1)
check(game.raised, "toggle: one grip press raises it and it stays out")
hold("Grip", "right", true); tick(0.1); hold("Grip", "right", false); tick(0.1)
check(not game.raised, "toggle: next press puts it away")
-- Holster at the right hip: the grip has to close there.
local hip_mod = require("routine_vr.hip")
local h = hip_mod.holster({ x = 0, y = 1.7, z = 0 }, { w = 1, x = 0, y = 0, z = 0 })
check(math.abs(h.x - 0.20) < 1e-6 and math.abs(h.y - 1.05) < 1e-6 and math.abs(h.z - 0.05) < 1e-6,
    "holster: below the head, to the right, a little behind (facing -z)")
local yaw90 = { w = math.cos(math.rad(45)), x = 0, y = math.sin(math.rad(45)), z = 0 } -- head turned 90 deg left
h = hip_mod.holster({ x = 0, y = 1.7, z = 0 }, yaw90)
check(math.abs(h.z + 0.20) < 1e-3 and math.abs(h.x - 0.05) < 1e-3, "holster turns with the head (facing left, right side is -z)")
settings.data.cat_grip = "hip"
fake.poses = { [0] = { pos = { 0, 1.7, 0 }, rot = { 1, 0, 0, 0 } }, [2] = { pos = { 0.3, 1.2, -0.4 }, rot = { 1, 0, 0, 0 } } }
hold("Grip", "right", true); tick(0.1)
check(not game.raised and not hip_mod.at_hip, "hip mode: gripping in front of you doesn't draw the C.A.T.")
hold("Grip", "right", false); tick(0.1)
fake.poses[2].pos = { 0.22, 1.07, 0.03 }
tick(0.1)
check(hip_mod.at_hip, "hand at the holster")
hold("Grip", "right", true); tick(0.1)
check(game.raised, "hip mode: grip at the holster draws the C.A.T.")
fake.poses[2].pos = { 0.3, 1.3, -0.4 }
tick(0.2)
check(game.raised, "keeps it out while the grip is held, hand away from the hip")
hold("Grip", "right", false); tick(0.1)
check(not game.raised, "grip released: put away")
fake.poses = nil

settings.data.cat_grip = "off"
hold("Grip", "right", true); tick(0.1)
gp = poll(XINPUT_GAMEPAD_RIGHT_SHOULDER)
tick(0.1)
gp = poll(XINPUT_GAMEPAD_RIGHT_SHOULDER)
check(not game.raised and has(gp, XINPUT_GAMEPAD_RIGHT_SHOULDER), "grip off: grip is RB (lean) again")
hold("Grip", "right", false)
-- Lean on the off-hand trigger (the default): LT pulled sends RB, and the
-- left grip sends nothing (it only curls the fingers).
settings.data.lean_button = "trigger"
settings.data.lt_raises_cat = false
tick(0.1)
gp = poll(XINPUT_GAMEPAD_LEFT_SHOULDER)
check(not has(gp, XINPUT_GAMEPAD_RIGHT_SHOULDER) and not has(gp, XINPUT_GAMEPAD_LEFT_SHOULDER), "trigger lean: the left grip doesn't lean")
local lean_state = { Gamepad = { wButtons = 0, bLeftTrigger = 200, bRightTrigger = 0, sThumbLX = 0, sThumbLY = 0, sThumbRX = 0, sThumbRY = 0 } }
callbacks.on_xinput_get_state(0, 0, lean_state)
check(has(lean_state.Gamepad, XINPUT_GAMEPAD_RIGHT_SHOULDER) and lean_state.Gamepad.bLeftTrigger == 0
    and not has(lean_state.Gamepad, XINPUT_GAMEPAD_DPAD_UP), "trigger lean: LT sends lean (RB), not LT or Focus")
settings.data.lt_raises_cat = true
settings.data.lean_button = "grip"
tick(0.1)
gp = poll(XINPUT_GAMEPAD_LEFT_SHOULDER)
check(has(gp, XINPUT_GAMEPAD_RIGHT_SHOULDER) and not has(gp, XINPUT_GAMEPAD_LEFT_SHOULDER), "grip lean: left grip leans (RB, not LB) in gameplay")
gp = poll(0)
check(not has(gp, XINPUT_GAMEPAD_RIGHT_SHOULDER), "left grip released: no lean")
settings.data.lean_button = "off"
settings.data.cat_grip = "hold"
tick(0.1)

input_mod.left_trigger = 255
tick(0.1)
light.Intensity = 5
tick(1.2)
local cs = fake.mc_states[cat_root]
check(game.inspecting and cs.hand == 0, "inspect: C.A.T. to the left hand by default")
check(require("routine_vr.input").block_stick_pitch == true, "gameplay: right stick pitch locked")
check(math.abs(math.abs(cs.rot.y) - math.sqrt(0.5)) < 1e-6, "inspect: C.A.T. turned a quarter so the side buttons face you")
check(fake.mc_states[cam].hand == 1, "inspect: camera (pointer) stays on the right hand")
input_mod.left_trigger = 0
tick(0.6)
check(fake.mc_states[cat_root] ~= nil, "inspecting keeps the C.A.T. out even with LT released")
light.Intensity = 0
input_mod.left_trigger = 255
tick(1.2)
check(not game.inspecting and fake.mc_states[cat_root].hand == 1, "inspect light off: back to the right hand")
input_mod.left_trigger = 0
check(#settings.get("attachments") == 2 and settings.get("attachments")[2].hand == "right",
    "inspect override doesn't touch saved attachments")
tick(0.1)
fake.objects = {}

local laser = require("routine_vr.laser")
local added = {}
uevr.api.add_component_by_class = function(self, actor, cls, deferred)
    local comp = { visible = nil, destroyed = false }
    function comp:SetVisibility(v) self.visible = v end
    function comp:SetCollisionEnabled(v) self.collision = v end
    function comp:SetCapsuleSize(r, h) self.half = h end
    function comp:K2_DestroyComponent() self.destroyed = true end
    added[#added + 1] = comp
    return comp
end
settings.data.laser = "inspect"
settings.data.laser_forward, settings.data.laser_up = 0, 0
laser.reset()
tick(0.5)
check(#added == 0, "no laser until it's needed")
fake.objects["Class /Script/Routine.RoutineGameCAT"] = { Pointlight_InspectCAT = { Intensity = 5 } }
tick(1.2)
local beam = nil
for _, c in ipairs(added) do if c.half ~= nil then beam = c end end -- the capsule, not the touch fingertip
check(beam ~= nil and beam.visible == true and beam.collision == 0, "inspecting: laser created, visible, no collision")
check(fake.mc_states[beam] and fake.mc_states[beam].hand == 1 and fake.mc_states[beam].loc.z == -50
    and fake.mc_states[beam].loc.x == 0, "laser on the right hand, forward is glm -z")
local lq = fake.mc_states[beam].rot
check(math.abs(math.abs(lq.x) - math.sqrt(0.5)) < 1e-6 and math.abs(lq.y) < 1e-6 and math.abs(lq.z) < 1e-6,
    "laser tipped 90 degrees about glm x (right), not y (up)")
fake.objects = {}
tick(1.2)
check(beam.visible == false, "inspect over: laser hidden")
hands.rescan()
tick(1.2)
check(fake.mc_states[beam] ~= nil, "hands rescans leave the laser's attachment alone")
settings.data.laser = "always"
tick(0.5)
check(beam.visible == true, "always mode: visible in gameplay")
local cam_a = settings.get("attachments")[1]
cam_a.loc = { 0, 0, 10 }
cam_a.rot = { 0, 90, 0 }
tick(0.5)
local bl = fake.mc_states[beam].loc
check(math.abs(bl.y - 10) < 1e-6 and math.abs(bl.x - 50) < 1e-4 and math.abs(bl.z) < 1e-4,
    "laser follows the camera's offset and yaw (the game's real ray)")
cam_a.loc, cam_a.rot = { 0, 0, 0 }, { 0, 0, 0 }
tick(0.5)
check(math.abs(fake.mc_states[beam].loc.z + 50) < 1e-6, "laser back on the controller")
settings.data.laser_forward, settings.data.laser_up = -14.4, 18.3
tick(0.5)
local nl = fake.mc_states[beam].loc
check(math.abs(nl.y - 18.3) < 1e-4 and math.abs(nl.z - (14.4 - 50)) < 1e-4, "laser start nudge (calibrated default)")
settings.data.laser_forward, settings.data.laser_up = 0, 0
settings.data.laser = "inspect"

-- Tap Y for the game's menu: Start for a moment, Y kept from the game.
-- Y is read from the buttons UEVR sends the game (its direct reads of the
-- face buttons came back false in the headset).
settings.data.y_opens_menu = true
local yg = poll(XINPUT_GAMEPAD_Y)
tick(0.1)
yg = poll(XINPUT_GAMEPAD_Y)
check(not has(yg, XINPUT_GAMEPAD_Y), "Y doesn't reach the game (no inspect)")
tick(1 / 72)
poll(0)
tick(1 / 72)
yg = poll()
check(has(yg, XINPUT_GAMEPAD_START), "Y tap: Start sent (game menu)")
tick(0.3)
check(not has(poll(), XINPUT_GAMEPAD_START), "...only for a moment")
poll(XINPUT_GAMEPAD_Y); tick(0.8); poll(0); tick(1 / 72)
check(not has(poll(), XINPUT_GAMEPAD_START), "Y held long (no polls in between): no menu")
poll(XINPUT_GAMEPAD_B | XINPUT_GAMEPAD_Y); tick(0.2); poll(0); tick(1 / 72)
check(not has(poll(), XINPUT_GAMEPAD_START), "B + Y (recenter chord): no menu")
tick(0.5)
settings.data.y_opens_menu = false

-- Hold B + Y to recenter (read from the buttons UEVR sends the game)
local before = fake.recentered
poll(XINPUT_GAMEPAD_B | XINPUT_GAMEPAD_Y)
tick(2.0)
check(fake.recentered == before, "B + Y: not yet at 2 s")
tick(1.2)
check(fake.recentered == before + 1, "B + Y held 3 s: recenter")
tick(3.5)
check(fake.recentered == before + 1, "keeps holding: only once")
poll(0)
tick(0.1)
-- Physical B + Y read by UEVR, with no face buttons in the game's input
-- (what the headset showed).
before = fake.recentered
hold("BButtonRight", "right", true); hold("BButtonLeft", "left", true)
tick(3.2)
check(fake.recentered == before + 1, "B + Y read from the controllers directly: recenter")
hold("BButtonRight", "right", false); hold("BButtonLeft", "left", false)
tick(0.1)
poll(XINPUT_GAMEPAD_X | XINPUT_GAMEPAD_Y)
tick(3.2)
check(fake.recentered == before + 2, "right B arriving as X (with Y): recenter")
-- Controllers without B/Y: their layout's chord (Vive: both pad clicks).
poll(0)
tick(0.1)
input.set_device("vive_wands")
hold("JoystickClick", "left", true); hold("JoystickClick", "right", true)
tick(3.2)
check(fake.recentered == before + 3, "Vive wands: both pad clicks held recenter")
hold("JoystickClick", "left", false); hold("JoystickClick", "right", false)
input.set_device("quest_touch")
poll(0)
tick(0.1)

-- Touch: fingertip vs the C.A.T.'s button boxes
local touch = require("routine_vr.touch")
local zero_rot = { Pitch = 0, Yaw = 0, Roll = 0 }
local c0, ext = { X = 0, Y = 0, Z = 0 }, { X = 2, Y = 1, Z = 1 }
check(touch.inside({ X = 1.9, Y = 0, Z = 0 }, c0, zero_rot, ext, 0) and not touch.inside({ X = 0, Y = 1.5, Z = 0 }, c0, zero_rot, ext, 0),
    "box test uses each axis' half extent")
check(touch.inside({ X = 0, Y = 1.9, Z = 0 }, c0, { Pitch = 0, Yaw = 90, Roll = 0 }, ext, 0)
    and not touch.inside({ X = 1.9, Y = 0, Z = 0 }, c0, { Pitch = 0, Yaw = 90, Roll = 0 }, ext, 0),
    "box test follows the box's yaw")
check(touch.inside({ X = 0, Y = 1.5, Z = 0 }, c0, zero_rot, ext, 1), "margin (fingertip radius) counts")

local tip = { X = 100, Y = 100, Z = 100 }
local marker
uevr.api.add_component_by_class = function(self, actor, cls, deferred)
    marker = { visible = nil }
    function marker:SetVisibility(v) self.visible = v end
    function marker:K2_GetComponentLocation() return tip end
    return marker
end
local function fake_box(x)
    return { K2_GetComponentLocation = function() return { X = x, Y = 0, Z = 0 } end,
             K2_GetComponentRotation = function() return zero_rot end,
             GetScaledBoxExtent = function() return { X = 1, Y = 1, Z = 1 } end }
end
local pressed_with, press_arg = nil, nil
-- Fake UFunction: Press(Hit: StructProperty HitResult) returning a bool.
local hit_struct = { get_fname = function() return { to_string = function() return "HitResult" end } end }
local function fake_prop(name, kind, flags, nxt, struct)
    return { get_fname = function() return { to_string = function() return name end } end,
             get_class = function() return { get_fname = function() return { to_string = function() return kind end } end } end,
             get_property_flags = function() return flags end,
             get_struct = function() return struct end,
             get_next = function() return nxt end }
end
local press_func = { get_child_properties = function()
    return fake_prop("Hit", "StructProperty", 0x80, fake_prop("ReturnValue", "BoolProperty", 0x80 | 0x400, nil), hit_struct)
end }
StructObject = { new = function(st) return { struct = st, ImpactPoint = { X = 0, Y = 0, Z = 0 } } end }
local pow = { bEnabled = true }
pow.get_class = function() return { find_function = function(_, n) return n == "Press" and press_func or nil end } end
pow.Press = function(self, ...) pressed_with = "Press"; press_arg = { n = select("#", ...), ... } end
fake.objects["Class /Script/Routine.RoutineGameCAT"] = { Pointlight_InspectCAT = { Intensity = 0 },
    Box_PowCol = fake_box(0), Box_WifiCol = fake_box(10), Interact_Pow = pow }
local buzzes = 0
local real_haptic = uevr.params.vr.trigger_haptic_vibration
uevr.params.vr.trigger_haptic_vibration = function() buzzes = buzzes + 1 end
touch.reset()
settings.data.touch_press_function = ""
require("routine_vr.input").left_trigger = 0
tick(0.1)
check(marker == nil, "no fingertip until the C.A.T. is out")
require("routine_vr.input").left_trigger = 255
tick(0.1)
check(marker ~= nil and fake.mc_states[marker].hand == 0 and math.abs(fake.mc_states[marker].loc.z + 8) < 1e-6,
    "fingertip on the left hand, 8 cm forward")
check(marker.visible == true and touch.touching == nil, "fingertip dot shown, not touching")
tip = { X = 10.5, Y = 0, Z = 0 }
tick(0.1)
check(touch.touching == "Wifi" and buzzes == 1, "touching a button box buzzes once")
tick(0.1)
check(buzzes == 1, "staying in the box doesn't buzz again")
check(pressed_with == nil, "no press until the press function is known")
settings.data.touch_press_function = "Press"
tip = { X = 0.2, Y = 0, Z = 0 }
tick(0.1)
check(touch.touching == "Pow" and pressed_with == "Press" and buzzes == 2, "touching Pow presses it with the configured function")
check(press_arg.n == 1 and press_arg[1].struct == hit_struct and press_arg[1].ImpactPoint.X == 0.2,
    "press builds the struct argument from the game's parameter list (no return value), fingertip as impact point")
check(touch.signature == "Press(Hit: StructProperty HitResult)", "panel shows the game function's signature")
local function fake_struct(n)
    return { get_fname = function() return { to_string = function() return n end } end }
end
local action_struct = fake_struct("RoutineGameInteractAction")
local real_gobc = UEVR_UObjectHook.get_objects_by_class
UEVR_UObjectHook.get_objects_by_class = function()
    return { fake_struct("Vector"), fake_struct("RoutineGameInteractDetails"), action_struct }
end
check(touch.find_struct("InteractAction") == action_struct and touch.struct_candidates:find("RoutineGameInteractDetails", 1, true),
    "struct type found by name among the game's Interact* structs")
check(touch.find_struct("Nothing") == nil, "unknown struct name: not found")
UEVR_UObjectHook.get_objects_by_class = real_gobc
pressed_with = nil
tip = { X = 100, Y = 0, Z = 0 }
tick(0.1)
tip = { X = 0.2, Y = 0, Z = 0 }
tick(0.1)
check(pressed_with == nil, "re-touching within the cooldown doesn't press twice")
tip = { X = 100, Y = 0, Z = 0 }
tick(0.5)
pow.bEnabled = false
tip = { X = 0.2, Y = 0, Z = 0 }
tick(0.1)
check(pressed_with == nil, "disabled button (mid-action) isn't pressed")
pow.bEnabled = true
tip = { X = 100, Y = 0, Z = 0 }
tick(0.5)
pow.Press = function() error("Invalid argument type for struct property") end
tip = { X = 0.2, Y = 0, Z = 0 }
tick(0.1)
check(touch.last_error and touch.last_error:find("Invalid argument", 1, true), "a failed press shows its error")
StructObject = nil
require("routine_vr.input").left_trigger = 0
tick(0.1)
check(marker.visible == false and touch.touching == nil, "C.A.T. put away: dot hidden, no touch")
settings.data.touch_press_function = ""
uevr.params.vr.trigger_haptic_vibration = real_haptic
fake.objects = {}

fake.mod_values.VR_CameraForwardOffset = "8937.988281"
tick(0.6)
check(fake.mod_values.VR_CameraForwardOffset == "0.000000", "camera offset forced back to 0")

fake.pawn, fake.pc = nil, nil
tick(0.6)

---------------------------------------------------------------------------
-- Vive touchpad quadrants
---------------------------------------------------------------------------

input.set_device("vive_wands")
check(fake.mod_values.VR_ControllerPitchOffset == "0.000000", "OpenXR: no per-controller pitch fix (OpenXR poses are already uniform)")
uevr.params.vr.is_openvr = function() return true end
input.set_device("vive_wands")
check(fake.mod_values.VR_ControllerPitchOffset == "-30.000000", "OpenVR: the vive layout pushes its pitch offset")
uevr.params.vr.is_openvr = nil

-- Auto-detect from the headset name in UEVR's log.
local devices = require("routine_vr.devices")
for _, c in ipairs({ { "Meta Quest 3 on WiVRn", "quest_touch" }, { "Oculus Rift S", "quest_touch" },
                     { "Valve Index", "index_knuckles" }, { "Bigscreen Beyond", "index_knuckles" },
                     { "HP Reverb G2", "wmr" }, { "Windows Mixed Reality", "wmr" },
                     { "PICO 4", "pico" }, { "HTC Vive Pro", "vive_wands" }, { "VIVE Focus 3", "quest_touch" },
                     { "Some New Headset", nil } }) do
    check(devices.from_system_name(c[1]) == c[2], "headset '" .. c[1] .. "' -> " .. tostring(c[2]))
end
local real_open, real_getenv = io.open, os.getenv
local log_text = "[info] [OpenXR] OpenXR system Name: Valve Index\r\n[info] other\r\n"
-- As in the game: UEVR's sandboxed io refuses absolute paths and "..", and
-- a relative path means the profile's data folder.
os.getenv = function(k) if k == "APPDATA" then return "C:\\users\\steamuser\\AppData\\Roaming" end return real_getenv(k) end
io.open = function(path, mode)
    if path:find("..", 1, true) then error("This API does not allow access to parent directories") end
    if path:find("^%a:[\\/]") or path:find("^[\\/]") then error("This API does not allow the use of absolute paths") end
    if path == "uevr_log.txt" then
        return { read = function() return log_text end, close = function() end }
    end
    return nil, "not found"
end
check(devices.read_system_name() == "Valve Index", "reads the headset name from UEVR's log")
input.set_device("auto")
check(input.device.id == "index_knuckles" and input.auto_device and input.detected_name == "Valve Index",
    "auto: Index headset -> Index layout")
log_text = ""
input.set_device("auto")
check(input.device.id == "quest_touch" and input.detected_name == nil, "auto, name not logged yet: Touch layout meanwhile")
log_text = "OpenXR system Name: PICO 4\r\n"
for _ = 1, 3 do input.tick_detect(1.0) end
check(input.device.id == "pico", "auto keeps looking until UEVR logs the headset")
io.open, os.getenv = real_open, real_getenv
input.set_device("vive_wands")
release_all()
tick(0.02)
hold("JoystickClick", "right", true)
fake.axis.right = { 0, -0.9 }
check(input.is_held("pad_down_r") and not input.is_held("pad_up_r"), "vive right pad down-click reads as pad down")
fake.axis.right = { 0.9, 0.1 }
check(input.is_held("pad_right_r"), "vive right pad right-click reads as pad right")
fake.axis.right = { 0.1, 0.1 }
check(not input.is_held("pad_down_r") and not input.is_held("pad_right_r"), "vive pad centre click is no quadrant")
input.set_device("quest_touch")
release_all()

---------------------------------------------------------------------------
-- Hands: discovery + attachment
---------------------------------------------------------------------------

settings.data.attachments = {}
fake.pawn = pawn
local cat = { tag = "cat" }
function cat:get_fname() return { to_string = function() return "CAT_Mesh" end } end
function cat:get_class() return { get_fname = function() return { to_string = function() return "SkeletalMeshComponent" end } end } end
pawn.K2_GetComponentsByClass = function(self, cls) return { cat } end
hands.rescan()
tick(1.1)
check(#hands.components == 1 and hands.components[1].name == "CAT_Mesh", "discovers pawn components")

hands.assign(hands.components[1], "right")
tick(1.1)
local st = fake.mc_states[cat]
check(st and st.hand == 1 and st.permanent, "assigning right hand attaches with hand=1, permanent")
check(st and math.abs(st.rot.w - 1) < 1e-6, "zero offset gives identity quaternion")

settings.get("attachments")[1].rot = { 0, 90, 0 }
hands.mark_dirty()
tick(0.02)
local yq = fake.mc_states[cat].rot
check(math.abs(yq.y - math.sqrt(0.5)) < 1e-4 and math.abs(yq.x) < 1e-6 and math.abs(yq.z) < 1e-6,
    "yaw 90 -> offset about glm y (up), inverted as UEVR applies it")

hands.assign(hands.components[1], nil)
tick(0.02)
check(fake.mc_states[cat] == nil, "detach removes motion controller state")

-- Pawn changes (level load): saved attachment re-applied to the new pawn.
hands.assign(hands.components[1], "left")
local cat2 = setmetatable({}, { __index = cat })
pawn = { get_address = function() return 0x2000 end, K2_GetComponentsByClass = function() return { cat2 } end }
fake.pawn = pawn
tick(1.1)
check(fake.mc_states[cat2] and fake.mc_states[cat2].hand == 0, "attachment re-applied after pawn change")

---------------------------------------------------------------------------
-- UI and reset don't throw
---------------------------------------------------------------------------

local windows = 0
local real_begin = imgui.begin_window
imgui.begin_window = function(...) windows = windows + 1 return true end
fake.drawing_ui = false
callbacks.on_frame()
check(windows == 0, "panel window hidden while UEVR menu is closed")
fake.drawing_ui = true
local ok, err = pcall(callbacks.on_frame)
check(ok and windows == 1, "panel window draws when UEVR menu is open: " .. tostring(err))
-- Every header and expander open: all of the panel draws, and each
-- expander that opens is closed again.
local opened, popped = 0, 0
imgui.collapsing_header = function() return true end
imgui.tree_node = function() opened = opened + 1 return true end
imgui.tree_pop = function() popped = popped + 1 end
local ui_ok, ui_err = pcall(callbacks.on_frame)
check(ui_ok and opened > 5 and opened == popped, "panel draws with every section open, expanders balanced: "
    .. tostring(ui_err) .. " (" .. opened .. " opened, " .. popped .. " closed)")
imgui.collapsing_header, imgui.tree_node, imgui.tree_pop = nil, nil, nil
fake.drawing_ui = false
imgui.begin_window = real_begin
ok, err = pcall(callbacks.on_script_reset)
check(ok, "script reset runs: " .. tostring(err))

-- UEVR's log on a launch where its frame tracking came up broken: the
-- warning once a second. The panel then says to restart the game.
local health = require("routine_vr.health")
local real_read = health.read_new
local W = "[warning] Something strange is going on, the vtable is already hooked, maybe previous frame was not rendered?\n"
health.reset()
health.read_new = function() return "[info] Cannot hook command with no vtable, falling back\n" end
tick(6.0)
check(not health.broken and health.status == "frame sync ok", "smooth launch (only the harmless fallback message): no warning")
health.read_new = function() return W:rep(5) end
tick(6.0)
check(health.broken and health.warnings == 5, "warning once a second in UEVR's log: this launch is flagged for a restart")
local hb_ok, hb_err = pcall(function() fake.drawing_ui = true callbacks.on_frame() fake.drawing_ui = false end)
check(hb_ok, "panel shows the restart notice: " .. tostring(hb_err))
health.read_new = real_read
health.reset()
-- The real reader, through UEVR's sandbox: only the link in data/ opens,
-- and each read picks up where the last stopped.
;(function()
local tmp = os.tmpname()
local real_io_open = io.open
local function log(text) local f = assert(real_io_open(tmp, "ab")); f:write(text); f:close() end
io.open = function(path, mode)
    if path:find("..", 1, true) or path:find("^%a:[\\/]") or path:find("^[\\/]") then error("sandboxed") end
    if path == "uevr_log.txt" then return real_io_open(tmp, mode) end
    return nil, "not found"
end
log("[info] start\n" .. W)
check(health.read_new():find("not rendered", 1, true) ~= nil, "the health check reads UEVR's log through the data/ link")
check(health.read_new() == "", "...and only new text on the next read")
log(W)
tick(6.0)
check(health.warnings == 1 and not health.broken, "a single warning (a hitch) doesn't flag the launch")
for _ = 1, 8 do log(W); tick(6.0) end
check(health.broken, "repeated warnings written a few at a time flag the launch too")
io.open = function() return nil, "not found" end
health.reset()
tick(6.0)
check(not health.broken and health.status:find("link missing", 1, true) ~= nil, "no link (manual install): says so instead of staying quiet")
io.open = real_io_open
os.remove(tmp)
health.reset()
end)()

local probe = require("routine_vr.probe")
local probe_props = { { name = "bRaised", kind = "BoolProperty" } }
local function fake_field(i)
    local p = probe_props[i]
    if p == nil then return nil end
    return { get_fname = function() return { to_string = function() return p.name end } end,
             get_class = function() return { get_fname = function() return { to_string = function() return p.kind end } end } end,
             get_next = function() return fake_field(i + 1) end }
end
local probe_cat = { bRaised = false, RootComponent = {} }
probe_cat.get_class = function() return {
    get_fname = function() return { to_string = function() return "RoutineGameCAT" end } end,
    get_child_properties = function() return fake_field(1) end } end
fake.objects["Class /Script/Routine.RoutineGameCAT"] = probe_cat
uevr.api.get_player_controller = function() return nil end
ok, err = pcall(function()
    probe.start()
    probe_cat.bRaised = true
    for _ = 1, 3 do probe.tick(0.1) end
end)
check(ok, "recorder runs against partial objects: " .. tostring(err))
local plines = saved_json["routine_vr_probe.json"] and saved_json["routine_vr_probe.json"].lines or {}
local saw_change = false
for _, l in ipairs(plines) do if l:find("CAT.bRaised false->true", 1, true) then saw_change = true end end
check(saw_change, "recorder logs C.A.T. property changes")
for _ = 1, 400 do probe.tick(0.1) end
check(probe.status:find("Done", 1, true) ~= nil, "recorder stops and saves after 40 s")
fake.objects = {}

-- Body scan / show (motion hands, step 1)
local body = require("routine_vr.body")
local bones = { "root", "spine_01", "hand_r", "index_01_r" }
local arm = { visible = false, owner_no_see = true, bOwnerNoSee = true }
function arm:get_fname() return { to_string = function() return "SkeletalMeshComponent_2147481592" end } end
function arm:get_address() return 0xA11 end
function arm:GetNumBones() return #bones end
function arm:GetBoneName(i) return { to_string = function() return bones[i + 1] end } end
function arm:IsVisible() return self.visible end
function arm:SetVisibility(v) self.visible = v end
function arm:SetOwnerNoSee(v) self.bOwnerNoSee = v end
function arm:SetHiddenInGame() end
arm.SkeletalMesh = { get_full_name = function() return "SkeletalMesh /Game/Characters/SK_Arms.SK_Arms" end }
fake.pawn = { get_address = function() return 0xB0D end, Mesh = arm,
              get_full_name = function() return "Routine_PlayerPawn_C /Game/Maps/Facility.Player" end,
              K2_GetComponentsByClass = function() return { arm } end }
body.scan()
local bj = saved_json["routine_vr_body.json"]
check(bj and #bj.meshes == 1 and bj.meshes[1].bone_count == 4 and bj.meshes[1].bones[3] == "hand_r"
    and bj.meshes[1].asset:find("SK_Arms", 1, true), "body scan: meshes listed once with asset and bone names")
body.set_show(true)
check(arm.visible == true and arm.bOwnerNoSee == false, "show body: visible, also to the player")
body.set_show(false)
check(arm.visible == false and arm.bOwnerNoSee == true, "show body off: back as it was")
fake.pawn = nil

-- Motion hands (spacesuit arms copy, palms on the controllers)
local mh = require("routine_vr.motion_hands")
local function near(a, b) return math.abs(a - b) < 1e-3 end
for _, r in ipairs({ { 10, 20, 30 }, { -45, 170, -60 }, { 80, -90, 5 } }) do
    local p, y, rr = mh.quat_to_rot(mh.rot_to_quat(r[1], r[2], r[3]))
    check(near(p, r[1]) and near(y, r[2]) and near(rr, r[3]), string.format("rotator <-> quat round trip (%d,%d,%d)", r[1], r[2], r[3]))
end
local pl, pr = mh.palm_transform({ X = 100, Y = 0, Z = 50 }, { Pitch = 0, Yaw = 90, Roll = 0 },
    { rot = { 0, 10, 0 }, loc = { 10, 0, 5 } })
check(near(pl.X, 100) and near(pl.Y, 10) and near(pl.Z, 55) and near(pr.Yaw, 100),
    "palm = controller transform then the hand offset in the controller's frame")

local mq = mh.mirror_transform({ q = mh.rot_to_quat(0, 30, 0), t = { x = 5, y = -20, z = 3 } },
    { x = 0, y = 1, z = 0 }, { w = 1, x = 0, y = 0, z = 0 })
local _, myaw = mh.quat_to_rot(mq.q)
check(near(myaw, -30) and near(mq.t.y, 20) and near(mq.t.x, 5), "mirror across the body's middle: yaw and sideways offset flip")

local arms_asset = { get_full_name = function() return "SkeletalMesh /Game/Art/3D/Character/Player/Default/Model/SK_Player_Default_Arms.SK_Player_Default_Arms" end,
                     get_fname = function() return { to_string = function() return "SK_Player_Default_Arms" end } end }
local arms_comp = { SkeletalMesh = arms_asset, GetNumMaterials = function() return 1 end, GetMaterial = function() return "mat" end }
local made = {}
local bone_sets = {}
uevr.api.add_component_by_class = function(self, actor, cls, deferred)
    local c = { cls = cls }
    if cls.name == "Class /Script/Engine.PoseableMeshComponent" then
        function c:SetSkinnedAssetAndUpdate(a) self.asset = a end
        function c:SetMaterial(i, m) self.mat = m end
        function c:K2_GetComponentScale() return { X = 1, Y = 1, Z = 1 } end
        function c:K2_GetComponentRotation() return { Pitch = 0, Yaw = 0, Roll = 0 } end
        function c:SetBoneScaleByName(b, v, space) bone_sets[#bone_sets + 1] = { "scale", b, v.X, space } end
        function c:SetBoneRotationByName(b, r, space) bone_sets[#bone_sets + 1] = { "rot", b, r.Yaw, space, r.Pitch, r.Roll } end
        function c:SetBoneLocationByName(b, v, space) bone_sets[#bone_sets + 1] = { "loc", b, v.X, space, v.Y, v.Z } end
        function c:SetVisibility(v) self.visible = v end
        function c:GetSocketLocation(b) return { X = 7, Y = 8, Z = 9, bone = b } end
        -- Game pose: each forearm bone 10 cm behind its palm, same rotation.
        -- Like the real mesh, the right fingers are modelled pre-curled
        -- (each joint turned 40 deg further than its parent).
        function c:GetBoneTransformByName(b, space)
            local x = b:find("Forearm", 1, true) and -10 or 0
            local y = b:find("_L_", 1, true) and -20 or (b:find("_R_", 1, true) and 20 or 0)
            local n = (b:find("_R_Finger", 1, true) or b:find("_R_Thumb", 1, true)) and tonumber(b:sub(-1)) or 0
            local h = math.rad(40 * n) / 2
            return { Translation = { X = x, Y = y, Z = 0 }, Rotation = { X = 0, Y = 0, Z = math.sin(h), W = math.cos(h) },
                     Scale3D = { X = 1, Y = 1, Z = 1 } }
        end
    else
        function c:K2_GetComponentLocation() return { X = 20, Y = 0, Z = 100 } end
        function c:K2_GetComponentRotation() return { Pitch = 0, Yaw = 30, Roll = 0 } end
    end
    made[#made + 1] = c
    return c
end
fake.objects["Class /Script/Engine.PoseableMeshComponent"] = nil
fake.pawn = { get_address = function() return 0xA3A end,
              get_full_name = function() return "BP_Player_C /Game/Maps/Facility.Player" end,
              Mesh = { AttachChildren = {} },
              K2_GetComponentsByClass = function() return { arms_comp } end }
settings.data.motion_hands = true
settings.data.thumb_wrap, settings.data.thumb_swing_1, settings.data.thumb_swing_2 = 0, 0, 0
settings.data.hand_right = { rot = { 0, 0, 0 }, loc = { 0, 0, 0 } }
settings.data.hand_left = { rot = { 0, 0, 0 }, loc = { 0, 0, 0 } }
mh.reset()
tick(0.2)
local poseable = nil
for _, c in ipairs(made) do if c.asset then poseable = c end end
check(poseable ~= nil and poseable.asset == arms_asset and poseable.mat == "mat", "motion hands: poseable copy of the game's arms, with its materials")
local collapsed, palm_r, palm_l = false, false, false
for _, b in ipairs(bone_sets) do
    if b[1] == "scale" and b[2] == "Bone_Pelvis" and b[3] < 0.01 and b[4] == 1 then collapsed = true end
    if b[1] == "rot" and b[2] == "Bone_Arm_R_Palm" and near(b[3], 30) and b[4] == 0 then palm_r = true end
    if b[1] == "loc" and b[2] == "Bone_Arm_L_Palm" and near(b[3], 20) and b[4] == 0 then palm_l = true end
end
check(collapsed, "body collapsed (pelvis scaled to almost nothing)")
local palm_full, fore_r = false, nil
for _, b in ipairs(bone_sets) do
    if b[1] == "scale" and b[2] == "Bone_Arm_R_Palm" and b[3] == 1 and b[4] == 1 then palm_full = true end
    if b[1] == "loc" and b[2] == "Bone_Arm_R_Forearm_03" and b[4] == 0 then fore_r = b[3] end
end
check(palm_full, "palm put back to full size (location/rotation keep the collapsed scale)")
-- Controller yaw 30 at x=20: 10 cm behind the palm along that heading.
check(fore_r and near(fore_r, 20 - 10 * math.cos(math.rad(30))), "forearm held rigidly behind the palm, as in the game's pose")
local upper_tiny = false
for _, b in ipairs(bone_sets) do
    if b[1] == "scale" and b[2] == "Bone_Arm_R_Upperarm_02" and b[3] < 0.01 and b[4] == 1 then upper_tiny = true end
end
check(upper_tiny, "upper arm shrunk to a point at the elbow, so the sleeve doesn't stretch to the body")

-- Fingers: live game pose (identity joints 3 cm apart) plus curl on input.
arms_comp.GetSocketTransform = function(self, bone, space)
    return { Translation = { X = 3, Y = 0, Z = 0 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 } }
end
local function last_set(kind, bone)
    local v = nil
    for _, b in ipairs(bone_sets) do if b[1] == kind and b[2] == bone then v = b[3] end end
    return v
end
bone_sets = {}
tick(0.2)
local open_yaw = last_set("rot", "Bone_Arm_R_Finger_B_02")
check(open_yaw ~= nil and near(open_yaw, 30), "right hand relaxed like the left (its own modelled pre-curl replaced)")
settings.data.finger_axis = "z"
poll(XINPUT_GAMEPAD_RIGHT_SHOULDER)
bone_sets = {}
tick(0.5)
local curled = last_set("rot", "Bone_Arm_R_Finger_B_02")
check(curled ~= nil and math.abs(curled - 30) > 100, "grip curls the middle finger (two joints, ~160 deg about the bend axis)")
check(near(last_set("rot", "Bone_Arm_R_Finger_A_02"), 30), "index stays open with the trigger released")
check(near(last_set("rot", "Bone_Arm_L_Finger_B_02"), 30), "right grip doesn't curl the left hand")
poll(0)

-- The C.A.T. rides in the right glove at its game socket while it's out.
local attached_to = nil
StructObject = StructObject or { new = function() return {} end }
local cat_root2 = { AttachParent = arms_comp, AttachSocketName = "Socket_Hand_R",
                    get_address = function() return 0xCA7 end,
                    K2_AttachToComponent = function(self, parent, socket, a, b, c, d) attached_to = { parent, socket, a } end,
                    K2_GetComponentLocation = function() return { X = 0, Y = 0, Z = 0 } end,
                    K2_GetComponentRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
                    K2_SetRelativeLocationAndRotation = function(self, l, r) self.rel = { l.X, l.Y, l.Z, r.Yaw } end,
                    RelativeLocation = { X = 1, Y = 2, Z = 3 }, RelativeRotation = { Pitch = 0, Yaw = 5, Roll = 0 } }
fake.objects["Class /Script/Routine.RoutineGameCAT"] = { Pointlight_InspectCAT = { Intensity = 0 }, RootComponent = cat_root2 }
require("routine_vr.input").left_trigger = 255
tick(0.2)
check(attached_to and attached_to[1] == mh.mesh and attached_to[2] == "Socket_Hand_R" and mh.holding_cat,
    "C.A.T. out: attached to the glove at the game's own socket")
check(fake.mc_states[cat_root2] == nil, "...instead of hooked to the controller")
require("routine_vr.input").left_trigger = 0
tick(0.2)
check(attached_to[1] == arms_comp and not mh.holding_cat, "put away: back on the game's arms so the game can lower it")
check(cat_root2.rel and cat_root2.rel[1] == 1 and cat_root2.rel[4] == 5, "...with its own relative offset back")

-- The game's live pose (here: every joint turned 40 deg) only shapes the
-- right hand's grip on the C.A.T., never the thumb or the left hand.
arms_comp.GetSocketTransform = function(self, bone, space)
    local h = math.rad(40) / 2
    return { Translation = { X = 3, Y = 0, Z = 0 }, Rotation = { X = 0, Y = 0, Z = math.sin(h), W = math.cos(h) } }
end
require("routine_vr.input").left_trigger = 255
bone_sets = {}
tick(0.3)
check(mh.holding_cat and math.abs(last_set("rot", "Bone_Arm_R_Finger_B_02") - 30) > 50, "holding the C.A.T.: right fingers take the game's grip")
check(near(last_set("rot", "Bone_Arm_L_Finger_B_02"), 30), "left hand keeps its own (reference) pose when the C.A.T. comes out")
-- Fake model: right thumb joint 02 sits 40 deg past joint 01 (80 deg in all).
check(near(last_set("rot", "Bone_Arm_R_Thumb_02"), 30 + 80), "holding: the right thumb takes the mesh's modelled grip thumb, not the game's")
settings.data.thumb_swing_1 = 0.5
bone_sets = {}
tick(0.1)
local swung = nil
for _, b in ipairs(bone_sets) do if b[1] == "rot" and b[2] == "Bone_Arm_R_Thumb_01" then swung = b end end
check(swung ~= nil and (math.abs(swung[5]) > 5 or math.abs(swung[6]) > 5), "thumb swing moves the thumb's base while holding the C.A.T.")
settings.data.thumb_swing_1 = 0
require("routine_vr.input").left_trigger = 0
tick(0.2)

-- LT no longer raises the C.A.T. (default): kept from the game too.
settings.data.lt_raises_cat = false
tick(0.1)
local lt_state = { Gamepad = { wButtons = 0, bLeftTrigger = 255, bRightTrigger = 0, sThumbLX = 0, sThumbLY = 0, sThumbRX = 0, sThumbRY = 0 } }
callbacks.on_xinput_get_state(0, 0, lt_state)
tick(0.1)
check(lt_state.Gamepad.bLeftTrigger == 0 and not game.raised, "LT doesn't raise the C.A.T. and doesn't reach the game")
settings.data.lt_raises_cat = true
fake.objects = {}
fake.objects = {}
check(palm_r and palm_l, "both palms set to their controllers' world transforms")
check(poseable.visible == true and mh.fingertip("left").bone == "Bone_Arm_L_Finger_A_03", "hands shown; left index fingertip available for touch")
settings.data.motion_hands = false
tick(0.1)
check(mh.mesh == nil and mh.fingertip("left") == nil, "motion hands off: removed")

-- Arms from the body's shoulders: the elbow solver and the placed arm.
local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end
local sh0, wr0 = { x = 0, y = 0, z = 0 }, { x = 30, y = 0, z = 0 }
local el = mh.solve_elbow(sh0, wr0, 20, 20, { x = 0, y = 0, z = -1 })
check(near(dist(el, sh0), 20) and near(dist(el, wr0), 20) and el.z < 0, "elbow: both bone lengths kept, bent toward the pole (down)")
el = mh.solve_elbow(sh0, { x = 100, y = 0, z = 0 }, 20, 20, { x = 0, y = 0, z = -1 })
check(near(el.x, 20) and math.abs(el.z) < 0.5, "out of reach: the arm goes straight toward the hand")
local aq = mh.arc({ x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 })
local _, ay = mh.quat_to_rot(aq)
check(near(ay, 90), "shortest rotation from forward to right is a 90 deg yaw")

local body_comp = { SkeletalMesh = { get_full_name = function() return "SkeletalMesh /Game/Art/3D/Character/Player/Default/Model/SK_Player_Default_Body.SK_Player_Default_Body" end },
                    -- Live body pose: shoulder at z 105, elbow hanging 10 below it.
                    GetSocketTransform = function(self, b, space)
                        local y = b:find("_L_", 1, true) and -20 or 20
                        local z = b:find("Collarbone", 1, true) and 108 or (b:find("Forearm_01", 1, true) and 95 or 105)
                        return { Translation = { X = 10, Y = y, Z = z }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 } }
                    end }
fake.pawn = { get_address = function() return 0xA3B end,
              get_full_name = function() return "BP_Player_C /Game/Maps/Facility.Player" end,
              Mesh = { AttachChildren = {} },
              K2_GetComponentsByClass = function() return { arms_comp, body_comp } end,
              GetActorRightVector = function() return { X = 0, Y = 1, Z = 0 } end,
              GetActorForwardVector = function() return { X = 1, Y = 0, Z = 0 } end }
settings.data.motion_hands, settings.data.show_body, settings.data.arm_ik = true, true, true
mh.reset()
bone_sets = {}
tick(0.2)
local up, fo = nil, nil
for _, b in ipairs(bone_sets) do
    if b[1] == "loc" and b[2] == "Bone_Arm_R_Upperarm_01" then up = { x = b[3], y = b[5], z = b[6] } end
    if b[1] == "loc" and b[2] == "Bone_Arm_R_Forearm_01" then fo = { x = b[3], y = b[5], z = b[6] } end
end
check(up and near(up.x, 10) and near(up.y, 20) and near(up.z, 105), "arm IK: upper arm starts at the body's shoulder")
-- Hand at (20,0,100), shoulder at (10,20,105): just out of the 20 cm reach.
local reach0 = dist({ x = 20, y = 0, z = 100 }, { x = 10, y = 20, z = 105 })
local k0 = math.max(1, reach0 / 20 * 1.001)
check(fo and near(dist(fo, up), 10 * k0), "arm IK: elbow one (stretched-to-reach) upper-arm length from the shoulder")
local col = nil
for _, b in ipairs(bone_sets) do
    if b[1] == "loc" and b[2] == "Bone_Arm_R_Collarbone" then col = { x = b[3], z = b[6] } end
end
check(col and near(col.z, 108), "arm IK: the arm's collarbone sits on the body's own collarbone (no gap)")
-- Out of reach: the arm lengthens (up to 1.5x) instead of the wrist.
fake.pawn.K2_GetComponentsByClass = function() return { arms_comp, body_comp } end
body_comp.GetSocketTransform = function(self, b, space)
    local y = b:find("_L_", 1, true) and -20 or 20
    local z = b:find("Collarbone", 1, true) and 108 or (b:find("Forearm_01", 1, true) and 95 or 105)
    return { Translation = { X = -15, Y = y, Z = z }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 } }
end
bone_sets = {}
tick(0.1)
for _, b in ipairs(bone_sets) do
    if b[1] == "loc" and b[2] == "Bone_Arm_R_Upperarm_01" then up = { x = b[3], y = b[5], z = b[6] } end
    if b[1] == "loc" and b[2] == "Bone_Arm_R_Forearm_01" then fo = { x = b[3], y = b[5], z = b[6] } end
end
check(dist(fo, up) > 10.5, "out of reach: the upper arm lengthens to reach")

-- Put away with motion hands: the C.A.T. hangs on the body's hip.
local att3 = nil
local cat_root3 = { AttachParent = arms_comp, AttachSocketName = "Socket_Hand_R",
                    get_address = function() return 0xCA8 end,
                    K2_AttachToComponent = function(self, parent, socket, a, b, c) att3 = { parent, socket, a, c }; self.AttachParent, self.AttachSocketName = parent, socket; if c == 2 then self.RelativeScale3D = { X = 1, Y = 1, Z = 1 } end end,
                    K2_GetComponentLocation = function() return { X = 0, Y = 0, Z = 0 } end,
                    K2_GetComponentRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
                    K2_SetRelativeLocationAndRotation = function(self, l, r) self.rel = { l.X, l.Y, l.Z } end,
                    RelativeLocation = { X = 0, Y = 0, Z = 0 }, RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 },
                    -- The game draws the C.A.T. scaled down for its first-person view.
                    RelativeScale3D = { X = 0.6, Y = 0.6, Z = 0.6 },
                    SetRelativeScale3D = function(self, v) self.RelativeScale3D = { X = v.X, Y = v.Y, Z = v.Z } end }
fake.objects["Class /Script/Routine.RoutineGameCAT"] = { Pointlight_InspectCAT = { Intensity = 0 }, RootComponent = cat_root3 }
settings.data.cat_holster = true
settings.data.cat_holster_right = { rot = { 0, 0, 0 }, loc = { 4, 5, 6 } }
require("routine_vr.input").left_trigger = 0
tick(0.2)
check(att3 and att3[1] == body_comp and att3[2] == "Bone_Pelvis" and att3[3] == 2 and cat_root3.rel[2] == 5
    and mh.cat_place == "holster", "put away: the C.A.T. snaps to the body's pelvis at the hip offset")
-- The offset is in the character's terms: turned 90 deg, "right" is world -X.
require("routine_vr.input").left_trigger = 255
tick(0.2)
fake.pawn.K2_GetActorRotation = function() return { Pitch = 0, Yaw = 90, Roll = 0 } end
require("routine_vr.input").left_trigger = 0
tick(0.2)
check(near(cat_root3.rel[1], -5) and near(cat_root3.rel[2], 4) and near(cat_root3.rel[3], 6),
    "holster offset follows the character's facing (forward/right/up)")
fake.pawn.K2_GetActorRotation = nil
require("routine_vr.input").left_trigger = 255
tick(0.2)
check(att3[1] == mh.mesh and att3[2] == "Socket_Hand_R" and mh.cat_place == "glove", "raised: from the hip into the glove")
check(not require("routine_vr.hands").is_attached("C.A.T.") and not require("routine_vr.game").cat_hooked,
    "hip -> hand: the controller hook never takes the C.A.T. (it wrote the hip offset back over the glove's)")
check(near(cat_root3.RelativeScale3D.X, 0.6) and att3[3] == 0, "hip -> hand: the C.A.T. keeps the game's scale (wasn't reset to 1 by the hip)")

check(mh.mirror_n ~= nil and mh.mirror_c ~= nil,
    "mirror frame learned with the hands (the left hold and grip need it)")
-- The left glove gets the right glove's hold mirrored across the body,
-- through the skeleton's right-side frame correction c.
local ml, mr = mh.mirror_offset({ 1, 2, 3 }, { 0, 0, 0 }, { x = 0, y = 1, z = 0 }, { w = 1, x = 0, y = 0, z = 0 })
check(near(ml[1], 1) and near(ml[2], -2) and near(ml[3], 3) and near(mr[1], 0) and near(mr[2], 0) and near(mr[3], 0),
    "left glove offset: mirrored across the body")
ml = mh.mirror_offset({ 1, 2, 3 }, { 0, 0, 0 }, { x = 0, y = 1, z = 0 }, { w = 0, x = 1, y = 0, z = 0 })
check(near(ml[1], 1) and near(ml[2], 2) and near(ml[3], -3), "left glove offset: turned by the frame correction")

-- The game takes the C.A.T. back after a cutscene: re-attached, or a new
-- one. It's placed again instead of staying where the game left it.
;(function()
local function addr(v) return function() return v end end
arms_comp.get_address, body_comp.get_address = arms_comp.get_address or addr(0xA1), body_comp.get_address or addr(0xB1)
mh.mesh.get_address = mh.mesh.get_address or addr(0xC1)
require("routine_vr.input").left_trigger = 0
tick(0.2)
check(mh.cat_place == "holster" and cat_root3.AttachParent == body_comp, "(setup) the C.A.T. is on the hip")
cat_root3.AttachParent, cat_root3.AttachSocketName = arms_comp, "Socket_Hand_R"
tick(0.2)
check(cat_root3.AttachParent == body_comp and mh.cat_place == "holster", "the game re-attached the C.A.T.: back on the hip")
local before = att3
local new_root = {}
for k, v in pairs(cat_root3) do new_root[k] = v end
new_root.get_address = function() return 0xCA9 end
new_root.AttachParent, new_root.AttachSocketName = arms_comp, "Socket_Hand_R"
fake.objects["Class /Script/Routine.RoutineGameCAT"].RootComponent = new_root
tick(0.2)
check(new_root.AttachParent == body_comp and mh.cat_place == "holster", "a new C.A.T. after a cutscene: picked up and put on the hip")
new_root.AttachParent, new_root.AttachSocketName = arms_comp, "Socket_Cutscene"
local root2 = {}
for k, v in pairs(new_root) do root2[k] = v end
root2.get_address = function() return 0xCAA end
fake.objects["Class /Script/Routine.RoutineGameCAT"].RootComponent = root2
tick(0.2)
require("routine_vr.input").left_trigger = 255
tick(0.2)
check(root2.AttachParent == mh.mesh and root2.AttachSocketName == "Socket_Hand_R" and mh.cat_place == "glove",
    "found on an odd socket after a cutscene: it still goes to the glove at the hand socket")
-- Zero size after a cutscene (the Ward): restored, and never learned.
local world_scale = 0
root2.K2_GetComponentScale = function() return { X = world_scale, Y = world_scale, Z = world_scale } end
root2.SetRelativeScale3D = function(self, v) self.scale_set = v.X; world_scale = v.X end
root2.RelativeScale3D = { X = 0, Y = 0, Z = 0 }
tick(0.1)
check(root2.scale_set == 0.6 or root2.scale_set == 1, "the C.A.T. left at zero size is put back to its real size")
local root3 = {}
for k, v in pairs(root2) do root3[k] = v end
root3.get_address = function() return 0xCAB end
root3.AttachParent, root3.AttachSocketName = arms_comp, "Socket_Hand_R"
root3.RelativeScale3D = { X = 0, Y = 0, Z = 0 }
root3.scale_set = nil
world_scale = 0
fake.objects["Class /Script/Routine.RoutineGameCAT"].RootComponent = root3
tick(0.2)
check(root3.scale_set == 1, "a C.A.T. found at zero size doesn't teach the mod a zero size")
-- Put away mid-animation: the hip is worked out again once the body moves.
root3.K2_GetComponentScale = nil
require("routine_vr.input").left_trigger = 0
tick(0.2)
check(mh.cat_place == "holster", "(setup) back on the hip")
local real_socket = body_comp.GetSocketTransform
local before_rel = root3.rel and root3.rel[1]
local h = math.rad(90) / 2
body_comp.GetSocketTransform = function(self, b, space)
    local t = real_socket(self, b, space)
    if b == "Bone_Pelvis" then t.Rotation = { X = 0, Y = math.sin(h), Z = 0, W = math.cos(h) } end
    return t
end
tick(0.5)
check(root3.rel ~= nil and math.abs(root3.rel[1] - before_rel) > 1, "the pelvis turned (lying down, standing up): the hip offset is redone")
-- Walking sway: a small turn of the pelvis leaves the hip where it is,
-- even at the tuned near-vertical pitch.
local settled = root3.rel[1]
h = math.rad(100) / 2
tick(0.5)
check(root3.rel[1] == settled, "a small pelvis turn (a walking stride) doesn't move the C.A.T.")
body_comp.GetSocketTransform = real_socket
tick(0.5)
fake.objects["Class /Script/Routine.RoutineGameCAT"].RootComponent = cat_root3
cat_root3.AttachParent, cat_root3.AttachSocketName = arms_comp, "Socket_Hand_R"
tick(0.2)
-- Built while the game's arms were in another pose (on the floor): rebuilt
-- once they settle into a different hold, and only then.
do
    local real_arms = arms_comp.GetSocketTransform
    local function moved(by)
        arms_comp.GetSocketTransform = function(self, b, space)
            local t = real_arms(self, b, space)
            if b == "Socket_Hand_R" then t.Translation.X = t.Translation.X + by() end
            return t
        end
    end
    tick(0.2)
    local n = mh.settle.rebuilds
    local swing = 0
    moved(function() swing = swing + 3; return swing end)
    tick(3.0)
    check(mh.settle.rebuilds == n, "the game's arms still animating: no rebuild yet")
    moved(function() return 6 end)
    tick(4.0)
    check(mh.settle.rebuilds == n + 1 and mh.mesh ~= nil, "arms settled into a different hold: gloves rebuilt from it")
    tick(4.0)
    check(mh.settle.rebuilds == n + 1, "...once: the new hold is now the one they were built from")
    arms_comp.GetSocketTransform = real_arms
    tick(4.0)
end
require("routine_vr.input").left_trigger = 255 -- raised again, as the next tests expect
tick(0.2)
end)()

-- Thumbs curl when the thumb is on the stick or the thumbrest (one action,
-- the binding files add the stick's touch sensor to it) or a face button.
-- (In a function of its own: the main chunk is at Lua's 200-locals limit.)
;(function()
release_all()
check(mh.curl_targets("left").Thumb == 0 and mh.curl_targets("right").Thumb == 0, "thumbs relaxed with nothing touched")
hold("ThumbrestTouchLeft", "right", true) -- UEVR answered the left action under the other hand's query
check(mh.curl_targets("left").Thumb == 1, "left thumb curls on its thumbrest/stick, whichever side UEVR reports it on")
release_all()
hold("ThumbrestTouchRight", "right", true)
check(mh.curl_targets("right").Thumb == 1 and mh.curl_targets("left").Thumb == 0, "right thumb on its stick: only the right curls")
release_all()
hold("BButtonTouchLeft", "left", true)
check(mh.curl_targets("left").Thumb == 1, "left thumb resting on Y: curls")
release_all()
-- A thumb pushing its stick is on it (UEVR has no stick-touch action).
local im = require("routine_vr.input")
im.stick.lx, im.stick.ly = 0, 20000
check(mh.curl_targets("left").Thumb == 1 and mh.curl_targets("right").Thumb == 0, "left stick pushed: left thumb curls")
im.stick.lx, im.stick.ly = 1500, 0
check(mh.curl_targets("left").Thumb == 0, "stick barely off centre: no curl")
im.stick.lx, im.stick.ly, im.stick.rx = 0, 0, -30000
check(mh.curl_targets("right").Thumb == 1, "right stick pushed: right thumb curls")
im.stick.rx = 0
-- The left source handle failing to read must not hide the right one.
local vrp = uevr.params.vr
local real_active, real_left = vrp.is_action_active, vrp.get_left_joystick_source
vrp.get_left_joystick_source = function() return nil end
vrp.is_action_active = function(h, src)
    if src == nil then error("bad argument #2 (userdata expected, got nil)") end
    return real_active(h, src)
end
im.reset()
hold("ThumbrestTouchRight", "right", true)
check(mh.curl_targets("right").Thumb == 1 and im.read_errors.left ~= nil,
    "a left-hand read that errors doesn't stop the right thumb (error kept for the panel)")
vrp.is_action_active, vrp.get_left_joystick_source = real_active, real_left
im.reset()
release_all()
end)()

-- Left-handed: everything to the other hands.
settings.data.handedness = "left"
tick(0.2)
check(att3[1] == mh.mesh and att3[2] == "Bone_Arm_L_Palm" and mh.cat_place == "glove", "left-handed: the C.A.T. moves to the left palm (Socket_Hand_R has no left twin)")
check(fake.mod_values.VR_AimMethod == "3", "left-handed: aim with the left controller")
local lt_state = { Gamepad = { wButtons = 0, bLeftTrigger = 200, bRightTrigger = 0, sThumbLX = 0, sThumbLY = 0, sThumbRX = 0, sThumbRY = 0 } }
callbacks.on_xinput_get_state(0, 0, lt_state)
check(lt_state.Gamepad.bRightTrigger == 200, "left-handed: the left index trigger interacts (sent as RT)")
settings.data.handedness = "right"
require("routine_vr.input").left_trigger = 0
tick(0.2)
check(fake.mod_values.VR_AimMethod == "2", "back to right-handed: right controller aim")
fake.objects = {}
settings.data.motion_hands = false
tick(0.1)
fake.pawn = nil
fake.pawn = nil

---------------------------------------------------------------------------
-- Settings file with wrong-typed values (empty tables saved as null)
---------------------------------------------------------------------------

saved_json["routine_vr.json"] = { hand_right = "null", attachments = 0, snap_turn = false }
settings.load()
check(type(settings.get("hand_right")) == "table" and type(settings.get("attachments")) == "table",
    "wrong-typed saved values fall back to defaults")
check(settings.get("snap_turn") == false, "correctly typed saved values kept")

saved_json["routine_vr.json"] = { attachments = {
    { name = "CameraComponent", hand = "right", rot = { 0, 0, 0 }, loc = { -30, 3, -15 } } } }
settings.load()
local ma = settings.get("attachments")
check(#ma == 2 and ma[1].loc[1] == 0 and ma[2].name == "C.A.T." and settings.get("attachments_layout") == 2,
    "old layout migrated: camera offset cleared, C.A.T. attached on its own")
ma[2].loc = { 5, 0, 0 }
saved_json["routine_vr.json"] = { attachments = ma, attachments_layout = 2 }
settings.load()
check(settings.get("attachments")[2].loc[1] == 5, "migrated layout left alone after that")
saved_json["routine_vr.json"] = { cat_holster_right = { rot = { 0, 0, 0 }, loc = { 0, 0, 0 } },
                                  cat_holster_left = { rot = { 0, 0, 0 }, loc = { 3, 0, 0 } } }
settings.load()
check(settings.get("cat_holster_right").loc[2] == 24.2 and settings.get("cat_holster_left").loc[1] == 3,
    "old zero holster offset takes the new hip default; a tuned one is kept")
saved_json["routine_vr.json"] = { crouch_button = "X", crouch_drop = 0.35 }
settings.load()
check(settings.get("crouch_button") == "B" and settings.get("crouch_drop") == 0.25 and settings.get("physical_crouch") == true,
    "saved crouch on X (never crouched) moves to B, the old 35 cm duck to 25 cm, and crouch comes on")
saved_json["routine_vr.json"] = { crouch_layout = 3, physical_crouch = false }
settings.load()
check(settings.get("physical_crouch") == false, "crouch turned off after it was on by default: stays off")
saved_json["routine_vr.json"] = { device = "quest_touch" }
settings.load()
check(settings.get("device") == "auto", "old saved Touch default moves to auto-detect")
saved_json["routine_vr.json"] = { device = "index_knuckles", device_layout = 2 }
settings.load()
check(settings.get("device") == "index_knuckles", "a layout picked by hand is kept")
saved_json["routine_vr.json"] = { cat_inspect = { hand = "right", rot = { 0, 0, 0 }, loc = { 0, 0, 0 } }, cat_inspect_layout = 2 }
settings.load()
check(settings.get("cat_inspect").hand == "left" and settings.get("cat_inspect").rot[2] == -90
    and settings.get("cat_inspect_layout") == 3, "layout-2 right-hand inspect default goes back to the left hand")
saved_json["routine_vr.json"] = { cat_inspect = { hand = "right", rot = { 0, 20, 0 }, loc = { 0, 0, 0 } }, cat_inspect_layout = 2 }
settings.load()
check(settings.get("cat_inspect").hand == "right", "a tuned inspect pose is kept")

;(function()
    local grab = require("routine_vr.grab")
    local function near(a, b) return math.abs(a - b) < 0.05 end

    local angle, len = grab.off_line(100, 0, 0)
    check(near(angle, 0) and near(len, 100), "dead ahead is 0 degrees off")
    angle, len = grab.off_line(100, 100, 0)
    check(near(angle, 45), "off to the side measures the angle")

    local f_axis, r_axis, u_axis = grab.axes(0, 90, 0)
    check(near(f_axis.y, 1) and near(r_axis.x, -1) and near(u_axis.z, 1), "rotator axes: yaw 90 faces +Y")
    local f2, r2, u2 = grab.to_hand({ X = 10, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 90, Roll = 0 }, { x = 10, y = 50, z = 5 })
    check(near(f2, 50) and near(r2, 0) and near(u2, 5), "world point into the hand's frame")

    local list = {
        { f = 100, r = 30, u = 0, reach = 200, key = 1 }, -- about 17 deg off
        { f = 100, r = 12, u = 0, reach = 200, key = 2 }, -- about 7 deg off
    }
    local best = grab.choose(list, 12, nil)
    check(best and best.key == 2, "the thing closest to the line wins")
    local picked = grab.pick(list, 20, nil, function(c) return c.key == 2 end)
    check(picked and picked.key == 1, "something walled off gives way to the next closest")
    check(grab.pick({ list[2] }, 20, nil, function() return true end) == nil, "only something walled off: no target, trigger stays the game's")
    check(grab.choose({ list[1] }, 12, nil) == nil, "too far off isn't picked")
    check(grab.choose({ list[1] }, 14, 1) ~= nil, "a picked target stays a little past the cone")
    check(grab.choose({ { f = 300, r = 0, u = 0, reach = 200, key = 3 } }, 12, nil) == nil, "out of the game's reach isn't picked")
end)()

;(function()
    local held = require("routine_vr.held")
    local real_find, real_list = uevr.api.find_uobject, UEVR_UObjectHook.get_objects_by_class
    local cls = {}
    local inspecting, lerping, game_scale = true, true, { X = 0.1, Y = 0.1, Z = 0.1 }
    local sets, moved, turned = 0, nil, nil
    local game_rot = { Pitch = 0, Yaw = 30, Roll = 0 }
    local motion_hands = require("routine_vr.motion_hands")
    local real_pose, real_struct = motion_hands.controller_pose, StructObject
    motion_hands.controller_pose = function()
        return { X = 100, Y = 20, Z = 30 }, { Pitch = 0, Yaw = 0, Roll = 0 }
    end
    StructObject = { new = function() return {} end }
    local actor = {
        K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
        K2_GetActorRotation = function() return { Pitch = game_rot.Pitch, Yaw = game_rot.Yaw, Roll = game_rot.Roll } end,
        K2_SetActorLocationAndRotation = function(_, v, r)
            moved = { X = v.X, Y = v.Y, Z = v.Z }
            turned = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
        end,
        IsInspecting = function() return inspecting end,
        IsLerping = function() return lerping end,
        GetNativeTransform = function() return { Scale3D = { X = 1, Y = 1, Z = 1 } } end,
        GetActorScale3D = function() return { X = game_scale.X, Y = game_scale.Y, Z = game_scale.Z } end,
        SetActorScale3D = function(_, v) sets = sets + 1; game_scale = { X = v.X, Y = v.Y, Z = v.Z } end,
        K2_GetRootComponent = function() return nil end,
        get_class = function() return { get_fname = function() return { to_string = function() return "Paper" end } end } end,
    }
    uevr.api.find_uobject = function() return cls end
    UEVR_UObjectHook.get_objects_by_class = function() return { actor } end
    local saved_size = settings.get("held_size")
    settings.set("held_size", 2.0)
    local saved_offset, saved_rot = settings.get("held_offset"), settings.get("held_rot")
    settings.set("held_offset", { 8.0, 0.0, 10.0 })
    settings.set("held_rot", false)

    held.reset()
    held.tick(0.25)
    check(held.active == actor and game_scale.X == 2.0, "picked up: full size from the start of the flight")
    check(moved == nil, "not moved while it flies to the hand")
    lerping = false
    held.tick(0.016)
    held.apply(true)
    check(moved ~= nil and math.abs(moved.X - 108) < 0.01 and math.abs(moved.Y - 20) < 0.01 and math.abs(moved.Z - 40) < 0.01,
        "in the hand: placed off the controller by the offset")
    game_scale = { X = 0.1, Y = 0.1, Z = 0.1 }
    held.apply()
    check(game_scale.X == 2.0, "the game shrinking it again is undone")

    local function turned_like(p, y, r)
        return turned and math.abs(turned.Pitch - p) < 0.1 and math.abs(turned.Yaw - y) < 0.1 and math.abs(turned.Roll - r) < 0.1
    end
    check(turned_like(0, 30, 0), "no saved hold: keeps the game's turn")
    check(held.save_hold() and settings.get("held_rot") ~= false, "a hold can be saved")
    settings.set("held_rot", { math.cos(math.rad(45)), 0, 0, math.sin(math.rad(45)) }) -- yaw 90 in the hand
    game_rot = { Pitch = 0, Yaw = 30, Roll = 0 }
    held.apply(true)
    check(turned_like(0, 90, 0), "saved hold replaces the game's turn")
    game_rot = { Pitch = 0, Yaw = 40, Roll = 0 }
    held.apply(true)
    check(turned_like(0, 100, 0), "the stick still turns it from the saved hold")
    local before = turned
    game_rot = { Pitch = turned.Pitch, Yaw = turned.Yaw, Roll = turned.Roll }
    held.apply(true)
    check(turned_like(before.Pitch, before.Yaw, before.Roll), "if the game didn't touch it this frame, nothing drifts")
    settings.set("held_rot", false)

    moved = nil
    lerping = true
    held.tick(0.016)
    check(held.active == actor and moved == nil and game_scale.X == 2.0, "flying back: kept full size, not moved")
    lerping, inspecting = false, false
    held.tick(0.016)
    check(held.active == nil and game_scale.X == 1.0, "put down: back to world size")
    motion_hands.controller_pose = real_pose
    StructObject = real_struct

    settings.set("held_size", saved_size)
    settings.set("held_offset", saved_offset)
    settings.set("held_rot", saved_rot)
    uevr.api.find_uobject, UEVR_UObjectHook.get_objects_by_class = real_find, real_list
    held.reset()
end)()

---------------------------------------------------------------------------

print(string.format("%d passed, %d failed", passes, failures))
os.exit(failures == 0 and 0 or 1)
