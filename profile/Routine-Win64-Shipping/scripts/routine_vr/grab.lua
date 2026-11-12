-- Easier grabbing. Routine's interaction is one thin ray from your hand. When
-- something usable is close to where you're pointing, your hand buzzes and
-- the trigger presses that thing directly, the same call the game's own
-- click makes. (Bending the ray doesn't work: in the headset the camera did
-- turn, but the game kept tracing straight along the controller.)
--
-- Left alone: the C.A.T.'s own buttons and anything with a screen, anything
-- behind a wall, and everything while the C.A.T. is out or an item is in
-- your hand. With nothing close, the trigger reaches the game as usual.

local settings = require("routine_vr.settings")
local hands = require("routine_vr.hands")
local handed = require("routine_vr.handed")
local input = require("routine_vr.input")
local game = require("routine_vr.game")
local motion_hands = require("routine_vr.motion_hands")
local held = require("routine_vr.held")
local notes = require("routine_vr.notes")
local touch = require("routine_vr.touch")

local M = {}

local CLASS = "Class /Script/Routine.RoutineGameInteractComponent"
local WIDGET_CLASS = "Class /Script/UMG.WidgetComponent"
local SCAN_SECONDS = 0.3
local SCAN_RANGE = 450          -- cm from the hand; nothing's reachable further
local DEFAULT_REACH = 250       -- cm, for a component that doesn't say
local KEEP_FACTOR = 1.3         -- a target already picked stays until this far off
local PRESSED = 40              -- trigger value (0-255)
local WALL_MARGIN = 15          -- cm short of the target that a hit counts as a wall
local NEAR_HAND = 10            -- cm; a hit this close is the hand's own surroundings

M.status = "Nothing nearby."
M.target = nil                  -- name of what the trigger would press
M.found, M.skipped = 0, 0       -- usable things in the level, and how many are left alone

local candidates = {}           -- { x, y, z, reach, name, key }
local known = {}                -- component address -> { skip, reach, name }
local timer = SCAN_SECONDS
local current = nil             -- the chosen candidate
local owner_pawn = nil
local was_pressed = false
local hit_result, no_color, kismet = nil, nil, nil
local walled = {}               -- candidate key -> blocked or not, until the next scan
local wall_failed = false

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

M.axes = hands.rotator_axes

local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end

-- A world point in the hand's frame, forward/right/up.
function M.to_hand(hand_loc, hand_rot, point)
    local f, r, u = M.axes(hand_rot.Pitch, hand_rot.Yaw, hand_rot.Roll)
    local d = { x = point.x - hand_loc.X, y = point.y - hand_loc.Y, z = point.z - hand_loc.Z }
    return dot(d, f), dot(d, r), dot(d, u)
end

-- How far a point in the hand's frame is off the pointing line (degrees),
-- and how far away (cm).
function M.off_line(f, r, u)
    local len = math.sqrt(f * f + r * r + u * u)
    if len < 0.001 then return 180.0, 0.0 end
    return math.deg(math.acos(math.max(-1, math.min(1, f / len)))), len
end

-- The candidate closest to the line, or nil, and how far off it is. Each
-- has f, r, u: its position in the hand's frame.
function M.choose(list, cone, keep_key)
    local best, best_angle = nil, nil
    for _, c in ipairs(list) do
        local angle, len = M.off_line(c.f, c.r, c.u)
        local limit = (c.key == keep_key) and cone * KEEP_FACTOR or cone
        if len <= c.reach and angle <= limit and (best == nil or angle < best_angle) then
            best, best_angle = c, angle
        end
    end
    return best, best_angle
end

