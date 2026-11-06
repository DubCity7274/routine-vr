-- Panel drawn inside UEVR's overlay (both sticks clicked -> Script UI).

local settings = require("routine_vr.settings")
local devices = require("routine_vr.devices")
local input = require("routine_vr.input")
local roomscale = require("routine_vr.roomscale")
local movement = require("routine_vr.movement")
local hands = require("routine_vr.hands")
local effects = require("routine_vr.effects")
local game = require("routine_vr.game")
local laser = require("routine_vr.laser")
local probe = require("routine_vr.probe")
local hip = require("routine_vr.hip")
local body = require("routine_vr.body")
local motion_hands = require("routine_vr.motion_hands")
-- Everything is required at load: UEVR only finds the mod's files while
-- the script is first running (a require from on_frame fails).
local VERSION = require("routine_vr.version")
local touch = require("routine_vr.touch")

local M = {}

local CROUCH_MODES = { "toggle", "hold" }
local REMAP_SOURCES = { "A", "B", "X", "Y", "LB", "RB", "LS", "RS", "LT", "RT" }

local function index_of(list, value)
    for i, v in ipairs(list) do
        if v == value then return i end
    end
    return 1
end

local function combo_setting(label, key, list)
    local changed, idx = imgui.combo(label, index_of(list, settings.get(key)), list)
    if changed then settings.set(key, list[idx]) end
end

local function checkbox_setting(label, key)
    local changed, v = imgui.checkbox(label, settings.get(key))
    if changed then settings.set(key, v) end
end

local function slider_setting(label, key, lo, hi)
    local changed, v = imgui.slider_float(label, settings.get(key), lo, hi)
    if changed then settings.set(key, v) end
end

