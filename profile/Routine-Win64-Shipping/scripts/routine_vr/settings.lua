-- Persistent settings for the Routine VR mod.
-- Stored as JSON in <profile>/data/routine_vr.json via UEVR's json binding.

local M = {}

local FILE = "routine_vr.json"

M.defaults = {
    -- Which controller layout to use. See devices/init.lua for the list.
    device = "quest_touch",

    -- false = let UEVR's built-in button mapping through untouched. Off by
    -- default until Routine's controls are better understood (the user asked
    -- for the stock mapping after terminal mode didn't help).
    custom_buttons = false,

    -- Left stick direction during gameplay: "aim", "left_hand" or "head".
    -- Menus always get the raw stick (see movement.lua).
    move_direction = "head",
    -- Off = smooth turning by the game. Off in menus and terminal mode regardless.
    snap_turn = false,

    -- Terminal mode: what the cursor follows ("hand" or "head") and which
    -- gamepad button the right trigger is sent as (Routine's Interact is X).
    terminal_aim = "hand",
    terminal_trigger = "X",

    -- Physical crouch: duck in real life -> press the game's crouch button.
    -- Measured as a drop from the calibrated standing head height, so it works
    -- the same in OpenVR standing space and OpenXR LOCAL/STAGE space.
    -- Off by default: calibration can land on a bad height (0.00 m seen).
    physical_crouch = false,
    crouch_drop = 0.35,            -- metres below standing height that counts as crouched
    crouch_hysteresis = 0.07,      -- must rise this much back above the threshold to stand
    crouch_button = "B",           -- gamepad button the game uses for crouch
    crouch_mode = "toggle",        -- "toggle" (tap on enter/leave) or "hold"

    -- Laser from the right hand: "inspect", "always" or "off" (laser.lua).
    laser = "inspect",
    laser_length = 100.0,          -- cm
    -- Where the laser starts, so it runs through Routine's centre dot.
    -- Routine's interaction ray starts above the camera component;
    -- calibrated in the headset against a terminal.
    laser_forward = -14.4,         -- cm
    laser_up = 18.3,               -- cm
    lock_stick_pitch = true,       -- right stick up/down does nothing in gameplay

    -- Touch the C.A.T.'s side buttons with your left hand (touch.lua).
    touch_buttons = true,
    touch_marker = true,           -- show the fingertip dot while the C.A.T. is out
    touch_forward = 8.0,           -- cm from the controller to your fingertip
    touch_up = 0.0,                -- cm
    touch_press_function = "Interact", -- RoutineGameInteractComponent function that presses

    -- Camera effects removed for comfort (see effects.lua).
    remove_fisheye = true,
    remove_grain = true,
    remove_sharpen = true,
    remove_color_grading = true,
    remove_vignette = true,

    -- Component -> hand attachments, edited in the Hands panel.
    -- { name = "<component FName>", hand = "right"|"left", rot = {p,y,r}, loc = {x,y,z} }
    -- Routine traces interactions from the pawn's CameraComponent, so it
    -- sits right on the controller. The C.A.T. actor ("C.A.T.", game.lua)
    -- goes on the same hand on its own.
    attachments = {
        { name = "CameraComponent", hand = "right", rot = { 0, 0, 0 }, loc = { 0, 0, 0 } },
        { name = "C.A.T.", hand = "right", rot = { 0, 0, 0 }, loc = { 0, 0, 0 } },
    },
    attachments_layout = 2,

    -- Where the C.A.T. goes while you inspect it: left hand, turned a
    -- quarter so the side buttons face you for pointing with the right
    -- hand. Touch presses work without inspecting (touch.lua).
    cat_inspect = { hand = "left", rot = { 0, -90, 0 }, loc = { 0, 0, 0 } },
    cat_inspect_layout = 3,

    -- Right grip raises the C.A.T.: "hold", "toggle", "hip" (grip at your
    -- right hip to draw it, hold to keep it out) or "off". LT still works.
    cat_grip = "hold",
    lt_raises_cat = false,         -- the grip does it now; LT can be turned back on
    -- The hip holster, from the headset (metres): below, to the right, behind.
    hip_drop = 0.65,
    hip_side = 0.20,
    hip_back = 0.05,
    hip_radius = 0.30,             -- the user went to ~0.36 seated; generous is easier to find
    -- Lean (RB) on the left grip in gameplay; Routine has no use for LB.
    lean_left_grip = true,
    -- Motion hands from the game's spacesuit arms (motion_hands.lua), with
    -- each palm's offset from its controller (UE terms: pitch/yaw/roll,
    -- forward/right/up cm), tuned in the panel.
    motion_hands = true,
    show_body = true,              -- the suit's body under you (head hidden), with the ID card
    arm_ik = true,                 -- arms run from the body's shoulders to the hands
    -- Lined up in the headset by the user (Quest 3S).
    hand_right = { rot = { 0.5, 2.1, 157.3 }, loc = { -3.0, 3.0, 0.9 } },
    hand_left = { rot = { 0.5, -2.1, 21.1 }, loc = { -6.2, -3.0, 0.9 } },
    -- Which local axis the finger joints bend around, and per-hand flips
    -- (set once with the curl preview in the panel).
    finger_axis = "z",
    right_rest_from_left = true,   -- right hand's relaxed pose mirrored from the left
    -- The thumb around the C.A.T.'s grip, tuned in the headset.
    thumb_wrap = -0.31,            -- extra curl on the thumb's joints
    thumb_swing_1 = 0.67,          -- swing the thumb's base out/around the grip (x60 deg)
    thumb_swing_2 = 0.48,
    finger_flip_left = false,
    finger_flip_right = false,
    finger_curl_preview = 0.0,     -- not saved as anything but 0 in practice

    -- Turn at a steady speed with the C.A.T. out, instead of Routine's
    -- slow, ramping precise-aim turn (game.lua).
    stop_cat_aim_turn = true,
    cat_turn_speed = 120.0,        -- degrees per second at full stick
    cat_turn_reverse = false,      -- flip it if pushing right turns you left
    -- Hold right B + left Y this long (s) to recenter the view.
    recenter_hold = 3.0,

    -- Remaps applied on top of the device layout: logical -> gamepad button.
    remap = {},
}

