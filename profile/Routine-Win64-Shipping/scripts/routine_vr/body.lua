-- Finding out what body Routine has, as the first step toward motion
-- hands. Routine shows no first-person hands, so hands would have to be
-- made from the character's own meshes (CharacterMesh0 and the skeletal
-- meshes under it, which game.lua hides because they float in front of
-- the HMD).
--
-- "Scan body" writes data/routine_vr_body.json: every skeletal mesh on
-- the pawn with its parent, mesh asset, anim instance, visibility flags
-- and all bone names. "Show body" makes them visible (and visible to the
-- owner) so you can see in the headset what's there.

local M = {}

local api = uevr.api
local FILE = "routine_vr_body.json"

M.status = "Not scanned yet."
M.showing = false
local saved = {}   -- component address -> { visible, owner_no_see } before showing

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function name_of(obj)
    return safe(function() return obj:get_fname():to_string() end) or "?"
end

local function full_name(obj)
    if obj == nil then return nil end
    return safe(function() return obj:get_full_name() end) or name_of(obj)
end

local function fname_text(v)
    if type(v) == "string" then return v end
    return safe(function() return v:to_string() end) or tostring(v)
end

-- The pawn's skeletal meshes (CharacterMesh0 included when it is one).
function M.meshes(pawn)
    local out, seen = {}, {}
    local function add(c)
        if c == nil then return end
        local a = safe(function() return c:get_address() end) or c
        if seen[a] then return end
        seen[a] = true
        out[#out + 1] = c
    end
    add(safe(function() return pawn.Mesh end))
    local cls = api:find_uobject("Class /Script/Engine.SkinnedMeshComponent")
        or api:find_uobject("Class /Script/Engine.SkeletalMeshComponent")
    local comps = cls and safe(function() return pawn:K2_GetComponentsByClass(cls) end)
    for _, c in ipairs(type(comps) == "table" and comps or {}) do add(c) end
    return out
end

local function describe(c)
    local d = {
        name = name_of(c),
        class = safe(function() return name_of(c:get_class()) end),
        parent = safe(function() return name_of(c.AttachParent) end),
        socket = safe(function() return fname_text(c.AttachSocketName) end),
        asset = full_name(safe(function() return c.SkeletalMesh end))
            or full_name(safe(function() return c:GetSkeletalMeshAsset() end)),
        anim = full_name(safe(function() return c:GetAnimInstance() end)),
        visible = safe(function() return c:IsVisible() end),
        hidden_in_game = safe(function() return c.bHiddenInGame end),
        owner_no_see = safe(function() return c.bOwnerNoSee end),
        only_owner_see = safe(function() return c.bOnlyOwnerSee end),
        bones = {},
    }
    local n = safe(function() return c:GetNumBones() end) or 0
    d.bone_count = n
    for i = 0, n - 1 do
        d.bones[#d.bones + 1] = fname_text(safe(function() return c:GetBoneName(i) end))
    end
    return d
end

function M.scan()
    local pawn = api:get_local_pawn(0)
    if pawn == nil then
        M.status = "No pawn: load into the game first."
        return
    end
    local list = {}
    for _, c in ipairs(M.meshes(pawn)) do list[#list + 1] = describe(c) end
    local ok, err = pcall(json.dump_file, FILE, { pawn = full_name(pawn), meshes = list }, 2)
    if ok then
        local bones = 0
        for _, d in ipairs(list) do bones = bones + (d.bone_count or 0) end
        M.status = string.format("Scanned %d meshes, %d bones: saved data/%s", #list, bones, FILE)
    else
        M.status = "Could not write " .. FILE .. ": " .. tostring(err)
    end
end

-- Make the body visible (on = true) or put it back as it was.
function M.set_show(on)
    local pawn = api:get_local_pawn(0)
    if pawn == nil then return end
    for _, c in ipairs(M.meshes(pawn)) do
        local a = safe(function() return c:get_address() end) or c
        if on then
            if saved[a] == nil then
                saved[a] = { visible = safe(function() return c:IsVisible() end),
                             owner_no_see = safe(function() return c.bOwnerNoSee end) }
            end
            pcall(function() c:SetVisibility(true, false) end)
            pcall(function() c:SetHiddenInGame(false, false) end)
            pcall(function() c:SetOwnerNoSee(false) end)
        elseif saved[a] ~= nil then
            local s = saved[a]
            pcall(function() c:SetVisibility(s.visible ~= false, false) end)
            pcall(function() c:SetOwnerNoSee(s.owner_no_see == true) end)
        end
    end
    if not on then saved = {} end
    M.showing = on
end

function M.reset()
    saved = {}
    M.showing = false
end

return M
