-- Reads the VR controllers and edits the XInput gamepad state Routine reads.
--
-- UEVR maps the controllers to a gamepad itself (its default bindings work
-- for every headset); this module only edits that state afterwards: the
-- grip-raised C.A.T., lean on the left grip, Y for the menu, LT for Focus,
-- the C.A.T.-out turn, and buttons other modules press for a frame
-- (inject, e.g. physical crouch). The controller layouts (devices/) say
-- which physical inputs the mod's own reads use.

local devices = require("routine_vr.devices")
local settings = require("routine_vr.settings")

local M = {}

local vr = uevr.params.vr

M.BITS = {
    DPAD_UP = XINPUT_GAMEPAD_DPAD_UP,
    DPAD_DOWN = XINPUT_GAMEPAD_DPAD_DOWN,
    DPAD_LEFT = XINPUT_GAMEPAD_DPAD_LEFT,
    DPAD_RIGHT = XINPUT_GAMEPAD_DPAD_RIGHT,
    START = XINPUT_GAMEPAD_START,
    BACK = XINPUT_GAMEPAD_BACK,
    LS = XINPUT_GAMEPAD_LEFT_THUMB,
    RS = XINPUT_GAMEPAD_RIGHT_THUMB,
    LB = XINPUT_GAMEPAD_LEFT_SHOULDER,
    RB = XINPUT_GAMEPAD_RIGHT_SHOULDER,
    A = XINPUT_GAMEPAD_A,
    B = XINPUT_GAMEPAD_B,
    X = XINPUT_GAMEPAD_X,
    Y = XINPUT_GAMEPAD_Y,
}

-- Names offered in the UI for the crouch button.
M.BUTTON_NAMES = { "A", "B", "X", "Y", "LB", "RB", "LS", "RS", "LT", "RT",
                   "START", "BACK", "DPAD_UP", "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT" }

local handles = {}
local sources = {}
local injected = {}     -- button name -> true, cleared each frame

M.device = nil
M.block_stick_pitch = false   -- gameplay: right stick up/down off (game.lua)
M.left_trigger = 0            -- what the player is pulling on LT (0-255), before force_lt
M.right_trigger = 0           -- and on RT
M.force_lt = false            -- grip raises the C.A.T.: send LT fully pulled (game.lua)
M.block_lt = false            -- LT doesn't raise the C.A.T. (panel option): LT kept from the game
M.clear_rb = false            -- ...and drop the RB (lean) that UEVR maps the right grip to
M.lean_left_grip = false      -- gameplay: left grip sends RB (lean) instead of LB (game.lua)
M.block_turn = false          -- C.A.T. out: right stick X hidden from the game (game.lua turns instead)
M.inject_rx = nil             -- C.A.T. turn handover: right stick X pushed for the player (game.lua)
M.y_to_menu = false           -- Y is kept from the game (it opens the menu instead; game.lua)
M.start_pulse = 0.0           -- seconds left of a Start press sent for a Y tap
M.swap_triggers = false       -- left-handed: left index interacts (RT), right trigger is the off one
M.focus = false               -- the off-hand trigger sends Focus (D-pad up; game.lua)
M.xi_in = 0                   -- buttons UEVR sent in the last poll, before any edits
M.xi_seen = 0                 -- every button UEVR sent in any poll since the last take_seen()
M.polls = 0                   -- XInput polls so far
M.right_grip = false          -- right grip as read on the engine tick (game.lua), for raising the C.A.T.
M.diag = { polls = 0, gate = "?", rb_in = false, rb_out = false, lt_out = 0, rx_out = 0,
           rgrip = false, clear = false, wb_in = 0, wb_clear = -1, wb_out = 0 }

M.auto_device = false         -- the layout follows the detected headset
M.detected_name = nil         -- headset name from UEVR's log, once read
local detect_timer, detect_tries = 0.0, 0
local DETECT_INTERVAL, DETECT_TRIES = 2.0, 30

