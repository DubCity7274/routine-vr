-- Device registry.
--
-- A device module describes one controller family as data only:
--
--   id, name          identifiers shown in the UI
--   buttons           gamepad button -> list of physical input names (any held = pressed)
--   triggers          { LT = {...}, RT = {...} } same format
--   uevr              optional UEVR mod values applied when the device is selected
--   hand_offset       default rotation/location offset for attached components
--   glove             optional { left = {rot, loc}, right = {rot, loc} } added to
--                     the motion-hands glove offset for this controller
--                     (zero under OpenXR, whose poses are uniform)
--   recenter          optional list of chords (lists of input names) that
--                     recenter when held; default right B + left Y
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
    a_l            = { action = P .. "AButtonLeft",        hand = "left",  either = true },
    b_l            = { action = P .. "BButtonLeft",        hand = "left",  either = true },
    a_r            = { action = P .. "AButtonRight",       hand = "right", either = true },
    b_r            = { action = P .. "BButtonRight",       hand = "right", either = true },
    stick_click_l  = { action = P .. "JoystickClick",      hand = "left"  },
    stick_click_r  = { action = P .. "JoystickClick",      hand = "right" },
    -- Thumb on the thumbrest, or on the stick: the mod's binding files
    -- (profile root, _interaction_profiles_*.json) add each stick's touch
    -- sensor to these actions, since UEVR has no stick-touch action.
    -- Actions that only exist on one hand are read from both sides
    -- (either = true): UEVR's per-hand read gave the wrong hand for the
    -- left (the left thumb never curled).
    thumbrest_l    = { action = P .. "ThumbrestTouchLeft", hand = "left",  either = true },
    thumbrest_r    = { action = P .. "ThumbrestTouchRight",hand = "right", either = true },
    a_touch_l      = { action = P .. "AButtonTouchLeft",   hand = "left",  either = true },
    b_touch_l      = { action = P .. "BButtonTouchLeft",   hand = "left",  either = true },
    a_touch_r      = { action = P .. "AButtonTouchRight",  hand = "right", either = true },
    b_touch_r      = { action = P .. "BButtonTouchRight",  hand = "right", either = true },
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

-- Auto-detect: UEVR logs the headset's name at startup ("OpenXR system
-- Name: Meta Quest 3 on WiVRn"); the Lua API has no call for it, so the log
-- is read. The headset name stands in for the controllers that usually come
-- with it. First match wins (lower-case substrings).
M.PATTERNS = {
    { "vive focus", "quest_touch" }, { "xr elite", "quest_touch" }, { "cosmos", "quest_touch" },
    { "quest", "quest_touch" }, { "oculus", "quest_touch" }, { "rift", "quest_touch" }, { "meta", "quest_touch" },
    { "index", "index_knuckles" }, { "valve", "index_knuckles" }, { "bigscreen", "index_knuckles" },
    { "beyond", "index_knuckles" }, { "varjo", "index_knuckles" }, { "pimax", "index_knuckles" },
    { "pico", "pico" },
    { "reverb", "wmr" }, { "odyssey", "wmr" }, { "mixed reality", "wmr" }, { "wmr", "wmr" },
    { "holographic", "wmr" },
    { "playstation", "quest_touch" }, { "psvr", "quest_touch" },
    { "vive", "vive_wands" },
}

function M.from_system_name(name)
    if name == nil then return nil end
    local low = name:lower()
    for _, p in ipairs(M.PATTERNS) do
        if low:find(p[1], 1, true) then return p[2] end
    end
    return nil
end

local LOG_NAMES = { "OpenXR system Name: ([^\r\n]+)", "[Ss]ystem [Nn]ame: ([^\r\n]+)" }

-- The headset name from UEVR's log, or nil (log not readable or not yet
-- written). Tries Lua's io (the profile folder under %APPDATA%), then
-- UEVR's fs, which is rooted in the profile's data folder.
function M.read_system_name()
    local text = nil
    pcall(function()
        local appdata = os.getenv("APPDATA")
        if appdata == nil then return end
        local f = io.open(appdata .. "\\UnrealVRMod\\Routine-Win64-Shipping\\log.txt", "rb")
        if f then
            text = f:read("a")
            f:close()
        end
    end)
    if text == nil then
        pcall(function() text = fs.read("../log.txt") end)
    end
    if type(text) ~= "string" then return nil end
    local found = nil
    for _, pat in ipairs(LOG_NAMES) do
        for name in text:gmatch(pat) do found = name end -- the last one is this session's
        if found then break end
    end
    return found
end

local cache = {}

-- Every layout is loaded now: UEVR only finds the mod's files while the
-- script is first loading, so a layout required later (auto-detect, or a
-- pick in the panel) would silently fall back to Touch.
for _, id in ipairs(M.order) do
    local ok, mod = pcall(require, "routine_vr.devices." .. id)
    if ok then
        mod.id = mod.id or id
        cache[id] = mod
    else
        print("[routine_vr] couldn't load layout '" .. id .. "': " .. tostring(mod))
    end
end

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

-- OpenXR gives every controller the same grip and aim poses, so the
-- per-controller pitch fixes are only for OpenVR (SteamVR), where the raw
-- poses differ by controller. Under OpenXR the pitch offset stays 0, which
-- also keeps the glove alignment the same across controllers.
function M.uses_openvr()
    local ok, v = pcall(function() return uevr.params.vr.is_openvr() end)
    return ok and v == true
end

-- Push the device's UEVR overrides (e.g. controller pitch) into UEVR.
function M.apply_uevr_overrides(device)
    if device.uevr == nil then return end
    local openvr = M.uses_openvr()
    for key, value in pairs(device.uevr) do
        if key == "VR_ControllerPitchOffset" and not openvr then value = "0.000000" end
        uevr.params.vr.set_mod_value(key, tostring(value))
    end
end

return M
