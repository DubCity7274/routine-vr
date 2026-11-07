-- C.A.T. recorder, for working out how Routine raises, inspects and clicks
-- the C.A.T. without a UE5 SDK dump.
--
-- Started from the panel. It writes data/routine_vr_probe.json: first the
-- C.A.T.'s class chain, properties, functions and components, then for
-- RECORD_SECONDS every number/boolean property on the C.A.T., the pawn and
-- the player controller that changes, timestamped, with LT and the mod's
-- own raised/inspecting flags alongside. Do things one at a time (raise,
-- lower, inspect, press each side button) and the changes line up.

local game = require("routine_vr.game")
local input = require("routine_vr.input")
local touch = require("routine_vr.touch")
local roomscale = require("routine_vr.roomscale")
local motion_hands = require("routine_vr.motion_hands")
local handed = require("routine_vr.handed")
local health = require("routine_vr.health")

local M = {}

local FILE = "routine_vr_probe.json"
local PREV_FILE = "routine_vr_probe_prev.json"   -- the recording before this one
local RECORD_SECONDS = 40.0
local SAMPLE_INTERVAL = 0.1
local SAVE_INTERVAL = 2.0

M.status = "Not recording."

local lines = {}
local running = false
local elapsed, sample_timer, save_timer = 0.0, 0.0, 0.0
local watched = {}  -- { label, obj, names, last }
local last_flags = nil

