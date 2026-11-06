-- Which hand does what (settings.handedness). Right-handed: the C.A.T. and
-- aiming on the right hand, touch, lean and inspect on the left. Left-handed
-- swaps all of it, and the triggers (interact on the left index).

local settings = require("routine_vr.settings")

local M = {}

function M.is_left() return settings.get("handedness") == "left" end
function M.main() return M.is_left() and "left" or "right" end   -- C.A.T., aim, pointer
function M.off() return M.is_left() and "right" or "left" end    -- touch, lean, inspect

-- UEVR hand index (0 left, 1 right).
function M.index(side) return side == "left" and 0 or 1 end

return M
