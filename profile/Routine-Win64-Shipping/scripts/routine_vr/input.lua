-- Turns VR controller state into the XInput gamepad state Routine reads.
--
-- Ownership split with UEVR:
--   * face buttons, bumpers, stick clicks, triggers: rebuilt here from the
--     active device layout, so every headset gets an explicit mapping.
--   * thumbsticks, START, BACK, d-pad: left as UEVR produced them, because
--     UEVR's snap turn, d-pad shifting and menu combos live there.
-- Other modules can press buttons (inject) or hide them (suppress) for a frame.

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

-- Names offered in the UI for crouch/remap targets.
M.BUTTON_NAMES = { "A", "B", "X", "Y", "LB", "RB", "LS", "RS", "LT", "RT",
                   "START", "BACK", "DPAD_UP", "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT" }

local UEVR_OWNED = M.BITS.START | M.BITS.BACK
    | M.BITS.DPAD_UP | M.BITS.DPAD_DOWN | M.BITS.DPAD_LEFT | M.BITS.DPAD_RIGHT

local handles = {}
local sources = {}
local injected = {}     -- button name -> true, cleared each frame
local suppressed = {}   -- physical input name -> true, cleared each frame

M.device = nil
M.block_right_stick = false   -- set by terminal mode (movement.lua)
M.block_stick_pitch = false   -- gameplay: right stick up/down off (game.lua)
M.trigger_sends = nil         -- terminal mode: right trigger sent as this button
M.last_sent = ""              -- buttons sent on the last poll, for the panel
M.left_trigger = 0            -- what the player is pulling on LT (0-255), before force_lt
M.right_trigger = 0           -- and on RT
M.force_lt = false            -- grip raises the C.A.T.: send LT fully pulled (game.lua)
M.block_lt = false            -- LT doesn't raise the C.A.T. (panel option): LT kept from the game
M.clear_rb = false            -- ...and drop the RB (lean) that UEVR maps the right grip to
M.lean_left_grip = false      -- gameplay: left grip sends RB (lean) instead of LB (game.lua)
M.block_turn = false          -- C.A.T. out: right stick X hidden from the game (game.lua turns instead)
M.inject_rx = nil             -- C.A.T. turn handover: right stick X pushed for the player (game.lua)
M.xi_in = 0                   -- buttons UEVR sent in the last poll, before any edits
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
    if suppressed[name] then return false end

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

-- Injections and suppressions last from one engine tick to the next, so a
-- game that polls XInput several times per frame sees them every time.
function M.begin_frame()
    injected, suppressed = {}, {}
end

function M.inject(button) injected[button] = true end
function M.suppress(input) suppressed[input] = true end

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

    if M.force_lt then
        state.Gamepad.bLeftTrigger = 255
    elseif M.block_lt then
        state.Gamepad.bLeftTrigger = 0
    end
    -- The right grip raises the C.A.T. instead of leaning.
    if M.clear_rb and right_grip then
        state.Gamepad.wButtons = state.Gamepad.wButtons & ~XINPUT_GAMEPAD_RIGHT_SHOULDER
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
    if M.block_stick_pitch then
        state.Gamepad.sThumbRY = 0
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
    M.apply_mapping(state)
    apply_overrides(state)
end

function M.apply_mapping(state)
    M.left_trigger = state.Gamepad.bLeftTrigger or 0
    M.right_trigger = state.Gamepad.bRightTrigger or 0

    local device = M.device
    if device == nil then return end

    -- Leave a real gamepad alone when the player isn't using motion controllers.
    if not vr.is_runtime_ready() or not vr.is_using_controllers() then
        return
    end

    local gp = state.Gamepad

    if M.block_right_stick then
        gp.sThumbRX, gp.sThumbRY = 0, 0
    end

    -- Layout switched off in the panel: UEVR's own mapping goes through as-is.
    if not settings.get("custom_buttons") then
        return
    end

    -- UEVR's overlay is open: it already filtered the state, don't add to it.
    if uevr.params.functions.is_drawing_ui() then
        return
    end

    local pressed = {}
    for button, inputs in pairs(device.buttons) do
        if M.any_held(inputs) then pressed[button] = true end
    end
    for trig, inputs in pairs(device.triggers) do
        if M.any_held(inputs) then pressed[trig] = true end
    end

    -- Both stick clicks together is UEVR's menu toggle; keep it out of the game.
    if pressed.LS and pressed.RS then
        pressed.LS, pressed.RS = nil, nil
    end

    if M.trigger_sends ~= nil and pressed.RT then
        pressed.RT = nil
        pressed[M.trigger_sends] = true
    end

    for button in pairs(injected) do pressed[button] = true end

    -- User remaps: logical button -> different gamepad button.
    local remap = settings.get("remap") or {}
    local out = {}
    for button in pairs(pressed) do
        out[remap[button] or button] = true
    end

    local bits = gp.wButtons & UEVR_OWNED
    for button in pairs(out) do
        local bit = M.BITS[button]
        if bit ~= nil then bits = bits | bit end
    end

    gp.wButtons = bits
    gp.bLeftTrigger = out.LT and 255 or 0
    gp.bRightTrigger = out.RT and 255 or 0

    local names = {}
    for _, name in ipairs(M.BUTTON_NAMES) do
        local bit = M.BITS[name]
        if (bit ~= nil and bits & bit ~= 0) or (name == "LT" and out.LT) or (name == "RT" and out.RT) then
            names[#names + 1] = name
        end
    end
    M.last_sent = table.concat(names, " ")
end

return M
