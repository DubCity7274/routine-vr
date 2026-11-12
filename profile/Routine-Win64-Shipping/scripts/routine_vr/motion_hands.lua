-- Motion hands made from Routine's own spacesuit arms.
--
-- The body scan (body.lua) found SK_Player_Default_Arms on the pawn, a
-- full skeleton with Bone_Arm_L/R_Palm and three bones per finger, animated
-- by the game for the flat-screen view (and hidden by game.lua because it
-- floats in front of the HMD). Here a PoseableMeshComponent copy of it is
-- added to the pawn and:
--
--   * Bone_Pelvis is scaled to almost nothing, which collapses the whole
--     body, arms included, to an invisible point;
--   * every frame each palm bone is set to its controller's world
--     transform (plus a per-hand offset from the panel) and back to full
--     scale (setting a bone's location/rotation keeps its collapsed scale:
--     the first try showed only a few stretched wrist triangles), with the
--     forearm bones placed rigidly behind it as in the game's pose.
--
-- The controllers' world transforms come from two empty SceneComponents
-- held on the hands by UObjectHook, like the laser and touch dot.

local settings = require("routine_vr.settings")
local hands = require("routine_vr.hands")
local game = require("routine_vr.game")
-- Required here, not in functions: UEVR only finds the mod's files while
-- the script is first loading.
local input = require("routine_vr.input")
local handed = require("routine_vr.handed")

local M = {}

local api = uevr.api
local WORLD_SPACE = 0
local COMPONENT_SPACE = 1
local BOUNDS_SCALE = 20.0      -- culling box around the arms, times the imported one
local RTS_COMPONENT = 2      -- ERelativeTransformSpace, for GetSocketTransform
local COLLAPSE = 0.001
local RETRY_SECONDS = 5.0
local HAND = { left = 0, right = 1 }
local PALM = { left = "Bone_Arm_L_Palm", right = "Bone_Arm_R_Palm" }
-- Posed rigidly behind the palm as the game's own pose had them, so the
-- wrist and sleeve don't stretch back to the collapsed body.
-- Shrunk to a point at the elbow (where Forearm_01 goes): left at the
-- collapsed body they stretched the sleeve up and back whenever the hands
-- moved away from the body.
local UPPER_ARM = {
    left = { "Bone_Arm_L_Collarbone", "Bone_Arm_L_Upperarm_01", "Bone_Arm_L_Upperarm_02" },
    right = { "Bone_Arm_R_Collarbone", "Bone_Arm_R_Upperarm_01", "Bone_Arm_R_Upperarm_02" },
}
local FOREARM = {
    left = { "Bone_Arm_L_Forearm_01", "Bone_Arm_L_Forearm_02", "Bone_Arm_L_Forearm_03" },
    right = { "Bone_Arm_R_Forearm_01", "Bone_Arm_R_Forearm_02", "Bone_Arm_R_Forearm_03" },
}
M.FINGERTIP = { left = "Bone_Arm_L_Finger_A_03", right = "Bone_Arm_R_Finger_A_03" }

-- Finger chains, knuckle first. A is the index finger (its tip presses the
-- C.A.T.'s buttons), B-D middle to pinky.
local CHAINS = { "Thumb", "Finger_A", "Finger_B", "Finger_C", "Finger_D" }
local JOINT_MAX = { finger = { 70, 90, 70 }, thumb = { 15, 35, 35 } }  -- degrees at full curl
local CURL_SPEED = 20.0
local RTS_PARENT_BONE = 3   -- ERelativeTransformSpace::RTS_ParentBoneSpace

local function chain_bones(side, chain)
    local s = side == "left" and "L" or "R"
    return { "Bone_Arm_" .. s .. "_" .. chain .. "_01", "Bone_Arm_" .. s .. "_" .. chain .. "_02",
             "Bone_Arm_" .. s .. "_" .. chain .. "_03" }
end

M.status = "Off."
M.mesh = nil
local markers = {}       -- hand -> SceneComponent on that controller
local rel = {}           -- bone -> { q, t } relative to its hand's palm, from the game's pose
local arm_ref = {}       -- side -> component-space transforms of the arm bones (game pose)
M.body = nil             -- the game's body mesh: the arms hang from its shoulders
local rest = {}          -- finger bone -> { q, t } relative to its parent bone (fallback pose)
local modelled = {}      -- right thumb bones as the mesh models them: shaped around the C.A.T.
local curl = { left = {}, right = {} }  -- chain -> smoothed 0..1
M.arms = nil             -- the game's own (hidden) arms mesh: live finger poses come from it
M.holding_cat = false    -- the C.A.T. is in the main hand's glove
local MIN_SCALE = 0.01   -- below this the C.A.T. is invisible, not small
local last_hold = nil    -- the C.A.T.'s last offset on the game's hand socket
local cat_home = nil     -- { root, parent, socket, rel_loc, rel_rot } where the game had the C.A.T.
local owner_pawn = nil
local retry_wait = 0.0
local shown = nil

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

-- UE rotator (degrees) <-> quaternion, as FRotator::Quaternion / FQuat::Rotator.
function M.rot_to_quat(p, y, r)
    local sp, cp = math.sin(math.rad(p) / 2), math.cos(math.rad(p) / 2)
    local sy, cy = math.sin(math.rad(y) / 2), math.cos(math.rad(y) / 2)
    local sr, cr = math.sin(math.rad(r) / 2), math.cos(math.rad(r) / 2)
    return {
        x = cr * sp * sy - sr * cp * cy,
        y = -cr * sp * cy - sr * cp * sy,
        z = cr * cp * sy - sr * sp * cy,
        w = cr * cp * cy + sr * sp * sy,
    }
end

local function norm_axis(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

function M.quat_to_rot(q)
    local sing = q.z * q.x - q.w * q.y
    local yaw = math.deg(math.atan(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z)))
    local pitch, roll
    if sing < -0.4999995 then
        pitch = -90
        roll = norm_axis(-yaw - 2 * math.deg(math.atan(q.x, q.w)))
    elseif sing > 0.4999995 then
        pitch = 90
        roll = norm_axis(yaw - 2 * math.deg(math.atan(q.x, q.w)))
    else
        pitch = math.deg(math.asin(2 * sing))
        roll = math.deg(math.atan(-2 * (q.w * q.x + q.y * q.z), 1 - 2 * (q.x * q.x + q.y * q.y)))
    end
    return pitch, yaw, roll
end

local function qmul(a, b)
    return {
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    }
end

local function qrot(q, v)
    local r = qmul(qmul(q, { w = 0, x = v.x, y = v.y, z = v.z }), { w = q.w, x = -q.x, y = -q.y, z = -q.z })
    return { x = r.x, y = r.y, z = r.z }
end

-- The palm's world transform: the controller's, then the hand's offset in
-- the controller's frame (UE axes: x forward, y right, z up).
function M.palm_transform(ctrl_loc, ctrl_rot, offset)
    local cq = M.rot_to_quat(ctrl_rot.Pitch, ctrl_rot.Yaw, ctrl_rot.Roll)
    local oq = M.rot_to_quat(offset.rot[1], offset.rot[2], offset.rot[3])
    local d = qrot(cq, { x = offset.loc[1], y = offset.loc[2], z = offset.loc[3] })
    local p, y, r = M.quat_to_rot(qmul(cq, oq))
    return { X = ctrl_loc.X + d.x, Y = ctrl_loc.Y + d.y, Z = ctrl_loc.Z + d.z }, { Pitch = p, Yaw = y, Roll = r }
end

-- The glove's offset from its controller: the panel's tuning plus the
-- controller layout's own adjustment (devices/*.lua: glove), which is zero
-- for every layout under OpenXR since its poses are uniform across
-- controllers. It's there so a calibration for another controller can be
-- shipped without touching anyone's own tuning.
function M.hand_offset(side)
    local user = settings.get("hand_" .. side)
    local dev = input.device and input.device.glove and input.device.glove[side]
    if dev == nil then return user end
    local ur, ul = user.rot or { 0, 0, 0 }, user.loc or { 0, 0, 0 }
    local dr, dl = dev.rot or { 0, 0, 0 }, dev.loc or { 0, 0, 0 }
    return { rot = { ur[1] + dr[1], ur[2] + dr[2], ur[3] + dr[3] },
             loc = { ul[1] + dl[1], ul[2] + dl[2], ul[3] + dl[3] } }
end

-- The game's arms mesh component on the pawn.
-- One of the suit's meshes on the pawn by asset name ("_Arms", "_Body").
local function find_part(pawn, tag)
    local cls = api:find_uobject("Class /Script/Engine.SkeletalMeshComponent")
    local comps = cls and safe(function() return pawn:K2_GetComponentsByClass(cls) end)
    for _, c in ipairs(type(comps) == "table" and comps or {}) do
        local asset = safe(function() return c.SkeletalMesh end) or safe(function() return c:GetSkeletalMeshAsset() end)
        local name = asset and safe(function() return asset:get_full_name() end) or ""
        if name:find(tag, 1, true) then return c, asset end
    end
    return nil
end

local function find_arms(pawn) return find_part(pawn, "_Arms") end

local function read_transform(mesh, bone)
    local t = mesh:GetBoneTransformByName(bone, COMPONENT_SPACE)
    return { q = { x = t.Rotation.X, y = t.Rotation.Y, z = t.Rotation.Z, w = t.Rotation.W },
             t = { x = t.Translation.X, y = t.Translation.Y, z = t.Translation.Z } }
end

local function conj(q) return { w = q.w, x = -q.x, y = -q.y, z = -q.z } end

-- Each finger bone's transform relative to its parent. Read from the
-- mesh's reference pose (before the game's pose is copied): it's the same
-- for both hands. The game's live pose differed per hand and curled both
-- hands whenever the C.A.T. came out.
local mirror_right_fingers
local mirror_frame
local learn_arms

