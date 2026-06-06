-- Generic helpers (table copy, list membership, distance).
-- Non-combat zones: hooks (AddSpawnCheck, doPull, doMelee, etc.) can skip combat logic when zone is in this list.

local mq = require('mq')
local botconfig = require('lib.config')
local state = require('lib.state')
local combat = require('lib.combat')

local utils = {}

local PROTECTED_NPC_PREFIXES = { 'soulbinder', 'translocator' }
local PROTECTED_NPC_NAMES = {
    ['agent of change'] = true,
}

local nocombatzones = require('lib.nocombatzones')

function utils.getNonCombatZones()
    return nocombatzones.getConfiguredZones()
end

---@param zone string|nil Zone short name (e.g. mq.TLO.Zone.ShortName()). If nil, returns false.
function utils.isNonCombatZone(zone)
    return nocombatzones.isActiveNoCombatZone(zone)
end

--- True when spawn CleanName is a protected NPC (exact name or soulbinder/translocator prefix, case-insensitive).
---@param name string|nil
function utils.isProtectedNpcName(name)
    if not name or name == '' then return false end
    local lower = string.lower(name)
    if PROTECTED_NPC_NAMES[lower] then return true end
    for _, prefix in ipairs(PROTECTED_NPC_PREFIXES) do
        if string.sub(lower, 1, #prefix) == prefix then return true end
    end
    return false
end

--- True when spawn is a protected NPC (never attack or debuff).
function utils.isProtectedSpawn(spawn)
    if not spawn then return false end
    return utils.isProtectedNpcName(spawn.CleanName())
end

--- True when in primary bind zone and within acleash of bind coordinates.
function utils.isNearPrimaryBindPoint()
    if not mq.TLO.Me.ZoneBound() then return false end
    local bindZoneId = mq.TLO.Me.ZoneBound.ID()
    if not bindZoneId or bindZoneId == 0 then return false end
    local bindZone = mq.TLO.Me.ZoneBound.ShortName()
    local currentZone = mq.TLO.Zone.ShortName()
    if not bindZone or bindZone == '' or not currentZone or currentZone == '' then return false end
    if string.lower(currentZone) ~= string.lower(bindZone) then return false end
    local bindX = mq.TLO.Me.ZoneBoundX()
    local bindY = mq.TLO.Me.ZoneBoundY()
    if bindX == nil or bindY == nil then return false end
    local acleashSq = botconfig.config.settings.acleashSq
    if not acleashSq then return false end
    local distSq = utils.getDistanceSquared2D(mq.TLO.Me.X(), mq.TLO.Me.Y(), bindX, bindY)
    return distSq ~= nil and distSq <= acleashSq
end

--- Disengage combat and clear engage state when near bind (stealth at bind point).
function utils.enforceBindStealth()
    local rc = state.getRunconfig()
    rc.engageTargetId = nil
    rc.attackCommandEngage = nil
    combat.ResetCombatState({ clearTarget = true, clearPet = true })
end

-- Create full copy of a table instead of a reference (recursive, including metatable).
function utils.DeepCopy(orig)
    local copy
    if type(orig) == "table" then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[utils.DeepCopy(orig_key)] = utils.DeepCopy(orig_value)
        end
        setmetatable(copy, utils.DeepCopy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

function utils.isInList(value, list)
    for _, v in ipairs(list) do
        if value == v then
            return true
        end
    end
    return false
end

--- Squared distance (no sqrt) for fast comparisons. Returns nil if any coord missing.
--- @return number|nil (x2-x1)^2 + (y2-y1)^2
function utils.getDistanceSquared2D(x1, y1, x2, y2)
    if x1 == nil or y1 == nil or x2 == nil or y2 == nil then return nil end
    return (x2 - x1) ^ 2 + (y2 - y1) ^ 2
end

--- Squared distance 3D (no sqrt) for fast comparisons. Returns nil if any coord missing.
--- @return number|nil (x2-x1)^2 + (y2-y1)^2 + (z2-z1)^2
function utils.getDistanceSquared3D(x1, y1, z1, x2, y2, z2)
    if x1 == nil or y1 == nil or z1 == nil or x2 == nil or y2 == nil or z2 == nil then return nil end
    return (x2 - x1) ^ 2 + (y2 - y1) ^ 2 + (z2 - z1) ^ 2
end

--- Actual distance (sqrt). Use only for display or when an API requires real distance.
--- For all normal comparisons (range checks, sorting) use getDistanceSquared2D/getDistanceSquared3D instead.
function utils.calcDist3D(x1, y1, z1, x2, y2, z2)
    if x1 and y1 and x2 and y2 and z1 and z2 then return math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2 + (z2 - z1) ^ 2) end
end

--- Actual distance (sqrt). Use only for display or when an API requires real distance.
--- For all normal comparisons (range checks, sorting) use getDistanceSquared2D instead.
function utils.calcDist2D(x1, y1, x2, y2)
    if x1 and y1 and x2 and y2 then return math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2) end
end

-- Split string on delimiter, trim whitespace from each segment, return array of strings.
function utils.splitString(str, delim)
    local result = {}
    for match in (str .. delim):gmatch("(.-)" .. delim) do
        table.insert(result, match:match("^%s*(.-)%s*$"))
    end
    return result
end

return utils