local function safe(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

local function fname(obj)
    return safe(function() return obj:get_fname():to_string() end) or "?"
end

local function super_of(s)
    return safe(function() return s:get_super_struct() end) or safe(function() return s:get_super() end)
end

local function add(text)
    lines[#lines + 1] = text
end

-- Property names (with types) of a class and its parents.
local function properties(cls)
    local out = {}
    local s = cls
    while s ~= nil do
        local f = safe(function() return s:get_child_properties() end)
        while f ~= nil do
            local name = fname(f)
            local kind = safe(function() return f:get_class():get_fname():to_string() end) or "?"
            out[#out + 1] = { name = name, kind = kind, owner = fname(s) }
            f = safe(function() return f:get_next() end)
        end
        s = super_of(s)
    end
    return out
end

local function functions(cls)
    local out = {}
    local u = safe(function() return cls:get_children() end)
    while u ~= nil do
        out[#out + 1] = fname(u)
        u = safe(function() return u:get_next() end)
    end
    return out
end

-- Every function up the class chain, with parameter names and types,
-- to find what presses an interact component.
local function functions_with_params(cls)
    local s = cls
    while s ~= nil do
        local owner = fname(s)
        if owner == "Object" or owner == "ActorComponent" then break end
        local u = safe(function() return s:get_children() end)
        while u ~= nil do
            local params = {}
            local f = safe(function() return u:get_child_properties() end)
            while f ~= nil do
                local kind = safe(function() return f:get_class():get_fname():to_string() end) or "?"
                params[#params + 1] = fname(f) .. ":" .. kind
                f = safe(function() return f:get_next() end)
            end
            add(string.format("  func %s.%s(%s)", owner, fname(u), table.concat(params, ", ")))
            u = safe(function() return u:get_next() end)
        end
        s = super_of(s)
    end
end

local function describe(label, obj, with_structs)
    local cls = safe(function() return obj:get_class() end)
    if cls == nil then
        add(label .. ": not found")
        return {}
    end

    local chain = {}
    local s = cls
    while s ~= nil do
        chain[#chain + 1] = fname(s)
        s = super_of(s)
    end
    add(label .. " class: " .. table.concat(chain, " > "))

    local props = properties(cls)
    local names = {}
    for _, p in ipairs(props) do
        add(string.format("  prop %s.%s : %s", p.owner, p.name, p.kind))
        if p.kind == "BoolProperty" or p.kind == "FloatProperty" or p.kind == "DoubleProperty"
            or p.kind == "IntProperty" or p.kind == "ByteProperty" or p.kind == "EnumProperty"
            or (with_structs and p.kind == "StructProperty") then
            names[#names + 1] = p.name
        end
    end
    for _, f in ipairs(functions(cls)) do
        add("  func " .. f)
    end
    return names
end

local function value_of(obj, name)
    local v = safe(function() return obj[name] end)
    local t = type(v)
    if t == "number" then return string.format("%.3f", v) end
    if t == "boolean" then return tostring(v) end
    -- Rotators and vectors (where the facing is likely kept), one decimal.
    if t == "userdata" or t == "table" then
        local r = safe(function() return string.format("P%.1f Y%.1f R%.1f", v.Pitch, v.Yaw, v.Roll) end)
        if r then return r end
        return safe(function() return string.format("(%.1f %.1f %.1f)", v.X, v.Y, v.Z) end)
    end
    return nil
end

local function components(label, actor)
    local scene = uevr.api:find_uobject("Class /Script/Engine.SceneComponent")
    local comps = safe(function() return actor:K2_GetComponentsByClass(scene) end)
    if type(comps) ~= "table" then return end
    for _, c in ipairs(comps) do
        local cls = safe(function() return c:get_class():get_fname():to_string() end) or "?"
        local parent = safe(function() return fname(c.AttachParent) end) or "-"
        add(string.format("  component %s (%s) under %s", fname(c), cls, parent))
    end
end

local function flags()
    return string.format("LT=%d raised=%s inspecting=%s touching=%s presses=%d error=%s gate=%s rb_in=%s rb_out=%s lt_out=%s rx_out=%s rgrip=%s clear=%s wb=%s/%s/%s polls=%s turn=%s view_turn=%.0f handover=%s yaws=%s inject=%s buttons=0x%04x recenter=%.2f chord=%s sig=%s hand=%s cat=%s@%s scale=%s hands=%s crouch=%s frame=%.1fms/worst %.1fms sync=%s start=%.2f", input.left_trigger or 0,
        tostring(game.raised), tostring(game.inspecting), tostring(touch.touching),
        touch.presses or 0, tostring(touch.last_error), tostring(input.diag.gate), tostring(input.diag.rb_in),
        tostring(input.diag.rb_out), tostring(input.diag.lt_out), tostring(input.diag.rx_out), tostring(input.diag.rgrip), tostring(input.diag.clear),
        tostring(input.diag.wb_in), tostring(input.diag.wb_clear), tostring(input.diag.wb_out), tostring(input.diag.polls),
        game.turn_method_name(), game.view_turn or 0, tostring(game.last_handover), game.yaw_readings_text(), tostring(input.inject_rx), input.xi_in or 0,
        roomscale.recenter_progress or 0, (function()
            local ok, bits, b, y = pcall(roomscale.chord_sources)
            if not ok then return "err" end
            return string.format("bits:%s B:%s Y:%s", tostring(bits), tostring(b), tostring(y))
        end)() .. (game.turn_error and (" err " .. game.turn_error) or ""),
        tostring(touch.signature), handed.main(), tostring(motion_hands.cat_place), tostring(motion_hands.cat_where), tostring(motion_hands.cat_scale), motion_hands.hidden_by_game and "rehidden" or "ok",
        roomscale.standing_y and string.format("%s/head %.2f/stand %.2f/%s", roomscale.crouched and "down" or "up",
            roomscale.head_y or 0, roomscale.standing_y, tostring(roomscale.crouch_method)) or ("uncalibrated/" .. tostring(roomscale.status)),
        M.frame_ms, M.worst_ms, health.broken and ("broken/" .. health.warnings) or ("ok/" .. health.warnings),
        input.start_pulse or 0)
end

local function save()
    local ok, err = pcall(json.dump_file, FILE, { lines = lines }, 1)
    if not ok then M.status = "Could not write " .. FILE .. ": " .. tostring(err) end
end

function M.start()
    local ok_prev, prev = pcall(json.load_file, FILE)
    if ok_prev and type(prev) == "table" then pcall(json.dump_file, PREV_FILE, prev, 1) end

    lines, watched = {}, {}
    elapsed, sample_timer, save_timer = 0.0, 0.0, 0.0

    local cat_class = uevr.api:find_uobject("Class /Script/Routine.RoutineGameCAT")
    local cat = cat_class and UEVR_UObjectHook.get_first_object_by_class(cat_class, false)
    local pawn = uevr.api:get_local_pawn(0)
    local pc = uevr.api:get_player_controller(0)

    local deadzone = cat and safe(function() return cat.DeadzoneComponent end)
    local pov = cat and safe(function() return cat.POVComponent end)
    -- Routine's own view/control components: where the character's facing
    -- lives, since SetControlRotation and AddYawInput don't turn it.
    local view = pawn and safe(function() return pawn.ViewComponent end)
    local control = pawn and safe(function() return pawn.ControlComponent end)
    local structs = { pawn_view = true, pawn_control = true, CAT_pov = true }
    for _, w in ipairs({ { "CAT", cat }, { "pawn", pawn }, { "controller", pc },
                         { "CAT_deadzone", deadzone }, { "CAT_pov", pov },
                         { "pawn_view", view }, { "pawn_control", control } }) do
        local label, obj = w[1], w[2]
        if obj ~= nil then
            local names = describe(label, obj, structs[label])
            if label == "pawn_view" or label == "pawn_control" then
                local cls = safe(function() return obj:get_class() end)
                if cls then functions_with_params(cls) end
            end
            if label == "CAT" or label == "pawn" then components(label, obj) end
            local last = {}
            for _, n in ipairs(names) do last[n] = value_of(obj, n) end
            watched[#watched + 1] = { label = label, obj = obj, names = names, last = last }
        else
            add(label .. ": not found")
        end
    end

    -- The side buttons: their class once, then watch each one.
    if cat ~= nil then
        local first = true
        for _, b in ipairs(touch.BUTTONS) do
            local comp = safe(function() return cat["Interact_" .. b] end)
            if comp ~= nil then
                local label = "Interact_" .. b
                local names
                if first then
                    names = describe(label, comp)
                    local cls = safe(function() return comp:get_class() end)
                    if cls ~= nil then functions_with_params(cls) end
                    first = false
                else
                    names = {}
                    local cls = safe(function() return comp:get_class() end)
                    for _, p in ipairs(cls and properties(cls) or {}) do
                        if p.kind == "BoolProperty" or p.kind == "FloatProperty" or p.kind == "DoubleProperty"
                            or p.kind == "IntProperty" or p.kind == "ByteProperty" or p.kind == "EnumProperty" then
                            names[#names + 1] = p.name
                        end
                    end
                end
                local last = {}
                for _, n in ipairs(names) do last[n] = value_of(comp, n) end
                watched[#watched + 1] = { label = label, obj = comp, names = names, last = last }
            end
        end
    end

    add(string.format("t=0.0 start %s", flags()))
    running = true
    M.status = string.format("Recording for %d s...", RECORD_SECONDS)
    save()
end

-- Frame time, smoothed, and the worst frame in the last second: for the
-- jitter that only a restart cured (is the game slowing down?).
M.frame_ms, M.worst_ms = 0.0, 0.0
local worst_window, worst_timer = 0.0, 0.0

function M.tick(delta)
    local ms = (delta or 0) * 1000
    M.frame_ms = M.frame_ms == 0 and ms or (M.frame_ms * 0.95 + ms * 0.05)
    worst_window = math.max(worst_window, ms)
    worst_timer = worst_timer + (delta or 0)
    if worst_timer >= 1.0 then
        M.worst_ms, worst_window, worst_timer = worst_window, 0.0, 0.0
    end
    if not running then return end
    elapsed = elapsed + delta
    sample_timer = sample_timer + delta
    save_timer = save_timer + delta

    if sample_timer >= SAMPLE_INTERVAL then
        sample_timer = 0.0
        local changes = {}
        for _, w in ipairs(watched) do
            for _, n in ipairs(w.names) do
                local v = value_of(w.obj, n)
                if v ~= w.last[n] then
                    changes[#changes + 1] = string.format("%s.%s %s->%s", w.label, n, tostring(w.last[n]), tostring(v))
                    w.last[n] = v
                end
            end
        end
        local f = flags()
        if #changes > 0 or f ~= last_flags then
            add(string.format("t=%.1f %s | %s", elapsed, f, table.concat(changes, ", ")))
        end
        last_flags = f
        M.status = string.format("Recording... %d s left", math.max(0, math.ceil(RECORD_SECONDS - elapsed)))
    end

    if elapsed >= RECORD_SECONDS then
        running = false
        save()
        M.status = "Done. Saved data/" .. FILE .. " (" .. #lines .. " lines)."
    elseif save_timer >= SAVE_INTERVAL then
        save_timer = 0.0
        save()
    end
end

function M.reset()
    running = false
    watched = {}
end

return M