local function learn_fingers(mesh)
    rest = {}
    for side in pairs(FOREARM) do
        for _, chain in ipairs(CHAINS) do
            local parent = PALM[side]
            for _, b in ipairs(chain_bones(side, chain)) do
                local ok_p, pt = pcall(read_transform, mesh, parent)
                local ok_b, bt = pcall(read_transform, mesh, b)
                if ok_p and ok_b then
                    local ip = conj(pt.q)
                    rest[b] = { q = qmul(ip, bt.q),
                                t = qrot(ip, { x = bt.t.x - pt.t.x, y = bt.t.y - pt.t.y, z = bt.t.z - pt.t.z }) }
                end
                parent = b
            end
        end
    end
    -- The mesh models the right hand already shaped around the C.A.T. (the
    -- left one is relaxed), so the right hand's relaxed pose is the left
    -- one mirrored. Copying the left's joint rotations straight across
    -- bunched the fingers, folded the thumb in and bent the grip downward:
    -- the right side's bone frames aren't simple mirrors. So the mirror is
    -- done properly in component space: reflect across the body's middle
    -- plane (normal: left to right upper arm), then turn by the frame
    -- correction C the skeleton uses on its right side, measured on the
    -- upper arms, which are modelled symmetrically.
    -- Keep the modelled right thumb first: it's posed around the C.A.T.'s
    -- grip, which is what the thumb should do while holding it.
    modelled = {}
    for _, b in ipairs(chain_bones("right", "Thumb")) do
        if rest[b] then modelled[b] = { q = rest[b].q, t = rest[b].t } end
    end
    if settings.get("right_rest_from_left") then
        pcall(mirror_right_fingers, mesh)
    end
    local ok, n, c = pcall(mirror_frame, mesh)
    M.mirror_n, M.mirror_c = ok and n or nil, ok and c or nil
end

-- Reflect a rotation across the plane with normal n (M R M as a quaternion).
local function mirror_q(q, n)
    local d = q.x * n.x + q.y * n.y + q.z * n.z
    return { w = q.w, x = -q.x + 2 * d * n.x, y = -q.y + 2 * d * n.y, z = -q.z + 2 * d * n.z }
end

local function mirror_v(v, n)
    local d = v.x * n.x + v.y * n.y + v.z * n.z
    return { x = v.x - 2 * d * n.x, y = v.y - 2 * d * n.y, z = v.z - 2 * d * n.z }
end

-- The left hand mirrored onto the right: component-space transforms.
function M.mirror_transform(xf, n, c)
    return { q = qmul(mirror_q(xf.q, n), c), t = mirror_v(xf.t, n) }
end

-- The body's middle plane (normal n, left to right upper arm) and the
-- right side's frame correction c, from the reference pose; nil if the
-- arms can't be read.
mirror_frame = function(mesh)
    local lu = read_transform(mesh, "Bone_Arm_L_Upperarm_01")
    local ru = read_transform(mesh, "Bone_Arm_R_Upperarm_01")
    local n = { x = ru.t.x - lu.t.x, y = ru.t.y - lu.t.y, z = ru.t.z - lu.t.z }
    local len = math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
    if len < 1e-3 then return nil end
    n = { x = n.x / len, y = n.y / len, z = n.z / len }
    return n, qmul(conj(mirror_q(lu.q, n)), ru.q)
end

-- The C.A.T.'s offset from the right glove's tool socket, carried to the
-- left glove's: the same hold mirrored across the body (the C.A.T. itself
-- isn't mirrored). The left socket's frame isn't the right one's mirror
-- image (the skeleton turns its right side by c), so reusing the right
-- offset as it was put the C.A.T. off the left hand. With R the right
-- tool's rotation and m() the reflection: left tool = m(R) m(c)^-1, so
-- the offset becomes rotation m(c q), position m(c) applied to m(t).
function M.mirror_offset(loc, rot, n, c)
    local q = M.rot_to_quat(rot[1], rot[2], rot[3])
    local mc = mirror_q(c, n)
    local t = qrot(mc, mirror_v({ x = loc[1], y = loc[2], z = loc[3] }, n))
    local p, y, r = M.quat_to_rot(mirror_q(qmul(c, q), n))
    return { t.x, t.y, t.z }, { p, y, r }
end

