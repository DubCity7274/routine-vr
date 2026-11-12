-- 6DoF hands: attach pawn components (C.A.T. tool, flashlight, arms mesh...)
-- to the motion controllers with UEVR's UObjectHook.
--
-- Routine's component names aren't known ahead of time, so the panel in
-- ui.lua lists the pawn's components and lets you assign each to a hand.
-- Assignments are saved by component name in settings.attachments and are
-- re-applied whenever the pawn changes (level loads, respawns).

local settings = require("routine_vr.settings")
local input = require("routine_vr.input")

local M = {}

local HAND = { left = 0, right = 1 }
local SCAN_INTERVAL = 1.0
local FULL_SCAN_INTERVAL = 5.0

M.components = {}   -- discovered: { obj, name, class }
local overrides = {} -- component name -> attachment that wins over settings (game.lua)
local attached = {}  -- component name -> true while this module has it on a hand
local inactive = {}  -- component name -> true while it should stay off the hands (game.lua)
local rest = {}      -- component name -> relative transform from before it was attached
local last_pawn = nil
local scan_timer = 0.0
local full_scan_timer = 0.0
local dirty = true
local scene_component_class = nil
local extras = {}    -- { name, fn, last } components that aren't the pawn's own (game.lua)

local function comp_name(obj)
    local ok, n = pcall(function() return obj:get_fname():to_string() end)
    return ok and n or "?"
end

local function class_name(obj)
    local ok, n = pcall(function() return obj:get_class():get_fname():to_string() end)
    return ok and n or "?"
end

local function find_saved(name)
    for i, a in ipairs(settings.get("attachments")) do
        if a.name == name then return a, i end
    end
    return nil
end

local function find_attachment(name)
    return overrides[name] or find_saved(name)
end

