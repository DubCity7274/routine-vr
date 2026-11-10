-- What's specific to ROUTINE's classes and widgets. Techniques from the
-- community UEVR profile (scripts/routine.lua there), reworked to fit
-- this mod's modules.
--
--   * modes: main menu, pre-rendered cutscene, gameplay. Cutscenes play on
--     UEVR's 2D screen; menus and cutscenes get plain aim, no room-scale and
--     no UObjectHook attachments.
--   * the C.A.T.: Routine hangs the first-person C.A.T. off the pawn's
--     CameraComponent, and traces interactions from that camera. Both go on
--     the right controller (hands.lua defaults): the camera with no offset,
--     so you point and click from your hand, and the C.A.T. actor's root
--     ("C.A.T." in the Hands panel) on its own, like the community profile's
--     grip attachment. It's only on the hand while LT is held (raised) or
--     while inspecting; otherwise it goes back to the game's lowered pose,
--     so it can be put away. While the C.A.T.'s inspect light is on, only
--     the C.A.T. moves, to the cat_inspect placement (left hand, turned so
--     the side buttons face you). Touch presses (touch.lua) work while it's
--     just raised, so inspect is optional.
--   * the right grip raises the C.A.T. too (hold or toggle), by sending LT.
--   * hides the ID card, helmet and body-mesh attachments that float in
--     front of the HMD.
--   * keeps UEVR's camera offsets at 0. Holding RT with UEVR's menu open
--     turns the sticks into a camera-offset control, which is how the view
--     ended up ~100 m outside the map. vr.get_mod_value throws in this UEVR
--     build, so the offsets are written blind every check.

local hands = require("routine_vr.hands")
local input = require("routine_vr.input")
local settings = require("routine_vr.settings")
local movement = require("routine_vr.movement")
local hip = require("routine_vr.hip")
local handed = require("routine_vr.handed")
local body = require("routine_vr.body")

local M = {}

M.CAT = "C.A.T."

local vr = uevr.params.vr
local api = uevr.api

local CHECK_INTERVAL = 0.5
local INSPECT_LIGHT_ON = 0.01
local LT_RAISED = 40    -- of 255

local grip_was = false
local grip_toggled = false
local grip_drawn = false   -- "hip": grip started at the holster, held since

local CLASS = {
    cat = "Class /Script/Routine.RoutineGameCAT",
    cine_video = "WidgetBlueprintGeneratedClass /Game/UI/Game/Cine/RUI_Cine_Video.RUI_Cine_Video_C",
    id_card = "BlueprintGeneratedClass /Game/Blueprint/Equipment/ID/Routine_ID.Routine_ID_C",
    helmet = "BlueprintGeneratedClass /Game/Blueprint/Equipment/Helmet/Routine_Helmet.Routine_Helmet_C",
}

M.mode = nil            -- "menu" | "cutscene" | "game"
M.inspecting = false
M.raised = false
M.cat_on_glove = false
M.cat_hooked = false
-- Body follow state (update_body_follow), declared here because
-- refresh_hands, further up, resets it.
local follow_last = nil
local follow_pending = 0.0
local follow_pause = 0.0
M.cat_managed = false        -- motion hands place the C.A.T. (glove/hip/home), not the controller hook

local classes = {}
local timer = CHECK_INTERVAL
local hidden_pawn = nil

local function class(key)
    local c = classes[key]
    if c == nil then
        c = api:find_uobject(CLASS[key])
        classes[key] = c
    end
    return c
end

local function first_of(key)
    local c = class(key)
    if c == nil then return nil end
    return UEVR_UObjectHook.get_first_object_by_class(c, false)
end

-- A cutscene video is on screen. The game can keep the video widget
-- alive after the video ends (seen after loading a save or starting a new
-- game), so a widget merely existing left the mod stuck in cutscene mode:
-- flat screen, default controls. Only a widget in the viewport and visible
-- counts; one that can't be asked counts as playing, as before.
local function widget_showing(w)
    local ok_v, in_view = pcall(function() return w:IsInViewport() end)
    if ok_v and in_view == false then
        -- Not on the viewport itself: still showing if it's inside another
        -- widget (removing it from the screen clears both).
        local ok_p, parent = pcall(function() return w:GetParent() end)
        if not ok_p or parent == nil then return false end
    end
    local ok_s, visible = pcall(function() return w:IsVisible() end)
    if ok_s and visible == false then return false end
    return true
