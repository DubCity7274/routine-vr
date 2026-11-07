-- Room-scale extras on top of UEVR's own VR_RoomscaleMovement (which moves
-- the pawn with your real-world head position, with collision sweeps):
--
--   * standing height calibration (auto on first frames, or the panel button)
--   * physical crouch -> the game's crouch button, kept in sync with the
--     pawn's bIsCrouched when the game exposes it
--   * recenter view + reset standing origin + recalibrate (panel button)

local settings = require("routine_vr.settings")
local input = require("routine_vr.input")

local M = {}

local vr = uevr.params.vr

local hmd_pos = UEVR_Vector3f.new()
local hmd_rot = UEVR_Quaternionf.new()

local PULSE_SECONDS = 0.2       -- how long a toggle "tap" holds the button (a real press is ~0.2 s)
local SYNC_TIMEOUT = 0.6        -- time for bIsCrouched to react to a tap
local AUTO_CALIBRATE_DELAY = 3.0

M.standing_y = nil
M.head_y = 0.0
M.crouched = false              -- physical state
M.status = "waiting for headset"

local ready_time = 0.0
local recenter_held = 0.0       -- how long B + Y have been held together
M.recenter_progress = 0.0       -- 0..1 for the panel
local pulse_left = 0.0
local waiting_sync = 0.0
local sync_reliable = nil       -- nil = unknown, true/false once tested

local function read_head()
    vr.get_pose(vr.get_hmd_index(), hmd_pos, hmd_rot)
    return hmd_pos.y
end

function M.calibrate()
    M.standing_y = read_head()
    M.crouched = false
    M.status = string.format("calibrated, standing head at %.2f m", M.standing_y)
    print("[routine_vr] " .. M.status)
end

M.on_recenter = nil   -- set by routine_vr.lua (game.clear_view_turn)

function M.recenter()
    vr.recenter_view()
    if M.on_recenter then M.on_recenter() end
    read_head()
    vr.set_standing_origin(hmd_pos)
    M.calibrate()
end

-- Reads ACharacter::bIsCrouched if the pawn has it. Returns nil when unknown.
local function pawn_crouched()
    if sync_reliable == false then return nil end
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then return nil end
    local ok, value = pcall(function() return pawn.bIsCrouched end)
    if ok and type(value) == "boolean" then return value end
    sync_reliable = false
    return nil
end

local function tap()
    pulse_left = PULSE_SECONDS
end