-- The left glove's hold: the C.A.T.'s offset from the game's right-hand
-- socket (Socket_Hand_R; there's no matching left one to swap to), taken
-- back to the right palm bone, then mirrored onto the left palm bone,
-- which the C.A.T. attaches to. The socket-to-palm step is read live in
-- component space; it's the same whatever pose the hand is in.
-- Read in world space: the posed copy's component space is skewed by its
-- collapsed pelvis, which made the left C.A.T. too big and off the palm.
-- Also returns the C.A.T.'s world scale in the right glove, so the left one
-- is set to exactly that size.
local function world_xf(mesh, name)
    local t = mesh:GetSocketTransform(name, 0)
    local sc = 1
    pcall(function() sc = t.Scale3D.X end)
    if type(sc) ~= "number" or math.abs(sc) < 1e-6 then sc = 1 end
    return { q = { x = t.Rotation.X, y = t.Rotation.Y, z = t.Rotation.Z, w = t.Rotation.W },
             t = { x = t.Translation.X, y = t.Translation.Y, z = t.Translation.Z }, s = sc }
end

function M.left_hold(mesh, socket, loc, rot, scale)
    local palm = world_xf(mesh, PALM.right)
    local st = world_xf(mesh, socket)
    local ip = conj(palm.q)
    local rs_q = qmul(ip, st.q)
    local rs_t = qrot(ip, { x = (st.t.x - palm.t.x) / palm.s, y = (st.t.y - palm.t.y) / palm.s,
                            z = (st.t.z - palm.t.z) / palm.s })
    local k = st.s / palm.s
    local q = qmul(rs_q, M.rot_to_quat(rot[1], rot[2], rot[3]))
    local d = qrot(rs_q, { x = loc[1] * k, y = loc[2] * k, z = loc[3] * k })
    local t = { rs_t.x + d.x, rs_t.y + d.y, rs_t.z + d.z }
    local p, y, r = M.quat_to_rot(q)
    local l, mr = M.mirror_offset(t, { p, y, r }, M.mirror_n, M.mirror_c)
    -- The offset is applied under the left palm, scaled by its own size.
    local ls = world_xf(mesh, PALM.left).s
    l = { l[1] / ls, l[2] / ls, l[3] / ls }
    local base = scale or { 1, 1, 1 }
    return l, mr, { base[1] * st.s, base[2] * st.s, base[3] * st.s }
end

mirror_right_fingers = function(mesh)
    local n, c = mirror_frame(mesh)
    if n == nil then return end

    for _, chain in ipairs(CHAINS) do
        local lb, rb = chain_bones("left", chain), chain_bones("right", chain)
        local parent = M.mirror_transform(read_transform(mesh, PALM.left), n, c)
        for i = 1, 3 do
            local b = M.mirror_transform(read_transform(mesh, lb[i]), n, c)
            local ip = conj(parent.q)
            rest[rb[i]] = { q = qmul(ip, b.q),
                            t = qrot(ip, { x = b.t.x - parent.t.x, y = b.t.y - parent.t.y, z = b.t.z - parent.t.z }) }
            parent = b
        end
    end
end

-- Each forearm bone's transform relative to its palm, in the game's pose.
local function learn_forearms(mesh)
    rel = {}
    for side, bones in pairs(FOREARM) do
        local ok_p, palm = pcall(read_transform, mesh, PALM[side])
        if ok_p then
            local ip = conj(palm.q)
            for _, b in ipairs(bones) do
                local ok_b, f = pcall(read_transform, mesh, b)
                if ok_b then
                    rel[b] = { q = qmul(ip, f.q),
                               t = qrot(ip, { x = f.t.x - palm.t.x, y = f.t.y - palm.t.y, z = f.t.z - palm.t.z }) }
                end
            end
        end
    end
end

-- World transform of a bone held rigidly to a palm at (loc, quat).
function M.follow(palm_loc, palm_q, r)
    local d = qrot(palm_q, r.t)
    local p, y, ro = M.quat_to_rot(qmul(palm_q, r.q))
    return { X = palm_loc.X + d.x, Y = palm_loc.Y + d.y, Z = palm_loc.Z + d.z }, { Pitch = p, Yaw = y, Roll = ro }
end

-- Where the C.A.T. is: "home" (where the game keeps it, on its arms mesh),
-- "glove" (in the main hand while out) or "holster" (on the body's hip
-- while put away, with motion hands on: the game's own lowered pose follows
-- its hidden arms, so the C.A.T. floated in front of you while crawling).
M.cat_place = "home"
M.hidden_by_game = false   -- the gloves were found hidden (by the game) and shown again
M.cat_scale = "?"          -- C.A.T. world scale and the gloves' palm/socket scales, for the recorder
M.cat_where = "?"          -- what the C.A.T. is attached to (parent:socket), for the recorder
local hit_result = nil
local show_wait = 0

-- Set a component's relative transform (UE loc/rot tables).
local function set_relative(comp, loc, rot)
    local l = comp:K2_GetComponentLocation()
    local r = comp:K2_GetComponentRotation()
    l.X, l.Y, l.Z = loc[1], loc[2], loc[3]
    r.Pitch, r.Yaw, r.Roll = rot[1], rot[2], rot[3]
    if hit_result == nil then
        hit_result = StructObject.new(api:find_uobject("ScriptStruct /Script/Engine.HitResult"))
    end
    comp:K2_SetRelativeLocationAndRotation(l, r, false, hit_result, false)
end

-- The holster offset is in the character's own terms (forward, right, up
-- cm from the pelvis, and a turn from facing forward), so it lands beside
-- the hip whatever way the pelvis bone's axes point; at zero the C.A.T.
-- sat inside the suit's hips. Turned into the bone's frame once, as it's
-- put away; after that it rides with the hips.
local body_bone
function M.holster_relative(o)
    local pelvis = body_bone("Bone_Pelvis")
    local pawn = api:get_local_pawn(0)
    local yaw = pawn and safe(function() return pawn:K2_GetActorRotation().Yaw end) or 0
    local face = M.rot_to_quat(0, yaw, 0)
    local off = qrot(face, { x = o.loc[1], y = o.loc[2], z = o.loc[3] })
    local ip = conj(pelvis.q)
    local t = qrot(ip, off)
    local p, y, r = M.quat_to_rot(qmul(ip, qmul(face, M.rot_to_quat(o.rot[1], o.rot[2], o.rot[3]))))
    return { t.x, t.y, t.z }, { p, y, r }
end

-- The hip offset is baked into the pelvis bone's frame, so whatever pose
-- the body was in when the C.A.T. went there stays in it: put away during
-- the wake-up animation in the Ward, it ended up in your chest. Worked out
-- again every so often, but only applied for a real change of pose (lying
-- down, crawling), or it stepped visibly with every stride. Compared as a
-- rotation, not angle by angle: near straight down (the tuned hip pitch is
-- about -84) pitch/yaw/roll swing wildly for a tiny turn.
local HIP_REBAKE_DEG = 25.0
function M.refresh_hip()
    local h = cat_home
    if h == nil or h.hip_rot == nil or M.body == nil then return end
    local ok, l, r = pcall(M.holster_relative, settings.get("cat_holster_" .. handed.main()))
    if not ok then return end
    local a = M.rot_to_quat(h.hip_rot[1], h.hip_rot[2], h.hip_rot[3])
    local q = M.rot_to_quat(r[1], r[2], r[3])
    local dot = math.min(1, math.abs(a.w * q.w + a.x * q.x + a.y * q.y + a.z * q.z))
    if math.deg(2 * math.acos(dot)) > HIP_REBAKE_DEG and pcall(set_relative, h.root, l, r) then
        h.hip_loc, h.hip_rot = l, r
    end
end