end

local function cine_playing()
    local c = class("cine_video")
    if c == nil then return false end
    local ok, all = pcall(function() return UEVR_UObjectHook.get_objects_by_class(c, false) end)
    if ok and type(all) == "table" then
        for _, w in ipairs(all) do
            if w ~= nil and widget_showing(w) then return true end
        end
        return false
    end
    local w = first_of("cine_video")
    return w ~= nil and widget_showing(w)
end

M.main_menu = false     -- the game's main menu is up (roomscale.lua recenters on it)

local function detect_mode()
    M.main_menu = false
    local pawn = api:get_local_pawn(0)
    if pawn == nil then return "menu" end

    local ok, name = pcall(function() return pawn:get_full_name() end)
    if ok and type(name) == "string" and name:find("Menu_Main", 1, true) then
        M.main_menu = true
        return "menu"
    end

    if settings.get("cutscene_mode") and cine_playing() then return "cutscene" end
    return "game"
end

local MODE_VALUES = {
    menu     = { VR_2DScreenMode = "false", VR_AimMethod = "0", VR_RoomscaleMovement = "false", VR_DecoupledPitch = "false" },
    cutscene = { VR_2DScreenMode = "true",  VR_AimMethod = "0", VR_RoomscaleMovement = "false", VR_DecoupledPitch = "false" },
    game     = { VR_2DScreenMode = "false", VR_AimMethod = "2", VR_RoomscaleMovement = "true",  VR_DecoupledPitch = "true" },
}

local function enter_mode(mode)
    M.mode = mode
    movement.force_menu = mode ~= "game"
    print("[routine_vr] mode: " .. mode)


    for key, value in pairs(MODE_VALUES[mode]) do
        vr.set_mod_value(key, value)
    end
    -- Left-handed: aim with the left controller (UEVR AimMethod 3).
    if mode == "game" and handed.is_left() then vr.set_mod_value("VR_AimMethod", "3") end
    UEVR_UObjectHook.set_disabled(mode ~= "game")
    hidden_pawn = nil
end

local function hide(obj, field)
    if obj == nil then return end
    pcall(function()
        local mesh = obj[field]
        if mesh ~= nil and mesh:IsVisible() then mesh:SetVisibility(false, false) end
    end)
end

local function asset_name(comp)
    local ok, n = pcall(function()
        local a = comp.SkeletalMesh or comp:GetSkeletalMeshAsset()
        return a:get_full_name()
    end)
    return ok and n or ""
end

