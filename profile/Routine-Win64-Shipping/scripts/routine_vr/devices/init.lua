-- Device registry.
--
-- A device module describes one controller family as data only:
--
--   id, name          identifiers shown in the UI
--   buttons           gamepad button -> list of physical input names (any held = pressed)
--   triggers          { LT = {...}, RT = {...} } same format
--   uevr              optional UEVR mod values applied when the device is selected
--   hand_offset       default rotation/location offset for attached components
--
-- Physical input names come from M.inputs below. They map onto UEVR's action
-- set, which is identical for OpenXR and OpenVR, so a device module never
-- talks to a runtime directly. To add a headset, copy quest_touch.lua, change
-- the tables, and add its id to M.order.

local M = {}

local P = "/actions/default/in/"

-- name -> { action = <UEVR action path>, hand = "left"|"right"|nil, dir = <touchpad quadrant>|nil }
-- hand=nil means "either controller". dir turns a click into a quadrant press
-- using that hand's joystick/touchpad axis (for Vive wands, WMR pads).
M.inputs = {
    trigger_l      = { action = P .. "Trigger",            hand = "left"  },
    trigger_r      = { action = P .. "Trigger",            hand = "right" },
    grip_l         = { action = P .. "Grip",               hand = "left"  },
    grip_r         = { action = P .. "Grip",               hand = "right" },
    a_l            = { action = P .. "AButtonLeft",        hand = "left"  },
    b_l            = { action = P .. "BButtonLeft",        hand = "left"  },
    a_r            = { action = P .. "AButtonRight",       hand = "right" },
    b_r            = { action = P .. "BButtonRight",       hand = "right" },
    stick_click_l  = { action = P .. "JoystickClick",      hand = "left"  },
    stick_click_r  = { action = P .. "JoystickClick",      hand = "right" },
    thumbrest_l    = { action = P .. "ThumbrestTouchLeft", hand = "left"  },
    thumbrest_r    = { action = P .. "ThumbrestTouchRight",hand = "right" },
    system         = { action = P .. "SystemButton" },

    pad_up_l       = { action = P .. "JoystickClick", hand = "left",  dir = "up"    },
    pad_down_l     = { action = P .. "JoystickClick", hand = "left",  dir = "down"  },
    pad_left_l     = { action = P .. "JoystickClick", hand = "left",  dir = "left"  },
    pad_right_l    = { action = P .. "JoystickClick", hand = "left",  dir = "right" },
    pad_up_r       = { action = P .. "JoystickClick", hand = "right", dir = "up"    },
    pad_down_r     = { action = P .. "JoystickClick", hand = "right", dir = "down"  },
    pad_left_r     = { action = P .. "JoystickClick", hand = "right", dir = "left"  },
    pad_right_r    = { action = P .. "JoystickClick", hand = "right", dir = "right" },
}

M.order = { "quest_touch", "index_knuckles", "pico", "wmr", "vive_wands" }

local cache = {}

function M.get(id)
    if cache[id] == nil then
        local ok, mod = pcall(require, "routine_vr.devices." .. id)
        if not ok then
            print("[routine_vr] unknown device '" .. tostring(id) .. "', falling back to quest_touch: " .. tostring(mod))
            return M.get("quest_touch")
        end
        mod.id = mod.id or id
        cache[id] = mod
    end
    return cache[id]
end

function M.names()
    local out = {}
    for i, id in ipairs(M.order) do out[i] = M.get(id).name end
    return out
end

function M.index_of(id)
    for i, v in ipairs(M.order) do
        if v == id then return i end
    end
    return 1
end

-- Push the device's UEVR overrides (e.g. controller pitch) into UEVR.
function M.apply_uevr_overrides(device)
    if device.uevr == nil then return end
    for key, value in pairs(device.uevr) do
        uevr.params.vr.set_mod_value(key, tostring(value))
    end
end

return M