local function draw_controllers()

    local changed_move, move_idx = imgui.combo("Left stick moves toward",
        index_of(movement.CHOICES, settings.get("move_direction")), movement.LABELS)
    if changed_move then settings.set("move_direction", movement.CHOICES[move_idx]) end
    imgui.text("Right now: " .. (movement.in_menu and "menu (raw stick)" or "gameplay"))

    checkbox_setting("Snap turn on right stick", "snap_turn")
    checkbox_setting("Right stick up/down does nothing in gameplay (look with your head)", "lock_stick_pitch")
    imgui.text("Snap turn right now: " .. (movement.snap_turn_active() and "on" or "off"))
    local d = input.diag
    imgui.text(string.format("Input check: %d polls, UEVR %s", d.polls, d.gate))
    imgui.text(string.format("  RB (lean) from UEVR: %s, sent: %s | LT sent: %d | stick X sent: %d",
        d.rb_in and "on" or "off", d.rb_out and "on" or "off", d.lt_out or 0, d.rx_out or 0))
    if imgui.separator then imgui.separator() end

    -- First entry: auto-detect from the headset name in UEVR's log.
    local names = { "Auto-detect" }
    for _, n in ipairs(devices.names()) do names[#names + 1] = n end
    local cur = settings.get("device") == "auto" and 1 or devices.index_of(settings.get("device")) + 1
    local changed, idx = imgui.combo("Controller layout", cur, names)
    if changed then
        local id = idx == 1 and "auto" or devices.order[idx - 1]
        settings.set("device", id)
        input.set_device(id)
        hands.mark_dirty()
    end
    imgui.text("Using: " .. input.device.name .. (input.auto_device and
        (" (headset: " .. tostring(input.detected_name or "not known yet") .. ")") or " (chosen by hand)"))
    imgui.text("Runtime: " .. (devices.uses_openvr() and "OpenVR (per-controller pitch fix on)" or "OpenXR"))
end

local function draw_roomscale()
    imgui.text("Status: " .. roomscale.status)
    if roomscale.standing_y ~= nil then
        imgui.text(string.format("Head %.2f m, drop %.2f m, %s",
            roomscale.head_y, roomscale.standing_y - roomscale.head_y,
            roomscale.crouched and "CROUCHED" or "standing"))
    end

    imgui.text(string.format("Or hold B + Y for %.0f s anywhere (menus too).", settings.get("recenter_hold")))
    if roomscale.recenter_progress > 0 then
        imgui.text(string.format("Recentering... %d%%", math.floor(roomscale.recenter_progress * 100)))
    end
    if imgui.button("Recenter + recalibrate now") then roomscale.recenter() end
    imgui.same_line()
    if imgui.button("Recalibrate height only") then roomscale.calibrate() end

    if imgui.separator then imgui.separator() end
    checkbox_setting("Physical crouch", "physical_crouch")
    slider_setting("Crouch when head drops (m)", "crouch_drop", 0.15, 0.7)
    slider_setting("Stand-up hysteresis (m)", "crouch_hysteresis", 0.02, 0.2)
    combo_setting("Game crouch button", "crouch_button", input.BUTTON_NAMES)
    combo_setting("Game crouch style", "crouch_mode", CROUCH_MODES)
end

local function draw_offset_sliders(comp, a)
    local changed = false
    local c

    a.rot = a.rot or { 0, 0, 0 }
    a.loc = a.loc or { 0, 0, 0 }

    c, a.rot[1] = imgui.slider_float("Pitch##" .. comp.name, a.rot[1], -180, 180); changed = changed or c
    c, a.rot[2] = imgui.slider_float("Yaw##" .. comp.name, a.rot[2], -180, 180); changed = changed or c
    c, a.rot[3] = imgui.slider_float("Roll##" .. comp.name, a.rot[3], -180, 180); changed = changed or c
    c, a.loc[1] = imgui.slider_float("Forward (cm)##" .. comp.name, a.loc[1], -50, 50); changed = changed or c
    c, a.loc[2] = imgui.slider_float("Right (cm)##" .. comp.name, a.loc[2], -50, 50); changed = changed or c
    c, a.loc[3] = imgui.slider_float("Up (cm)##" .. comp.name, a.loc[3], -50, 50); changed = changed or c

    if changed then
        settings.save()
        hands.mark_dirty()
    end
end

local function draw_cat_inspect()
    local a = settings.get("cat_inspect")
    imgui.text("C.A.T. while inspecting (hold Y to try it):  [" .. a.hand .. "]")
    imgui.push_id("cat_inspect")
    local function set_hand(hand)
        a.hand = hand
        local r = settings.INSPECT_POSE[hand]
        a.rot, a.loc = { r[1], r[2], r[3] }, { 0, 0, 0 }
        settings.save(); hands.mark_dirty(); game.refresh_hands()
    end
    if imgui.small_button("Left hand") then set_hand("left") end
    imgui.same_line()
    if imgui.small_button("Right hand") then set_hand("right") end
    imgui.same_line()
    if imgui.small_button("Reset pose") then set_hand(a.hand) end
    draw_offset_sliders({ name = "cat_inspect" }, a)
    game.refresh_hands() -- left-handers get a mirrored copy of this pose
    imgui.pop_id()
    if imgui.separator then imgui.separator() end
end

local function draw_motion_hands()
    checkbox_setting("Show motion hands (the game's spacesuit gloves on your controllers)", "motion_hands")
    checkbox_setting("Arms attached to the body's shoulders (needs the body shown)", "arm_ik")
    checkbox_setting("Body turns to follow your head", "body_follow")
    if settings.get("body_follow") then
        slider_setting("Head turn before the body follows (deg)", "body_follow_deadzone", 0, 90)
        slider_setting("Body turn speed (deg/s)", "body_follow_speed", 30, 720)
    end
    if motion_hands.arm_error then imgui.text("Arm error: " .. motion_hands.arm_error) end
    local changed_b, vb = imgui.checkbox("Show your body (spacesuit, chest ID; head hidden)", settings.get("show_body"))
    if changed_b then
        settings.set("show_body", vb)
        game.rehide_body()
    end
    imgui.text(motion_hands.status)
    imgui.text("Line each glove up with your real hand. Right hand:")
    local r = settings.get("hand_right")
    draw_offset_sliders({ name = "hand_right" }, r)
    imgui.text("Left hand:")
    local l = settings.get("hand_left")
    if imgui.small_button("Copy right hand, mirrored") then
        -- The left palm bone is mirrored with a half turn of roll (the
        -- user's tuning: right roll 157, left 21).
        l.rot = { r.rot[1], -r.rot[2], 180 - r.rot[3] }
        l.loc = { r.loc[1], -r.loc[2], r.loc[3] }
        settings.save()
    end
    draw_offset_sliders({ name = "hand_left" }, l)
    imgui.text("With hands on, the C.A.T.'s buttons are pressed with your left index finger.")
    imgui.text("C.A.T.: " .. ({ glove = "in your hand", holster = "on your hip", home = "where the game keeps it" })[motion_hands.cat_place or "home"])
    checkbox_setting("Put-away C.A.T. hangs on your hip (keeps it out of your way when crawling)", "cat_holster")
    if settings.get("cat_holster") then
        local side = settings.get("handedness") == "left" and "left" or "right"
        imgui.text("Hip position from your pelvis (forward/right/up cm; put the C.A.T. away to see it):")
        draw_offset_sliders({ name = "cat_holster_" .. side }, settings.get("cat_holster_" .. side))
    end
    imgui.text("Fingers: index follows the trigger, the rest the grip, thumb on buttons/thumbrest.")
    imgui.text("If they bend the wrong way, drag the preview and pick the axis that curls them into a fist:")
    slider_setting("Curl preview (drag, then set back to 0)", "finger_curl_preview", 0, 1)
    imgui.text("Bend axis: " .. settings.get("finger_axis"))
    for i, ax in ipairs({ "x", "y", "z" }) do
        if i > 1 then imgui.same_line() end
        if imgui.small_button("Axis " .. ax:upper()) then settings.set("finger_axis", ax) end
    end
    checkbox_setting("Right hand relaxed like the left (applies when hands are rebuilt)", "right_rest_from_left")
    imgui.text("Thumb on the C.A.T. (hold it out while you adjust):")
    slider_setting("Thumb bend (curl the joints)", "thumb_wrap", -0.5, 1.0)
    slider_setting("Thumb swing 1 (move the whole thumb from its base)", "thumb_swing_1", -1.0, 1.0)
    slider_setting("Thumb swing 2 (the other way)", "thumb_swing_2", -1.0, 1.0)
    if imgui.small_button("Rebuild hands") then motion_hands.reset() end
    checkbox_setting("Flip right-hand bend", "finger_flip_right")
    checkbox_setting("Flip left-hand bend", "finger_flip_left")
end

local function draw_body()
    imgui.text("Motion hands, step 1: find out what body Routine has.")
    if imgui.button("Scan body") then body.scan() end
    imgui.same_line()
    local changed, v = imgui.checkbox("Show body", body.showing)
    if changed then
        body.set_show(v)
        if not v then game.rehide_body() end
    end
    imgui.text(body.status)
end

local function draw_hands()
    draw_cat_inspect()
    imgui.text("Assign the pawn's parts to your hands. Look for the C.A.T.,")
    imgui.text("flashlight, and first-person arms. Saved per component name.")
    if imgui.button("Rescan pawn") then hands.rescan() end

    if #hands.components == 0 then
        imgui.text("No pawn yet. Load into the game first.")
        return
    end

    for _, comp in ipairs(hands.components) do
        local a = hands.attachment_for(comp)
        local tag = a and ("  [" .. a.hand .. "]") or ""

        imgui.push_id(comp.name)
        if imgui.small_button("L") then hands.assign(comp, "left") end
        imgui.same_line()
        if imgui.small_button("R") then hands.assign(comp, "right") end
        imgui.same_line()
        if imgui.small_button("x") then hands.assign(comp, nil) end
        imgui.same_line()

        if a ~= nil then
            if imgui.tree_node(comp.name .. " (" .. comp.class .. ")" .. tag) then
                draw_offset_sliders(comp, a)
                imgui.tree_pop()
            end
        else
            imgui.text(comp.name .. " (" .. comp.class .. ")")
        end
        imgui.pop_id()
    end
end

local function draw_status()
    imgui.text("Mode: " .. tostring(game.mode) .. (game.inspecting and " (inspecting C.A.T.)" or ""))
end

local function draw_laser()
    local changed, idx = imgui.combo("Laser pointer", index_of(laser.CHOICES, settings.get("laser")), laser.LABELS)
    if changed then settings.set("laser", laser.CHOICES[idx]) end
    slider_setting("Laser length (cm)", "laser_length", 20, 400)
    slider_setting("Laser start forward (cm)", "laser_forward", -30, 30)
    slider_setting("Laser start up (cm)", "laser_up", -30, 30)
end

local function draw_effects()
    for _, g in ipairs(effects.GROUPS) do
        local changed, v = imgui.checkbox(g.label, settings.get(g.key))
        if changed then
            settings.set(g.key, v)
            effects.apply_all(false)
        end
    end
    imgui.text(effects.status)
end

local function draw_probe()
    imgui.text("Records what the game's C.A.T. does for 40 s, for debugging.")
    imgui.text("Start it, close this menu, then slowly: raise (LT), lower,")
    imgui.text("raise + inspect (Y), point at each side button and press RT,")
    imgui.text("then touch each side button with your left hand.")
    if imgui.button("Record C.A.T. (40 s)") then probe.start() end
    imgui.text(probe.status)
end

local GRIP_MODES = { { "hold", "Hold grip" }, { "toggle", "Press grip to toggle" },
    { "hip", "Grip at right hip (holster)" }, { "off", "Off" } }

local function draw_cat()
    local changed_h, left = imgui.checkbox("Left-handed (C.A.T. and aiming on the left hand)", settings.get("handedness") == "left")
    if changed_h then
        settings.set("handedness", left and "left" or "right")
        game.refresh_hands()
    end
    local mode = settings.get("cat_grip")
    imgui.text("Your main hand's grip raises the C.A.T. Now: " .. mode)
    for i, m in ipairs(GRIP_MODES) do
        if i > 1 then imgui.same_line() end
        if imgui.small_button(m[2]) then settings.set("cat_grip", m[1]) end
    end
    if settings.get("cat_grip") == "hip" then
        imgui.text("Reach to your right hip and grip to draw the C.A.T.; hold to keep it out.")
        imgui.text(string.format("Right hand at hip: %s (%.2f m from the holster)",
            hip.at_hip and "yes" or "no", hip.distance or -1))
        slider_setting("Holster below head (m)", "hip_drop", 0.3, 1.0)
        slider_setting("Holster to the right (m)", "hip_side", -0.1, 0.5)
        slider_setting("Holster behind (m)", "hip_back", -0.2, 0.3)
        slider_setting("Holster size (m)", "hip_radius", 0.1, 0.4)
    end
    checkbox_setting("Left trigger also raises the C.A.T.", "lt_raises_cat")
    checkbox_setting("Off-hand trigger sends Focus (the game's D-pad up)", "lt_focus")
    checkbox_setting("Tap Y to open the game's menu (off: Y inspects the C.A.T.)", "y_opens_menu")
    checkbox_setting("Lean with the left grip (right-handed; left-handers lean with the right grip)", "lean_left_grip")
    imgui.text("Lean: " .. (settings.get("lean_left_grip") and "left grip" or
        (settings.get("cat_grip") == "off" and "right grip" or "none - turn one of these on")))
    checkbox_setting("Normal-speed turning with the C.A.T. out (not the slow aim turn)", "stop_cat_aim_turn")
    slider_setting("Turn speed with the C.A.T. out (deg/s)", "cat_turn_speed", 30, 360)
    imgui.text("Turn method: " .. game.turn_method_name())
    imgui.text(string.format("View turned ahead of your character: %.0f deg (handed over when the C.A.T. is lowered)", game.view_turn))
    if game.last_handover then imgui.text("Last handover: " .. game.last_handover) end
    checkbox_setting("Reverse C.A.T.-out turning (if right turns you left)", "cat_turn_reverse")
    if game.turn_error then imgui.text("Turn error: " .. game.turn_error) end
    imgui.text("C.A.T. out: " .. (game.raised and "yes" or "no"))
end

local function draw_touch()
    checkbox_setting("Touch the C.A.T.'s side buttons with your left hand", "touch_buttons")
    checkbox_setting("Show fingertip dot while the C.A.T. is out", "touch_marker")
    slider_setting("Fingertip forward (cm)", "touch_forward", -10, 20)
    slider_setting("Fingertip up (cm)", "touch_up", -10, 10)
    imgui.text(touch.status)
    local fn = settings.get("touch_press_function")
    imgui.text(fn == "" and "Pressing is off: a touch only buzzes."
        or ("Presses with " .. fn .. "(). Presses so far: " .. tostring(touch.presses or 0)))
    if touch.signature then imgui.text("Game function: " .. touch.signature) end
    if touch.last_error then imgui.text("Last error: " .. touch.last_error) end
end

local function section(title, draw)
    if imgui.separator then imgui.separator() end
    imgui.text("== " .. title .. " ==")
    draw()
end

function M.draw()
    imgui.text("Routine VR " .. VERSION)
    draw_status()

    section("Laser", draw_laser)
    section("C.A.T.", draw_cat)
    section("Touch", draw_touch)
    section("C.A.T. recorder", draw_probe)
    section("Motion hands", draw_motion_hands)
    section("Body (motion hands)", draw_body)
    section("Controllers", draw_controllers)
    section("Room-scale", draw_roomscale)
    section("Comfort", draw_effects)
    section("Hands (6DoF)", draw_hands)
end

return M