-- The suit under you (settings.show_body): the game's body mesh
-- (SK_Player_Default_Body, the identification unit on the chest) stays
-- visible with its head and neck hidden, so the view isn't from inside
-- them. The game's arms stay hidden (motion_hands.lua makes the gloves),
-- and so does the helmet. The ID card is left alone then: the story has
-- you look down at it.
-- Anything visible hanging off the game camera: the camera rides on the
-- right controller, so it would float in your hand. The helmet is one, and
-- the late-game save showed a helmet the single-instance hide missed, so
-- every child is hidden except lights (the player's light) and the
-- camera's widget interaction.
local function hide_camera_children(pawn)
    pcall(function()
        for _, child in ipairs(pawn.CameraComponent.AttachChildren) do
            if child ~= nil then
                local cls = ""
                pcall(function() cls = child:get_class():get_fname():to_string() end)
                if not cls:find("Light", 1, true) and not cls:find("WidgetInteraction", 1, true) then
                    pcall(function()
                        if child:IsVisible() then child:SetVisibility(false, true) end
                    end)
                end
            end
        end
    end)
end

local function hide_clutter(pawn)
    hide_camera_children(pawn)
    local show_body = settings.get("show_body")
    if show_body then
        local card = first_of("id_card")
        pcall(function()
            if card ~= nil and not card.StaticMesh:IsVisible() then card.StaticMesh:SetVisibility(true, false) end
        end)
    else
        hide(first_of("id_card"), "StaticMesh")
    end
    hide(first_of("helmet"), "SkeletalMesh")
    if body.showing then return end -- "Show body" in the panel (body.lua)

    local addr = pawn:get_address()
    if addr == hidden_pawn then return end
    hidden_pawn = addr
    pcall(function()
        for _, child in ipairs(pawn.Mesh.AttachChildren) do
            if child ~= nil then
                if show_body and asset_name(child):find("_Body", 1, true) then
                    pcall(function() child:SetVisibility(true, false) end)
                    pcall(function() child:SetOwnerNoSee(false) end)
                    pcall(function() child:HideBoneByName("Bone_Neck", 0) end)
                else
                    child:SetVisibility(false, false)
                end
            end
        end
    end)
end

-- C.A.T. inspect: the C.A.T. to the left hand; the camera (the pointer)
-- stays on the right.
local function update_inspect()
    local inspecting = false
    local cat = first_of("cat")
    if cat ~= nil then
        local ok, intensity = pcall(function() return cat.Pointlight_InspectCAT.Intensity end)
        inspecting = ok and type(intensity) == "number" and intensity > INSPECT_LIGHT_ON
    end

    M.inspecting = inspecting
end

local function find_saved(name)
    for _, a in ipairs(settings.get("attachments")) do
        if a.name == name then return a end
    end
    return nil
end

-- The hooks that follow handedness: the camera (the pointer) and the
-- C.A.T. on the main hand, and the inspect pose on the off hand (mirrored
-- for left-handers). Only touched when something changes.
local applied_hands = nil
local function update_hand_overrides()
    local left = handed.is_left()
    local key = tostring(left) .. "/" .. tostring(M.inspecting)
    if key == applied_hands then return end
    applied_hands = key

    local cam = find_saved("CameraComponent")
    hands.set_override("CameraComponent", (left and cam) and { hand = "left", rot = cam.rot, loc = cam.loc } or nil)

    if M.inspecting then
        local p = settings.get("cat_inspect")
        if left then
            p = { hand = p.hand == "left" and "right" or "left", loc = { p.loc[1], -p.loc[2], p.loc[3] },
                  rot = { p.rot[1], -p.rot[2], -p.rot[3] } }
        end
        hands.set_override(M.CAT, p)
    else
        local c = find_saved(M.CAT)
        hands.set_override(M.CAT, (left and c) and { hand = "left", rot = c.rot, loc = c.loc } or nil)
    end
    if M.mode == "game" then vr.set_mod_value("VR_AimMethod", left and "3" or "2") end
end

-- Panel changes to the inspect pose re-apply it.
function M.refresh_hands()
    applied_hands = nil
    M.follow_active, follow_last = false, nil
    follow_pending = 0.0
end

local OFFSETS = { "VR_CameraForwardOffset", "VR_CameraRightOffset", "VR_CameraUpOffset" }

local function guard_offsets()
    for _, key in ipairs(OFFSETS) do
        vr.set_mod_value(key, "0.000000")
    end
end

-- Right grip raises the C.A.T. (hold, or press to toggle), by sending LT.
-- UEVR maps the grip to RB (lean), so RB is dropped while it's used.
-- Y opens the game's menu (settings.y_opens_menu): inspect isn't needed now
-- that the C.A.T.'s buttons are pressed by touch. A short tap sends Start;
-- a longer hold, or one with B held too (the recenter chord), sends
-- nothing.
local Y_TAP = 0.4
local START_PULSE = 0.12
local y_held_for = nil     -- seconds Y has been down, nil when up
local y_chord = false      -- B was held during this Y press

local seen_y, seen_b = false, false

local function update_y_menu(delta)
    input.start_pulse = math.max(0, input.start_pulse - delta)
    -- Y and B as UEVR sent them to the game (any poll since the last tick;
    -- unchanged when the game didn't poll). UEVR's direct reads of the face
    -- buttons always read false here, so a tap was never seen.
    local bits = input.take_seen()
    if bits ~= nil then
        seen_y, seen_b = bits & XINPUT_GAMEPAD_Y ~= 0, bits & XINPUT_GAMEPAD_B ~= 0
    end
    local on = settings.get("y_opens_menu")
    input.y_to_menu = on
    if not on then
        y_held_for = nil
        return
    end
    local b = input.device and input.device.buttons
    local y = seen_y or (b ~= nil and input.any_held(b.Y))
    if y then
        y_held_for = (y_held_for or 0) + delta
        if seen_b or (b ~= nil and input.any_held(b.B)) then y_chord = true end
    elseif y_held_for ~= nil then
        if y_held_for < Y_TAP and not y_chord then input.start_pulse = START_PULSE end
        y_held_for, y_chord = nil, false
    end
end

local function update_grip()
    local mode = settings.get("cat_grip")
    -- The main hand's grip: what UEVR sends (LB = left grip, RB = right),
    -- or for the right grip UEVR's direct read, which proved reliable (the
    -- left one's didn't: it read held while only the right grip was).
    local left = handed.is_left()
    local bit = left and XINPUT_GAMEPAD_LEFT_SHOULDER or XINPUT_GAMEPAD_RIGHT_SHOULDER
    local b = input.device and input.device.buttons
    input.right_grip = b ~= nil and input.any_held(b.RB)
    input.main_grip_bit = bit
    hip.tick()
    local main_held = (input.xi_in or 0) & bit ~= 0 or (not left and input.right_grip)
    local held = M.mode == "game" and mode ~= "off" and main_held
    if mode == "toggle" then
        if held and not grip_was then grip_toggled = not grip_toggled end
    else
        grip_toggled = false
    end
    -- Hip: the grip has to close at the holster; then the C.A.T. stays out
    -- for as long as the grip is held, wherever the hand goes.
    if mode == "hip" then
        if held and not grip_was then grip_drawn = hip.at_hip end
        if not held then grip_drawn = false end
    else
        grip_drawn = false
    end
    if M.mode ~= "game" then grip_toggled, grip_drawn = false, false end
    grip_was = held

    M.grip_raise = (mode == "hold" and held) or (mode == "toggle" and grip_toggled) or (mode == "hip" and grip_drawn)
    input.force_lt = M.grip_raise
    input.clear_rb = M.mode == "game" and mode ~= "off"
    input.block_lt = M.mode == "game" and not settings.get("lt_raises_cat")
    local lean = settings.get("lean_button")
    input.lean = (M.mode == "game" and (lean == "trigger" or lean == "grip")) and lean or nil
    input.focus = input.block_lt and settings.get("lt_focus") and lean ~= "trigger"
    input.swap_triggers = M.mode == "game" and handed.is_left()
end

-- With the C.A.T. out, Routine's aim mode filters right-stick turning
-- into a slow turn that ramps up (its precise-aim deadzone; switching the
-- DeadzoneComponent's tick off didn't change it). While it's out, the
-- stick's X is hidden from the game and the mod turns the player itself
-- at a steady speed with AddYawInput, like the game's own turn input.
local TURN_DEADZONE = 0.15
-- First try: AddYawInput did nothing in game (no turning at all with the
-- C.A.T. out), probably because Routine ignores look input while aiming.
-- So each way of turning is checked: after CHECK_DEGREES of asked-for turn,
-- if the pawn turned less than CHECK_RATIO of it, the next method is tried.
-- "game" hands the stick back to Routine's own (slow) aim turn, so turning
-- never stops working.
-- The game-side methods all failed in the headset (Routine's aim mode
-- overrides them), so "vr_view" comes first: it turns UEVR's rotation
-- offset (what recentering sets), outside the game. Movement follows the
-- head and aim follows the hand, so both turn with it. It can't be
-- checked against the game camera, so it's trusted unless it errors.
-- AddYawInput, SetControlRotation and turning the root component were all
-- tried and never turned Routine's character. The recorder found Routine's
-- own RoutineGameViewComponent (pawn.ViewComponent) with Get/Set/
-- AddViewRotation: that's tried first, and checked against the
-- character's yaw. If it works there's no view offset and so nothing to
-- hand over later.
local TURN_METHODS = { "view_rotation", "vr_view", "game" }
local CHECK_DEGREES = 20.0
local CHECK_RATIO = 0.3

M.turn_method = 1
M.turn_verified = false
local asked, turned, last_yaw = 0.0, 0.0, nil

-- The character's facing. (The camera manager's yaw only read now and
-- then, and moved with hand aim, which caused small snaps.)
local function view_yaw()
    local pawn = api:get_local_pawn(0)
    if pawn == nil then return nil end
    local ok, y = pcall(function() return pawn:K2_GetActorRotation().Yaw end)
    return ok and y or nil
