-- A small diary in the profile's data folder, data/routine_vr_notes.json.
-- Lua's print doesn't reach UEVR's log.txt, so anything worth reading after
-- a session is written here. Starts fresh each launch; keeps the last lines.

local M = {}

local FILE = "routine_vr_notes.json"
local MAX_LINES = 400

M.lines = {}

function M.add(text)
    print("[routine_vr] " .. text)
    M.lines[#M.lines + 1] = string.format("%.1f %s", os.clock(), text)
    if #M.lines > MAX_LINES then table.remove(M.lines, 1) end
    pcall(json.dump_file, FILE, { lines = M.lines }, 1)
end

function M.reset()
    M.lines = {}
end

return M
