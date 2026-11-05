-- Routine VR: room-scale + 6DoF motion controls for ROUTINE (UE 5.5) on UEVR.
-- Entry point; UEVR autoruns every .lua directly inside scripts/.
-- Modules live in scripts/routine_vr/ and are loaded with require.

local settings = require("routine_vr.settings")
local input = require("routine_vr.input")
local roomscale = require("routine_vr.roomscale")
local movement = require("routine_vr.movement")
local hands = require("routine_vr.hands")
local effects = require("routine_vr.effects")
local game = require("routine_vr.game")
local laser = require("routine_vr.laser")
local probe = require("routine_vr.probe")
local touch = require("routine_vr.touch")
local motion_hands = require("routine_vr.motion_hands")
local ui = require("routine_vr.ui")

settings.load()
input.set_device(settings.get("device"))
hands.init()
game.init()
roomscale.on_recenter = game.clear_view_turn

print("[routine_vr] loaded")

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    input.begin_frame()
    roomscale.tick(delta)
    game.tick(delta)
    movement.tick(delta)
    hands.tick(delta)
    laser.tick(delta)
    effects.tick(delta)
    probe.tick(delta)
    motion_hands.tick(delta)
    touch.tick(delta)
end)

uevr.sdk.callbacks.on_early_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
    game.on_stereo_view(view_index)
end)

uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
    input.apply(state)
end)

-- The panel gets its own window next to UEVR's whenever the UEVR menu is
-- open. UEVR's Script UI page is hidden behind "Show Advanced Options",
-- so it isn't used.
local ImGuiCond_FirstUseEver = 4

uevr.sdk.callbacks.on_frame(function()
    if not uevr.params.functions.is_drawing_ui() then return end

    imgui.set_next_window_pos({ 60, 60 }, ImGuiCond_FirstUseEver)
    imgui.set_next_window_size({ 560, 760 }, ImGuiCond_FirstUseEver)
    imgui.begin_window("Routine VR", nil, 0)
    ui.draw()
    imgui.end_window()
end)

uevr.sdk.callbacks.on_script_reset(function()
    input.reset()
    roomscale.reset()
    game.reset()
    movement.reset()
    hands.reset()
    laser.reset()
    effects.reset()
    require("routine_vr.body").reset()
    probe.reset()
    touch.reset()
    motion_hands.reset()
end)
