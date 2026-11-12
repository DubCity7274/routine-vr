-- Touching the C.A.T.'s side buttons with your left hand.
--
-- Each side button is a Routine_InteractComponent_C (Interact_Pow, ...)
-- under a BoxComponent collider (Box_PowCol, ...) on the C.A.T. (found with
-- the recorder, see docs/DESIGN.md). A small sphere rides on the left hand
-- as a fingertip, and every frame while the C.A.T. is out its position is
-- tested against each box. Entering a box buzzes the left controller.
--
-- Pressing calls RoutineGameInteractComponent.Interact() on the matching
-- Interact_* component (settings.touch_press_function), which is what the
-- centre-dot click ends in: clicking a button in the recorder flipped its
-- bEnabled off and on, and buttons with bEnabled off are skipped. One press
-- per touch: leave the box (and wait PRESS_COOLDOWN) to press again.

local settings = require("routine_vr.settings")
local hands = require("routine_vr.hands")
local game = require("routine_vr.game")
local motion_hands = require("routine_vr.motion_hands")
local handed = require("routine_vr.handed")

local M = {}

M.BUTTONS = { "Pow", "Wifi", "Nav", "Amp", "Sec", "Deg" }

local RETRY_SECONDS = 5.0
local MARKER_RADIUS = 1.0
local PRESS_COOLDOWN = 0.4

M.touching = nil      -- button name the fingertip is in, or nil
M.status = "C.A.T. not out."
M.last_error = nil

M.marker = nil
local sphere_class = nil
local owner_pawn = nil
local applied = nil
local shown = nil
local retry_wait = 0.0
local cooldown = 0.0

local function destroy()
    if M.marker ~= nil then
        local m = M.marker
        pcall(function() UEVR_UObjectHook.remove_motion_controller_state(m) end)
        pcall(function() m:K2_DestroyComponent(m) end)
    end
    M.marker, owner_pawn, applied, shown = nil, nil, nil, nil
end

local function signature()
    return string.format("%.3f %.3f %s", settings.get("touch_forward"), settings.get("touch_up"), handed.off())
end

local function place()
    local state = UEVR_UObjectHook.get_or_add_motion_controller_state(M.marker)
    if state == nil then return end
    state:set_hand(handed.index(handed.off()))
    state:set_rotation_offset(hands.rotator_to_offset_quat(0, 0, 0))
    state:set_location_offset(hands.location_to_offset(settings.get("touch_forward"), 0, settings.get("touch_up")))
    state:set_permanent(true)
    applied = signature()
end

local function create(pawn)
    if sphere_class == nil then
        sphere_class = uevr.api:find_uobject("Class /Script/Engine.SphereComponent")
        if sphere_class == nil then return end
    end
    local ok, comp = pcall(function() return uevr.api:add_component_by_class(pawn, sphere_class, false) end)
    if not ok or comp == nil then
        M.last_error = "could not add fingertip: " .. tostring(comp)
        retry_wait = RETRY_SECONDS
        return
    end
    pcall(function() comp:SetCollisionEnabled(0) end)
    pcall(function() comp:SetGenerateOverlapEvents(false) end)
    pcall(function() comp:SetSphereRadius(MARKER_RADIUS, false) end)
    pcall(function() comp:SetHiddenInGame(false, false) end)
    M.marker = comp
    owner_pawn = pawn:get_address()
    place()
end

