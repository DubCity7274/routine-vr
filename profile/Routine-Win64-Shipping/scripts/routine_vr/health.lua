-- Watches UEVR's own log for a launch where its frame tracking came up
-- broken, so the panel can say "restart the game" instead of leaving you
-- to guess.
--
-- Seen in the headset: some launches, from the first frame on, UEVR logs
-- "the vtable is already hooked, maybe previous frame was not rendered?"
-- once a second, and head tracking is jittery for the whole session; a
-- smooth launch logs it zero times. Frame time was the same (about 21 ms)
-- in both, so it isn't the game slowing down, and only a restart cures it.
--
-- The log is read from where the last read stopped, every few seconds.

local M = {}

local CHECK_INTERVAL = 5.0
local WARNING = "previous frame was not rendered"
local BROKEN_AFTER = 4          -- warnings in one check (5 s) that mean it's broken
local BROKEN_TOTAL = 8          -- or this many in all (a smooth launch logs none)

M.broken = false                -- this launch has the jitter; restart the game
M.warnings = 0                  -- seen this launch
M.status = "not checked yet"

local timer = CHECK_INTERVAL    -- check on the first tick
local pos = 0
local readable = true

-- New text in UEVR's log since the last call, or nil. UEVR sandboxes Lua's
-- file access to the profile's data folder, so this reads the link the
-- installer makes there (see devices/init.lua). Replaced in tests.
function M.read_new()
    if io == nil or io.open == nil then return nil end
    local f = io.open("uevr_log.txt", "rb")
    if f == nil then return nil end
    local size = f:seek("end")
    if size < pos then pos = 0 end -- a new log (the game was restarted)
    f:seek("set", pos)
    local text = f:read("a")
    pos = f:seek("cur") or size
    f:close()
    return text
end

local function count(text)
    local n, start = 0, 1
    while true do
        local i = text:find(WARNING, start, true)
        if i == nil then return n end
        n, start = n + 1, i + #WARNING
    end
end

function M.tick(delta)
    if not readable then return end
    timer = timer + delta
    if timer < CHECK_INTERVAL then return end
    timer = 0.0
    local ok, text = pcall(M.read_new)
    if not ok then
        readable = false
        M.status = "can't read UEVR's log"
        return
    end
    if type(text) ~= "string" then
        M.status = "can't see UEVR's log (data/uevr_log.txt link missing; the installer makes it)"
        return
    end
    local n = count(text)
    M.warnings = M.warnings + n
    -- Once a second normally; the total catches a log written in bursts.
    if n >= BROKEN_AFTER or M.warnings >= BROKEN_TOTAL then M.broken = true end
    M.status = M.broken and "UEVR frame sync broken this launch: restart the game for smooth tracking"
        or "frame sync ok"
end

function M.reset()
    timer, pos, readable = CHECK_INTERVAL, 0, true
    M.broken, M.warnings, M.status = false, 0, "not checked yet"
end

return M