-- id = a layout from devices.order, or "auto" (detect from the headset;
-- Touch layout until the name is known).
function M.set_device(id)
    M.auto_device = id == "auto"
    if M.auto_device then
        M.detected_name = devices.read_system_name()
        id = devices.from_system_name(M.detected_name) or "quest_touch"
        detect_timer, detect_tries = 0.0, 0
    end
    M.device = devices.get(id)
    devices.apply_uevr_overrides(M.device)
    print("[routine_vr] controller layout: " .. M.device.name
        .. (M.auto_device and (" (auto, headset: " .. tostring(M.detected_name) .. ")") or ""))
end

-- Auto-detect keeps looking until UEVR has logged the headset (it starts
-- OpenXR after the scripts load), for about a minute.
function M.tick_detect(delta)
    if not M.auto_device or M.detected_name ~= nil or detect_tries >= DETECT_TRIES then return end
    detect_timer = detect_timer + delta
    if detect_timer < DETECT_INTERVAL then return end
    detect_timer = 0.0
    detect_tries = detect_tries + 1
    local name = devices.read_system_name()
    if name ~= nil then M.set_device("auto") end
end

function M.reset()
    handles = {}
    sources = {}
end

local function action_handle(path)
    local h = handles[path]
    if h == nil then
        h = vr.get_action_handle(path)
        handles[path] = h
    end
    return h
end

local function source(hand)
    -- Re-query until valid; handles are 0 before the runtime finishes init.
    local s = sources[hand]
    if s == nil or s == 0 then
        s = hand == "left" and vr.get_left_joystick_source() or vr.get_right_joystick_source()
        sources[hand] = s
    end
    return s
end

local axis = UEVR_Vector2f.new()

local function quadrant(hand, dir)
    vr.get_joystick_axis(source(hand), axis)
    local x, y = axis.x, axis.y
    if x * x + y * y < 0.25 then return false end -- centre of the pad = no quadrant
    if math.abs(y) >= math.abs(x) then
        return (dir == "up" and y > 0) or (dir == "down" and y < 0)
    end
    return (dir == "right" and x > 0) or (dir == "left" and x < 0)
end

-- Is a physical input (by name from devices.inputs) held right now?
function M.is_held(name)
    local def = devices.inputs[name]
    if def == nil then return false end

    local h = action_handle(def.action)
    if h == nil or h == 0 then return false end

    local active
    if def.hand == nil then
        active = vr.is_action_active(h, source("left")) or vr.is_action_active(h, source("right"))
    else
        active = vr.is_action_active(h, source(def.hand))
    end

    if active and def.dir ~= nil then
        return quadrant(def.hand, def.dir)
    end
    return active
end

function M.any_held(list)
    if list == nil then return false end
    for _, name in ipairs(list) do
        if M.is_held(name) then return true end
    end
    return false
end

-- Injections last from one engine tick to the next, so a game that polls
-- XInput several times per frame sees them every time.
function M.begin_frame()
    injected = {}
end

function M.inject(button) injected[button] = true end