-- The game's own crouch: ACharacter::Crouch / UnCrouch on the pawn. Routine
-- crouches the standard Unreal way (bIsCrouched), so this needs no button
-- (a tapped button only works if the game's crouch is a toggle). If the
-- pawn's bIsCrouched doesn't follow within SYNC_TIMEOUT, it's given up on
-- and the button is used instead.
local call_works = nil          -- nil = untested, true/false once seen
local call_wait = 0.0           -- time left to see bIsCrouched follow a call
M.crouch_method = "untested"    -- for the panel and the recorder

local function call_crouch(want)
    if call_works == false then return false end
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then return false end
    local ok = pcall(function()
        if want then pawn:Crouch(false) else pawn:UnCrouch(false) end
    end)
    if not ok then
        call_works = false
        return false
    end
    if call_works == nil then call_wait = SYNC_TIMEOUT end
    return true
end

local function update_crouch(delta)
    if not settings.get("physical_crouch") or M.standing_y == nil then return end

    local drop = M.standing_y - M.head_y
    local enter = settings.get("crouch_drop")
    local leave = enter - settings.get("crouch_hysteresis")

    local was = M.crouched
    if not M.crouched and drop > enter then
        M.crouched = true
    elseif M.crouched and drop < leave then
        M.crouched = false
    end

    local button = settings.get("crouch_button")

    -- A button press already under way finishes first, whatever started it.
    if pulse_left > 0 then
        pulse_left = pulse_left - delta
        input.inject(button)
        return
    end

    -- First choice: the game's own crouch, on each physical change.
    if call_works ~= false then
        if call_wait > 0 then
            call_wait = call_wait - delta
            local game = pawn_crouched()
            if game == M.crouched then
                call_works, call_wait = true, 0
            elseif call_wait <= 0 then
                call_works = false
                print("[routine_vr] Crouch() didn't crouch the pawn; using the crouch button")
                was = not M.crouched -- let the button take this change
            end
        end
        if call_works ~= false then
            M.crouch_method = call_works and "game crouch" or "trying the game crouch"
            if was == M.crouched or call_crouch(M.crouched) then return end
            -- Couldn't call it (no pawn, or no Crouch): the button takes this change.
        end
    end
    M.crouch_method = "button " .. button .. " (" .. settings.get("crouch_mode") .. ")"

    if settings.get("crouch_mode") == "hold" then
        if M.crouched then input.inject(button) end
        return
    end

    -- Toggle mode. Prefer syncing against the game's own crouch flag so a
    -- manual button press can't leave the two out of step.

    local game = pawn_crouched()

    if game ~= nil and sync_reliable ~= false then
        if waiting_sync > 0 then
            waiting_sync = waiting_sync - delta
            if game == M.crouched then
                waiting_sync = 0
                sync_reliable = true
            elseif waiting_sync <= 0 and sync_reliable == nil then
                -- The flag never moved after a tap: the game crouches some
                -- other way. Fall back to tapping on physical edges only.
                sync_reliable = false
                print("[routine_vr] bIsCrouched does not follow the crouch button; using edge taps")
            end
            return
        end

        if game ~= M.crouched then
            tap()
            waiting_sync = SYNC_TIMEOUT
        end
        return
    end

    if was ~= M.crouched then tap() end
end

-- Hold B (right) + Y (left) for settings.recenter_hold seconds: recenter.
-- Works in menus too, for the main menu that starts behind you.
-- B and Y are read from what UEVR sends the game (right B -> B, left Y ->
-- Y): the per-hand VR action reads proved unreliable (see input.lua).
-- Either source counts: the buttons UEVR passes the game (right B can
-- arrive as B or X), or UEVR's own read of the physical B (right) and Y
-- (left) buttons. In the headset no face button ever showed up in the
-- game's input while the chord was held, so the bits alone weren't enough.
function M.chord_sources()
    local bits = input.xi_in or 0
    local from_bits = bits & XINPUT_GAMEPAD_Y ~= 0
        and (bits & XINPUT_GAMEPAD_B ~= 0 or bits & XINPUT_GAMEPAD_X ~= 0)
    local b_ok, b = pcall(input.is_held, "b_r")
    local y_ok, y = pcall(input.is_held, "b_l")
    return from_bits, (b_ok and b) == true, (y_ok and y) == true
end

-- Controllers without B/Y list their own chords (devices/*.lua: recenter).
local function device_chord_held()
    local chords = input.device and input.device.recenter
    if chords == nil then return false end
    for _, chord in ipairs(chords) do
        local all = #chord > 0
        for _, name in ipairs(chord) do
            local ok, v = pcall(input.is_held, name)
            if not (ok and v) then all = false end
        end
        if all then return true end
    end
    return false
end

local function update_recenter_chord(delta)
    local from_bits, b_held, y_held = M.chord_sources()
    local held = from_bits or (b_held and y_held) or device_chord_held()
    if not held then
        recenter_held, M.recenter_progress = 0.0, 0.0
        return
    end
    if recenter_held < 0 then return end -- already fired; wait for release
    recenter_held = recenter_held + delta
    local need = settings.get("recenter_hold")
    M.recenter_progress = math.min(1.0, recenter_held / need)
    if recenter_held >= need then
        M.recenter()
        recenter_held = -1.0
        pcall(function()
            vr.trigger_haptic_vibration(0.0, 0.15, 1.0, 1.0, vr.get_left_joystick_source())
            vr.trigger_haptic_vibration(0.0, 0.15, 1.0, 1.0, vr.get_right_joystick_source())
        end)
    end
end

-- Recenter on its own at the start, so the menus are in front of you
-- instead of behind (it was every start): first on the game's opening
-- screens (the "press any button" splash), once they've been up a few
-- seconds (1.5 s was too early: it went off during loading), then once
-- more when the main menu first appears, which proved reliable. If your
-- head didn't move in between, the second one changes nothing. B + Y and
-- the panel button still work any time after.
local SPLASH_DELAY = 4.0
local MENU_DELAY = 1.0
local splash_done, menu_done = false, false
local splash_time, menu_time = 0.0, 0.0
M.start_recenter_done = false

-- Arm it again (tests; a fresh game start does this by loading the script).
function M.reset_start_recenter()
    splash_done, menu_done, splash_time, menu_time = false, false, 0.0, 0.0
    M.start_recenter_done = false
end

local function start_recenter(why)
    M.start_recenter_done = true
    pcall(M.recenter)
    print("[routine_vr] recentered at start (" .. why .. ")")
end

function M.tick_start_recenter(delta, in_menus, in_main_menu)
    if not settings.get("recenter_on_start") or M.standing_y == nil then return end
    if not splash_done then
        splash_time = in_menus and splash_time + delta or 0.0
        if splash_time >= SPLASH_DELAY then
            splash_done = true
            start_recenter("opening screen")
        end
    end
    if not menu_done then
        menu_time = in_main_menu and menu_time + delta or 0.0
        if menu_time >= MENU_DELAY then
            menu_done, splash_done = true, true
            start_recenter("main menu")
        end
    end
end

function M.tick(delta)
    -- Before the headset check: recentering is for when things look wrong.
    if vr.is_runtime_ready() then update_recenter_chord(delta) end

    -- Ready once the runtime is and the headset has a real pose (UEVR's
    -- is_hmd_active alone may read false under OpenXR, which would leave
    -- calibration and crouch off for good).
    if not vr.is_runtime_ready() then
        M.status = "waiting for headset"
        ready_time = 0.0
        return
    end
    local ok_pose = pcall(read_head)
    if not ok_pose or (hmd_pos.x == 0 and hmd_pos.y == 0 and hmd_pos.z == 0) then
        M.status = "waiting for headset tracking"
        ready_time = 0.0
        return
    end

    M.head_y = hmd_pos.y

    if M.standing_y == nil then
        ready_time = ready_time + delta
        M.status = "stand up straight, calibrating..."
        if ready_time >= AUTO_CALIBRATE_DELAY then M.calibrate() end
        return
    end

    -- Player stood taller than the calibration: follow them up.
    if M.head_y > M.standing_y + 0.08 then
        M.standing_y = M.head_y
    end

    update_crouch(delta)
end

function M.reset()
    M.standing_y = nil
    M.crouched = false
    pulse_left, waiting_sync = 0.0, 0.0
    sync_reliable = nil
    call_works, call_wait = nil, 0.0
    M.crouch_method = "untested"
end

return M