-- Move the C.A.T. to place ("home", "glove", "holster").
local function move_cat(place, socket)
    local h = cat_home
    if h == nil then return false end
    local ok = pcall(function()
        -- Back to the game's own relative offset first, so a holster offset
        -- never carries over into the glove or the game's pose.
        set_relative(h.root, h.rel_loc, h.rel_rot)
        -- And its own size: the game scales the C.A.T. for its first-person
        -- view. Snapping it to the hip reset that to 1, and the bigger C.A.T.
        -- then came back into the hand. Every move keeps the game's scale.
        if h.rel_scale ~= nil then
            local sc = h.root.RelativeScale3D
            sc.X, sc.Y, sc.Z = h.rel_scale[1], h.rel_scale[2], h.rel_scale[3]
            h.root:SetRelativeScale3D(sc)
        end
        if place == "glove" then
            h.root:K2_AttachToComponent(M.mesh, socket, 0, 0, 0, false)
            if handed.is_left() and M.mirror_n ~= nil then
                local l, r, ws = M.left_hold(M.mesh, h.socket_name, h.rel_loc, h.rel_rot, h.rel_scale)
                set_relative(h.root, l, r)
                local sc = h.root.RelativeScale3D
                sc.X, sc.Y, sc.Z = ws[1], ws[2], ws[3]
                h.root:SetWorldScale3D(sc)
            end
        elseif place == "holster" then
            h.root:K2_AttachToComponent(M.body, "Bone_Pelvis", 2, 2, 0, false) -- snap to the bone, keep its size
            local l, r = M.holster_relative(settings.get("cat_holster_" .. handed.main()))
            set_relative(h.root, l, r)
            h.hip_loc, h.hip_rot = l, r
        else
            h.root:K2_AttachToComponent(h.parent, h.socket, 0, 0, 0, false)
            set_relative(h.root, h.rel_loc, h.rel_rot)
        end
    end)
    if ok then M.cat_place = place end
    return ok
end

local function release_cat()
    if M.cat_place ~= "home" then move_cat("home") end
    M.cat_place = "home"
    M.cat_sig = nil
    M.holding_cat = false
    game.cat_on_glove = false
end

local function destroy()
    release_cat()
    game.cat_managed = false
    cat_home = nil
    for _, m in pairs(markers) do
        pcall(function() UEVR_UObjectHook.remove_motion_controller_state(m) end)
        pcall(function() m:K2_DestroyComponent(m) end)
    end
    if M.mesh ~= nil then
        local mesh = M.mesh
        pcall(function() mesh:K2_DestroyComponent(mesh) end)
    end
    markers, M.mesh, owner_pawn, shown, rel, rest, modelled = {}, nil, nil, nil, {}, {}, {}
    arm_ref, M.body = {}, nil
    M.arms = nil
    curl = { left = {}, right = {} }
end

local function fail(msg)
    M.status = msg
    retry_wait = RETRY_SECONDS
    destroy()
end

-- Where the game's hand socket sits on the palm, on the game's own arms.
-- The gloves copy the arm pose once, when they're built; nothing updates
-- the part that carries that socket afterwards. Built during the wake-up
-- on the floor in the Ward, the C.A.T. sat wrong for the whole session
-- until a reload. So the gloves are rebuilt once the game's arms have
-- settled into a different hold than the one they were built from.
local SETTLE_INTERVAL, SETTLE_SAMPLES = 0.5, 4    -- steady for about 2 s
local SETTLE_CM, SETTLE_DEG = 0.8, 4.0
local SETTLE_MAX_REBUILDS = 3                     -- per pawn
local settle = { timer = 0.0, base = nil, last = nil, same = 0, rebuilds = 0, pawn = nil }

M.settle = settle -- for the recorder and tests

local function arm_hold()
    local palm = world_xf(M.arms, PALM.right)
    local st = world_xf(M.arms, "Socket_Hand_R")
    local ip = conj(palm.q)
    return { q = qmul(ip, st.q), t = qrot(ip, { x = st.t.x - palm.t.x, y = st.t.y - palm.t.y, z = st.t.z - palm.t.z }) }
end

local function hold_differs(a, b)
    local dx, dy, dz = a.t.x - b.t.x, a.t.y - b.t.y, a.t.z - b.t.z
    local dot = math.min(1, math.abs(a.q.w * b.q.w + a.q.x * b.q.x + a.q.y * b.q.y + a.q.z * b.q.z))
    return math.sqrt(dx * dx + dy * dy + dz * dz) > SETTLE_CM or math.deg(2 * math.acos(dot)) > SETTLE_DEG
end

-- Only while the C.A.T. is away: raised, the game's arms are in its hold.
local function settle_check(delta)
    if M.mesh == nil or M.arms == nil or game.mode ~= "game" or game.raised then
        settle.last, settle.same = nil, 0
        return
    end
    settle.timer = settle.timer + delta
    if settle.timer < SETTLE_INTERVAL then return end
    settle.timer = 0.0
    local ok, now = pcall(arm_hold)
    if not ok then return end
    if settle.base == nil then settle.base = now return end
    if settle.last ~= nil and not hold_differs(now, settle.last) then
        settle.same = settle.same + 1
    else
        settle.same = 0
    end
    settle.last = now
    if settle.same >= SETTLE_SAMPLES and settle.rebuilds < SETTLE_MAX_REBUILDS and hold_differs(now, settle.base) then
        settle.rebuilds = settle.rebuilds + 1
        settle.base, settle.last, settle.same = nil, nil, 0
        M.reset()
    end
end

local function create(pawn)
    local arms, asset = find_arms(pawn)
    if arms == nil or asset == nil then return fail("Couldn't find the game's arms mesh yet.") end
    M.arms = arms
    M.body = find_part(pawn, "_Body")
    -- Keep the hidden arms animating: their finger poses (e.g. gripping
    -- the C.A.T.) are copied onto the gloves. 0 = AlwaysTickPoseAndRefreshBones.
    pcall(function() arms.VisibilityBasedAnimTickOption = 0 end)

    local poseable = api:find_uobject("Class /Script/Engine.PoseableMeshComponent")
    local scene = api:find_uobject("Class /Script/Engine.SceneComponent")
    if poseable == nil or scene == nil then return fail("PoseableMeshComponent class not found.") end

    local ok, mesh = pcall(function() return api:add_component_by_class(pawn, poseable, false) end)
    if not ok or mesh == nil then return fail("Couldn't add the hands mesh: " .. tostring(mesh)) end
    M.mesh = mesh
    owner_pawn = pawn:get_address()

    local set = pcall(function() mesh:SetSkinnedAssetAndUpdate(asset, true) end)
        or pcall(function() mesh:SetSkeletalMesh(asset, true) end)
    if not set then return fail("Couldn't give the hands mesh the arms asset.") end
    pcall(function()
        for i = 0, arms:GetNumMaterials() - 1 do mesh:SetMaterial(i, arms:GetMaterial(i)) end
    end)
    pcall(function() mesh:SetCollisionEnabled(0) end)
    pcall(function() mesh:SetCastShadow(false) end)
    pcall(function() mesh:SetOwnerNoSee(false) end)
    -- The engine culls the mesh by a box around its imported pose, which
    -- the posed hands leave far behind: looking down at some angles, or
    -- crawling, the box went out of view and the arms vanished. A big box
    -- keeps them drawn wherever the hands are.
    pcall(function() mesh:SetBoundsScale(BOUNDS_SCALE) end)
    -- The game's own pose gives natural fingers (it holds the C.A.T.).
    learn_fingers(mesh)
    pcall(function() mesh:CopyPoseFromSkeletalComponent(arms) end)
    local addr = safe(function() return pawn:get_address() end)
    if settle.pawn ~= addr then settle.pawn, settle.rebuilds = addr, 0 end
    settle.timer, settle.last, settle.same = 0.0, nil, 0
    do
        local ok, h = pcall(arm_hold)
        settle.base = (ok and not game.raised) and h or nil
    end

    learn_forearms(mesh)
    learn_arms(mesh)

    -- Collapse the body; the palms are put back every frame.
    local scale = safe(function() return mesh:K2_GetComponentScale() end)
    local ok_scale = scale ~= nil and pcall(function()
        scale.X, scale.Y, scale.Z = COLLAPSE, COLLAPSE, COLLAPSE
        mesh:SetBoneScaleByName("Bone_Pelvis", scale, COMPONENT_SPACE)
    end)
    if not ok_scale then return fail("Couldn't collapse the body bones.") end

    for side, hand in pairs(HAND) do
        local ok_m, m = pcall(function() return api:add_component_by_class(pawn, scene, false) end)
        if not ok_m or m == nil then return fail("Couldn't add a hand marker.") end
        local state = UEVR_UObjectHook.get_or_add_motion_controller_state(m)
        if state == nil then return fail("UObjectHook wouldn't take the hand marker.") end
        state:set_hand(hand)
        state:set_rotation_offset(hands.rotator_to_offset_quat(0, 0, 0))
        state:set_location_offset(hands.location_to_offset(0, 0, 0))
        state:set_permanent(true)
        markers[side] = m
    end
    M.status = "Hands made from " .. (safe(function() return asset:get_fname():to_string() end) or "the arms mesh") .. "."