end

-- Turn the character through Routine's own view component.
local function turn_body(yaw)
    local vc = api:get_local_pawn(0).ViewComponent
    local r = vc:GetViewRotation()
    r.Yaw = r.Yaw + yaw
    vc:SetViewRotation(r)
end

local function yaw_diff(a, b)
    local d = (a - b) % 360
    if d > 180 then d = d - 360 end
    return d
end

local offset_q = nil

-- Turn the VR view by yaw degrees (UE sense) through UEVR's rotation offset.
local function turn_view(yaw)
    if offset_q == nil then offset_q = UEVR_Quaternionf.new() end
    vr.get_rotation_offset(offset_q)
    local cur = { w = offset_q.w, x = offset_q.x, y = offset_q.y, z = offset_q.z }
    local sign = settings.get("cat_turn_reverse") and -1 or 1
    local q = hands.qmul(hands.rotator_to_quat(0, yaw * sign, 0), cur)
    offset_q.w, offset_q.x, offset_q.y, offset_q.z = q.w, q.x, q.y, q.z
    vr.set_rotation_offset(offset_q)
end

-- The view turn isn't the character's: it still faces the old way, so the
-- game reads forward as backward (no sprint). SetControlRotation and
-- AddYawInput don't turn Routine's character even with the C.A.T. lowered
-- (it has its own native View/Control components); only the right stick
-- does. So once the C.A.T. is lowered the turn is handed over by pushing
-- the stick for the player and turning the VR view back by exactly what
-- the game turns each frame, so the world holds still while the
-- character catches up underneath.
--
-- Which yaw reading follows the game's turn isn't known, so several are
-- watched for the first frames and the one that moved most is used.
M.view_turn = 0.0          -- degrees the view has turned that the character hasn't
M.last_handover = nil
local PICK_FRAMES = 8
local MAX_FRAMES = 900
-- Close enough: what's left stays on the view (a few degrees of desync is
-- harmless). Starting and finishing use the same threshold so a leftover
-- never starts another handover.
local HANDOVER_DONE = 5.0
-- The weakest push that still turns the game: at ~25% of the stick the
-- game stopped turning (its deadzone) and the handover hung there,
-- holding the stick so the player couldn't turn.
local MIN_PUSH = 0.45
local STALL_FRAMES = 20
local PLAYER_STICK = 0.3
local handover = nil
local handover_blocked = false  -- the game didn't turn: wait for the next raise

