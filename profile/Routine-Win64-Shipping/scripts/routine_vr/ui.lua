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
local health = require("routine_vr.health")

local M = {}

local CROUCH_MODES = { "toggle", "hold" }

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

-- A section of the panel: a collapsing header (closed until opened).
local function header(title)
    if imgui.collapsing_header then return imgui.collapsing_header(title) end
    if imgui.separator then imgui.separator() end
    imgui.text("== " .. title .. " ==")
    return true
end

-- Sliders and details tucked into an expander inside a section.
local function expander(label, draw)
    if imgui.tree_node(label) then
        draw()
        imgui.tree_pop()
    end
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

-- A row of small buttons that set one setting; shows the current value.
local function choice_buttons(label, key, choices)
    imgui.text(label .. "  [" .. tostring(settings.get(key)) .. "]")
    for i, m in ipairs(choices) do
        if i > 1 then imgui.same_line() end
        if imgui.small_button(m[2] .. "##" .. key) then settings.set(key, m[1]) end
    end
end

---------------------------------------------------------------------------
-- Top: always visible
---------------------------------------------------------------------------

local function draw_top()
    imgui.text("Routine VR " .. VERSION .. "   |   mode: " .. tostring(game.mode)
        .. "   |   C.A.T.: " .. (game.raised and "out" or "away")
        .. "   |   " .. (settings.get("handedness") == "left" and "left-handed" or "right-handed")
        .. string.format("   |   frame %.1f ms (worst %.1f)", probe.frame_ms or 0, probe.worst_ms or 0))
    if health.broken then
        imgui.text("!! Head tracking will be jittery this launch (UEVR's frame sync came up broken).")
        imgui.text("!! Restart the game to fix it.")
    end
    if imgui.button("Recenter + recalibrate now") then roomscale.recenter() end
    imgui.same_line()
    imgui.text(string.format("(or hold B + Y for %.0f s, menus too)", settings.get("recenter_hold")))
    if roomscale.recenter_progress > 0 then
        imgui.text(string.format("Recentering... %d%%", math.floor(roomscale.recenter_progress * 100)))
    end
end

---------------------------------------------------------------------------
-- Controls
---------------------------------------------------------------------------

local GRIP_MODES = { { "hip", "Grip at your hip (holster)" }, { "hold", "Hold grip anywhere" },
    { "toggle", "Press grip to toggle" }, { "off", "Off" } }
local LEAN_MODES = { { "trigger", "Trigger" }, { "grip", "Grip" }, { "off", "Off" } }

local function draw_controls()
    local changed_h, left = imgui.checkbox("Left-handed (C.A.T., aim and interact on the left hand)", settings.get("handedness") == "left")
    if changed_h then
        settings.set("handedness", left and "left" or "right")
        game.refresh_hands()
    end
    choice_buttons("Your main hand's grip raises the C.A.T.:", "cat_grip", GRIP_MODES)
    if settings.get("cat_grip") == "hip" then
        imgui.text(string.format("Hand at your hip: %s (%.2f m from the draw spot)",
            hip.at_hip and "yes" or "no", hip.distance or -1))
        expander("Where the hip draw spot is", function()
            slider_setting("Below your head (m)", "hip_drop", 0.3, 1.0)
            slider_setting("To the side (m)", "hip_side", -0.1, 0.5)
            slider_setting("Behind (m)", "hip_back", -0.2, 0.3)
            slider_setting("Size (m)", "hip_radius", 0.1, 0.4)
        end)
    end
    choice_buttons("Lean with your off hand's:", "lean_button", LEAN_MODES)
    if settings.get("lean_button") ~= "trigger" then
        checkbox_setting("Off-hand trigger sends Focus (the game's D-pad up)", "lt_focus")
    end
    checkbox_setting("Tap Y to open the game's menu", "y_opens_menu")
    checkbox_setting("Left trigger also raises the C.A.T.", "lt_raises_cat")

    if imgui.separator then imgui.separator() end
    local changed_move, move_idx = imgui.combo("Left stick moves toward",
        index_of(movement.CHOICES, settings.get("move_direction")), movement.LABELS)
    if changed_move then settings.set("move_direction", movement.CHOICES[move_idx]) end
    checkbox_setting("Snap turn on the right stick", "snap_turn")
    checkbox_setting("Right stick up/down does nothing in gameplay (look with your head)", "lock_stick_pitch")
    expander("Turning with the C.A.T. out", function()
        checkbox_setting("Normal-speed turning (not the game's slow aim turn)", "stop_cat_aim_turn")
        slider_setting("Turn speed (deg/s)", "cat_turn_speed", 30, 360)
        checkbox_setting("Reverse it (if right turns you left)", "cat_turn_reverse")
        imgui.text("Turn method: " .. game.turn_method_name())
        imgui.text(string.format("View turned ahead of your character: %.0f deg", game.view_turn))
        if game.last_handover then imgui.text("Last handover: " .. game.last_handover) end
        if game.turn_error then imgui.text("Turn error: " .. game.turn_error) end
    end)