end

-- Put one bone at a world transform, full size. Parents first: setting a
-- parent afterwards would drag its children along.
local function place_bone(mesh, bone, loc, rot, rot_s, loc_s, scale)
    rot_s.Pitch, rot_s.Yaw, rot_s.Roll = rot.Pitch, rot.Yaw, rot.Roll
    mesh:SetBoneRotationByName(bone, rot_s, WORLD_SPACE)
    loc_s.X, loc_s.Y, loc_s.Z = loc.X, loc.Y, loc.Z
    mesh:SetBoneLocationByName(bone, loc_s, WORLD_SPACE)
    mesh:SetBoneScaleByName(bone, scale, COMPONENT_SPACE)
end

-- Arms from the body's shoulders (settings.arm_ik): a two-bone arm, the
-- shoulder on the game's visible body mesh and the hand on the controller.
-- Bone lengths and directions come from the game's own arm pose; the
-- elbow bends down and a little outward; the forearm keeps the hand's
-- twist and is swung to run from the elbow to the wrist. Out of reach,
-- the arm goes straight and the hand stays on the controller.
local ARM_BONES = { "Collarbone", "Upperarm_01", "Upperarm_02", "Forearm_01", "Forearm_02", "Forearm_03", "Palm" }

local function vsub(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end
local function vadd(a, b) return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z } end
local function vscale(a, k) return { x = a.x * k, y = a.y * k, z = a.z * k } end
local function vdot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function vcross(a, b) return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x } end
local function vlen(a) return math.sqrt(vdot(a, a)) end
local function vnorm(a)
    local l = vlen(a)
    if l < 1e-6 then return { x = 0, y = 0, z = 0 } end
    return vscale(a, 1 / l)
end

-- Shortest rotation taking unit vector u onto unit vector v.
function M.arc(u, v)
    local d = vdot(u, v)
    if d < -0.999999 then
        local axis = vcross({ x = 1, y = 0, z = 0 }, u)
        if vlen(axis) < 1e-6 then axis = vcross({ x = 0, y = 1, z = 0 }, u) end
        axis = vnorm(axis)
        return { w = 0, x = axis.x, y = axis.y, z = axis.z }
    end
    local c = vcross(u, v)
    local q = { w = 1 + d, x = c.x, y = c.y, z = c.z }
    local l = math.sqrt(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z)
    return { w = q.w / l, x = q.x / l, y = q.y / l, z = q.z / l }
end

-- Elbow position for shoulder s, wrist w, upper arm l1, forearm l2, and a
-- pole direction the elbow should point toward.
function M.solve_elbow(s, w, l1, l2, pole)
    local d = vsub(w, s)
    local dist = vlen(d)
    local dir = dist > 1e-6 and vscale(d, 1 / dist) or { x = 0, y = 0, z = -1 }
    dist = math.max(math.abs(l1 - l2) + 1e-3, math.min(dist, l1 + l2 - 1e-3))
    local a = (l1 * l1 - l2 * l2 + dist * dist) / (2 * dist)
    local h = math.sqrt(math.max(0, l1 * l1 - a * a))
    local n = vnorm(vsub(pole, vscale(dir, vdot(pole, dir))))
    return vadd(s, vadd(vscale(dir, a), vscale(n, h)))
end

learn_arms = function(mesh)
    arm_ref = {}
    for side in pairs(FOREARM) do
        local s = side == "left" and "L" or "R"
        local r = {}
        for _, b in ipairs(ARM_BONES) do
            local ok, xf = pcall(read_transform, mesh, "Bone_Arm_" .. s .. "_" .. b)
            if not ok then r = nil; break end
            r[b] = xf
        end
        if r ~= nil then
            r.l1 = vlen(vsub(r.Forearm_01.t, r.Upperarm_01.t))
            r.l2 = vlen(vsub(r.Palm.t, r.Forearm_01.t))
            if r.l1 > 1 and r.l2 > 1 then arm_ref[side] = r end
        end
    end
end

local function to_rot(q)
    local p, y, r = M.quat_to_rot(q)
    return { Pitch = p, Yaw = y, Roll = r }
end

local MAX_STRETCH = 1.5   -- the arm may lengthen this much to reach the hand
local RTS_WORLD = 0

-- A body bone's live world transform.
body_bone = function(name)
    local body = M.body
    local t = body:GetSocketTransform(name, RTS_WORLD)
    return { q = { x = t.Rotation.X, y = t.Rotation.Y, z = t.Rotation.Z, w = t.Rotation.W },
             t = { x = t.Translation.X, y = t.Translation.Y, z = t.Translation.Z } }
end

-- Twist of rotation q about unit axis a, in radians (-pi..pi).
local function twist_angle(q, a)
    local ang = 2 * math.atan(q.x * a.x + q.y * a.y + q.z * a.z, q.w)
    if ang > math.pi then ang = ang - 2 * math.pi elseif ang < -math.pi then ang = ang + 2 * math.pi end
    return ang
end

