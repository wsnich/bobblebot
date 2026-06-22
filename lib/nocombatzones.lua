-- Global no-combat zone list (cz_common.noCombatZones) and session-only enable/disable state.

local botconfig = require('lib.config')

local nocombatzones = {}

local DEFAULT_NO_COMBAT_ZONES = {
    'GuildHall', 'GuildLobby', 'PoKnowledge', 'Nexus', 'Bazaar', 'AbysmalSea', 'potranquility',
}

-- Session-only: lowercase zone name -> true when temporarily disabled in GUI.
local _disabled = {}

function nocombatzones.getDefaultZones()
    return DEFAULT_NO_COMBAT_ZONES
end

local function zoneKey(zone)
    return zone and string.lower(zone) or ''
end

function nocombatzones.zoneInList(zone, list)
    if not zone or not list then return false end
    local key = zoneKey(zone)
    for _, z in ipairs(list) do
        if zoneKey(z) == key then return true end
    end
    return false
end

local function ensureList()
    local common = botconfig.getCommon()
    if not common.noCombatZones then common.noCombatZones = {} end
    return common.noCombatZones
end

function nocombatzones.getConfiguredZones()
    return ensureList()
end

function nocombatzones.isZoneEnabled(zone)
    return not _disabled[zoneKey(zone)]
end

function nocombatzones.setZoneEnabled(zone, enabled)
    local key = zoneKey(zone)
    if key == '' then return end
    if enabled then
        _disabled[key] = nil
    else
        _disabled[key] = true
    end
end

function nocombatzones.isActiveNoCombatZone(zone)
    if not zone or zone == '' then return false end
    if not nocombatzones.zoneInList(zone, ensureList()) then return false end
    return nocombatzones.isZoneEnabled(zone)
end

function nocombatzones.addZone(zone)
    if not zone or zone == '' then return false end
    if nocombatzones.zoneInList(zone, ensureList()) then return false end
    local added = false
    botconfig.mutateCommon(function(common)
        if not common.noCombatZones then common.noCombatZones = {} end
        if nocombatzones.zoneInList(zone, common.noCombatZones) then return end
        common.noCombatZones = botconfig.unionStringList(common.noCombatZones, { zone })
        added = true
    end)
    return added
end

function nocombatzones.removeZone(zone)
    if not zone or zone == '' then return false end
    local key = zoneKey(zone)
    local removed = false
    botconfig.mutateCommon(function(common)
        local list = common.noCombatZones
        if not list then return end
        local newList = {}
        for _, z in ipairs(list) do
            if zoneKey(z) ~= key then
                newList[#newList + 1] = z
            else
                removed = true
            end
        end
        if removed then
            common.noCombatZones = newList
            _disabled[key] = nil
        end
    end)
    return removed
end

function nocombatzones.seedDefaultsIfEmpty()
    local common = botconfig.getCommon()
    if common.noCombatZones and #common.noCombatZones > 0 then return false end
    common.noCombatZones = {}
    for _, z in ipairs(DEFAULT_NO_COMBAT_ZONES) do
        table.insert(common.noCombatZones, z)
    end
    return true
end

return nocombatzones
