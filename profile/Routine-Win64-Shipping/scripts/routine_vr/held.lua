-- Papers and other items you pick up to read came out tiny in the headset.
-- They are RoutineGameInspectable actors: the game moves one toward the
-- camera (which rides on your hand) and shrinks it for its flat first-person
-- view. While one is held this puts it back at its size in the world, times
-- the panel's slider. Everything is read at run time and each pickup is
-- logged, since the game's own handling of these actors isn't visible here.

local settings = require("routine_vr.settings")
local hands = require("routine_vr.hands")
local handed = require("routine_vr.handed")
local motion_hands = require("routine_vr.motion_hands")
local notes = require("routine_vr.notes")

local M = {}

local CLASS = "Class /Script/Routine.RoutineGameInspectable"
local POLL_SECONDS = 0.2
local TOLERANCE = 0.01

M.active = nil          -- the actor in your hand, or nil
M.status = "Nothing held."

local base = nil        -- { X, Y, Z }: its size in the world
local arrived = false   -- finished flying to the hand
local returning = false -- flying back
local moves = 0
local written = nil     -- the rotation last set here
local game_rel = nil    -- the game's own rotation of it, relative to the hand
local first_rel = nil   -- that, on arrival
local hit_result = nil
local timer = POLL_SECONDS
local writes = 0        -- how often its size had to be set (the log tells if the game fights it)

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function alive(actor)
    if UEVR_UObjectHook.exists == nil then return true end
    return safe(function() return UEVR_UObjectHook.exists(actor) end) == true
end

local function name_of(obj)
    return safe(function() return obj:get_class():get_fname():to_string() end) or "?"
end

local function find_inspecting()
    local cls = safe(function() return uevr.api:find_uobject(CLASS) end)
    if cls == nil then return nil end
    local list = safe(function() return UEVR_UObjectHook.get_objects_by_class(cls, false) end)
    for _, actor in ipairs(type(list) == "table" and list or {}) do
        if safe(function() return actor:IsInspecting() end) == true then return actor end
    end
    return nil
end

local function vector_text(v)
    if v == nil then return "?" end
    return string.format("%.3f,%.3f,%.3f", v.X or 0, v.Y or 0, v.Z or 0)
end

-- Its size in the world, from the game's own record of where it came from.
local function world_size(actor)
    local native = safe(function() return actor:GetNativeTransform() end)
    local s = native and safe(function() return native.Scale3D end)
    if s ~= nil and s.X ~= nil and s.X > 0 then return { X = s.X, Y = s.Y, Z = s.Z } end
    return nil
end

local function write_size(actor, x, y, z)
    local v = safe(function() return actor:GetActorScale3D() end)
    if v == nil then return false end
    local far = math.abs(v.X - x) > TOLERANCE * x or math.abs(v.Y - y) > TOLERANCE * y
        or math.abs(v.Z - z) > TOLERANCE * z
    if not far then return false end
    v.X, v.Y, v.Z = x, y, z
    pcall(function() actor:SetActorScale3D(v) end)
    return true
end

local function conj(q) return { w = q.w, x = -q.x, y = -q.y, z = -q.z } end

-- Holds are stored for the right hand; the left hand gets the mirror image.
local function mirrored(q)
    if not handed.is_left() then return q end
    return { w = q.w, x = -q.x, y = q.y, z = -q.z }
end

local function same_rot(a, b)
    return b ~= nil and math.abs(a.Pitch - b.Pitch) + math.abs(a.Yaw - b.Yaw) + math.abs(a.Roll - b.Roll) < 0.02
end

-- The item's turn relative to the hand. The game keeps setting the item's
-- rotation, which is where the stick's turning arrives: that much is added
-- to the saved hold. With no hold saved it stays the game's.
local function hold_turn(actor, hand_q)
    local g = actor:K2_GetActorRotation()
    if not same_rot(g, written) then
        game_rel = hands.qmul(conj(hand_q), motion_hands.rot_to_quat(g.Pitch, g.Yaw, g.Roll))
        if first_rel == nil then first_rel = game_rel end
    end
    local saved = settings.get("held_rot")
    if type(saved) ~= "table" then return game_rel end
    local q = mirrored({ w = saved[1], x = saved[2], y = saved[3], z = saved[4] })
    return hands.qmul(hands.qmul(game_rel, conj(first_rel)), q)
end