-- Place the whole arm for one side; false if it couldn't (then the
-- floating forearm is used).
--
--   * Shoulder: the body's live Collarbone and Upperarm_01, so the arm
--     mesh's shoulder sits exactly on the body's (the two meshes share the
--     skeleton and were modelled to join there; shrinking the collarbone
--     left the opening showing).
--   * Upper arm: the body's own live upper-arm rotation, swung onto the
--     solved shoulder->elbow line, so its twist always agrees with the
--     shoulder (the first try took an arbitrary twist and the shoulder
--     turned inside out).
--   * Forearm: hinged on the upper arm as in the game pose, swung to run
--     elbow->wrist, with the hand's twist spread over Forearm_02/03 (a
--     straight copy of the hand's twist wrung the sleeve at the elbow).
--   * Reach: the arm lengthens up to MAX_STRETCH so the wrist doesn't
--     stretch on its own when your real arm reaches further.
local function pose_arm(side, mesh, palm_loc, palm_q, rot_s, loc_s, one, tiny)
    local r = arm_ref[side]
    if r == nil or M.body == nil then return false end
    local s = side == "left" and "L" or "R"
    local function name(b) return "Bone_Arm_" .. s .. "_" .. b end
    local col = body_bone(name("Collarbone"))
    local bu = body_bone(name("Upperarm_01"))
    local bf = body_bone(name("Forearm_01"))
    local sh = bu.t
    local w = { x = palm_loc.X, y = palm_loc.Y, z = palm_loc.Z }
    local pawn = api:get_local_pawn(0)

    local reach = vlen(vsub(w, sh))
    local k = math.min(MAX_STRETCH, math.max(1.0, reach / (r.l1 + r.l2) * 1.001))
    local l1, l2 = r.l1 * k, r.l2 * k

    -- Elbow: down, a little out to the side and back.
    local right = safe(function() local v = pawn:GetActorRightVector(); return { x = v.X, y = v.Y, z = v.Z } end)
        or { x = 0, y = 1, z = 0 }
    local fwd = safe(function() local v = pawn:GetActorForwardVector(); return { x = v.X, y = v.Y, z = v.Z } end)
        or { x = 1, y = 0, z = 0 }
    local out = side == "left" and vscale(right, -1) or right
    local pole = vadd(vadd({ x = 0, y = 0, z = -1 }, vscale(out, 0.5)), vscale(fwd, -0.3))
    local e = M.solve_elbow(sh, w, l1, l2, pole)

    local function in_frame(base, b)
        local ib = conj(base.q)
        return qmul(ib, b.q), qrot(ib, vsub(b.t, base.t))
    end

    -- Shoulder and upper arm, from the body.
    local qu = qmul(M.arc(vnorm(vsub(bf.t, bu.t)), vnorm(vsub(e, sh))), bu.q)
    place_bone(mesh, name("Collarbone"), { X = col.t.x, Y = col.t.y, Z = col.t.z }, to_rot(col.q), rot_s, loc_s, one)
    place_bone(mesh, name("Upperarm_01"), { X = sh.x, Y = sh.y, Z = sh.z }, to_rot(qu), rot_s, loc_s, one)
    local q2, t2 = in_frame(r.Upperarm_01, r.Upperarm_02)
    local p2 = vadd(sh, qrot(qu, vscale(t2, k)))
    place_bone(mesh, name("Upperarm_02"), { X = p2.x, Y = p2.y, Z = p2.z }, to_rot(qmul(qu, q2)), rot_s, loc_s, one)

    -- Forearm hinged on the upper arm, pointed at the wrist.
    local qf1, _ = in_frame(r.Upperarm_01, r.Forearm_01)
    local qf_base = qmul(qu, qf1)
    local _, tpf = in_frame(r.Forearm_01, r.Palm)
    local axis = vnorm(vsub(w, e))
    local qf = qmul(M.arc(vnorm(qrot(qf_base, vnorm(tpf))), axis), qf_base)
    place_bone(mesh, name("Forearm_01"), { X = e.x, Y = e.y, Z = e.z }, to_rot(qf), rot_s, loc_s, one)

    -- The hand's twist about the forearm, spread along it.
    local q_hand = qmul(palm_q, rel[name("Forearm_01")].q)
    local tw = twist_angle(qmul(q_hand, conj(qf)), axis)
    local share = { Forearm_02 = 1 / 3, Forearm_03 = 2 / 3 }
    for _, b in ipairs({ "Forearm_02", "Forearm_03" }) do
        local qb, tb = in_frame(r.Forearm_01, r[b])
        local pb = vadd(e, qrot(qf, vscale(tb, k)))
        local h = tw * share[b] / 2
        local twist = { w = math.cos(h), x = axis.x * math.sin(h), y = axis.y * math.sin(h), z = axis.z * math.sin(h) }
        place_bone(mesh, name(b), { X = pb.x, Y = pb.y, Z = pb.z }, to_rot(qmul(twist, qmul(qf, qb))), rot_s, loc_s, one)
    end
    return true
end

local function pose_palm(side)
    local m, mesh = markers[side], M.mesh
    local ctrl_loc = m:K2_GetComponentLocation()
    local ctrl_rot = m:K2_GetComponentRotation()
    local one = mesh:K2_GetComponentScale()
    one.X, one.Y, one.Z = 1, 1, 1
    local tiny = mesh:K2_GetComponentScale()
    tiny.X, tiny.Y, tiny.Z = COLLAPSE, COLLAPSE, COLLAPSE
    local loc, rot = M.palm_transform(ctrl_loc, ctrl_rot, M.hand_offset(side))
    local pq = M.rot_to_quat(rot.Pitch, rot.Yaw, rot.Roll)
    local armed = false
    if settings.get("arm_ik") and settings.get("show_body") then
        local ok_a, res = pcall(pose_arm, side, mesh, loc, pq, ctrl_rot, ctrl_loc, one, tiny)
        armed = ok_a and res == true
        M.arm_error = (not ok_a) and tostring(res) or nil
    end
    local elbow = rel[FOREARM[side][1]]
    if armed then
        elbow = nil -- the arm is placed; skip the floating forearm
    end
    if elbow ~= nil then
        local eloc, erot = M.follow(loc, pq, elbow)
        for _, b in ipairs(UPPER_ARM[side]) do
            place_bone(mesh, b, eloc, erot, ctrl_rot, ctrl_loc, tiny)
        end
    end
    if not armed then
        for _, b in ipairs(FOREARM[side]) do
            if rel[b] ~= nil then
                local floc, frot = M.follow(loc, pq, rel[b])
                place_bone(mesh, b, floc, frot, ctrl_rot, ctrl_loc, one)
            end
        end
    end
    place_bone(mesh, PALM[side], loc, rot, ctrl_rot, ctrl_loc, one)
    return loc, pq, ctrl_rot, ctrl_loc, one
end

-- Curl targets from the controller: index on the trigger, the other three
-- on the grip, the thumb when it rests on the buttons or thumbrest. The
-- grips and triggers come from what UEVR sends (LB/RB, analog triggers),
-- the thumb from UEVR's direct reads.
local STICK_THUMB = 0.12 * 32767   -- stick pushed this far: the thumb is on it

local function curl_targets(side)
    local bits = input.xi_in or 0
    -- (Not "a and b or c": with the left grip released that fell through to
    -- the right grip, so the right grip curled both hands.)
    local grip
    if side == "left" then
        grip = bits & XINPUT_GAMEPAD_LEFT_SHOULDER ~= 0
    else
        grip = bits & XINPUT_GAMEPAD_RIGHT_SHOULDER ~= 0
    end
    local trig = (side == "left" and input.left_trigger or input.right_trigger) or 0
    -- Thumb down: on the stick or the thumbrest (one action, see
    -- devices/init.lua), or touching/pressing a face button.
    local h = side == "left" and "l" or "r"
    local thumb = false
    for _, n in ipairs({ "thumbrest_" .. h, "a_touch_" .. h, "b_touch_" .. h, "a_" .. h, "b_" .. h }) do
        local ok, v = pcall(input.is_held, n)
        if ok and v then thumb = true end
    end
    -- A thumb pushing its stick is on it. (UEVR has no stick-touch action;
    -- carrying stick touch on the thumbrest action turned on UEVR's D-pad
    -- shifting, which stopped the left stick moving you.)
    local st = input.stick or {}
    local x = side == "left" and (st.lx or 0) or (st.rx or 0)
    local y = side == "left" and (st.ly or 0) or (st.ry or 0)
    if x * x + y * y > STICK_THUMB * STICK_THUMB then thumb = true end
    M.thumb_down = M.thumb_down or {}
    M.thumb_down[side] = thumb
    local g = grip and 1 or 0
    return { Thumb = thumb and 1 or 0, Finger_A = trig / 255, Finger_B = g, Finger_C = g, Finger_D = g }