end

---------------------------------------------------------------------------
-- Hands and body
---------------------------------------------------------------------------

local function draw_hands_body()
    checkbox_setting("Motion hands (the game's spacesuit arms on your controllers)", "motion_hands")
    local changed_b, vb = imgui.checkbox("Show your body (spacesuit and chest ID; head hidden)", settings.get("show_body"))
    if changed_b then
        settings.set("show_body", vb)
        game.rehide_body()
    end
    checkbox_setting("Arms attached to the body's shoulders", "arm_ik")
    imgui.text(motion_hands.status)
    if motion_hands.arm_error then imgui.text("Arm error: " .. motion_hands.arm_error) end

    checkbox_setting("Body turns to follow your head", "body_follow")
    if settings.get("body_follow") then
        expander("Body follow tuning", function()
            slider_setting("Head turn before the body follows (deg)", "body_follow_deadzone", 0, 90)
            slider_setting("Body turn speed (deg/s)", "body_follow_speed", 30, 720)
        end)
    end

    expander("Glove alignment (line each glove up with your real hand)", function()
        local r = settings.get("hand_right")
        imgui.text("Right hand:")
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
    end)

    expander("Fingers and thumb", function()
        imgui.text("Index follows the trigger, the rest the grip, thumb the buttons/thumbrest.")
        imgui.text("Thumb around the C.A.T. (hold it out while you adjust):")
        slider_setting("Thumb bend", "thumb_wrap", -0.5, 1.0)
        slider_setting("Thumb swing 1 (from its base)", "thumb_swing_1", -1.0, 1.0)
        slider_setting("Thumb swing 2 (the other way)", "thumb_swing_2", -1.0, 1.0)
        imgui.text("If fingers bend the wrong way: drag the preview, pick the axis that makes a fist.")
        slider_setting("Curl preview (drag, then set back to 0)", "finger_curl_preview", 0, 1)
        imgui.text("Bend axis: " .. settings.get("finger_axis"))
        for i, ax in ipairs({ "x", "y", "z" }) do
            imgui.same_line()
            if imgui.small_button("Axis " .. ax:upper()) then settings.set("finger_axis", ax) end
        end
        checkbox_setting("Flip right-hand bend", "finger_flip_right")
        checkbox_setting("Flip left-hand bend", "finger_flip_left")
        checkbox_setting("Right hand relaxed like the left (applies on rebuild)", "right_rest_from_left")
        if imgui.small_button("Rebuild hands") then motion_hands.reset() end
    end)
end

---------------------------------------------------------------------------
-- C.A.T.
---------------------------------------------------------------------------

local function draw_cat()
    imgui.text("C.A.T.: " .. ({ glove = "in your hand", holster = "on your hip", home = "where the game keeps it" })[motion_hands.cat_place or "home"])
    checkbox_setting("Put away, it hangs on your hip (needs motion hands)", "cat_holster")
    if settings.get("cat_holster") then
        local side = settings.get("handedness") == "left" and "left" or "right"
        expander("Hip position (" .. side .. "-handed; put the C.A.T. away to see it)", function()
            imgui.text("From your pelvis: forward/right/up cm, angle from facing forward.")
            draw_offset_sliders({ name = "cat_holster_" .. side }, settings.get("cat_holster_" .. side))
        end)
    end

    if imgui.separator then imgui.separator() end
    checkbox_setting("Press its side buttons by touching them with your other index finger", "touch_buttons")
    checkbox_setting("Fingertip dot while the C.A.T. is out", "touch_marker")
    expander("Touch details", function()
        slider_setting("Fingertip forward (cm)", "touch_forward", -10, 20)
        slider_setting("Fingertip up (cm)", "touch_up", -10, 10)
        imgui.text(touch.status)
        local fn = settings.get("touch_press_function")
        imgui.text(fn == "" and "Pressing is off: a touch only buzzes."
            or ("Presses with " .. fn .. "(). Presses so far: " .. tostring(touch.presses or 0)))
        if touch.signature then imgui.text("Game function: " .. touch.signature) end
        if touch.last_error then imgui.text("Last error: " .. touch.last_error) end
    end)

    if imgui.separator then imgui.separator() end
    local changed, idx = imgui.combo("Laser pointer", index_of(laser.CHOICES, settings.get("laser")), laser.LABELS)
    if changed then settings.set("laser", laser.CHOICES[idx]) end
    expander("Laser tuning", function()
        slider_setting("Length (cm)", "laser_length", 20, 400)
        slider_setting("Start forward (cm)", "laser_forward", -30, 30)
        slider_setting("Start up (cm)", "laser_up", -30, 30)
    end)