-- Into the hand instead of past the fingertips.
local function place(actor)
    local loc, rot = motion_hands.controller_pose(handed.main())
    if loc == nil then return end
    local o = settings.get("held_offset")
    local side = handed.is_left() and -1 or 1
    local f, r, u = hands.rotator_axes(rot.Pitch, rot.Yaw, rot.Roll)
    local v = safe(function() return actor:K2_GetActorLocation() end)
    if v == nil then return end
    if hit_result == nil then
        hit_result = safe(function()
            return StructObject.new(uevr.api:find_uobject("ScriptStruct /Script/Engine.HitResult"))
        end)
        if hit_result == nil then return end
    end
    v.X = loc.X + f.x * o[1] + r.x * o[2] * side + u.x * o[3]
    v.Y = loc.Y + f.y * o[1] + r.y * o[2] * side + u.y * o[3]
    v.Z = loc.Z + f.z * o[1] + r.z * o[2] * side + u.z * o[3]

    local hand_q = motion_hands.rot_to_quat(rot.Pitch, rot.Yaw, rot.Roll)
    local ok_turn, turn = pcall(hold_turn, actor, hand_q)
    if not ok_turn then return end
    M.turn = turn
    local want = actor:K2_GetActorRotation()
    want.Pitch, want.Yaw, want.Roll = motion_hands.quat_to_rot(hands.qmul(hand_q, turn))
    pcall(function() actor:K2_SetActorLocationAndRotation(v, want, false, hit_result, false) end)
    written = { Pitch = want.Pitch, Yaw = want.Yaw, Roll = want.Roll }
    moves = moves + 1
end

-- Keep the way the item is turned right now, for everything picked up from
-- here on (the panel's button).
function M.save_hold()
    if M.turn == nil then return false end
    local q = mirrored(M.turn)
    settings.set("held_rot", { q.w, q.x, q.y, q.z })
    first_rel = game_rel
    notes.add(string.format("held: saved hold %.4f,%.4f,%.4f,%.4f", q.w, q.x, q.y, q.z))
    return true
end

function M.can_save() return M.active ~= nil and M.turn ~= nil end

local function begin(actor)
    M.active, arrived, returning, writes, moves = actor, false, false, 0, 0
    written, game_rel, first_rel, M.turn = nil, nil, nil, nil
    local now = safe(function() return actor:GetActorScale3D() end)
    base = world_size(actor)
    local native_known = base ~= nil
    if base == nil and now ~= nil then base = { X = now.X, Y = now.Y, Z = now.Z } end
    local root = safe(function() return actor:K2_GetRootComponent() end)
    notes.add(string.format("held: %s scale=%s world=%s known=%s root_relative=%s lerping=%s",
        name_of(actor), vector_text(now), vector_text(base), tostring(native_known),
        vector_text(root and safe(function() return root.RelativeScale3D end)),
        tostring(safe(function() return actor:IsLerping() end))))
    M.status = "Holding " .. name_of(actor) .. "."
end

local function finish()
    local actor = M.active
    if actor ~= nil and base ~= nil and alive(actor) then
        write_size(actor, base.X, base.Y, base.Z)
    end
    if actor ~= nil then
        notes.add(string.format("held: put down after %d size writes, %d moves", writes, moves))
    end
    M.active, base, arrived, returning = nil, nil, false, false
    M.turn = nil
    M.status = "Nothing held."
end

-- Called each tick and as the view is built. The size holds for the flight
-- both ways, so it never pops. Position and turn only as the view is built
-- (with_place), after the game has set its own for this frame.
function M.apply(with_place)
    local actor = M.active
    if actor == nil or base == nil or not settings.get("held_fix") then return end
    if not alive(actor) then return end
    local k = settings.get("held_size")
    if write_size(actor, base.X * k, base.Y * k, base.Z * k) then writes = writes + 1 end
    if with_place and arrived and not returning and settings.get("held_in_palm") then place(actor) end
end

function M.tick(delta)
    if not settings.get("held_fix") then
        if M.active ~= nil then finish() end
        M.status = "Off."
        return
    end

    local actor = M.active
    if actor ~= nil then
        local there = alive(actor)
        local holding = there and safe(function() return actor:IsInspecting() end) == true
        local lerping = there and safe(function() return actor:IsLerping() end) == true
        if lerping then
            if arrived then returning = true end
        elseif holding and not returning then
            arrived = true
        else
            finish()
        end
    else
        timer = timer + delta
        if timer >= POLL_SECONDS then
            timer = 0.0
            local found = find_inspecting()
            if found ~= nil then begin(found) end
        end
    end
    M.apply()
end

function M.reset()
    M.active, base, arrived, returning, writes, moves = nil, nil, false, false, 0, 0
    written, game_rel, first_rel, M.turn = nil, nil, nil, nil
    timer = POLL_SECONDS
    M.status = "Nothing held."
end

return M
