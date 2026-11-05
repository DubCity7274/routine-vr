-- Camera effects that look fine on a monitor and make people sick in VR.
--
-- Routine's fisheye, grain and sharpen are post-process materials that
-- reading PostProcessVolumes from Lua couldn't reach. KeinZantezuken's
-- PPV/SML pak mod can: it registers "rpp <effect> <0|1>" cheat commands
-- (tools/install-pak-mods.sh puts it in the game's ~mods folder).
-- Cheat commands only run through the player controller's console, not
-- UEVR's execute_command (UEngine::Exec). PlayerController:ConsoleCommand
-- didn't take effect in game (typing the same command in the console did),
-- so they go through KismetSystemLibrary.ExecuteConsoleCommand with the
-- player controller, falling back to ConsoleCommand. They're re-sent every
-- few seconds because new levels bring new post-process volumes.
--
-- Vignette comes from the tonemapper: r.Tonemapper.Quality 0 removes it
-- (a plain cvar, so execute_command is fine).

local settings = require("routine_vr.settings")

local M = {}

M.GROUPS = {
    { key = "remove_fisheye",  label = "Remove fisheye lens",   rpp = "fisheye" },
    { key = "remove_grain",    label = "Remove film grain",     rpp = "grain" },
    { key = "remove_sharpen",  label = "Remove sharpen / pixel look", rpp = "sharpen" },
    { key = "remove_color_grading", label = "Remove color grading", rpp = "colorg", off_value = "0.0", on_value = "1.0" },
    { key = "remove_vignette", label = "Remove vignette (dark screen edges)",
      cvar = { on = "r.Tonemapper.Quality 0", off = "r.Tonemapper.Quality 5" } },
}

local MOD_CLASS = "BlueprintGeneratedClass /Game/Mods/RPP/MOD_RPP.MOD_RPP_C"
local REAPPLY_SECONDS = 5.0

M.mod_loaded = false
M.status = "not checked yet"

local timer = REAPPLY_SECONDS
local cvar_applied = {}
local rpp_applied = {}   -- key -> bool last sent

M.last_error = nil
local kismet = nil

local function console(cmd)
    local pc = uevr.api:get_player_controller(0)
    if pc == nil then return false end

    if kismet == nil then
        local cls = uevr.api:find_uobject("Class /Script/Engine.KismetSystemLibrary")
        kismet = cls and cls:get_class_default_object()
    end

    local ok, err = false, "no KismetSystemLibrary"
    if kismet ~= nil then
        ok, err = pcall(function() kismet:ExecuteConsoleCommand(pc, cmd, pc) end)
    end
    if not ok then
        local ok2, err2 = pcall(function() pc:ConsoleCommand(cmd, false) end)
        if ok2 then return true end
        M.last_error = tostring(err) .. " / " .. tostring(err2)
        return false
    end
    M.last_error = nil
    return true
end

local function check_mod()
    local ok, cls = pcall(function() return uevr.api:find_uobject(MOD_CLASS) end)
    M.mod_loaded = ok and cls ~= nil
end

-- force: re-send the rpp commands even if unchanged (new level).
function M.apply_all(force)
    check_mod()

    for _, g in ipairs(M.GROUPS) do
        local want = settings.get(g.key) == true
        -- Sent even if the mod class isn't found: an unknown command is
        -- harmless, and the class check may miss a loaded mod.
        if g.rpp ~= nil then
            -- Only touch effects this module manages: first pass with the box
            -- unticked leaves the game alone.
            if want or rpp_applied[g.key] ~= nil then
                if force or want ~= rpp_applied[g.key] then
                    console(string.format("rpp %s %s", g.rpp, want and (g.off_value or "0") or (g.on_value or "1")))
                end
                rpp_applied[g.key] = want
            end
        elseif g.cvar ~= nil and want ~= cvar_applied[g.key] then
            if want or cvar_applied[g.key] ~= nil then
                uevr.api:execute_command(want and g.cvar.on or g.cvar.off)
            end
            cvar_applied[g.key] = want
        end
    end

    M.status = M.mod_loaded and "PPV mod: loaded"
        or "PPV mod: not detected (fisheye/grain/sharpen need tools/install-pak-mods.sh)"
    if M.last_error ~= nil then
        M.status = M.status .. "\nCommand error: " .. M.last_error
    end
end

function M.tick(delta)
    timer = timer + delta
    if timer < REAPPLY_SECONDS then return end
    timer = 0.0
    M.apply_all(true)
end

function M.reset()
    timer = REAPPLY_SECONDS
    cvar_applied = {}
    rpp_applied = {}
end

return M
