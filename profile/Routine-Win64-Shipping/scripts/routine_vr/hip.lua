-- The C.A.T.'s holster at your right hip: gripping with your right hand
-- there draws it (cat_grip = "hip", game.lua).
--
-- The hip is placed from the headset, so it follows you as you walk,
-- turn and crouch: hip_drop below the head, hip_side to the right and
-- hip_back behind, along the direction you face (head yaw only). Positions
-- are UEVR's tracking space in metres (x right, y up, z back). The right
-- controller buzzes lightly as it enters the holster, so you can find it
-- without looking.

local settings = require("routine_vr.settings")
local hands = require("routine_vr.hands")
local handed = require("routine_vr.handed")

local M = {}

local vr = uevr.params.vr

local hmd_pos = UEVR_Vector3f.new()
local hmd_rot = UEVR_Quaternionf.new()
local hand_pos = UEVR_Vector3f.new()
local hand_rot = UEVR_Quaternionf.new()

M.at_hip = false
M.distance = nil   -- metres from the holster centre, for the panel

-- Holster centre in tracking space.
function M.holster(head, rot)
    local fwd = hands.rotate({ w = rot.w, x = rot.x, y = rot.y, z = rot.z }, { x = 0, y = 0, z = -1 })
    local len = math.sqrt(fwd.x * fwd.x + fwd.z * fwd.z)
    if len < 1e-4 then fwd, len = { x = 0, z = -1 }, 1 end -- looking straight down/up
    local fx, fz = fwd.x / len, fwd.z / len
    local rx, rz = -fz, fx -- right of the facing direction
    -- Left-handers holster on the left hip.
    local side, back = settings.get("hip_side") * (handed.is_left() and -1 or 1), settings.get("hip_back")
    return {
        x = head.x + rx * side - fx * back,
        y = head.y - settings.get("hip_drop"),
        z = head.z + rz * side - fz * back,
    }
end

local function read()
    local ok = pcall(function()
        vr.get_pose(vr.get_hmd_index(), hmd_pos, hmd_rot)
        local idx = handed.is_left() and vr.get_left_controller_index() or vr.get_right_controller_index()
        vr.get_pose(idx, hand_pos, hand_rot)
    end)
    if not ok then return nil end
    local h = M.holster(hmd_pos, hmd_rot)
    local dx, dy, dz = hand_pos.x - h.x, hand_pos.y - h.y, hand_pos.z - h.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function M.tick(delta)
    M.distance = read()
    local was = M.at_hip
    M.at_hip = M.distance ~= nil and M.distance <= settings.get("hip_radius")
    if M.at_hip and not was and settings.get("cat_grip") == "hip" then
        pcall(function()
            local src -- (not "a and b or c": the left source can be nil)
            if handed.is_left() then src = vr.get_left_joystick_source() else src = vr.get_right_joystick_source() end
            vr.trigger_haptic_vibration(0.0, 0.03, 1.0, 0.3, src)
        end)
    end
end

function M.reset()
    M.at_hip, M.distance = false, nil
end

return M
