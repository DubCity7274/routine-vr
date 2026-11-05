-- A laser showing what you're pointing at when you click the C.A.T.'s
-- buttons or a terminal. Routine traces its interactions from the camera,
-- and the camera component rides on a controller (hands.lua), so the laser
-- copies the camera's placement: same hand, starting at the camera and
-- running along its forward axis. That makes it the game's actual ray.
--
-- Same trick as the community profile's interaction laser: a capsule shape
-- component with no collision, drawn in game, added to the pawn and put on
-- the hand with UObjectHook. It's pitched 90 degrees so the capsule's long
-- axis (Z) runs forward, and pushed forward by half its length.

local settings = require("routine_vr.settings")
local hands = require("routine_vr.hands")
local game = require("routine_vr.game")

local M = {}

M.CHOICES = { "inspect", "always", "off" }
M.LABELS = { "While inspecting the C.A.T.", "Always in gameplay", "Off" }

local CHECK_INTERVAL = 0.2
local RETRY_SECONDS = 5.0
local RADIUS = 0.15
local HAND_RIGHT = 1
local CAMERA = "CameraComponent"

M.component = nil
local capsule_class = nil
local owner_pawn = nil
local shown = nil
local applied = nil    -- signature of the last placement
local timer = CHECK_INTERVAL
local retry_wait = 0.0

local function destroy()
    if M.component ~= nil then
        local comp = M.component
        pcall(function() UEVR_UObjectHook.remove_motion_controller_state(comp) end)
        pcall(function() comp:K2_DestroyComponent(comp) end)
    end
    M.component, owner_pawn, shown, applied = nil, nil, nil, nil
end

-- Hand, rotation and start point of the ray: the camera's placement, or
-- the bare right controller if the camera isn't on a hand.
local function ray()
    local hand, q, loc = hands.placement_of(CAMERA)
    if hand == nil then
        hand, q, loc = HAND_RIGHT, hands.rotator_to_quat(0, 0, 0), { x = 0, y = 0, z = 0 }
    end
    -- Visual nudge from the panel; the game's ray itself doesn't move.
    local nudge = hands.rotate(q, hands.location_to_glm(settings.get("laser_forward"), 0, settings.get("laser_up")))
    return hand, q, { x = loc.x + nudge.x, y = loc.y + nudge.y, z = loc.z + nudge.z }
end

local function signature(length)
    local hand, q, loc = ray()
    return string.format("%d %.4f %.4f %.4f %.4f %.3f %.3f %.3f %.3f",
        hand, q.w, q.x, q.y, q.z, loc.x, loc.y, loc.z, length)
end

local function place(length)
    local comp = M.component
    pcall(function() comp:SetCapsuleSize(RADIUS, length / 2, false) end)

    local state = UEVR_UObjectHook.get_or_add_motion_controller_state(comp)
    if state == nil then return end

    local hand, q, loc = ray()
    local mid = hands.rotate(q, hands.location_to_glm(length / 2, 0, 0))
    state:set_hand(hand)
    state:set_rotation_offset(hands.quat_to_offset(hands.qmul(q, hands.rotator_to_quat(90, 0, 0))))
    state:set_location_offset(hands.vec({ x = loc.x + mid.x, y = loc.y + mid.y, z = loc.z + mid.z }))
    state:set_permanent(true)
    applied = signature(length)
end

local function create(pawn)
    if capsule_class == nil then
        capsule_class = uevr.api:find_uobject("Class /Script/Engine.CapsuleComponent")
        if capsule_class == nil then return end
    end

    local ok, comp = pcall(function() return uevr.api:add_component_by_class(pawn, capsule_class, false) end)
    if not ok or comp == nil then
        print("[routine_vr] laser: could not add component: " .. tostring(comp))
        retry_wait = RETRY_SECONDS
        return
    end

    -- Never collide: it hangs off the pawn and would block movement.
    pcall(function() comp:SetCollisionEnabled(0) end)
    pcall(function() comp:SetGenerateOverlapEvents(false) end)
    pcall(function() comp:SetHiddenInGame(false, false) end)
    pcall(function() comp.LineThickness = 0.4 end)

    M.component = comp
    owner_pawn = pawn:get_address()
    shown = nil
    place(settings.get("laser_length"))
end

local function wanted()
    if game.mode ~= "game" then return false end
    local mode = settings.get("laser")
    return mode == "always" or (mode == "inspect" and game.inspecting)
end

function M.tick(delta)
    timer = timer + delta
    if timer < CHECK_INTERVAL then return end
    retry_wait = retry_wait - timer
    timer = 0.0

    local want = wanted()
    local pawn = uevr.api:get_local_pawn(0)

    if pawn == nil or (M.component ~= nil and pawn:get_address() ~= owner_pawn) then
        destroy()
    end
    if pawn == nil then return end

    -- Created on first need, then kept and hidden.
    if M.component == nil then
        if not want or retry_wait > 0 then return end
        create(pawn)
        if M.component == nil then return end
    end

    local length = settings.get("laser_length")
    if applied ~= signature(length) then place(length) end

    if want ~= shown then
        shown = want
        local comp = M.component
        pcall(function() comp:SetVisibility(want, false) end)
    end
end

function M.reset()
    destroy()
    timer = CHECK_INTERVAL
    retry_wait = 0.0
end

return M