-- Buttons UEVR sent since the last call, for reads on the engine tick
-- (face buttons included; UEVR's direct reads of them came back false).
-- nil when the game hasn't polled since, so the caller keeps what it had.
local seen_polls = -1
function M.take_seen()
    if M.polls == seen_polls then return nil end
    seen_polls = M.polls
    local b = M.xi_seen
    M.xi_seen = 0
    return b
end

function M.right_stick_x()
    vr.get_joystick_axis(source("right"), axis)
    return axis.x
end

-- Grip-raised C.A.T., lean on the left grip and the C.A.T.-out turn
-- (game.lua): applied last, whichever mapping ran. Written through state.Gamepad
-- directly, like UEVR's own examples; edits through a local copy of
-- state.Gamepad never reached the game.
local function apply_overrides(state)
    -- Which grip is which comes from UEVR's own mapping (left grip -> LB,
    -- right grip -> RB): reading the grips per hand with is_action_active
    -- got the left grip wrong (true while only the right was held).
    local wb_in = state.Gamepad.wButtons
    local right_grip = wb_in & XINPUT_GAMEPAD_RIGHT_SHOULDER ~= 0
    local left_grip = wb_in & XINPUT_GAMEPAD_LEFT_SHOULDER ~= 0
    M.diag.rb_in = right_grip
    M.diag.rgrip, M.diag.clear = right_grip, M.clear_rb
    M.diag.wb_in, M.diag.wb_clear = state.Gamepad.wButtons, -1

    -- Left-handed: the left index is the interact trigger (RT) and the
    -- right trigger becomes the off-hand one.
    local off_trigger = M.left_trigger
    if M.swap_triggers then
        state.Gamepad.bRightTrigger = M.left_trigger
        state.Gamepad.bLeftTrigger = M.right_trigger
        off_trigger = M.right_trigger
    end
    -- Focus is on the D-pad, awkward on motion controllers: the off-hand
    -- trigger sends it (when it isn't raising the C.A.T.).
    if M.focus and off_trigger > 128 then
        state.Gamepad.wButtons = state.Gamepad.wButtons | XINPUT_GAMEPAD_DPAD_UP
    end
    if M.force_lt then
        state.Gamepad.bLeftTrigger = 255
    elseif M.block_lt then
        state.Gamepad.bLeftTrigger = 0
    end
    -- The main hand's grip raises the C.A.T. instead of reaching the game
    -- (right-handed: RB, which is lean; left-handed: LB).
    local main_bit = M.main_grip_bit or XINPUT_GAMEPAD_RIGHT_SHOULDER
    if M.clear_rb and wb_in & main_bit ~= 0 then
        state.Gamepad.wButtons = state.Gamepad.wButtons & ~main_bit
        M.diag.wb_clear = state.Gamepad.wButtons
    end
    -- Lean moves to the left grip, which Routine doesn't otherwise use.
    if M.lean_left_grip then
        state.Gamepad.wButtons = state.Gamepad.wButtons & ~XINPUT_GAMEPAD_LEFT_SHOULDER
        if left_grip then
            state.Gamepad.wButtons = state.Gamepad.wButtons | XINPUT_GAMEPAD_RIGHT_SHOULDER
        end
    end
    if M.block_turn then
        state.Gamepad.sThumbRX = 0
    end
    if M.inject_rx ~= nil then
        state.Gamepad.sThumbRX = M.inject_rx
    end
    -- Y opens the menu: Y itself never reaches the game, and a tap sends
    -- Start for a moment (game.lua decides what counts as a tap).
    if M.y_to_menu then
        state.Gamepad.wButtons = state.Gamepad.wButtons & ~XINPUT_GAMEPAD_Y
    end
    if M.start_pulse > 0 then
        state.Gamepad.wButtons = state.Gamepad.wButtons | XINPUT_GAMEPAD_START
    end
    if M.block_stick_pitch then
        state.Gamepad.sThumbRY = 0
    end
    for button in pairs(injected) do
        if button == "LT" then
            state.Gamepad.bLeftTrigger = 255
        elseif button == "RT" then
            state.Gamepad.bRightTrigger = 255
        elseif M.BITS[button] then
            state.Gamepad.wButtons = state.Gamepad.wButtons | M.BITS[button]
        end
    end

    M.diag.rb_out = state.Gamepad.wButtons & XINPUT_GAMEPAD_RIGHT_SHOULDER ~= 0
    M.diag.wb_out = state.Gamepad.wButtons
    M.diag.lt_out = state.Gamepad.bLeftTrigger
    M.diag.rx_out = state.Gamepad.sThumbRX
end

-- Called from on_xinput_get_state. Mutates state in place.
function M.apply(state)
    M.diag.polls = M.diag.polls + 1
    M.diag.gate = (vr.is_runtime_ready() and "ready" or "not ready") .. ", "
        .. (vr.is_using_controllers() and "using controllers" or "NOT using controllers")
    M.xi_in = state.Gamepad.wButtons
    M.xi_seen = M.xi_seen | M.xi_in
    M.polls = M.polls + 1
    M.apply_mapping(state)
    apply_overrides(state)
end

-- What the player pulls on the triggers, before any edits.
function M.apply_mapping(state)
    M.left_trigger = state.Gamepad.bLeftTrigger or 0
    M.right_trigger = state.Gamepad.bRightTrigger or 0
end

return M