-- The closest one that isn't walled off. Anything behind a wall or a
-- terminal must not count as a target at all, or it would take the trigger
-- away from what's actually in front of you.
function M.pick(list, cone, keep_key, is_walled)
    local open = list
    while true do
        local best, angle = M.choose(open, cone, keep_key)
        if best == nil or not is_walled(best) then return best, angle end
        local rest = {}
        for _, c in ipairs(open) do
            if c ~= best then rest[#rest + 1] = c end
        end
        open = rest
    end
end

local function describe(comp, pawn, widget_class)
    local info = { skip = true, reach = DEFAULT_REACH, name = "?" }
    local owner = safe(function() return comp:GetOwner() end)
    if owner == nil then return info end
    info.name = safe(function() return owner:get_fname():to_string() end) or "?"
    local class_name = safe(function() return owner:get_class():get_fname():to_string() end) or ""
    local is_pawn = owner:get_address() == pawn:get_address()
    local has_screen = widget_class ~= nil
        and safe(function() return owner:GetComponentByClass(widget_class) end) ~= nil
    local is_cat = class_name:find("CAT", 1, true) ~= nil
    info.skip = is_pawn or has_screen or is_cat
    info.why = (is_pawn and "pawn") or (has_screen and "screen") or (is_cat and "cat") or nil
    local d = safe(function() return comp.Distance end)
    if type(d) == "number" and d > 0 then info.reach = d end
    -- The trace has to hit the collision shape the component sits under.
    local parent = safe(function() return comp:GetAttachParent() end)
    local parent_class = parent and safe(function() return parent:get_class():get_fname():to_string() end) or ""
    if parent_class:find("Box", 1, true) or parent_class:find("Sphere", 1, true)
        or parent_class:find("Capsule", 1, true) then
        info.shape = parent
    end
    return info
end

local function scan(pawn, hand_loc)
    candidates, M.found, M.skipped = {}, 0, 0
    local cls = safe(function() return uevr.api:find_uobject(CLASS) end)
    if cls == nil then return end
    local list = safe(function() return UEVR_UObjectHook.get_objects_by_class(cls, false) end)
    local widget_class = safe(function() return uevr.api:find_uobject(WIDGET_CLASS) end)
    for _, comp in ipairs(type(list) == "table" and list or {}) do
        local key = comp:get_address()
        local info = known[key]
        if info == nil then
            info = describe(comp, pawn, widget_class)
            known[key] = info
        end
        M.found = M.found + 1
        if info.skip then M.skipped = M.skipped + 1 end
        if not info.skip and safe(function() return comp.bEnabled end) ~= false then
            local where = info.shape or comp
            local loc = safe(function() return where:K2_GetComponentLocation() end)
            if loc ~= nil then
                local dx, dy, dz = loc.X - hand_loc.X, loc.Y - hand_loc.Y, loc.Z - hand_loc.Z
                if dx * dx + dy * dy + dz * dz < SCAN_RANGE * SCAN_RANGE then
                    candidates[#candidates + 1] = { x = loc.X, y = loc.Y, z = loc.Z,
                        reach = info.reach, name = info.name, key = key, comp = comp, shape = info.shape }
                end
            end
        end
    end
end

-- Is there something solid between the hand and the point? Unknown counts
-- as clear, so a failed trace can't stop grabbing.
local function wall_between(pawn, hand_loc, c)
    local ok, blocked = pcall(function()
        if kismet == nil then
            kismet = uevr.api:find_uobject("Class /Script/Engine.KismetSystemLibrary"):get_class_default_object()
            hit_result = StructObject.new(uevr.api:find_uobject("ScriptStruct /Script/Engine.HitResult"))
            no_color = StructObject.new(uevr.api:find_uobject("ScriptStruct /Script/CoreUObject.LinearColor"))
        end
        local from = motion_hands.controller_pose(handed.main())
        local to = motion_hands.controller_pose(handed.main())
        to.X, to.Y, to.Z = c.x, c.y, c.z
        local dist = math.sqrt((c.x - hand_loc.X) ^ 2 + (c.y - hand_loc.Y) ^ 2 + (c.z - hand_loc.Z) ^ 2)
        local hit = kismet:LineTraceSingle(pawn, from, to, 0, true, { pawn }, 0, hit_result, true, no_color, no_color, 0.0)
        local d = hit_result.Distance
        return hit == true and d ~= nil and d > NEAR_HAND and d < dist - WALL_MARGIN
    end)
    if not ok and not wall_failed then
        wall_failed = true
        notes.add("grab: wall check failed: " .. tostring(blocked))
    end
    return ok and blocked == true
end

local function buzz()
    pcall(function()
        local vr = uevr.params.vr
        local src
        if handed.main() == "left" then src = vr.get_left_joystick_source() else src = vr.get_right_joystick_source() end
        vr.trigger_haptic_vibration(0.0, 0.04, 1.0, 0.35, src)
    end)
end

local function press_target(pawn, hand_loc)
    local c = current
    if c == nil then return end
    local ok = touch.interact(c.comp, pawn, hand_loc, c.shape, c.name)
    notes.add(string.format("press: pressed %s: %s %s", c.name, tostring(ok), tostring(touch.last_error)))
end

local function clear_target()
    M.target, current, current_key = nil, nil, nil
end

local function over_screen(pawn)
    return safe(function() return pawn.WidgetInteraction:IsOverInteractableWidget() end) == true
end

function M.tick(delta)
    local pawn = uevr.api:get_local_pawn(0)
    local addr = pawn and pawn:get_address()
    if addr ~= owner_pawn then
        owner_pawn, known, candidates, timer = addr, {}, {}, SCAN_SECONDS
        clear_target()
    end

    local main_trigger = handed.is_left() and input.left_trigger or input.right_trigger
    local pressed = main_trigger > PRESSED
    local edge = pressed and not was_pressed
    was_pressed = pressed

    local loc, rot
    if pawn ~= nil then loc, rot = motion_hands.controller_pose(handed.main()) end
    local on = settings.get("grab_assist") and game.mode == "game" and not game.raised
        and not game.inspecting and held.active == nil and loc ~= nil

    if not on then
        clear_target()
        if not pressed then input.block_rt = false end
        M.status = settings.get("grab_assist") and "Waiting (C.A.T. out, item held or not in gameplay)." or "Off."
        return
    end

    -- Through a press the choice stands, and the trigger stays with
    -- whoever had it when the press began.
    if pressed then
        if edge then press_target(pawn, loc) end
        return
    end

    timer = timer + delta
    if timer >= SCAN_SECONDS then
        timer = 0.0
        walled = {}
        scan(pawn, loc)
    end

    local local_list = {}
    for i, c in ipairs(candidates) do
        local f, r, u = M.to_hand(loc, rot, c)
        local_list[i] = { f = f, r = r, u = u, reach = c.reach, source = c, key = c.key }
    end
    local best, angle = M.pick(local_list, settings.get("grab_assist_angle"), current_key, function(c)
        if walled[c.key] == nil then walled[c.key] = wall_between(pawn, loc, c.source) end
        return walled[c.key]
    end)
    if best ~= nil and over_screen(pawn) then best = nil end

    if best == nil then
        clear_target()
        input.block_rt = false
        M.status = string.format("Nothing close to where you're pointing (%d nearby, %d in the level, %d left alone).",
            #candidates, M.found, M.skipped)
        return
    end
    if best.key ~= current_key then
        buzz()
        notes.add(string.format("grab: ready for %s, %.1f deg off", best.source.name, angle))
    end
    current, current_key, M.target = best.source, best.key, best.source.name
    input.block_rt = true
    M.status = string.format("Trigger grabs %s (%.0f deg off).", best.source.name, angle)
end

function M.reset()
    candidates, known, timer = {}, {}, SCAN_SECONDS
    clear_target()
    owner_pawn, was_pressed = nil, false
    hit_result, no_color, kismet = nil, nil, nil
    walled, wall_failed = {}, false
    input.block_rt = false
    M.status = "Nothing nearby."
end

return M