local function deep_copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deep_copy(v) end
    return out
end

function M.load()
    local ok, loaded = pcall(json.load_file, FILE)
    local data = deep_copy(M.defaults)

    if ok and type(loaded) == "table" then
        -- Type check: UEVR's json writes an empty table as null.
        for k, v in pairs(loaded) do
            if M.defaults[k] ~= nil and type(v) == type(M.defaults[k]) then data[k] = v end
        end
    end

    M.migrate(data, ok and type(loaded) == "table" and loaded or {})
    data.finger_curl_preview = 0.0 -- a tuning aid, never kept between sessions
    M.data = data
    return data
end

-- Layout 1 moved the camera 30 cm back so the C.A.T. hanging off it landed
-- in the hand, which also put the interaction ray 30 cm off. Layout 2
-- attaches the C.A.T. on its own and keeps the camera on the controller.
M.INSPECT_POSE = { left = { 0, -90, 0 }, right = { 0, 0, 0 } }

function M.migrate(data, loaded)
    -- Inspect layout 2 kept the C.A.T. in the right hand, back when touch
    -- seemed to need inspect; it doesn't, so an untouched layout-2 pose
    -- goes back to the left hand.
    if loaded.cat_inspect_layout ~= 3 then
        data.cat_inspect_layout = 3
        local c = data.cat_inspect
        if c.hand == "right" and type(c.rot) == "table" and type(c.loc) == "table"
            and c.rot[1] == 0 and c.rot[2] == 0 and c.rot[3] == 0
            and c.loc[1] == 0 and c.loc[2] == 0 and c.loc[3] == 0 then
            data.cat_inspect = { hand = "left", rot = { 0, -90, 0 }, loc = { 0, 0, 0 } }
        end
    end

    if loaded.attachments_layout == 2 then return end
    data.attachments_layout = 2
    local has_cat = false
    for _, a in ipairs(data.attachments) do
        if a.name == "CameraComponent" then
            a.rot, a.loc = { 0, 0, 0 }, { 0, 0, 0 }
        elseif a.name == "C.A.T." then
            has_cat = true
        end
    end
    if not has_cat then
        data.attachments[#data.attachments + 1] = { name = "C.A.T.", hand = "right", rot = { 0, 0, 0 }, loc = { 0, 0, 0 } }
    end
end

function M.save()
    local ok, err = pcall(json.dump_file, FILE, M.data, 4)
    if not ok then
        print("[routine_vr] failed to save settings: " .. tostring(err))
    end
end

function M.get(key)
    return M.data[key]
end

function M.set(key, value)
    M.data[key] = value
    M.save()
end

return M
