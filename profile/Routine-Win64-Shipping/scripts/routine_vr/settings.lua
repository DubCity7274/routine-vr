-- Persistent settings for the Routine VR mod.
-- Stored as JSON in <profile>/data/routine_vr.json via UEVR's json binding.

local M = {}

local FILE = "routine_vr.json"

M.defaults = {
    -- Which controller layout to use: "auto" (from the headset's name in
    -- UEVR's log) or an id from devices/init.lua.
    device = "auto",
    device_layout = 2,

    -- Left stick direction during gameplay: "aim", "left_hand" or "head".
    -- Menus always get the raw stick (see movement.lua).
    move_direction = "head",
    -- Off = smooth turning by the game. Always off in menus.
    snap_turn = false,

    -- Physical crouch: duck in real life -> press the game's crouch button.
    -- Measured as a drop from the calibrated standing head height, so it works
    -- the same in OpenVR standing space and OpenXR LOCAL/STAGE space.
    -- On by default since it presses the right button (B).
    physical_crouch = true,
    crouch_drop = 0.25,            -- metres below standing height that counts as crouched
    crouch_hysteresis = 0.07,      -- must rise this much back above the threshold to stand
    -- Gamepad button the game crouches on: B. UEVR sends your left X to the
    -- game as B (seen in a recording), so "X" never crouched.
    crouch_button = "B",
    crouch_layout = 3,
    crouch_mode = "toggle",        -- "toggle" (tap on enter/leave) or "hold"

    -- Laser from the right hand: "inspect", "always" or "off" (laser.lua).
    laser = "off",
    laser_length = 28.7,           -- cm
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

    -- Lean the interaction ray onto usable things near where you point (grab.lua).
    grab_assist = true,
    grab_assist_angle = 12.0,      -- degrees off that still counts
    -- Papers and items you pick up, at their size in the world (held.lua).
    held_fix = true,
    held_size = 1.0,               -- times that size
    held_in_palm = true,           -- in your hand rather than past the fingertips
    held_offset = { 20.5, -4.0, 1.7 }, -- cm from the controller: forward, outward, up
    held_rot = { 0.80353, 0.0, 0.0, 0.59527 }, -- turn in the hand (quaternion w,x,y,z, right-hand terms), or false

    -- Camera effects removed for comfort (see effects.lua).
    remove_fisheye = true,
    remove_grain = true,
    remove_sharpen = false,        -- the game looks better with its sharpen kept
    remove_color_grading = true,
    remove_vignette = true,
    -- Off: the game plays video cutscenes around you and you keep your
    -- controls. On: UEVR's flat 2D screen and plain gamepad-style controls
    -- while one plays. Off because the switch crashed the game as a
    -- cutscene started (D3D11 query error, the fish in chapter 4) and could
    -- stick on after one (a save projector).
    cutscene_mode = false,

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
    cat_grip = "hip",
    lt_raises_cat = false,         -- the grip does it now; LT can be turned back on
    lt_focus = true,               -- the off-hand trigger sends Focus (D-pad up) when lean isn't on it
    handedness = "right",          -- "left" swaps the C.A.T./aim hand, touch, grips and triggers
    y_opens_menu = true,           -- tap Y for the game's menu (Start); Y no longer inspects
    -- The hip holster, from the headset (metres): below, to the right, behind.
    hip_drop = 0.65,
    hip_side = 0.20,
    hip_back = 0.05,
    hip_radius = 0.27,             -- tuned standing (0.36 felt right seated)
    -- Lean (RB) in gameplay: "trigger" (the off hand's trigger), "grip" (the
    -- off hand's grip) or "off". Not the grip by default: it's easy to hold
    -- it without meaning to (curling the hand to press the C.A.T.'s
    -- buttons), and that stopped you and leaned.
    lean_button = "trigger",
    -- Motion hands from the game's spacesuit arms (motion_hands.lua), with
    -- each palm's offset from its controller (UE terms: pitch/yaw/roll,
    -- forward/right/up cm), tuned in the panel.
    motion_hands = true,
    show_body = true,              -- the suit's body under you (head hidden), with the ID card
    -- The character turns to follow your head past the dead zone (degrees),
    -- at up to body_follow_speed deg/s; the view itself never moves.
    body_follow = true,
    body_follow_deadzone = 20.6,
    body_follow_speed = 269.0,
    -- The put-away C.A.T. on the body's hip (with motion hands), per main
    -- hand: from the pelvis in the character's terms (forward/right/up cm,
    -- pitch/yaw/roll from facing forward; tuned in the panel).
    cat_holster = true,
    -- Tuned in the headset: beside the hip, screen up like the game's own.
    cat_holster_right = { rot = { -84.1, 0, 0 }, loc = { 13.5, 24.2, 5.9 } },
    cat_holster_left = { rot = { -88.7, 0, 0 }, loc = { 9.7, -26.9, 13.9 } },
    holster_layout = 2,
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
    recenter_on_start = true,      -- recenter once when the game's first screen shows
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
    -- Layout 1 had no auto-detect and saved the Touch default; move to auto.
    if loaded.device_layout ~= 2 then
        data.device_layout = 2
        if data.device == "quest_touch" then data.device = "auto" end
    end

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

    -- Crouch layout 1 could save "X", which the game doesn't crouch on.
    -- Layout 2: physical crouch never worked before, so it was saved off;
    -- it comes on now that it does.
    local cl = type(loaded.crouch_layout) == "number" and loaded.crouch_layout or 1
    if cl < 2 then
        if data.crouch_button == "X" then data.crouch_button = "B" end
        if data.crouch_drop == 0.35 then data.crouch_drop = 0.25 end
    end
    if cl < 3 then data.physical_crouch = true end
    data.crouch_layout = 3

    -- Holster layout 1 measured the offset in the pelvis bone's own axes,
    -- and its zero default hid the C.A.T. inside the hips. Untouched zero
    -- offsets take the new defaults.
    if loaded.holster_layout ~= 2 then
        data.holster_layout = 2
        for _, side in ipairs({ "right", "left" }) do
            local o = data["cat_holster_" .. side]
            local zero = type(o) == "table" and type(o.loc) == "table" and type(o.rot) == "table"
            for i = 1, 3 do zero = zero and o.loc[i] == 0 and o.rot[i] == 0 end
            if zero then data["cat_holster_" .. side] = deep_copy(M.defaults["cat_holster_" .. side]) end
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
