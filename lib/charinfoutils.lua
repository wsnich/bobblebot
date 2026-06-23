-- Helpers for MQCharInfo peer data (CharinfoPeer usertype from plugin.charinfo).
-- State[] is a 1-based string array (e.g. {'ATTACK', 'STAND', 'GROUP'}).

local mq = require('mq')
local utils = require('lib.utils')

local charinfoutils = {}

local UNAVAILABLE_STATE_FLAGS = { 'DEAD', 'FEIGN', 'HOVER' }

--- True when peer.State contains flag (e.g. 'ATTACK').
function charinfoutils.peerHasState(peer, flag)
    if not peer or not peer.State or not flag then return false end
    for _, v in ipairs(peer.State) do
        if v == flag then return true end
    end
    return false
end

function charinfoutils.peerHasAnyState(peer, flags)
    if not peer or not flags then return false end
    for _, flag in ipairs(flags) do
        if charinfoutils.peerHasState(peer, flag) then return true end
    end
    return false
end

local function leaderContextFromCharinfo(name, peer)
    local zone = peer.Zone
    local x = zone and zone.X or nil
    local y = zone and zone.Y or nil
    local z = zone and zone.Z or nil
    local distance = zone and zone.Distance or nil
    local sameZone = distance ~= nil
    local targetId = peer.Target and peer.Target.ID or nil
    if targetId and targetId <= 0 then targetId = nil end
    local alive = not charinfoutils.peerHasAnyState(peer, UNAVAILABLE_STATE_FLAGS)
        and (peer.PctHPs == nil or peer.PctHPs > 0)
    return {
        source = 'charinfo',
        name = name,
        x = x,
        y = y,
        z = z,
        distance = distance,
        targetId = targetId,
        inAttack = charinfoutils.peerHasState(peer, 'ATTACK'),
        alive = alive,
        sameZone = sameZone,
        peer = peer,
    }
end

local PLAYERSTATE_AGGRESSIVE = 4
local PLAYERSTATE_FORCED_AGGRESSIVE = 8

local function spawnInAttack(spawn)
    if not spawn then return false end
    local psFn = spawn.PlayerState
    if psFn then
        local ps = psFn()
        if ps then return bit32.band(ps, bit32.bor(PLAYERSTATE_AGGRESSIVE, PLAYERSTATE_FORCED_AGGRESSIVE)) ~= 0 end
    end
    local aggFn = spawn.Aggressive
    if aggFn then return aggFn() == true end
    return false
end

local function leaderContextFromSpawn(name)
    local spawn = mq.TLO.Spawn('pc =' .. name)
    local spawnId = spawn and spawn.ID()
    if not spawnId or spawnId == 0 then return nil end
    local meX, meY, meZ = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
    local sx, sy, sz = spawn.X(), spawn.Y(), spawn.Z()
    local distSq = utils.getDistanceSquared3D(meX, meY, meZ, sx, sy, sz)
    local distance = distSq and math.sqrt(distSq) or nil
    local targetId = spawn.Target and spawn.Target.ID() or nil
    if targetId and targetId <= 0 then targetId = nil end
    local alive = not spawn.Dead() and not spawn.Hovering()
    return {
        source = 'spawn',
        name = name,
        x = sx,
        y = sy,
        z = sz,
        distance = distance,
        targetId = targetId,
        inAttack = spawnInAttack(spawn),
        alive = alive,
        sameZone = true,
        peer = nil,
    }
end

--- Normalized leader context from charinfo (bot peer) or Spawn TLO (non-bot PC).
---@param name string|nil
---@return table|nil
function charinfoutils.getLeaderContext(name)
    if not name or name == '' then return nil end
    local ok, charinfo = pcall(require, 'plugin.charinfo')
    if ok and charinfo then
        local peer = charinfo.GetInfo(name)
        if peer then return leaderContextFromCharinfo(name, peer) end
    end
    return leaderContextFromSpawn(name)
end

return charinfoutils