end

---------------------------------------------------------------------------
-- Room-scale
---------------------------------------------------------------------------

local function draw_roomscale()
    imgui.text("Status: " .. roomscale.status)
    if roomscale.standing_y ~= nil then
        imgui.text(string.format("Head %.2f m, drop %.2f m, %s",
            roomscale.head_y, roomscale.standing_y - roomscale.head_y,
            roomscale.crouched and "crouched" or "standing"))
    end
    if imgui.button("Recalibrate height only") then roomscale.calibrate() end
    checkbox_setting("Recenter on its own when the game starts (on its first screen)", "recenter_on_start")
    expander("Physical crouch", function()
        checkbox_setting("Physical crouch (duck in real life to crouch)", "physical_crouch")
        imgui.text("Crouches with: " .. tostring(roomscale.crouch_method))
        imgui.text("The button settings below are only used if the game's own crouch doesn't work.")
        slider_setting("Crouch when head drops (m)", "crouch_drop", 0.15, 0.7)
        slider_setting("Stand-up hysteresis (m)", "crouch_hysteresis", 0.02, 0.2)
        combo_setting("Game crouch button", "crouch_button", input.BUTTON_NAMES)
        combo_setting("Game crouch style", "crouch_mode", CROUCH_MODES)
    end)
end

---------------------------------------------------------------------------
-- Comfort
---------------------------------------------------------------------------

local function draw_effects()
    checkbox_setting("Cutscene mode: flat screen and gamepad controls during video cutscenes (off recommended)", "cutscene_mode")
    for _, g in ipairs(effects.GROUPS) do
        local changed, v = imgui.checkbox(g.label, settings.get(g.key))
        if changed then
            settings.set(g.key, v)
            effects.apply_all(false)
        end
    end
    imgui.text(effects.status)
end

---------------------------------------------------------------------------
-- Controllers
---------------------------------------------------------------------------

local function draw_controllers()
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

---------------------------------------------------------------------------
-- Advanced: debugging, and the attachments used without motion hands
---------------------------------------------------------------------------

local function draw_cat_inspect()
    local a = settings.get("cat_inspect")
    imgui.text("C.A.T. while inspecting:  [" .. a.hand .. "]")
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
end

local function draw_attachments()
    imgui.text("Used with motion hands off: parts of the pawn on your controllers.")
    imgui.text("Saved per component name.")
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

local function draw_advanced()
    expander("C.A.T. recorder (for bug reports)", function()
        imgui.text("Records the C.A.T., your inputs and the hands for 40 s.")
        imgui.text("Start it, close this menu, then do the thing that goes wrong.")
        if imgui.button("Record (40 s)") then probe.start() end
        imgui.text(probe.status)
    end)
    expander("Input check", function()
        local d = input.diag
        imgui.text(string.format("%d polls, UEVR %s", d.polls, d.gate))
        imgui.text(string.format("RB (lean) from UEVR: %s, sent: %s | LT sent: %d | stick X sent: %d",
            d.rb_in and "on" or "off", d.rb_out and "on" or "off", d.lt_out or 0, d.rx_out or 0))
        imgui.text("Left stick right now: " .. (movement.in_menu and "menu (raw stick)" or "gameplay"))
        imgui.text("Snap turn right now: " .. (movement.snap_turn_active() and "on" or "off"))
        imgui.text("UEVR frame sync: " .. health.status .. " (" .. health.warnings .. " warnings)")
        imgui.text("Controller reads: " .. input.source_text())
        local td = motion_hands.thumb_down or {}
        imgui.text("Thumbs down: left " .. tostring(td.left) .. ", right " .. tostring(td.right))
    end)
    expander("Body scan", function()
        if imgui.button("Scan body") then body.scan() end
        imgui.same_line()
        local changed, v = imgui.checkbox("Show the game's own body", body.showing)
        if changed then
            body.set_show(v)
            if not v then game.rehide_body() end
        end
        imgui.text(body.status)
    end)
    expander("Controller attachments (without motion hands)", function()
        draw_cat_inspect()
        if imgui.separator then imgui.separator() end
        draw_attachments()
    end)
end

function M.draw()
    draw_top()
    if header("Controls") then draw_controls() end
    if header("Hands and body") then draw_hands_body() end
    if header("C.A.T.") then draw_cat() end
    if header("Room-scale") then draw_roomscale() end
    if header("Comfort") then draw_effects() end
    if header("Controllers") then draw_controllers() end
    if header("Advanced") then draw_advanced() end
end

return M