-- Only the character's yaw: the camera and control readings either didn't
-- read or followed hand aim, and picking them made the view snap a little.
local YAW_READINGS = {
    actor = function(pc, pawn) return pawn:K2_GetActorRotation().Yaw end,
}

local function read_yaws()
    local pc, pawn = api:get_player_controller(0), api:get_local_pawn(0)
    local out = {}
    for name, fn in pairs(YAW_READINGS) do
        local ok, y = pcall(fn, pc, pawn)
        if ok and type(y) == "number" then out[name] = y end
    end
    return out
end

function M.yaw_readings_text()
    local parts = {}
    for name, y in pairs(read_yaws()) do parts[#parts + 1] = string.format("%s=%.1f", name, y) end
    table.sort(parts)
    return table.concat(parts, " ")
end

local function stop_handover(result)
    input.inject_rx = nil
    if result then
        M.last_handover = result
        print("[routine_vr] C.A.T. turn handover: " .. result)
    end
    handover = nil
end

local function start_handover()
    if math.abs(M.view_turn) < HANDOVER_DONE then return end
    local now = read_yaws()
    -- Actor yaw is the one that followed in the headset; start with it so
    -- the view is held from the first frame, and switch if another moves.
    local reading = now.actor and "actor" or nil
    handover = { frames = 0, idle = 0, last = now, sums = {}, start = M.view_turn,
                 reading = reading, comp_last = reading and now[reading] or nil, picked = false }
    -- Try turning the character all at once through its view component;
    -- the stereo-view correction takes the view back in the same frame
    -- the character turns. If it does nothing, the stick push below does
    -- the job as before.
    pcall(turn_body, M.view_turn)
end

-- Hold the view still: called just before UEVR calculates each frame's
-- view (routine_vr.lua), so the correction lands in the same frame the
-- game turned. Done in the engine tick it lagged a frame and the whole
-- view jittered while the character turned.
-- The body follows the head (settings.body_follow). Physically turning
-- turns only the VR view, so the character, its body and shoulders and the
-- hip holster stayed facing the old way. When the head is more than the
-- dead zone away from the character's facing, the character turns toward
-- it through its view component, and on_stereo_view turns the VR view back
-- by the character's measured turn in the same frame: the world holds
-- still and only the body catches up. Off while the stick turns (that
-- turn is meant to move the view) and during a C.A.T. handover.
local hmd_pos = UEVR_Vector3f.new()
local hmd_rot = UEVR_Quaternionf.new()
local follow_q = nil
M.follow_active = false

-- How far the head is turned from the character's facing, in degrees
-- (UE sense, right positive), or nil.
function M.head_yaw()
    local ok, yaw = pcall(function()
        vr.get_pose(vr.get_hmd_index(), hmd_pos, hmd_rot)
        if follow_q == nil then follow_q = UEVR_Quaternionf.new() end
        vr.get_rotation_offset(follow_q)
        local q = hands.qmul({ w = follow_q.w, x = follow_q.x, y = follow_q.y, z = follow_q.z },
                             { w = hmd_rot.w, x = hmd_rot.x, y = hmd_rot.y, z = hmd_rot.z })
        local f = hands.rotate(q, { x = 0, y = 0, z = -1 })
        if f.x * f.x + f.z * f.z < 1e-6 then return nil end -- looking straight up/down
        return math.deg(math.atan(f.x, -f.z))
    end)
    return ok and yaw or nil
end

-- Turns body follow asked for that the view hasn't taken back yet. The
-- view only ever undoes these: undoing every change of the character's
-- facing also undid the game's own turns (onto a ladder, while leaning),
-- which pushed the head past the dead zone again and spun you around.
local LEAN_PAUSE = 0.5          -- s of no body follow after a lean ends
-- CharacterMovement modes the game drives itself (ladders): flying, custom.
local GAME_MOVED = { [5] = true, [6] = true }

local function game_moving_pawn()
    local pawn = api:get_local_pawn(0)
    if pawn == nil then return false end
    local ok, mode = pcall(function() return pawn.CharacterMovement.MovementMode end)
    return ok and GAME_MOVED[mode] == true
end

local function update_body_follow(delta)
    M.follow_active = false
    follow_pause = math.max(0, follow_pause - delta)
    if input.diag.rb_out then follow_pause = LEAN_PAUSE end -- leaning
    if not settings.get("body_follow") or M.mode ~= "game" or handover ~= nil
        or follow_pause > 0 or math.abs(input.right_stick_x() or 0) > TURN_DEADZONE
        or game_moving_pawn() then
        follow_pending = 0.0
        return
    end
    local rel = M.head_yaw()
    if rel == nil then return end
    M.follow_active = true
    local dz = settings.get("body_follow_deadzone")
    if math.abs(rel) <= dz then return end
    local excess = rel - (rel > 0 and dz or -dz)
    local max = settings.get("body_follow_speed") * delta
    local step = math.max(-max, math.min(max, excess))
    if pcall(turn_body, step) then
        -- Never more than a few frames' worth outstanding.
        follow_pending = math.max(-3 * max, math.min(3 * max, follow_pending + step))
    end
end

function M.on_stereo_view(view_index)
    if view_index ~= 0 then return end
    -- Body follow: undo, on the view, whatever the character turned.
    local y = view_yaw()
    if y ~= nil then
        if follow_pending ~= 0 and follow_last ~= nil then
            -- Only the part of the change that body follow asked for.
            local d = yaw_diff(y, follow_last)
            local c = 0
            if d * follow_pending > 0 then
                c = math.abs(d) < math.abs(follow_pending) and d or follow_pending
            end
            if c ~= 0 then
                pcall(turn_view, -c)
                follow_pending = follow_pending - c
            end
        end
        follow_last = y
    end

    local h = handover
    if h == nil or h.reading == nil or h.comp_last == nil then return end
    local fn = YAW_READINGS[h.reading]
    local ok, y = pcall(fn, api:get_player_controller(0), api:get_local_pawn(0))
    if not ok or type(y) ~= "number" then return end
    local d = yaw_diff(y, h.comp_last)
    h.comp_last = y
    if d ~= 0 then
        pcall(turn_view, -d)
        M.view_turn = M.view_turn - d
    end
end

local function step_handover()
    local h = handover
    h.frames = h.frames + 1

    -- The player's own stick always wins.
    if math.abs(input.right_stick_x() or 0) > PLAYER_STICK then
        handover_blocked = true
        return stop_handover(string.format("you took the stick, %.0f deg left", M.view_turn))
    end

    local now = read_yaws()
    local moved = {}
    for name, y in pairs(now) do
        if h.last[name] ~= nil then
            local d = yaw_diff(y, h.last[name])
            moved[name] = d
            h.sums[name] = (h.sums[name] or 0) + d
        end
    end
    h.last = now

    if not h.picked and h.frames >= PICK_FRAMES then
        h.picked = true
        local best, best_sum = nil, 0
        for name, sum in pairs(h.sums) do
            if math.abs(sum) > math.abs(best_sum) then best, best_sum = name, sum end
        end
        if best == nil or math.abs(best_sum) < 1 then
            handover_blocked = true
            return stop_handover("the game didn't turn (no reading moved)")
        end
        -- The stick turned the game the other way: push the other way from now on.
        h.flip = best_sum * h.start < 0
        if best ~= h.reading then
            -- Another reading is the one that moves: catch the view up on it.
            h.reading = best
            pcall(turn_view, -best_sum)
            M.view_turn = M.view_turn - best_sum
            h.comp_last = now[best]
        end
    elseif h.picked and moved[h.reading] ~= nil then
        local d = moved[h.reading]
        h.idle = math.abs(d) < 0.05 and h.idle + 1 or 0
        if h.idle > STALL_FRAMES then
            handover_blocked = true
            return stop_handover(string.format("the game stopped turning, %.0f deg left", M.view_turn))
        end
    end

    if math.abs(M.view_turn) < HANDOVER_DONE then
        return stop_handover(string.format("done, %.0f deg via the stick (%s)", h.start, tostring(h.reading)))
    end
    if math.abs(M.view_turn) > math.abs(h.start) + 60 or h.frames > MAX_FRAMES then
        handover_blocked = true
        return stop_handover(string.format("gave up with %.0f deg left (%s)", M.view_turn, tostring(h.reading)))
    end

    -- Push the stick towards the remaining turn, easing off near the end.
    local strength = MIN_PUSH + (1 - MIN_PUSH) * math.min(1.0, math.abs(M.view_turn) / 30)
    local dir = (M.view_turn > 0 and 1 or -1) * (h.flip and -1 or 1)
    input.inject_rx = math.floor(strength * 32767) * dir
end

local function update_handover()
    if M.raised or M.mode ~= "game" then
        if handover ~= nil then stop_handover("stopped: C.A.T. raised again") end
        if M.raised then handover_blocked = false end
        return
    end
    if handover == nil and not handover_blocked then start_handover() end
    if handover ~= nil then step_handover() end
end

-- Recentering resets UEVR's rotation offset, and with it any view turn.
function M.clear_view_turn()
    M.view_turn = 0.0
    if handover ~= nil then stop_handover(nil) end
    handover_blocked = false
end

local function turn_by(pc, yaw)
    local method = TURN_METHODS[M.turn_method]
    if method == "view_rotation" then
        turn_body(yaw)
    elseif method == "vr_view" then
        turn_view(yaw)
        M.view_turn = M.view_turn + yaw
    end
end

local function update_cat_turn(delta)
    update_handover()

    local on = M.raised and settings.get("stop_cat_aim_turn") and not settings.get("snap_turn")
        and TURN_METHODS[M.turn_method] ~= "game"
    input.block_turn = on
    if not on then
        last_yaw = nil
        return
    end

    local x = input.right_stick_x() or 0
    if not M.turn_verified then
        -- Only rotation the way the stick pushes counts; hand-aim wobble
        -- goes both ways and cancels out.
        local now = view_yaw()
        if last_yaw ~= nil and now ~= nil and math.abs(x) >= TURN_DEADZONE then
            turned = turned + yaw_diff(now, last_yaw) * (x < 0 and -1 or 1)
        end
        last_yaw = now
    end
    if math.abs(x) < TURN_DEADZONE then return end

    local scaled = (math.abs(x) - TURN_DEADZONE) / (1 - TURN_DEADZONE) * (x < 0 and -1 or 1)
    local pc = api:get_player_controller(0)
    if pc == nil then return end
    local yaw = scaled * settings.get("cat_turn_speed") * delta
    local ok, err = pcall(turn_by, pc, yaw)
    M.turn_error = (not ok) and tostring(err) or nil

    if TURN_METHODS[M.turn_method] == "vr_view" then
        if ok then
            M.turn_verified = true
        else
            print("[routine_vr] C.A.T. turn: vr_view failed: " .. tostring(err))
            M.turn_method = M.turn_method + 1
        end
        return
    end
    if M.turn_verified then return end
    asked = asked + math.abs(yaw)
    if asked >= CHECK_DEGREES then
        if turned >= asked * CHECK_RATIO then
            M.turn_verified = true
        else
            print(string.format("[routine_vr] C.A.T. turn: %s turned %.1f of %.1f deg, trying next",
                TURN_METHODS[M.turn_method], turned, asked))
            M.turn_method = math.min(M.turn_method + 1, #TURN_METHODS)
        end
        asked, turned = 0.0, 0.0
    end
end

-- Start the turn check over from the first method.
function M.reset_turn_check()
    M.clear_view_turn()
    M.turn_method, M.turn_verified = 1, false
    asked, turned, last_yaw = 0.0, 0.0, nil
end

function M.turn_method_name()
    return TURN_METHODS[M.turn_method] .. (M.turn_verified and " (works)" or " (checking)")
end

function M.tick(delta)
    if M.mode == "game" then update_hand_overrides() end
    update_y_menu(delta)
    update_grip()

    -- Every frame, so the C.A.T. follows LT/grip without lag.
    -- LT only counts when the panel allows it (off by default now that the
    -- grip raises the C.A.T.); input.lua then keeps LT from the game too.
    local lt = settings.get("lt_raises_cat") and input.left_trigger > LT_RAISED
    M.raised = M.mode == "game" and (lt or M.grip_raise or M.inspecting)
    -- With motion hands the C.A.T. rides in the glove instead of on the
    -- controller hook (motion_hands.lua sets cat_on_glove).
    -- Never on the hook while motion hands manage it: hooked for even one
    -- frame on the way out of the hip, the hook saved the hip offset and
    -- wrote it back over the glove's when it let go (the hip's pitch showed
    -- up in the hand).
    hands.set_active(M.CAT, M.raised and not M.cat_on_glove and not M.cat_managed)
    M.cat_hooked = hands.is_attached(M.CAT)
    update_cat_turn(delta)
    update_body_follow(delta)

    -- Stick pitch tilts Routine's aim, dot and HUD away from where your
    -- head is; in VR you look up and down with your head.
    input.block_stick_pitch = M.mode == "game" and settings.get("lock_stick_pitch")

    timer = timer + delta
    if timer < CHECK_INTERVAL then return end
    timer = 0.0

    guard_offsets()

    local mode = detect_mode()
    if mode ~= M.mode then enter_mode(mode) end

    if mode == "game" then
        local pawn = api:get_local_pawn(0)
        if pawn ~= nil then hide_clutter(pawn) end
        update_inspect()
    end
end

function M.init()
    hands.register_extra(M.CAT, function()
        local cat = first_of("cat")
        return cat and cat.RootComponent
    end)
end

-- Body hiding has to run again (e.g. after "Show body" is switched off).
function M.rehide_body()
    hidden_pawn = nil
end

function M.reset()
    movement.force_menu = false
    M.mode = nil
    M.inspecting = false
    M.grip_raise = false
    grip_was, grip_toggled, grip_drawn = false, false, false
    hip.reset()
    M.reset_turn_check()
    input.force_lt, input.clear_rb, input.block_turn = false, false, false
    input.lean = nil
    input.block_lt = false
    input.y_to_menu, input.start_pulse = false, 0.0
    input.focus, input.swap_triggers = false, false
    applied_hands = nil
    y_held_for, y_chord = nil, false
    classes = {}
    hidden_pawn = nil
    timer = CHECK_INTERVAL
end

return M
