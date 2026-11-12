-- Terminals by finger. Routine's terminals (its "Lexi" computers) take
-- their cursor from the game's interaction ray, which runs along the
-- controller from the camera in your hand; the fingertip is a few cm above
-- that line, so the cursor sat below it.
--
-- Near a screen the camera slides up to the fingertip, so the ray (and the
-- cursor) starts under your finger, and when the fingertip reaches the
-- screen the interact trigger is held for you: a tap is a click. Away from
-- screens the camera goes back to the hand.
--
-- Tried and dropped: moving the pawn's WidgetInteraction (unused by the
-- game), and writing the screen's MouseLocation (turned it to garbage and
-- stopped all clicks). The first camera slide went the wrong way (UEVR's
-- offset lands mirrored on it), which made it look like the ray started at
-- the head.

local settings = require("routine_vr.settings")
local input = require("routine_vr.input")
local handed = require("routine_vr.handed")
local game = require("routine_vr.game")
local motion_hands = require("routine_vr.motion_hands")
local hands = require("routine_vr.hands")
local held = require("routine_vr.held")
local touch = require("routine_vr.touch")
local notes = require("routine_vr.notes")

local M = {}

-- One-off survey of the terminal's own classes and values.
local lexi = { started = false, running = false }
do
    local FILE = "routine_vr_lexi.json"
    local CLASSES = { "RoutineGameLexiSystemComponent", "RoutineGameLexiMouse", "RoutineGameLexiOS",
        "RoutineGameLexiWidget", "RoutineGameLexiOSWidget", "RoutineGameLexiHardwareInterface",
        "RoutineGameLexiProcessor", "RoutineGameWidgetComponent", "RoutineGameRenderWidget",
        "RoutineVeneMouse", "RoutineComputerMainWidget" }
    local STOP = { Object = true, ActorComponent = true, SceneComponent = true, UserWidget = true,
        Widget = true, Visual = true, PrimitiveComponent = true, MeshComponent = true }
    local SAMPLE_SECONDS, SAMPLE_FOR = 0.25, 15.0
    local lines, watched, last, t, every = {}, {}, {}, 0.0, 0.0

    local function safe2(fn) local ok, v = pcall(fn) if ok then return v end return nil end
    local function fname(o) return o and safe2(function() return o:get_fname():to_string() end) or "?" end
    local function super_of(s) return safe2(function() return s:get_super_struct() end) end
    local function kind(p) return safe2(function() return p:get_class():get_fname():to_string() end) or "?" end
    local function save() pcall(json.dump_file, FILE, { lines = lines }, 1) end

    local function chain_text(cls)
        local out, s = {}, cls
        while s ~= nil do out[#out + 1] = fname(s); s = super_of(s) end
        return table.concat(out, " > ")
    end

    -- Properties and functions (with parameters) down to an engine base.
    local function dump_class(cls, label)
        lines[#lines + 1] = label .. ": " .. chain_text(cls)
        local s = cls
        while s ~= nil and not STOP[fname(s)] do
            local owner = fname(s)
            local p = safe2(function() return s:get_child_properties() end)
            while p ~= nil do
                lines[#lines + 1] = string.format("  prop %s.%s : %s", owner, fname(p), kind(p))
                p = safe2(function() return p:get_next() end)
            end
            local u = safe2(function() return s:get_children() end)
            while u ~= nil do
                local params = {}
                local f = safe2(function() return u:get_child_properties() end)
                while f ~= nil do
                    params[#params + 1] = fname(f) .. ":" .. kind(f)
                    f = safe2(function() return f:get_next() end)
                end
                lines[#lines + 1] = string.format("  func %s.%s(%s)", owner, fname(u), table.concat(params, ", "))
                u = safe2(function() return u:get_next() end)
            end
            s = super_of(s)
        end
    end

    local function props_of(obj)
        local out, s = {}, safe2(function() return obj:get_class() end)
        while s ~= nil and not STOP[fname(s)] do
            local p = safe2(function() return s:get_child_properties() end)
            while p ~= nil do
                out[#out + 1] = { name = fname(p), kind = kind(p) }
                p = safe2(function() return p:get_next() end)
            end
            s = super_of(s)
        end
        return out
    end

    local function value_text(obj, p)
        local v = safe2(function() return obj[p.name] end)
        if v == nil then return nil end
        if p.kind == "StructProperty" then
            local x, y, z = safe2(function() return v.X end), safe2(function() return v.Y end), safe2(function() return v.Z end)
            if type(x) == "number" then
                return string.format("%.2f,%.2f%s", x, y or 0, type(z) == "number" and string.format(",%.2f", z) or "")
            end
            return nil
        end
        if p.kind == "ObjectProperty" then return fname(safe2(function() return v:get_class() end)) .. ":" .. fname(v) end
        if type(v) == "number" then return string.format("%.3f", v) end
        return tostring(v)
    end

    local function watch(obj, label)
        if obj == nil or watched[label] then return end
        watched[label] = { obj = obj, props = props_of(obj) }
        local cls = safe2(function() return obj:get_class() end)
        if cls then dump_class(cls, label .. " (instance " .. fname(obj) .. ")") end
        -- And the Lexi objects it points at, one level down.
        for _, p in ipairs(watched[label].props) do
            if p.kind == "ObjectProperty" then
                local o = safe2(function() return obj[p.name] end)
                local c = o and fname(safe2(function() return o:get_class() end)) or ""
                if c:find("Lexi", 1, true) or c:find("Mouse", 1, true) or c:find("Vene", 1, true) then
                    watch(o, label .. "." .. p.name)
                end
            end
        end
    end

    function lexi.start(widget_comp)
        lexi.started, lexi.running, t, every = true, true, 0.0, SAMPLE_SECONDS
        for _, name in ipairs(CLASSES) do
            local cls = safe2(function() return uevr.api:find_uobject("Class /Script/Routine." .. name) end)
            if cls then dump_class(cls, "class " .. name) else lines[#lines + 1] = "class " .. name .. ": not found" end
        end
        local owner = safe2(function() return widget_comp:GetOwner() end)
        lines[#lines + 1] = "terminal actor " .. fname(owner) .. " " .. chain_text(safe2(function() return owner:get_class() end))
        for _, c in ipairs(safe2(function() return owner:K2_GetComponentsByClass(uevr.api:find_uobject("Class /Script/Engine.ActorComponent")) end) or {}) do
            local cn = fname(safe2(function() return c:get_class() end))
            lines[#lines + 1] = "  component " .. fname(c) .. " (" .. cn .. ")"
            if cn:find("Lexi", 1, true) then watch(c, "component " .. fname(c)) end
        end
        watch(widget_comp, "widget component")
        local w = safe2(function() return widget_comp:GetUserWidgetObject() end)
        watch(w, "widget")
        -- Every Lexi system in the level, in case the screen's is elsewhere.
        local cls = safe2(function() return uevr.api:find_uobject("Class /Script/Routine.RoutineGameLexiSystemComponent") end)
        local list = cls and safe2(function() return UEVR_UObjectHook.get_objects_by_class(cls, false) end) or {}
        lines[#lines + 1] = "lexi systems in the level: " .. #list
        for i, sys in ipairs(list) do
            local o = safe2(function() return sys:GetOwner() end)
            lines[#lines + 1] = "  " .. fname(sys) .. " on " .. fname(o)
            if i <= 3 then watch(sys, "lexi system " .. i) end
        end
        save()
    end

    -- Values that change, every quarter second for 15 s.
    function lexi.sample(delta)
        t, every = t + delta, every + delta
        if every < SAMPLE_SECONDS then return end
        every = 0.0
        local changes = {}
        for label, w in pairs(watched) do
            for _, p in ipairs(w.props) do
                local key = label .. "." .. p.name
                local v = value_text(w.obj, p)
                if v ~= nil and v ~= last[key] then
                    last[key] = v
                    changes[#changes + 1] = key .. "=" .. v
                end
            end
        end
        if #changes > 0 then lines[#lines + 1] = string.format("t=%.2f %s", t, table.concat(changes, " | ")) end
        if t >= SAMPLE_FOR then
            lexi.running = false
            lines[#lines + 1] = "done"
        end
        save()
    end
end

local WIDGET_CLASS = "Class /Script/UMG.WidgetComponent"
local SCAN_SECONDS = 0.5
local SCAN_RANGE = 80       -- cm from the fingertip
local RELEASE_EXTRA = 1.5   -- cm further out than the press point that lets go
local MIN_PRESS = 0.05      -- s: the shortest click sent (a few frames)
local PULLBACK = 1.0        -- cm back from the deepest point that ends a press
local TRIGGER_HELD = 8      -- trigger value (0-255): the finger is curling, keep the cursor put
local DEEPEST = -8.0        -- cm: further through than this is reaching past, not pressing
local FRONT = 15.0          -- cm: closer than this to a screen counts as near it
local SLIDE_NEAR = 40.0     -- cm: within this of a screen the camera goes to the fingertip
local MAX_SCREEN = 100.0    -- cm: wider than this isn't a terminal (the PDA's projector)
local EDGE = 3.0            -- cm of slack round a screen's edges

M.status = "Not near a screen."
M.pressing = false

local press_time = 0.0
local deepest = nil
local owner_pawn = nil
local screens = {}          -- { comp, name, half_w, half_h, cx, cy }
local known = {}            -- component address -> described
local timer = SCAN_SECONDS
local checked_ray = false

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end

-- A world point in a screen's frame: in front (cm, negative: through it),
-- across (right) and up. Widget components face along their forward axis.
function M.screen_point(screen_loc, screen_rot, point)
    local f, r, u = hands.rotator_axes(screen_rot.Pitch, screen_rot.Yaw, screen_rot.Roll)
    local d = { x = point.X - screen_loc.X, y = point.Y - screen_loc.Y, z = point.Z - screen_loc.Z }
    return dot(d, f), dot(d, r), dot(d, u)
end

function M.plane_distance(screen_loc, screen_rot, point)
    return (M.screen_point(screen_loc, screen_rot, point))
end

-- Is a point (across, up from the screen's origin) on the screen? s holds
-- its half size and centre.
function M.on_screen(s, across, up)
    return math.abs(across - s.cx) <= s.half_w + EDGE and math.abs(up - s.cy) <= s.half_h + EDGE
end

-- A point on a screen (across, up in cm from its origin) in the widget's
-- pixels, from the top left. s holds its size in cm (w, h), centre (cx, cy)
-- and pixels (px_w, px_h). Facing the screen, its right axis points to your
-- left, so pixels run against it; s.mirror turns that round (the mapping
-- check logs which way the game's own cursor agrees with).
function M.to_pixels(s, across, up)
    local fx = (across - s.cx) / s.w
    if not s.mirror then fx = -fx end
    local x = (fx + 0.5) * s.px_w
    local y = (0.5 - (up - s.cy) / s.h) * s.px_h
    return x, y
end

-- Where the game's ray starts: just in front of the glass, straight out
-- from the spot under the fingertip, so it lands there whatever the wrist
-- angle. Starting it right at the glass makes the ray's direction (UEVR's
-- aim, a little off the controller's grip) not matter; starting further
-- back put the cursor well below a relaxed tap. tip is a world point
-- (X/Y/Z), front its distance in front of the widget plane, normal the
-- screen's facing, and glass how far in front of that plane the ray's
-- target surface is (cm; panel slider). At 6 (the tap depth) a relaxed tap
-- landed above the finger, so the surface looks to be the widget plane.
local GAP = 1.5 -- cm in front of the glass
function M.ray_start(tip, front, normal, glass)
    local k = glass + GAP - front
    return { X = tip.X + normal.x * k, Y = tip.Y + normal.y * k, Z = tip.Z + normal.z * k }
end

-- Pressing or not, from the fingertip's distance to the screen (nil: not
-- over one). A press lets go as soon as the finger comes back PULLBACK from
-- the deepest it went, so a quick tap releases quickly; a finger held on
-- the screen, or slid along it, keeps pressing (dragging). Returns
-- pressing, how long, and the deepest point.
function M.step(pressing, held_for, distance, delta, press_at, deepest)
    press_at = press_at or 1.0
    if pressing then
        held_for = held_for + delta
        if distance ~= nil and (deepest == nil or distance < deepest) then deepest = distance end
        local out = distance == nil or distance < DEEPEST or distance > press_at + RELEASE_EXTRA
            or (deepest ~= nil and distance > deepest + PULLBACK)
        if out and held_for >= MIN_PRESS then return false, 0.0, nil end
        return true, held_for, deepest
    end
    if distance ~= nil and distance <= press_at and distance >= DEEPEST then return true, 0.0, distance end
    return false, 0.0, nil
end

local function name_of(obj)
    return obj and safe(function() return obj:get_fname():to_string() end) or "?"
end

-- Size of a widget component on screen, in cm, and where its middle is
-- relative to its origin (the pivot).
local function measure(comp)
    local size = safe(function() return comp.DrawSize end)
    local scale = safe(function() return comp:K2_GetComponentScale() end)
    local pivot = safe(function() return comp.Pivot end)
    if size == nil or size.X == nil then return nil end
    local sy = scale and scale.Y or 1
    local sz = scale and scale.Z or 1
    local w, h = size.X * sy, size.Y * sz
    local px = pivot and pivot.X or 0.5
    local py = pivot and pivot.Y or 0.5
    -- The pivot is measured from the top left; across is to the right, up is up.
    return { half_w = w / 2, half_h = h / 2, cx = (0.5 - px) * w, cy = (py - 0.5) * h, w = w, h = h,
        px_w = size.X, px_h = size.Y }
end

local function scan(tip)
    screens = {}
    local cls = safe(function() return uevr.api:find_uobject(WIDGET_CLASS) end)
    local list = cls and safe(function() return UEVR_UObjectHook.get_objects_by_class(cls, false) end)
    for _, comp in ipairs(type(list) == "table" and list or {}) do
        local loc = safe(function() return comp:K2_GetComponentLocation() end)
        if loc ~= nil then
            local dx, dy, dz = loc.X - tip.X, loc.Y - tip.Y, loc.Z - tip.Z
            if dx * dx + dy * dy + dz * dz < (SCAN_RANGE + 100) ^ 2 then
                local key = comp:get_address()
                local info = known[key]
                if info == nil then
                    local owner = safe(function() return comp:GetOwner() end)
                    local owner_class = owner and safe(function() return owner:get_class():get_fname():to_string() end) or ""
                    info = measure(comp) or {}
                    info.name = name_of(owner) .. "." .. name_of(comp)
                    info.skip = owner_class:find("CAT", 1, true) ~= nil or info.half_w == nil
                        or info.w > MAX_SCREEN
                    info.space = safe(function() return comp.Space end)
                    -- The screen mesh this widget is drawn on keeps the cursor.
                    for _, c in ipairs(owner and safe(function()
                        return owner:K2_GetComponentsByClass(uevr.api:find_uobject("Class /Script/Engine.StaticMeshComponent"))
                    end) or {}) do
                        local w = safe(function() return c.Widget end)
                        if w ~= nil and w:get_address() == key then
                            -- A terminal can have a primary and a secondary screen on the
                            -- same widget; the cursor is read from the primary.
                            info.screens = info.screens or {}
                            info.screens[#info.screens + 1] = c
                            if info.screen == nil or not name_of(c):find("Secondary", 1, true) then info.screen = c end
                        end
                    end
                    known[key] = info
                end
                if not info.skip then
                    screens[#screens + 1] = { comp = comp, info = info, key = key }
                end
            end
        end
    end
end

local function vec_text(v)
    if v == nil or v.X == nil then return "?" end
    return string.format("%.1f,%.1f,%.1f", v.X, v.Y, v.Z)
end

-- Once: where the game's ray actually starts, next to the camera, the
-- controller, the fingertip and the head, to check that sliding the camera
-- moves it.
local function check_ray(pawn, loc, rot, tip)
    checked_ray = true
    local function here(v)
        if v == nil or v.X == nil then return "?" end
        local f, r, u = motion_hands.controller_axes_point(loc, rot, v)
        return string.format("%.1f,%.1f,%.1f", f, r, u)
    end
    local cam = safe(function() return pawn.CameraComponent:K2_GetComponentLocation() end)
    local pc = uevr.api:get_player_controller(0)
    local head = pc and safe(function() return pc.PlayerCameraManager:GetCameraLocation() end)
    notes.add(string.format("terminal: in the controller's frame: camera %s fingertip %s view %s",
        here(cam), here(tip), here(head)))

    local list = touch.params_of(pawn, "GetTrace")
    if list == nil then
        notes.add("terminal: pawn has no GetTrace")
        return
    end
    notes.add("terminal: " .. touch.describe(list, "GetTrace"))
    local args = {}
    for i, e in ipairs(list) do
        if e.kind == "StructProperty" and e.struct ~= nil then
            args[i] = safe(function() return StructObject.new(e.struct) end)
        else
            args[i] = nil
        end
    end
    local ok, a, b, c = pcall(function() return pawn:GetTrace(table.unpack(args, 1, #list)) end)
    notes.add(string.format("terminal: GetTrace ok=%s returned %s %s %s", tostring(ok), tostring(a), tostring(b), tostring(c)))
    for _, v in ipairs({ a, b, c }) do
        if type(v) == "userdata" or type(v) == "table" then
            notes.add("terminal: GetTrace value " .. here(v) .. " (world " .. vec_text(v) .. ")")
            local start = safe(function() return v.TraceStart end)
            if start ~= nil then notes.add("terminal: GetTrace start " .. here(start) .. " end " .. here(safe(function() return v.TraceEnd end))) end
        end
    end
    for i, e in ipairs(list) do
        if args[i] ~= nil then
            notes.add("terminal: GetTrace arg " .. e.name .. " after: " .. here(args[i]))
            local start = safe(function() return args[i].TraceStart end)
            if start ~= nil then notes.add("terminal: GetTrace arg start " .. here(start) .. " end " .. here(safe(function() return args[i].TraceEnd end))) end
        end
    end
end

-- The fingertip's point, in pixels, into the screen's cursor.
local target = nil           -- { screen, x, y } while the fingertip drives a cursor

local function write_cursor()
    local t = target
    if t == nil then return end
    for _, screen in ipairs(t.screens) do
        local v = safe(function() return screen.MouseLocation end)
        if v ~= nil then
            v.X, v.Y = t.x, t.y
            pcall(function() screen.MouseLocation = v end)
            pcall(function() screen:SetMouseLocation(v) end)
        end
    end
end

function M.apply_late()
    if target ~= nil then write_cursor() end
end

-- A few times per screen: the game's own cursor next to where the mapping
-- puts the game's ray (head, along the controller), to check the mapping.
local function check_mapping(s, sl, sr, loc, rot, pawn)
    local info = s.info
    info.checks = (info.checks or 0) + 1
    if info.checks > 6 then return end
    local pc = uevr.api:get_player_controller(0)
    local head = pc and safe(function() return pc.PlayerCameraManager:GetCameraLocation() end)
    local game = safe(function() return info.screen.MouseLocation end)
    if head == nil or game == nil then return end
    local d = hands.rotator_axes(rot.Pitch, rot.Yaw, rot.Roll)
    local front = M.screen_point(sl, sr, head)
    local f = hands.rotator_axes(sr.Pitch, sr.Yaw, sr.Roll)
    local along = d.x * f.x + d.y * f.y + d.z * f.z
    if math.abs(along) < 0.01 then return end
    local t = -front / along
    local hit = { X = head.X + d.x * t, Y = head.Y + d.y * t, Z = head.Z + d.z * t }
    local _, across, up = M.screen_point(sl, sr, hit)
    local x, y = M.to_pixels(info, across, up)
    local mx = info.px_w - x
    -- Which way across runs, for the log.
    local agree = math.abs(x - game.X) <= math.abs(mx - game.X)
    info.votes = (info.votes or 0) + (agree and 1 or -1)
    notes.add(string.format("terminal: mapping check: game cursor %.0f,%.0f, head ray maps to %.0f,%.0f (mirrored %.0f)",
        game.X, game.Y, x, y, mx))
end

local function let_go()
    M.pressing, press_time, deepest = false, 0.0, nil
    input.force_rt = false
end

local function stand_down()
    target = nil
    hands.set_camera_nudge(0, 0, 0)
    let_go()
end

function M.tick(delta)
    local pawn = uevr.api:get_local_pawn(0)
    local addr = pawn and pawn:get_address()
    if addr ~= owner_pawn then
        owner_pawn, screens, known, timer = addr, {}, {}, SCAN_SECONDS
        stand_down()
    end
    if pawn == nil then return end

    local on = settings.get("terminal_touch") and game.mode == "game" and not game.raised
        and held.active == nil
    local side = handed.main()
    local tip = on and motion_hands.fingertip(side)
    local loc, rot
    if tip then loc, rot = motion_hands.controller_pose(side) end
    if not on or not tip or loc == nil then
        stand_down()
        M.status = settings.get("terminal_touch") and "Waiting (needs motion hands and the C.A.T. put away)." or "Off."
        return
    end

    if lexi.running then
        local ok, err = pcall(lexi.sample, delta)
        if not ok then lexi.running = false; notes.add("terminal: lexi sample failed: " .. tostring(err)) end
    end

    timer = timer + delta
    if timer >= SCAN_SECONDS then
        timer = 0.0
        scan(tip)
    end

    -- The screen the fingertip is in front of, nearest first.
    local best, best_d = nil, nil
    for _, s in ipairs(screens) do
        local sl = safe(function() return s.comp:K2_GetComponentLocation() end)
        local sr = safe(function() return s.comp:K2_GetComponentRotation() end)
        if sl ~= nil and sr ~= nil then
            local d, across, up = M.screen_point(sl, sr, tip)
            if d <= FRONT and d >= DEEPEST and M.on_screen(s.info, across, up)
                and (best_d == nil or math.abs(d) < math.abs(best_d)) then
                best, best_d = s, d
                s.across, s.up = across, up
            end
        end
    end

    -- Near any screen: the ray starts at the fingertip.
    local near, near_d, near_rot = false, nil, nil
    for _, s in ipairs(screens) do
        local sl = safe(function() return s.comp:K2_GetComponentLocation() end)
        local sr = safe(function() return s.comp:K2_GetComponentRotation() end)
        if sl ~= nil and sr ~= nil then
            local d, across, up = M.screen_point(sl, sr, tip)
            if d <= SLIDE_NEAR and d >= DEEPEST and M.on_screen(s.info, across, up)
                and (near_d == nil or math.abs(d) < math.abs(near_d)) then
                near, near_d, near_rot = true, d, sr
            end
        end
    end
    -- Pulling the trigger curls the finger into the hand; the cursor stays
    -- where the finger was pointing until it's let go.
    local trigger = handed.is_left() and input.left_trigger or input.right_trigger
    local curling = trigger > TRIGGER_HELD
    if near and settings.get("terminal_cursor") then
        if not curling then
            local start = tip
            if settings.get("terminal_under_tip") then
                local normal = hands.rotator_axes(near_rot.Pitch, near_rot.Yaw, near_rot.Roll)
                start = M.ray_start(tip, near_d, normal, settings.get("terminal_aim_depth"))
            end
            local f, r, u = motion_hands.controller_axes_point(loc, rot, start)
            hands.set_camera_nudge(f, r, u)
        end
    else
        hands.set_camera_nudge(0, 0, 0)
    end
    M.near = near

    -- Writing the screen's cursor directly broke it; left off.
    local drive = settings.get("terminal_write_mouse") and best ~= nil and best.info.screen ~= nil
    if drive then
        local x, y = M.to_pixels(best.info, best.across, best.up)
        target = { screens = best.info.screens or { best.info.screen }, x = x, y = y }
        write_cursor()
    else
        target = nil
    end
    if not drive and best == nil then
        -- Not close: check the mapping against the game's own cursor.
        for _, s in ipairs(screens) do
            if s.info.screen ~= nil and (s.info.checks or 0) < 6 then
                local sl = safe(function() return s.comp:K2_GetComponentLocation() end)
                local sr = safe(function() return s.comp:K2_GetComponentRotation() end)
                if sl ~= nil and sr ~= nil then
                    local d = M.screen_point(sl, sr, tip)
                    s.check_wait = (s.check_wait or 0) - delta
                    if d > FRONT and d < 60 and s.check_wait <= 0 then
                        s.check_wait = 1.0
                        pcall(check_mapping, s, sl, sr, loc, rot, pawn)
                    end
                end
            end
        end
    end

    if near and not M.logged_slide then
        M.logged_slide, M.slide_wait = true, 0.5
    end
    if M.slide_wait ~= nil then
        M.slide_wait = M.slide_wait - delta
        if M.slide_wait <= 0 then
            M.slide_wait = nil
            local cam = safe(function() return pawn.CameraComponent:K2_GetComponentLocation() end)
            if cam ~= nil then
                local cf, cr, cu = motion_hands.controller_axes_point(loc, rot, cam)
                local tf, tr, tu = motion_hands.controller_axes_point(loc, rot, tip)
                notes.add(string.format("terminal: camera slid to %.1f,%.1f,%.1f, fingertip at %.1f,%.1f,%.1f (controller frame)",
                    cf, cr, cu, tf, tr, tu))
            end
        end
    end

    if best ~= nil and not best.info.logged then
        best.info.logged = true
        notes.add(string.format("terminal: near %s size %.0fx%.0f cm (%dx%d px) space=%s screen=%s fingertip %.1f in front, at %.1f,%.1f",
            best.info.name, best.info.w, best.info.h, best.info.px_w or 0, best.info.px_h or 0, tostring(best.info.space),
            best.info.screen and name_of(best.info.screen) or "none", best_d, best.across, best.up))
        if not checked_ray then pcall(check_ray, pawn, loc, rot, tip) end
        if settings.get("terminal_survey") and not lexi.started then
            local ok, err = pcall(lexi.start, best.comp)
            if not ok then notes.add("terminal: lexi dump failed: " .. tostring(err)) end
        end
    end

    local was = M.pressing
    if curling and not M.pressing then
        best_d = nil -- the trigger is doing the clicking
    end
    M.pressing, press_time, deepest = M.step(M.pressing, press_time, best_d, delta, settings.get("terminal_press_at"), deepest)
    input.force_rt = M.pressing
    if M.pressing and not was then
        motion_hands.buzz(side)
        notes.add(string.format("terminal: press on %s at %.1f cm", best and best.info.name or "?", best_d or 0))
    end

    if best == nil then
        M.status = string.format("Not near a screen (%d screens around).", #screens)
    else
        M.status = string.format("Fingertip %.1f cm from a screen%s%s.", best_d,
            target and string.format(", cursor %.0f,%.0f", target.x, target.y) or ", cursor not found",
            M.pressing and " (pressing)" or "")
    end
end

function M.reset()
    let_go()
    owner_pawn, screens, known, timer, checked_ray = nil, {}, {}, SCAN_SECONDS, false
    lexi.started, lexi.running = false, false
    target, M.logged_slide, M.slide_wait = nil, false, nil
    M.status = "Not near a screen."
end

return M