-- Unreal rotator -> the box's local axes (FRotationMatrix rows).
local function axes(r)
    local p, y, ro = math.rad(r.Pitch), math.rad(r.Yaw), math.rad(r.Roll)
    local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(ro), math.cos(ro)
    return { cp * cy, cp * sy, sp },
        { sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp },
        { -(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp }
end

-- Is world point pt inside the oriented box (centre c, rotator r, half
-- extent e), grown by margin?
function M.inside(pt, c, r, e, margin)
    local d = { pt.X - c.X, pt.Y - c.Y, pt.Z - c.Z }
    local ext = { e.X, e.Y, e.Z }
    local ax = { axes(r) }
    for i = 1, 3 do
        local a = ax[i]
        local l = d[1] * a[1] + d[2] * a[2] + d[3] * a[3]
        if math.abs(l) > ext[i] + margin then return false end
    end
    return true
end

local function cat_actor()
    local cls = uevr.api:find_uobject("Class /Script/Routine.RoutineGameCAT")
    return cls and UEVR_UObjectHook.get_first_object_by_class(cls, false)
end

local function find_touch(cat, tip)
    for _, name in ipairs(M.BUTTONS) do
        local box = cat["Box_" .. name .. "Col"]
        if box ~= nil then
            local ok, hit = pcall(function()
                return M.inside(tip, box:K2_GetComponentLocation(), box:K2_GetComponentRotation(),
                    box:GetScaledBoxExtent(), MARKER_RADIUS)
            end)
            if ok and hit then return name end
            if not ok then M.last_error = tostring(hit) end
        end
    end
    return nil
end

local function buzz()
    pcall(function()
        local vr = uevr.params.vr
        local src -- (not "a and b or c": the left source can be nil)
            if handed.off() == "left" then src = vr.get_left_joystick_source() else src = vr.get_right_joystick_source() end
        vr.trigger_haptic_vibration(0.0, 0.05, 1.0, 0.6, src)
    end)
end

-- Interact() takes a struct (calling it with the pawn or with nothing
-- fails with "Invalid argument type for struct property"), so its
-- parameters are read from the game's UFunction and arguments built to
-- match: structs as fresh StructObjects (hit-result style fields filled
-- with the fingertip and the button), objects as the pawn, the rest zero.
local CPF_PARM = 0x80
local CPF_OUT = 0x100
local CPF_RETURN = 0x400

M.signature = nil     -- e.g. "Interact(Hit: StructProperty HitResult)", for the panel

local function kind_of(prop)
    local ok, k = pcall(function() return prop:get_class():get_fname():to_string() end)
    return ok and k or "?"
end

-- The parameter's struct type can't be read from the property in this
-- UEVR build (get_struct comes back empty), so look through the game's
-- ScriptStructs for one named like the parameter, e.g. InteractAction ->
-- RoutineGameInteractAction. Candidates are kept for the panel.
M.struct_candidates = nil
local struct_cache = {}

function M.find_struct(param_name)
    if struct_cache[param_name] ~= nil then return struct_cache[param_name] or nil end
    local found, names = nil, {}
    pcall(function()
        local cls = uevr.api:find_uobject("Class /Script/CoreUObject.ScriptStruct")
            or uevr.api:find_uobject("/Script/CoreUObject.ScriptStruct")
        local all = UEVR_UObjectHook.get_objects_by_class(cls, false)
        local want = param_name:lower()
        for _, st in ipairs(all or {}) do
            local n = st:get_fname():to_string()
            local low = n:lower()
            if low:find("interact", 1, true) then
                names[#names + 1] = n
                if low:find(want, 1, true) and (found == nil or #n < #found:get_fname():to_string()) then
                    found = st
                end
            end
        end
    end)
    M.struct_candidates = table.concat(names, ", ")
    struct_cache[param_name] = found or false
    return found
end

-- "Field: Kind, ..." of a struct, for the panel and recorder.
function M.struct_fields(st)
    local out = {}
    pcall(function()
        local f = st:get_child_properties()
        while f ~= nil do
            out[#out + 1] = f:get_fname():to_string() .. ":" .. kind_of(f)
            f = f:get_next()
        end
    end)
    return table.concat(out, ", ")
end

local function params_of(comp, fn)
    local func = nil
    pcall(function() func = comp:get_class():find_function(fn) end)
    if func == nil then return nil end

    local list = {}
    local p = nil
    pcall(function() p = func:get_child_properties() end)
    while p ~= nil do
        local flags = 0
        pcall(function() flags = p:get_property_flags() end)
        if flags & CPF_RETURN == 0 and (flags == 0 or flags & CPF_PARM ~= 0) then
            local name = "?"
            pcall(function() name = p:get_fname():to_string() end)
            local entry = { name = name, kind = kind_of(p), out = flags & CPF_OUT ~= 0, prop = p }
            if entry.kind == "StructProperty" then
                pcall(function() entry.struct = p:get_struct() end)
                if entry.struct == nil then entry.struct = M.find_struct(name) end
            end
            list[#list + 1] = entry
        end
        local nxt = nil
        pcall(function() nxt = p:get_next() end)
        p = nxt
    end
    return list
end

local function fill_vector(v, pt)
    pcall(function() v.X, v.Y, v.Z = pt.X, pt.Y, pt.Z end)
end

local function make_arg(entry, ctx)
    local k = entry.kind
    if k == "StructProperty" then
        if entry.struct == nil then return nil end
        local s = StructObject.new(entry.struct)
        -- Fields that name who or what is interacting.
        pcall(function()
            local f = entry.struct:get_child_properties()
            while f ~= nil do
                local fname, fk = f:get_fname():to_string(), kind_of(f)
                local low = fname:lower()
                if fk == "ObjectProperty" or fk == "WeakObjectProperty" then
                    if low:find("component", 1, true) then
                        pcall(function() s[fname] = ctx.comp end)
                    elseif low:find("interactor", 1, true) or low:find("instigator", 1, true)
                        or low:find("pawn", 1, true) or low:find("actor", 1, true) or low:find("player", 1, true) then
                        pcall(function() s[fname] = ctx.pawn end)
                    end
                end
                f = f:get_next()
            end
        end)
        -- Hit-result style fields, where they exist.
        for _, f in ipairs({ "Location", "ImpactPoint", "TraceEnd" }) do
            pcall(function() fill_vector(s[f], ctx.tip) end)
        end
        pcall(function() fill_vector(s.TraceStart, ctx.tip) end)
        pcall(function() s.bBlockingHit = true end)
        for _, f in ipairs({ "Component", "HitComponent" }) do
            pcall(function() s[f] = ctx.box end)
        end
        for _, f in ipairs({ "Actor", "HitActor", "Interactor", "Instigator" }) do
            pcall(function() s[f] = ctx.pawn end)
        end
        return s
    elseif k == "ObjectProperty" or k == "WeakObjectProperty" then
        return ctx.pawn
    elseif k == "BoolProperty" then
        return false
    elseif k == "StrProperty" or k == "NameProperty" or k == "TextProperty" then
        return ""
    end
    return 0
end

function M.describe(list, fn)
    local parts = {}
    for _, e in ipairs(list) do
        local struct_name = ""
        if e.struct ~= nil then
            pcall(function() struct_name = " " .. e.struct:get_fname():to_string() end)
            local fields = M.struct_fields(e.struct)
            if fields ~= "" then struct_name = struct_name .. " {" .. fields .. "}" end
        elseif e.kind == "StructProperty" then
            struct_name = " <type not found>"
        end
        parts[#parts + 1] = e.name .. ": " .. e.kind .. struct_name .. (e.out and " (out)" or "")
    end
    return fn .. "(" .. table.concat(parts, ", ") .. ")"
end

local function press(cat, name, pawn, tip)
    local fn = settings.get("touch_press_function")
    if fn == "" or cooldown > 0 then return false end
    local comp = cat["Interact_" .. name]
    if comp == nil then return false end
    local ok_en, enabled = pcall(function() return comp.bEnabled end)
    if ok_en and enabled == false then return false end
    cooldown = PRESS_COOLDOWN
    return M.interact(comp, pawn, tip, cat["Box_" .. name .. "Col"], name)
end

-- Press any RoutineGameInteractComponent, as the game's own click does.
function M.interact(comp, pawn, tip, box, name)
    local fn = settings.get("touch_press_function")
    local list = params_of(comp, fn)
    if list == nil then
        M.last_error = "press " .. name .. ": no function " .. fn
        return false
    end
    M.signature = M.describe(list, fn)

    local ctx = { pawn = pawn, tip = tip, box = box, comp = comp }
    local args = {}
    for _, e in ipairs(list) do
        if e.kind == "StructProperty" and e.struct == nil then
            M.last_error = "press " .. name .. ": couldn't find the type of " .. e.name
                .. " (structs named Interact*: " .. tostring(M.struct_candidates) .. ")"
            return false
        end
    end
    for i, e in ipairs(list) do
        local ok_arg, v = pcall(make_arg, e, ctx)
        if not ok_arg then
            M.last_error = "press " .. name .. ": building " .. e.name .. ": " .. tostring(v)
            return false
        end
        args[i] = v
    end

    local ok, err = pcall(function() comp[fn](comp, table.unpack(args, 1, #list)) end)
    if ok then
        M.presses = (M.presses or 0) + 1
        M.last_error = nil
    else
        M.last_error = "press " .. name .. ": " .. tostring(err)
    end
    print("[routine_vr] touch press " .. name .. " via " .. M.signature .. ": " .. (ok and "ok" or tostring(err)))
    return ok
end

local function set_shown(want)
    if want == shown or M.marker == nil then return end
    shown = want
    local m = M.marker
    pcall(function() m:SetVisibility(want, false) end)
end

function M.tick(delta)
    retry_wait = retry_wait - delta
    cooldown = cooldown - delta

    local enabled = settings.get("touch_buttons")
    local active = enabled and game.mode == "game" and game.raised
    local pawn = uevr.api:get_local_pawn(0)

    if pawn == nil or (M.marker ~= nil and pawn:get_address() ~= owner_pawn) then destroy() end
    if pawn == nil or not enabled then
        set_shown(false)
        M.touching = nil
        M.status = enabled and "C.A.T. not out." or "Off."
        return
    end

    if M.marker == nil then
        if not active or retry_wait > 0 then return end
        create(pawn)
        if M.marker == nil then return end
    end
    if applied ~= signature() then place() end

    set_shown(active and settings.get("touch_marker"))
    if not active then
        M.touching = nil
        M.status = "C.A.T. not out."
        return
    end

    local cat = cat_actor()
    local m = M.marker
    -- The real left index fingertip when motion hands are on, else the dot.
    local tip = motion_hands.fingertip(handed.off())
    local ok = tip ~= nil
    if not ok then ok, tip = pcall(function() return m:K2_GetComponentLocation() end) end
    if cat == nil or not ok or tip == nil then
        M.touching = nil
        return
    end

    local name = find_touch(cat, tip)
    if name ~= nil and name ~= M.touching then
        buzz()
        press(cat, name, pawn, tip)
    end
    M.touching = name
    M.status = name and ("Touching: " .. name) or "Not touching a button."
end

function M.reset()
    destroy()
    M.touching = nil
    retry_wait = 0.0
end

return M