-- UObjectHook moves a component by rewriting its relative transform, and
-- leaves it wherever it was when the hook comes off. Keep the original so
-- detaching puts it back under its parent (e.g. the C.A.T. back to the
-- game's lowered pose).
local function save_rest(comp)
    local ok, r = pcall(function()
        local l, q = comp.obj.RelativeLocation, comp.obj.RelativeRotation
        return { l.X, l.Y, l.Z, q.Pitch, q.Yaw, q.Roll }
    end)
    rest[comp.name] = ok and r or nil
end

local function restore_rest(comp)
    local r = rest[comp.name]
    rest[comp.name] = nil
    if r == nil then return end
    pcall(function()
        local l, q = comp.obj.RelativeLocation, comp.obj.RelativeRotation
        l.X, l.Y, l.Z = r[1], r[2], r[3]
        q.Pitch, q.Yaw, q.Roll = r[4], r[5], r[6]
    end)
end

-- UObjectHook offsets live in UEVR's VR (glm) space, not Unreal's:
-- x = right, y = up, z = backward (UObjectHook.cpp: the location offset is
-- rotated by the hand in glm space, and the rotation offset is applied as
-- hand * inverse(offset)). Settings stay in Unreal terms (pitch/yaw/roll,
-- forward/right/up cm) and are converted here.

local function qmul(a, b)
    return {
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    }
end

local function axis_quat(x, y, z, deg)
    local h = math.rad(deg) / 2
    local s = math.sin(h)
    return { w = math.cos(h), x = x * s, y = y * s, z = z * s }
end

M.qmul = qmul

-- Unreal's rotator axes in world space: forward, right, up, each {x,y,z}.
function M.rotator_axes(p, y, r)
    local sp, cp = math.sin(math.rad(p)), math.cos(math.rad(p))
    local sy, cy = math.sin(math.rad(y)), math.cos(math.rad(y))
    local sr, cr = math.sin(math.rad(r)), math.cos(math.rad(r))
    return { x = cp * cy, y = cp * sy, z = sp },
        { x = sr * sp * cy - cr * sy, y = sr * sp * sy + cr * cy, z = -sr * cp },
        { x = -(cr * sp * cy + sr * sy), y = cy * sr - cr * sp * sy, z = cr * cp }
end

-- UE rotator (degrees) -> glm quaternion in hand space, same mapping UEVR
-- uses for component rotations: glm::yawPitchRoll(-yaw, pitch, -roll).
function M.rotator_to_quat(p, y, r)
    return qmul(qmul(axis_quat(0, 1, 0, -y), axis_quat(1, 0, 0, p)), axis_quat(0, 0, 1, -r))
end

-- glm quaternion -> what set_rotation_offset wants (UEVR applies the inverse).
function M.quat_to_offset(q)
    local out = UEVR_Quaternionf.new()
    out.w, out.x, out.y, out.z = q.w, -q.x, -q.y, -q.z
    return out
end

function M.rotator_to_offset_quat(p, y, r)
    return M.quat_to_offset(M.rotator_to_quat(p, y, r))
end

-- Rotate a glm vector {x,y,z} by a glm quaternion.
function M.rotate(q, v)
    local r = qmul(qmul(q, { w = 0, x = v.x, y = v.y, z = v.z }), { w = q.w, x = -q.x, y = -q.y, z = -q.z })
    return { x = r.x, y = r.y, z = r.z }
end

-- UE forward/right/up (cm) -> glm {x,y,z}.
function M.location_to_glm(fwd, right, up)
    return { x = right, y = up, z = -fwd }
end

function M.vec(v)
    local out = UEVR_Vector3f.new()
    out.x, out.y, out.z = v.x, v.y, v.z
    return out
end

-- UE forward/right/up (cm) -> glm x/y/z for set_location_offset.
function M.location_to_offset(fwd, right, up)
    return M.vec(M.location_to_glm(fwd, right, up))
end

-- Addresses, since UEVR can hand out a fresh wrapper for the same object.
local function addr_of(obj)
    if obj == nil then return nil end
    local ok, a = pcall(function() return obj:get_address() end)
    return ok and a or obj
end

local function scan(pawn)
    if scene_component_class == nil then
        scene_component_class = uevr.api:find_uobject("Class /Script/Engine.SceneComponent")
    end

    local list = {}
    local ok, comps = pcall(function() return pawn:K2_GetComponentsByClass(scene_component_class) end)
    if ok and type(comps) == "table" then
        for _, c in ipairs(comps) do
            list[#list + 1] = { obj = c, name = comp_name(c), class = class_name(c) }
        end
    else
        print("[routine_vr] could not list pawn components: " .. tostring(comps))
    end

    for _, e in ipairs(extras) do
        local eok, obj = pcall(e.fn)
        e.last = addr_of(eok and obj or nil)
        if eok and obj ~= nil then
            list[#list + 1] = { obj = obj, name = e.name, class = class_name(obj) }
        end
    end

    table.sort(list, function(a, b) return a.name < b.name end)
    M.components = list
end

-- Where an attachment ends up relative to its controller, in glm terms:
-- hand index, rotation quaternion (not yet inverted) and location.
local function placement(a)
    local base = input.device and input.device.hand_offset or { rot = { 0, 0, 0 }, loc = { 0, 0, 0 } }
    local rot = a.rot or { 0, 0, 0 }
    local loc = a.loc or { 0, 0, 0 }
    return HAND[a.hand] or HAND.right,
        M.rotator_to_quat(rot[1] + base.rot[1], rot[2] + base.rot[2], rot[3] + base.rot[3]),
        M.location_to_glm(loc[1] + base.loc[1], loc[2] + base.loc[2], loc[3] + base.loc[3])
end

local function apply_one(comp, a)
    local state = UEVR_UObjectHook.get_or_add_motion_controller_state(comp.obj)
    if state == nil then return end

    local hand, q, loc = placement(a)
    state:set_hand(hand)
    state:set_rotation_offset(M.quat_to_offset(q))
    state:set_location_offset(M.vec(loc))
    state:set_permanent(true)
end

-- Placement of a component by name (override or saved), or nil.
function M.placement_of(name)
    local a = find_attachment(name)
    if a == nil then return nil end
    return placement(a)
end

-- A component that isn't one of the pawn's, e.g. the C.A.T. actor's root.
-- fn returns the component or nil; it's looked up on every scan.
function M.register_extra(name, fn)
    for _, e in ipairs(extras) do
        if e.name == name then e.fn = fn; return end
    end
    extras[#extras + 1] = { name = name, fn = fn }
end

local function apply_all()
    for _, comp in ipairs(M.components) do
        local a = not inactive[comp.name] and find_attachment(comp.name) or nil
        if a ~= nil then
            if not attached[comp.name] then save_rest(comp) end
            apply_one(comp, a)
            attached[comp.name] = true
        elseif attached[comp.name] then
            -- Only detach what this module attached; the laser lives on the
            -- pawn too and manages its own state.
            UEVR_UObjectHook.remove_motion_controller_state(comp.obj)
            restore_rest(comp)
            attached[comp.name] = nil
        end
    end
end

-- hand = "left" | "right" | nil (detach)
function M.assign(comp, hand)
    local attachments = settings.get("attachments")
    local a, i = find_saved(comp.name)

    if hand == nil then
        if i ~= nil then table.remove(attachments, i) end
    elseif a ~= nil then
        a.hand = hand
    else
        attachments[#attachments + 1] = { name = comp.name, hand = hand, rot = { 0, 0, 0 }, loc = { 0, 0, 0 } }
    end

    settings.save()
    dirty = true
end

-- Temporary attachment for a component, e.g. the C.A.T. to the left hand
-- while inspecting. nil puts the saved attachment back.
function M.set_override(name, a)
    overrides[name] = a
    dirty = true
end

-- Keep a component off the hands for now (false) or let its attachment
-- apply again (true), e.g. the C.A.T. only while it's raised.
function M.set_active(name, active)
    local was = not inactive[name]
    if was == active then return end
    inactive[name] = (not active) or nil
    dirty = true
end

function M.is_attached(name)
    return attached[name] == true
end

function M.attachment_for(comp)
    return find_attachment(comp.name)
end

function M.mark_dirty()
    dirty = true
end

function M.rescan()
    last_pawn = nil
end

local function extras_changed()
    for _, e in ipairs(extras) do
        local ok, obj = pcall(e.fn)
        if addr_of(ok and obj or nil) ~= e.last then return true end
    end
    return false
end

function M.tick(delta)
    scan_timer = scan_timer + delta
    if scan_timer < SCAN_INTERVAL and not dirty then return end
    scan_timer = 0.0

    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then
        M.components = {}
        last_pawn = nil
        return
    end

    -- Compare by address; also rescan now and then because items like the
    -- C.A.T. can be spawned onto the pawn after it exists.
    local addr = pawn:get_address()
    full_scan_timer = full_scan_timer + SCAN_INTERVAL
    if addr ~= last_pawn or full_scan_timer >= FULL_SCAN_INTERVAL or extras_changed() then
        last_pawn = addr
        full_scan_timer = 0.0
        scan(pawn)
        dirty = true
    end

    if dirty then
        dirty = false
        apply_all()
    end
end

function M.init()
    UEVR_UObjectHook.activate()
end

function M.reset()
    overrides = {}
    attached = {}
    inactive = {}
    rest = {}
    M.components = {}
    last_pawn = nil
    dirty = true
end

return M
