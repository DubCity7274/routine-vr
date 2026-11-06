-- Which way the left stick moves you, and snap turn.
--
-- UEVR's MovementOrientation rotates the left stick by the left controller
-- (or head) whenever it differs from AimMethod, and it does that everywhere,
-- including menus, where it makes "up" point wherever your hand happens to.
-- So the profile ships with MovementOrientation = Game (raw stick) and this
-- module switches to the chosen hand/head only while you're in gameplay.
-- Snap turn is off in menus.

local settings = require("routine_vr.settings")
local input = require("routine_vr.input")

local M = {}

local vr = uevr.params.vr

-- settings.move_direction -> UEVR MovementOrientation index
M.CHOICES = { "aim", "left_hand", "head" }
M.LABELS = { "Where you aim (right hand)", "Where your left hand points", "Where you look" }
local ORIENTATION = { aim = 0, left_hand = 3, head = 1 }

local CHECK_INTERVAL = 0.25

M.in_menu = true
M.force_menu = false    -- set by game.lua outside gameplay (main menu has a pawn)
local applied = nil
local applied_snap = nil
local timer = CHECK_INTERVAL

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

function M.snap_turn_active()
    return settings.get("snap_turn") and not M.in_menu
end

function M.tick(delta)
    timer = timer + delta
    if timer < CHECK_INTERVAL then return end
    timer = 0.0

    M.in_menu = detect_menu()

    local wanted = ORIENTATION[settings.get("move_direction")] or 0
    apply(M.in_menu and 0 or wanted)
    apply_snap(M.snap_turn_active())
end

function M.reset()
    applied, applied_snap = nil, nil
    timer = CHECK_INTERVAL
end

return M
