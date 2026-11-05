-- Which way the left stick moves you, and cursor mode for terminals.
--
-- UEVR's MovementOrientation rotates the left stick by the left controller
-- (or head) whenever it differs from AimMethod, and it does that everywhere,
-- including menus, where it makes "up" point wherever your hand happens to.
-- So the profile ships with MovementOrientation = Game (raw stick) and this
-- module switches to the chosen hand/head only while you're in gameplay.
--
-- Terminal mode (cursor_mode in code): Routine's terminal cursor sits where
-- the camera points, which with right-controller aim is where your right hand
-- points (or your head, if terminal_aim = "head"). Once you have the C.A.T.,
-- RT (Interact / Fire) raises the C.A.T. instead of clicking, so in terminal
-- mode the right trigger is sent as Interact (X) and the right stick is cut
-- off so it can't turn you. Left grip + right stick click or the panel
-- button toggles it. Snap turn is also off in menus.

local settings = require("routine_vr.settings")
local input = require("routine_vr.input")

local M = {}

local vr = uevr.params.vr

-- settings.move_direction -> UEVR MovementOrientation index
M.CHOICES = { "aim", "left_hand", "head" }
M.LABELS = { "Where you aim (right hand)", "Where your left hand points", "Where you look" }
local ORIENTATION = { aim = 0, left_hand = 3, head = 1 }
local AIM_HEAD = "1"
local AIM_GAMEPLAY = "2"   -- game.lua's gameplay AimMethod

local CHECK_INTERVAL = 0.25

M.in_menu = true
M.force_menu = false    -- set by game.lua outside gameplay (main menu has a pawn)
M.cursor_mode = false   -- manual toggle
local applied = nil
local applied_snap = nil
local timer = CHECK_INTERVAL
local toggle_was_held = false
local aim_changed = false

-- Menus, loading screens and terminal/cursor screens.
local function detect_menu()
    if M.force_menu then return true end

    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then return true end

    local pc = uevr.api:get_player_controller(0)
    if pc == nil then return true end

    local ok, cursor = pcall(function() return pc.bShowMouseCursor end)
    if ok and cursor == true then return true end

    return false
end

local function apply(value)
    if value == applied then return end
    applied = value
    vr.set_mod_value("VR_MovementOrientation", tostring(value))
end

local function apply_snap(on)
    if on == applied_snap then return end
    applied_snap = on
    vr.set_mod_value("VR_SnapTurn", on and "true" or "false")
end

-- terminal_aim = "head": aim with the head while in terminal mode.
-- (vr.get_mod_value throws in this UEVR build, so the gameplay value is
-- restored rather than whatever was set before.)
local function apply_cursor_aim(on)
    if on and not aim_changed and settings.get("terminal_aim") == "head" then
        aim_changed = true
        vr.set_mod_value("VR_AimMethod", AIM_HEAD)
    elseif not on and aim_changed then
        aim_changed = false
        vr.set_mod_value("VR_AimMethod", AIM_GAMEPLAY)
    end
end

function M.set_cursor_mode(on)
    M.cursor_mode = on
    apply_cursor_aim(on)
    input.block_right_stick = on
    input.trigger_sends = on and settings.get("terminal_trigger") or nil
    vr.trigger_haptic_vibration(0.0, 0.08, 1.0, on and 1.0 or 0.4, vr.get_right_joystick_source())
end

-- Left grip + right stick click. The click is hidden from the game while
-- the grip is held, so the chord doesn't also send RS.
local function update_toggle()
    local grip = input.is_held("grip_l")
    local click = grip and input.is_held("stick_click_r")
    if grip then input.suppress("stick_click_r") end
    if click and not toggle_was_held then M.set_cursor_mode(not M.cursor_mode) end
    toggle_was_held = click
end

function M.snap_turn_active()
    return settings.get("snap_turn") and not M.in_menu and not M.cursor_mode
end

function M.tick(delta)
    update_toggle()

    timer = timer + delta
    if timer < CHECK_INTERVAL then return end
    timer = 0.0

    M.in_menu = detect_menu()

    local wanted = ORIENTATION[settings.get("move_direction")] or 0
    apply(M.in_menu and 0 or wanted)
    apply_snap(M.snap_turn_active())
end

function M.reset()
    apply_cursor_aim(false)
    input.block_right_stick = false
    input.trigger_sends = nil
    applied, applied_snap = nil, nil
    M.cursor_mode, toggle_was_held = false, false
    timer = CHECK_INTERVAL
end

return M