end

M.curl_targets = curl_targets -- for tests

local function axis_quat(axis, deg)
    local h = math.rad(deg) / 2
    local sn = math.sin(h)
    return { w = math.cos(h), x = axis.x * sn, y = axis.y * sn, z = axis.z * sn }
end

local AXES = { x = { x = 1, y = 0, z = 0 }, y = { x = 0, y = 1, z = 0 }, z = { x = 0, y = 0, z = 1 } }

-- A finger bone's pose relative to its parent: the game's live animation
-- (only used for the right hand's grip on the C.A.T.), else the
-- reference pose.
local function game_pose(bone)
    local arms = M.arms
    local ok, t = pcall(function() return arms:GetSocketTransform(bone, RTS_PARENT_BONE) end)
    if ok and t ~= nil then
        local ok2, r = pcall(function()
            return { q = { x = t.Rotation.X, y = t.Rotation.Y, z = t.Rotation.Z, w = t.Rotation.W },
                     t = { x = t.Translation.X, y = t.Translation.Y, z = t.Translation.Z } }
        end)
        if ok2 then return r end
    end
    return rest[bone]
end

local function pose_fingers(side, palm_loc, palm_q, rot_s, loc_s, one, delta)
    local mesh = M.mesh
    local targets = curl_targets(side)
    local preview = settings.get("finger_curl_preview")
    -- Holding the C.A.T.: the game's own grip on its handle, no extra curl
    -- (the game only animates a right-hand grip; a left hand holding it
    -- closes its fingers instead).
    local holding = side == handed.main() and M.holding_cat
    -- Left-handed, the left hand takes the right hand's grip mirrored
    -- across the body (same mirror as its hold on the C.A.T.).
    local mirrored = holding and side == "left" and M.mirror_n ~= nil
    local game_grip = holding and (side == "right" or mirrored)
    local axis = AXES[settings.get("finger_axis")] or AXES.z
    local sign = settings.get("finger_flip_" .. (mirrored and "right" or side)) and -1 or 1
    local mc, imc
    if mirrored then
        mc = mirror_q(M.mirror_c, M.mirror_n)
        imc = conj(mc)
    end
    local k = math.min(1.0, delta * CURL_SPEED)
    for _, chain in ipairs(CHAINS) do
        -- The thumb never takes the game's grip (it sank into the C.A.T.).
        -- Holding the C.A.T. it takes the mesh's modelled grip thumb, plus
        -- the panel's wrap amount; otherwise it rests and follows input.
        local from_game = game_grip and chain ~= "Thumb"
        local wrap_thumb = game_grip and chain == "Thumb"
        local target = from_game and 0 or targets[chain]
        if wrap_thumb then target = settings.get("thumb_wrap") end
        if holding and not game_grip and chain ~= "Thumb" and chain ~= "Finger_A" then target = 1 end -- no mirror frame yet
        if preview > 0 then target = preview end
        local c = (curl[side][chain] or 0)
        c = c + (target - c) * k
        curl[side][chain] = c
        local maxes = chain == "Thumb" and JOINT_MAX.thumb or JOINT_MAX.finger
        local ploc, pq = palm_loc, palm_q
        local twins = chain_bones("right", chain)
        for i, b in ipairs(chain_bones(side, chain)) do
            local src = mirrored and twins[i] or b
            local lp = (from_game and game_pose(src)) or (wrap_thumb and modelled[src]) or rest[src]
            if lp == nil then break end
            local bend = axis_quat(axis, sign * maxes[i] * c)
            -- Holding the C.A.T. the thumb's base can also swing out and
            -- around the grip, about the two axes that aren't the bend.
            if wrap_thumb and i == 1 then
                local others = {}
                for _, k in ipairs({ "x", "y", "z" }) do
                    if AXES[k] ~= axis then others[#others + 1] = AXES[k] end
                end
                bend = qmul(bend, qmul(axis_quat(others[1], 60 * settings.get("thumb_swing_1")),
                                        axis_quat(others[2], 60 * settings.get("thumb_swing_2"))))
            end
            local lq, lt = qmul(lp.q, bend), lp.t
            if mirrored then
                -- Right local pose -> left: m(c) m(q) m(c)^-1, m(c) M t.
                lq = qmul(mc, qmul(mirror_q(lq, M.mirror_n), imc))
                lt = qrot(mc, mirror_v(lt, M.mirror_n))
            end
            local q = qmul(pq, lq)
            local d = qrot(pq, lt)
            local loc = { X = ploc.X + d.x, Y = ploc.Y + d.y, Z = ploc.Z + d.z }
            local p, y, r = M.quat_to_rot(q)
            place_bone(mesh, b, loc, { Pitch = p, Yaw = y, Roll = r }, rot_s, loc_s, one)
            ploc, pq = loc, q
        end
    end
end

-- The C.A.T. rides in the right glove at the same socket the game uses on
-- its arms mesh, so it sits in the hand as designed. Only while it's out;
-- put away, it goes back to the game's arms so the game can lower it.
local function update_cat()
    game.cat_managed = M.mesh ~= nil
    local raised = game.raised and settings.get("motion_hands")
    local cls = api:find_uobject("Class /Script/Routine.RoutineGameCAT")
    local cat = cls and UEVR_UObjectHook.get_first_object_by_class(cls, false)
    local root = cat and safe(function() return cat.RootComponent end)
    if root == nil then
        M.holding_cat = false
        game.cat_on_glove = false
        return
    end
    local addr = safe(function() return root:get_address() end) or root
    -- The game can take the C.A.T. back: re-attach it, or swap in a new one
    -- (seen waking up after a cutscene, in the base by the canal: it sat in
    -- your chest and turned invisible until a reload). Believing it was
    -- still on the hip, the mod never placed it again.
    if M.cat_place ~= "home" then
        local ours = M.cat_place == "glove" and M.mesh or M.body
        local parent = safe(function() return root.AttachParent:get_address() end)
        local want_parent = ours and safe(function() return ours:get_address() end)
        local swapped = cat_home == nil or cat_home.addr ~= addr
        if swapped or (parent ~= nil and want_parent ~= nil and parent ~= want_parent) then
            M.cat_place, M.cat_sig = "home", nil
            if swapped then cat_home = nil end
        end
    end
    if cat_home == nil or cat_home.addr ~= addr then
        local parent = safe(function() return root.AttachParent end)
        local socket = safe(function() return root.AttachSocketName end)
        local rl = safe(function() local v = root.RelativeLocation; return { v.X, v.Y, v.Z } end) or { 0, 0, 0 }
        local rr = safe(function() local v = root.RelativeRotation; return { v.Pitch, v.Yaw, v.Roll } end) or { 0, 0, 0 }
        local rs = safe(function() local v = root.RelativeScale3D; return { v.X, v.Y, v.Z } end)
        -- Zero is a state the game leaves it in, not its size (see below).
        if rs ~= nil and math.abs(rs[1]) < MIN_SCALE then rs = nil end
        if parent == nil then return end
        local sname = safe(function() return type(socket) == "string" and socket or socket:to_string() end) or "?"
        -- After a script reload the C.A.T. can still be on our glove or the
        -- hip: learning that as home carried the holster offset into the hand.
        local pname = safe(function() return parent:get_fname():to_string() end) or ""
        -- So can finding it anywhere but a hand: the hold is learned from
        -- the game's hand socket, and a cutscene may leave it somewhere else.
        if pname:find("Poseable", 1, true) or sname == "Bone_Pelvis" or not sname:find("Hand", 1, true) then
            -- Fall back to the game's own spot: the arms mesh's hand socket,
            -- with the last hold seen there.
            local pawn = api:get_local_pawn(0)
            local arms = pawn and find_arms(pawn)
            if arms == nil then return end
            local h = last_hold or { rl = { 0, 0, 0 }, rr = { 0, 0, 0 } }
            parent, socket, sname, rl, rr, rs = arms, "Socket_Hand_R", "Socket_Hand_R", h.rl, h.rr, h.rs
        else
            last_hold = { rl = rl, rr = rr, rs = rs }
        end
        cat_home = { root = root, addr = addr, parent = parent, socket = socket, socket_name = sname, rel_loc = rl, rel_rot = rr, rel_scale = rs }
        M.cat_socket = sname
    end
    -- The glove socket: the game's own (right palm), or the left palm's
    -- matching one for left-handers.
    local socket = cat_home.socket
    if handed.is_left() then
        socket = PALM.left
    end

    local want
    if raised then
        want = "glove"
    elseif settings.get("cat_holster") and M.body ~= nil then
        want = "holster"
    else
        want = "home"
    end
    -- Re-place when handedness or the holster offset changes.
    local o = settings.get("cat_holster_" .. handed.main())
    local sig = want .. tostring(handed.is_left()) .. table.concat(o.loc, ",") .. table.concat(o.rot, ",")

    -- game.lua unhooks the C.A.T. from the controller while cat_on_glove is
    -- set, and puts back its relative transform; move on the next frame.
    game.cat_on_glove = want == "glove"
    if sig ~= M.cat_sig and not (want == "glove" and game.cat_hooked) then
        if move_cat(want, socket) then M.cat_sig = sig end
    end
    M.holding_cat = M.cat_place == "glove"
    -- The game can leave the C.A.T. at zero size: waking up in the Ward it
    -- went to scale 0 on the first draw and stayed there (invisible, still
    -- fired, its buttons collapsed to a point) until a reload. Every frame,
    -- since the game may set it again.
    if M.cat_place ~= "home" then
        local world = safe(function() return root:K2_GetComponentScale().X end)
        if type(world) == "number" and math.abs(world) < MIN_SCALE then
            local rs = cat_home.rel_scale or { 1, 1, 1 }
            pcall(function()
                local sc = root.RelativeScale3D
                sc.X, sc.Y, sc.Z = rs[1], rs[2], rs[3]
                root:SetRelativeScale3D(sc)
            end)
        end
    end
    -- The game hides the put-away C.A.T. (it was gone from the hip, and
    -- while crawling); show it again now and then while it's on the hip or
    -- in the glove (a cutscene can leave it hidden).
    if M.cat_place ~= "home" then
        show_wait = show_wait - 1
        if show_wait <= 0 then
            show_wait = 15
            if M.cat_place == "holster" then M.refresh_hip() end
            pcall(function() cat:SetActorHiddenInGame(false) end)
            local skel = safe(function() return cat.SkeletalMeshComponent end)
            if skel ~= nil then
                pcall(function() skel:SetHiddenInGame(false, false) end)
                pcall(function() skel:SetVisibility(true, false) end)
                pcall(function() skel:SetOwnerNoSee(false) end)
            end
        end
    else
        show_wait = 0
    end
    M.cat_scale = safe(function()
        local v = root:K2_GetComponentScale()
        local out = string.format("%.2f mirror %s", v.X, M.mirror_n and "yes" or "no")
        -- What the C.A.T.'s hold was learned as, and its live relative
        -- transform: the wake-up in the Ward looked off until a reload.
        local rl, rr, rs = cat_home.rel_loc, cat_home.rel_rot, cat_home.rel_scale
        out = out .. string.format(" held %.1f,%.1f,%.1f rot %.0f,%.0f,%.0f size %s on %s", rl[1], rl[2], rl[3], rr[1], rr[2], rr[3],
            rs and string.format("%.2f", rs[1]) or "-", tostring(cat_home.socket_name))
        out = out .. " rebuilds " .. settle.rebuilds
        local lv = root.RelativeLocation
        local ls = root.RelativeScale3D
        out = out .. string.format(" live %.1f,%.1f,%.1f size %.2f", lv.X, lv.Y, lv.Z, ls.X)
        if M.mesh ~= nil then
            out = out .. string.format(" palmL %.2f palmR %.2f sock %.2f", world_xf(M.mesh, PALM.left).s,
                world_xf(M.mesh, PALM.right).s, world_xf(M.mesh, cat_home.socket_name or "Socket_Hand_R").s)
        end
        return out
    end) or "?"
    M.cat_where = safe(function()
        local p = root.AttachParent
        local sock = root.AttachSocketName
        sock = type(sock) == "string" and sock or (sock and sock:to_string()) or ""
        return (p and p:get_fname():to_string() or "nil") .. ":" .. sock
    end) or "?"
end

-- The game hides the pawn's arm meshes in some states (crawling), which
-- can catch the gloves too: while they should show, check every so often
-- that they still do.
local recheck = 0
local function set_shown(want)
    if M.mesh == nil then return end
    local mesh = M.mesh
    if want == shown then
        recheck = recheck - 1
        if not want or recheck > 0 then return end
        recheck = 15
        local hidden = safe(function() return not mesh:IsVisible() or mesh.bHiddenInGame == true end)
        M.hidden_by_game = hidden == true
        if not hidden then return end
        pcall(function() mesh:SetHiddenInGame(false, false) end)
    end
    shown = want
    pcall(function() mesh:SetVisibility(want, false) end)
end

-- A controller's world location and rotation, or nil (grab.lua).
function M.controller_pose(side)
    local m = markers[side]
    if m == nil then return nil end
    local loc = safe(function() return m:K2_GetComponentLocation() end)
    local rot = safe(function() return m:K2_GetComponentRotation() end)
    if loc == nil or rot == nil then return nil end
    return loc, rot
end

-- World position of a hand's index fingertip, or nil (touch.lua).
function M.fingertip(side)
    if M.mesh == nil or not shown then return nil end
    local mesh = M.mesh
    return safe(function() return mesh:GetSocketLocation(M.FINGERTIP[side]) end)
end

function M.tick(delta)
    retry_wait = retry_wait - delta
    local want = settings.get("motion_hands") and game.mode == "game"
    local pawn = api:get_local_pawn(0)

    if pawn == nil or (M.mesh ~= nil and pawn:get_address() ~= owner_pawn) then destroy() end
    if not settings.get("motion_hands") then
        if M.mesh ~= nil then destroy() end
        M.status = "Off."
        return
    end
    if pawn == nil then return end

    if M.mesh == nil then
        if not want or retry_wait > 0 then return end
        create(pawn)
        if M.mesh == nil then return end
    end

    set_shown(want)
    if not want then
        release_cat()
        return
    end
    pcall(update_cat)
    pcall(settle_check, delta)
    for side in pairs(HAND) do
        local ok, loc, pq, rot_s, loc_s, one = pcall(pose_palm, side)
        if not ok then
            M.status = "Posing the " .. side .. " hand failed: " .. tostring(loc)
        else
            local ok_f, err = pcall(pose_fingers, side, loc, pq, rot_s, loc_s, one, delta)
            if not ok_f then M.status = "Posing the " .. side .. " fingers failed: " .. tostring(err) end
        end
    end
end

function M.reset()
    destroy()
    retry_wait = 0.0
    M.status = "Off."
end

return M
