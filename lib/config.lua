---@class ConfigSettings
---@field dodebuff boolean|nil
---@field doheal boolean|nil
---@field dobuff boolean|nil
---@field docure boolean|nil
---@field domelee boolean|nil
---@field doraid boolean|nil
---@field dodrag boolean|nil
---@field domount boolean|nil
---@field mountcast string|nil
---@field dosit boolean|nil
---@field doforage boolean|nil
---@field sitmana number|nil
---@field sitendur number|nil
---@field sitaggro number|nil
---@field TankName string|nil
---@field AssistName string|nil
---@field TargetFilter number|nil
---@field petassist boolean|nil
---@field acleash number|nil
---@field acleashSq number|nil precomputed acleash^2 for distance-squared comparisons
---@field followdistance number|nil
---@field followdistanceSq number|nil precomputed followdistance^2 for distance-squared comparisons
---@field zradius number|nil
---@field campRestDistance number|nil distance in units to consider "at camp" for leash and return
---@field campRestDistanceSq number|nil precomputed campRestDistance^2 for distance-squared comparisons
---@field maCampAnchor boolean|nil when true, MobList anchor follows nearby MA; inject ATTACK targets
---@field maAnchorLeash number|nil max MA distance for anchor/inject; defaults to acleash
---@field spelldb string|nil

---@class ConfigPullSpell
---@field gem number|string|nil 1-12, 'item', 'alt', 'disc', 'ability', 'script', 'melee', or 'ranged'
---@field spell string|nil spell name, item name (for ranged bow), or empty for melee
---@field range number|nil optional; derived from spell/ability when possible

---@class ConfigPull
---@field spell ConfigPullSpell|nil single pull spell block
---@field radius number|nil
---@field radiusSq number|nil precomputed radius^2 for distance-squared comparisons
---@field radiusPlus40Sq number|nil precomputed (radius+40)^2 for nav-abort distance-squared comparison
---@field zrange number|nil
---@field pullMinCon number|nil minimum con color index (1-7) for valid pull target
---@field pullMaxCon number|nil maximum con color index (1-7) for valid pull target
---@field maxLevelDiff number|nil max levels above player when using con (e.g. "levels into red")
---@field usePullLevels boolean|nil if true use pullMinLevel/pullMaxLevel instead of con
---@field pullMinLevel number|nil minimum mob level when usePullLevels true
---@field pullMaxLevel number|nil maximum mob level when usePullLevels true
---@field chainpullhp number|nil
---@field chainpullcnt number|nil
---@field mana number|nil
---@field manaclass string[]|nil array of uppercase class short names (CLR, DRU, SHM)
---@field leash number|nil
---@field leashSq number|nil precomputed leash^2 for distance-squared comparisons
---@field fteLockoutSec number|nil seconds to skip pull target after FTE lock or already-engaged (default 120)
---@field backupCandidates number|nil max pull targets queued per outing before returning to camp (default 3, clamped 1-5)
---@field addAbortRadius number|nil radius (units) for add-abort check while navigating; NPCs within this with LoS trigger abort (default 50)
---@field usepriority boolean|nil
---@field hunter boolean|nil
---@field roam boolean|nil

---@class ConfigMelee
---@field assistpct number|nil
---@field stickcmd string|nil
---@field stayBehind boolean|nil
---@field behindAggroPct number|nil
---@field evadePct number|nil
---@field offtank boolean|nil
---@field mtSticky boolean|nil
---@field minmana number|nil
---@field otoffset number|nil

---@class ConfigHeal
---@field spells table[]|nil
---@field rezoffset number|nil
---@field interruptlevel number|nil
---@field xttargets number|nil

---@class ConfigBuff
---@field spells table[]|nil

---@class ConfigDebuff
---@field spells table[]|nil

---@class ConfigCure
---@field spells table[]|nil

---@class ConfigBard
---@field mez_remez_sec number|nil seconds before notmatar debuff (e.g. mez) ends to re-apply

---@class Config
---@field settings ConfigSettings|nil
---@field pull ConfigPull|nil
---@field bard ConfigBard|nil
---@field melee ConfigMelee|nil
---@field heal ConfigHeal|nil
---@field buff ConfigBuff|nil
---@field debuff ConfigDebuff|nil
---@field cure ConfigCure|nil
---@field script table|nil

local mq = require('mq')
local state = require('lib.state')
local M = {}
---@type Config
M.config = {}

-- Allowed category names for debuff dontStack (MQ Target TLO members). Slowed excluded so stronger slow can overwrite weaker.
M.DEBUFF_DONTSTACK_ALLOWED = { Charmed = true, Crippled = true, Feared = true, Maloed = true, Mezzed = true, Rooted = true, Snared = true, Tashed = true }
-- stopWhen: omit from twist / skip cast when target already has category (e.g. Slowed for resist setup debuffs).
M.DEBUFF_STOPWHEN_ALLOWED = { Slowed = true, Snared = true, Rooted = true, Mezzed = true, Charmed = true, Crippled = true, Feared = true, Maloed = true, Tashed = true }
M._configLoaders = {}
M._common = nil
M._commonReadOnly = false
M._guiDirty = false

-- Consider (con) color names and name-to-index map for pull filtering and UI. Indices 1-7.
M.ConColors = { "Grey", "Green", "Light Blue", "Blue", "White", "Yellow", "Red" }
M.ConColorsNameToId = {}
for i, v in ipairs(M.ConColors) do M.ConColorsNameToId[v:upper()] = i end

local keyOrder = { 'settings', 'pull', 'melee', 'heal', 'buff', 'debuff', 'cure', 'script' }

local subOrder = {
    settings = { 'dodebuff', 'doheal', 'dobuff', 'docure', 'domelee', 'doraid', 'dodrag', 'domount', 'mountcast', 'dosit', 'doforage', 'sitmana', 'sitendur', 'sitaggro', 'TankName', 'AssistName', 'TargetFilter', 'petassist', 'acleash', 'followdistance', 'zradius', 'campRestDistance', 'maCampAnchor', 'maAnchorLeash', 'engageXTargetOnly' },
    pull = { 'spell', 'radius', 'zrange', 'pullMinCon', 'pullMaxCon', 'maxLevelDiff', 'usePullLevels', 'pullMinLevel', 'pullMaxLevel', 'chainpullhp', 'chainpullcnt', 'mana', 'manaclass', 'leash', 'fteLockoutSec', 'backupCandidates', 'addAbortRadius', 'usepriority', 'hunter', 'roam' },
    melee = { 'assistpct', 'stickcmd', 'stayBehind', 'behindAggroPct', 'evadePct', 'offtank', 'mtSticky', 'minmana', 'otoffset' },
    heal = { 'rezoffset', 'interruptlevel', 'xttargets', 'spells' },
    buff = { 'spells' },
    debuff = { 'spells' },
    cure = { 'spells' },
    script = {}
}

local spellSlotOrder = {
    heal = { 'gem', 'spell', 'alias', 'announce', 'minmana', 'minmanapct', 'maxmanapct', 'enabled', 'inCombat', 'tarcnt', 'bands', 'healResource', 'precondition' },
    buff = { 'gem', 'spell', 'alias', 'announce', 'minmana', 'enabled', 'inCombat', 'inIdle', 'combatOnly', 'tarcnt', 'bands', 'spellicon', 'precondition' },
    debuff = { 'gem', 'spell', 'alias', 'announce', 'minmana', 'enabled', 'onlyMT', 'bands', 'recast', 'delay', 'precondition', 'dontStack', 'stopWhen' },
    cure = { 'gem', 'spell', 'alias', 'announce', 'minmana', 'curetype', 'enabled', 'tarcnt', 'bands', 'precondition' },
    pull = { 'gem', 'spell', 'range' },
}

local function applySectionDefaults(section, defaults)
    local t = M.config[section]
    if not t then return end
    for k, v in pairs(defaults) do
        if t[k] == nil then t[k] = v end
    end
end

local function normalizeDebuffTargetPhaseToken(token)
    if token == 'tanktar' then return 'matar' end
    if token == 'notanktar' then return 'notmatar' end
    return token
end

-- Canonical default spell entry per section. getDefaultSpellEntry returns a copy so callers do not mutate.
local defaultSpellEntries = {
    heal = { gem = 0, spell = '', minmana = 0, minmanapct = 0, maxmanapct = 100, alias = false, announce = false, enabled = true, inCombat = false, bands = { { targetphase = { 'self', 'tank', 'groupmember' }, validtargets = { 'all' }, min = 0, max = 60 } }, healResource = 'hp', precondition = nil },
    buff = { gem = 0, spell = '', minmana = 0, alias = false, announce = false, enabled = true, inCombat = false, inIdle = true, combatOnly = false, bands = { { targetphase = { 'self', 'tank', 'pc', 'mypet', 'pet' }, validtargets = { 'all' } } }, spellicon = 0, precondition = nil },
    debuff = { gem = 0, spell = '', minmana = 0, alias = false, announce = false, enabled = true, bands = { { targetphase = { 'matar', 'notmatar', 'named' }, min = 20, max = 100 } }, recast = 0, delay = 0, precondition = nil, dontStack = nil, stopWhen = nil, onlyMT = false },
    cure = { gem = 0, spell = '', minmana = 0, alias = false, announce = false, curetype = { 'all' }, enabled = true, bands = { { targetphase = { 'self', 'tank', 'groupmember', 'pc' }, validtargets = { 'all' } } }, precondition = nil },
}

function M.getDefaultSpellEntry(section)
    local src = defaultSpellEntries[section]
    if not src then return nil end
    local t = {}
    for k, v in pairs(src) do
        if type(v) == "table" and v[1] then
            if type(v[1]) == "table" then
                -- array of tables (e.g. bands)
                local copy = {}
                for i, band in ipairs(v) do
                    copy[i] = {}
                    for bk, bv in pairs(band) do
                        if type(bv) == "table" and bv[1] ~= nil then
                            -- array of primitives (targetphase, validtargets) - copy by value so each spell entry has its own
                            local arr = {}
                            for j, x in ipairs(bv) do arr[j] = x end
                            copy[i][bk] = arr
                        else
                            copy[i][bk] = bv
                        end
                    end
                end
                t[k] = copy
            else
                -- array of strings or other primitives (e.g. curetype)
                local copy = {}
                for i, x in ipairs(v) do copy[i] = x end
                t[k] = copy
            end
        else
            t[k] = v
        end
    end
    return t
end

function M.getPath()
    return mq.configDir .. '\\cz_' .. mq.TLO.Me.CleanName() .. '.lua'
end

function M.getCommon()
    if M._common == nil then M.loadCommon() end
    return M._common
end

local COMMON_FILENAME = 'cz_common.lua'

local function commonFilePath()
    return mq.configDir .. '/' .. COMMON_FILENAME
end

local function commonFileExists()
    local f = io.open(commonFilePath(), 'r')
    if f then f:close(); return true end
    return false
end

--- Union of string arrays: disk order first, then memory entries not already present.
function M.unionStringList(diskList, memList)
    local out = {}
    local seen = {}
    if type(diskList) == 'table' then
        for _, name in ipairs(diskList) do
            if name and name ~= '' and not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            end
        end
    end
    if type(memList) == 'table' then
        for _, name in ipairs(memList) do
            if name and name ~= '' and not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            end
        end
    end
    return out
end

--- Copy a string array (ipairs order).
function M.copyStringList(list)
    local copy = {}
    if type(list) == 'table' then
        for i, v in ipairs(list) do copy[i] = v end
    end
    return copy
end

--- Union of bool maps (key -> true); keys from either map are kept.
function M.unionBoolMap(diskMap, memMap)
    local out = {}
    if type(diskMap) == 'table' then
        for k, v in pairs(diskMap) do
            if v then out[k] = true end
        end
    end
    if type(memMap) == 'table' then
        for k, v in pairs(memMap) do
            if v then out[k] = true end
        end
    end
    return next(out) and out or nil
end

local function ensureZoneBlockIn(common, zone)
    if not common.zones then common.zones = {} end
    if not common.zones[zone] then common.zones[zone] = {} end
    return common.zones[zone]
end

local function migrateOldCommonToZones(common)
    if not common.nukeFlavorsByZone and not common.excludelist then return false end
    if not common.zones then common.zones = {} end
    if common.nukeFlavorsByZone then
        for zone, val in pairs(common.nukeFlavorsByZone) do
            if not common.zones[zone] then common.zones[zone] = {} end
            common.zones[zone].nukeFlavors = val
        end
        common.nukeFlavorsByZone = nil
    end
    if common.nukeFlavorsAutoDisabledByZone then
        for zone, val in pairs(common.nukeFlavorsAutoDisabledByZone) do
            if not common.zones[zone] then common.zones[zone] = {} end
            common.zones[zone].nukeFlavorsAutoDisabled = val
        end
        common.nukeFlavorsAutoDisabledByZone = nil
    end
    for _, key in ipairs({ 'excludelist', 'prioritylist', 'charmlist' }) do
        local byZone = common[key]
        if byZone then
            for zone, val in pairs(byZone) do
                if not common.zones[zone] then common.zones[zone] = {} end
                common.zones[zone][key] = val
            end
            common[key] = nil
        end
    end
    return true
end

local function migrateCzimmuneIntoZones(common)
    local immunePath = mq.configDir .. '/' .. 'czimmune.lua'
    local immuneData, errr = loadfile(immunePath)
    if errr or not immuneData then return false end
    local oldImmune = immuneData()
    if not oldImmune or type(oldImmune) ~= 'table' then return false end
    if not common.zones then common.zones = {} end
    for spell, zoneData in pairs(oldImmune) do
        if type(zoneData) == 'table' then
            for zone, mobs in pairs(zoneData) do
                if type(mobs) == 'table' then
                    if not common.zones[zone] then common.zones[zone] = {} end
                    if not common.zones[zone].immune then common.zones[zone].immune = {} end
                    if not common.zones[zone].immune[spell] then common.zones[zone].immune[spell] = {} end
                    for mobName, _ in pairs(mobs) do
                        common.zones[zone].immune[spell][mobName] = true
                    end
                end
            end
        end
    end
    return true
end

--- Return the zone block for zone (read-only); nil if zone or zones missing.
function M.getZoneBlock(zone)
    local common = M.getCommon()
    if not common.zones then return nil end
    return common.zones[zone]
end

--- Return the zone block for zone, creating common.zones and zone entry if needed (for writing).
function M.ensureZoneBlock(zone)
    local common = M.getCommon()
    if not common.zones then common.zones = {} end
    if not common.zones[zone] then common.zones[zone] = {} end
    return common.zones[zone]
end

function M.loadCommon()
    local path = commonFilePath()
    local commonData, errr = loadfile(path)
    local newFile = false
    if not errr and commonData then
        M._common = commonData()
        if not M._common then M._common = {} end
        M._commonReadOnly = false
    elseif commonFileExists() then
        printf('\aybobblebot:\ax Failed to load \ar%s\ax: %s', path, errr or 'unknown error')
        M._common = {}
        M._commonReadOnly = true
    else
        M._common = {}
        M._commonReadOnly = false
        newFile = true
    end
    local migrated = migrateOldCommonToZones(M._common) or migrateCzimmuneIntoZones(M._common)
    local nocombatzones = require('lib.nocombatzones')
    if nocombatzones.seedDefaultsIfEmpty() then migrated = true end
    if not M._commonReadOnly and (migrated or newFile) then M.saveCommon() end
    return M._common
end

function M.saveCommon()
    if M._commonReadOnly or not M._common then return end
    local path = commonFilePath()
    local src = io.open(path, 'rb')
    if src then
        local content = src:read('*all')
        src:close()
        local dst = io.open(path .. '.bak', 'wb')
        if dst then
            dst:write(content)
            dst:close()
        end
    end
    mq.pickle(COMMON_FILENAME, M._common)
end

--- Reload cz_common from disk, apply mutator, then save. No-op when file failed to load (read-only).
function M.mutateCommon(mutator)
    if mutator == nil then return false end
    M.loadCommon()
    if M._commonReadOnly then
        printf('\aybobblebot:\ax Cannot save \ar%s\ax — fix load error and reload script', commonFilePath())
        return false
    end
    mutator(M._common)
    M.saveCommon()
    return true
end

--- Reload cz_common from disk and refresh current-zone exclude/priority/charm lists and nuke flavors.
function M.refreshZoneStateFromCommon()
    M.loadCommon()
    local mobfilter = require('lib.mobfilter')
    mobfilter.process('exclude', 'zone')
    mobfilter.process('priority', 'zone')
    mobfilter.process('charm', 'zone')
    local rolelists = require('lib.rolelists')
    rolelists.loadFromCommon()
    M.loadNukeFlavorsFromZone()
end

--- Load nuke flavor state for current zone from cz_common into runconfig. Call on zone change.
function M.loadNukeFlavorsFromZone()
    local zone = mq.TLO.Zone.ShortName()
    local zb = M.getZoneBlock(zone)
    local rc = state.getRunconfig()
    rc.nukeFlavorsAllowed = zb and zb.nukeFlavors or nil
    rc.nukeFlavorsAutoDisabled = zb and zb.nukeFlavorsAutoDisabled or nil
    if rc.nukeFlavorsAutoDisabled and next(rc.nukeFlavorsAutoDisabled) == nil then
        rc.nukeFlavorsAutoDisabled = nil
    end
end

--- Persist current runconfig nuke flavor state to cz_common for current zone. Call after toggle or auto-disable.
function M.saveNukeFlavorsToCommon()
    local zone = mq.TLO.Zone.ShortName()
    if not zone or zone == '' then return end
    local rc = state.getRunconfig()
    M.mutateCommon(function(common)
        local zb = ensureZoneBlockIn(common, zone)
        zb.nukeFlavors = rc.nukeFlavorsAllowed
        zb.nukeFlavorsAutoDisabled = M.unionBoolMap(zb.nukeFlavorsAutoDisabled, rc.nukeFlavorsAutoDisabled)
    end)
end

--- Zone junk list (cz_common zones[zone].junk): set of item names to destroy when foraged in this zone.
function M.getZoneJunk(zone)
    local zb = M.getZoneBlock(zone)
    return zb and zb.junk or nil
end

function M.addZoneJunk(zone, itemName)
    if not zone or zone == '' or not itemName or itemName == '' then return end
    M.mutateCommon(function(common)
        local zb = ensureZoneBlockIn(common, zone)
        zb.junk = M.unionBoolMap(zb.junk, { [itemName] = true })
    end)
end

function M.isZoneJunk(zone, itemName)
    local junk = M.getZoneJunk(zone)
    if not junk or not itemName or itemName == '' then return false end
    if junk[itemName] then return true end
    local lower = itemName:lower()
    for k in pairs(junk) do
        if k and k:lower() == lower then return true end
    end
    return false
end

--- Zone forage disable (cz_common zones[zone].forageDisabled): when true, do not auto-forage in this zone.
function M.isForageDisabledInZone(zone)
    local zb = M.getZoneBlock(zone)
    return zb and zb.forageDisabled == true
end

function M.setForageDisabledInZone(zone, disabled)
    if not zone or zone == '' then return end
    M.mutateCommon(function(common)
        local zb = ensureZoneBlockIn(common, zone)
        zb.forageDisabled = disabled and true or false
    end)
end

function M.getSubOrder()
    return subOrder
end

function M.getSpellSlotOrder()
    return spellSlotOrder
end

function M.getSpellEntry(section, index)
    if not M.config[section] or not M.config[section].spells then return nil end
    return M.config[section].spells[index]
end

function M.getSpellCount(section)
    if not M.config[section] or not M.config[section].spells then return 0 end
    return #M.config[section].spells
end

function M.RegisterConfigLoader(fn)
    table.insert(M._configLoaders, fn)
end

function M.RunConfigLoaders()
    for _, fn in ipairs(M._configLoaders) do
        fn()
    end
end

function M.MarkDirty()
    M._guiDirty = true
end

function M.IsDirty()
    return M._guiDirty
end

function M.ClearDirty()
    M._guiDirty = false
end

--- Call after GUI mutates config: refresh derived state and schedule persist at end of frame.
function M.ApplyAndPersist()
    M.RunConfigLoaders()
    M.MarkDirty()
end

--- Swap two spell entries in a section array and persist.
function M.swapSpellEntries(section, fromIndex, toIndex)
    local spells = M.config[section] and M.config[section].spells
    if not spells or fromIndex == toIndex then return end
    spells[fromIndex], spells[toIndex] = spells[toIndex], spells[fromIndex]
    M.ApplyAndPersist()
end

local function sanitizeConfigFile(filepath)
    local file, err = io.open(filepath, "r")
    if not file then
        print("Error opening file:", err)
        return nil
    end
    local content = file:read("*all")
    file:close()
    content = content:gsub("%['%w+'%]%s*=%s*table: 0x[%w]+%s*,?", function(entry)
        print("Sanitizing invalid entry:", entry)
        return entry:gsub("table: 0x[%w]+", "nil")
    end)
    local configData, loadErr = load(content)
    if not configData then
        print("Error loading sanitized config:", loadErr)
        return nil
    end
    print("Config repaired and reloaded successfully")
    return configData()
end

local function writeConfigToFile(config, filename)
    local file = io.open(filename, "w")
    if not file then
        return false, "Could not open file for writing."
    end

    local function isValidLuaIdentifier(key)
        return type(key) == "string" and key ~= "" and key:match("^[%a_][%w_]*$")
    end

    local function formatKey(key)
        if isValidLuaIdentifier(key) then
            return key
        end
        return "['" .. tostring(key):gsub("'", "\\'") .. "']"
    end

    local function writeBands(bands, indent)
        if type(bands) ~= "table" then return end
        file:write(indent .. formatKey('bands') .. " = {\n")
        file:flush()
        for _, band in ipairs(bands) do
            if type(band) == "table" then
                file:write(indent .. "  {\n")
                if type(band.targetphase) == "table" then
                    file:write(indent .. "    " .. formatKey('targetphase') .. " = { ")
                    local parts = {}
                    for _, c in ipairs(band.targetphase) do
                        local cn = normalizeDebuffTargetPhaseToken(c)
                        parts[#parts + 1] = "'" .. tostring(cn):gsub("'", "\\'") .. "'"
                    end
                    file:write(table.concat(parts, ", "))
                    file:write(" },\n")
                end
                if type(band.validtargets) == "table" then
                    file:write(indent .. "    " .. formatKey('validtargets') .. " = { ")
                    local parts = {}
                    for _, c in ipairs(band.validtargets) do
                        parts[#parts + 1] = "'" .. tostring(c):gsub("'", "\\'") .. "'"
                    end
                    file:write(table.concat(parts, ", "))
                    file:write(" },\n")
                elseif type(band.targetphase) == "table" and #band.targetphase > 0 then
                    local isDebuffOnly = true
                    for _, p in ipairs(band.targetphase) do
                        p = normalizeDebuffTargetPhaseToken(p)
                        if p ~= 'matar' and p ~= 'notmatar' and p ~= 'named' then
                            isDebuffOnly = false
                            break
                        end
                    end
                    if not isDebuffOnly then
                        file:write(indent .. "    " .. formatKey('validtargets') .. " = { 'all' },\n")
                    end
                end
                if band.min ~= nil then
                    file:write(indent .. "    " .. formatKey('min') .. " = " .. tonumber(band.min) .. ",\n")
                end
                if band.max ~= nil then
                    file:write(indent .. "    " .. formatKey('max') .. " = " .. tonumber(band.max) .. ",\n")
                end
                if band.aggroMin ~= nil and tonumber(band.aggroMin) ~= 0 then
                    file:write(indent .. "    " .. formatKey('aggroMin') .. " = " .. tonumber(band.aggroMin) .. ",\n")
                end
                if band.aggroMax ~= nil and tonumber(band.aggroMax) ~= 100 then
                    file:write(indent .. "    " .. formatKey('aggroMax') .. " = " .. tonumber(band.aggroMax) .. ",\n")
                end
                if band.mintar ~= nil and band.mintar > 0 then
                    file:write(indent .. "    " .. formatKey('mintar') .. " = " .. tonumber(band.mintar) .. ",\n")
                end
                if band.maxtar ~= nil and band.maxtar > 0 then
                    file:write(indent .. "    " .. formatKey('maxtar') .. " = " .. tonumber(band.maxtar) .. ",\n")
                end
                file:write(indent .. "  },\n")
            end
        end
        file:write(indent .. "},\n")
        file:flush()
    end

    local function writesubTable(t, order2, indent)
        indent = indent or ""
        if type(order2) == "table" then
            local value = ''
            local valueStr = nil
            for _, key in ipairs(order2) do
                value = t[key]
                if value == nil or (key == 'announce' and value == false) or (key == 'onlyMT' and value == false) then
                    -- omit nil keys and announce/onlyMT when false to keep config sparse
                elseif key == 'dontStack' and type(value) == "table" and #value > 0 then
                    local allowed = M.DEBUFF_DONTSTACK_ALLOWED
                    local parts = {}
                    for _, c in ipairs(value) do
                        local tag = tostring(c)
                        if allowed[tag] then parts[#parts + 1] = "'" .. tag:gsub("'", "\\'") .. "'" end
                    end
                    if #parts > 0 then
                        file:write(indent .. formatKey('dontStack') .. " = { ")
                        file:write(table.concat(parts, ", "))
                        file:write(" },\n")
                        file:flush()
                    end
                elseif key == 'stopWhen' and type(value) == "table" and #value > 0 then
                    local allowed = M.DEBUFF_STOPWHEN_ALLOWED
                    local parts = {}
                    for _, c in ipairs(value) do
                        local tag = tostring(c)
                        if allowed[tag] then parts[#parts + 1] = "'" .. tag:gsub("'", "\\'") .. "'" end
                    end
                    if #parts > 0 then
                        file:write(indent .. formatKey('stopWhen') .. " = { ")
                        file:write(table.concat(parts, ", "))
                        file:write(" },\n")
                        file:flush()
                    end
                elseif key == 'bands' and type(value) == "table" then
                    writeBands(value, indent)
                elseif key == 'precondition' then
                    if value ~= nil and not (type(value) == 'string' and value:match('^%s*$')) then
                        local preStr = type(value) == 'string' and value or tostring(value)
                        file:write(indent ..
                        formatKey('precondition') .. " = " .. '"' .. preStr:gsub('\\', '\\\\'):gsub('"', '\\"') .. '",\n')
                        file:flush()
                    end
                elseif key == 'curetype' and type(value) == "table" then
                    if #value > 0 then
                        local parts = {}
                        for _, s in ipairs(value) do
                            parts[#parts + 1] = "'" .. tostring(s):gsub("'", "\\'") .. "'"
                        end
                        file:write(indent .. formatKey('curetype') .. " = { ")
                        file:write(table.concat(parts, ", "))
                        file:write(" },\n")
                        file:flush()
                    end
                    -- omit when empty; readers treat as { 'all' }
                elseif type(value) == "table" then
                    print("detected a corrupted value for:", key, " = ", value)
                    print("setting ", key, " to nil, please check your config")
                    valueStr = nil
                    file:write(indent .. formatKey(key) .. " =  nil ,\n")
                    file:flush()
                else
                    if tonumber(value) then
                        valueStr = tonumber(value)
                        file:write(indent .. formatKey(key) .. " = ", valueStr, ",\n")
                        file:flush()
                    elseif value == true then
                        valueStr = true
                        file:write(indent .. formatKey(key) .. " = true,\n")
                        file:flush()
                    elseif value == false then
                        valueStr = false
                        file:write(indent .. formatKey(key) .. " = false ,\n")
                    else
                        valueStr = type(value) == "string" and '"' .. value .. '"' or tostring(value)
                        file:write(indent .. formatKey(key) .. " = " .. valueStr .. ",\n")
                        file:flush()
                    end
                end
            end
        end
    end

    local function writeTable(t, order1)
        local indent = ""
        if type(order1) == "table" then
            local value = ''
            for _, key in ipairs(order1) do
                value = t[key]
                if type(value) == "table" then
                    file:write(indent .. formatKey(key) .. " = {\n")
                    file:flush()
                    if key == 'heal' or key == 'buff' or key == 'debuff' or key == 'cure' then
                        for _, subkey in ipairs(subOrder[key]) do
                            if subkey ~= 'spells' then
                                local subval = value[subkey]
                                if subval == nil then
                                    -- omit nil keys to keep config sparse
                                elseif tonumber(subval) then
                                    file:write(indent .. "  " .. formatKey(subkey) .. " = ", tonumber(subval), ",\n")
                                elseif subval == true then
                                    file:write(indent .. "  " .. formatKey(subkey) .. " = true,\n")
                                elseif subval == false then
                                    file:write(indent .. "  " .. formatKey(subkey) .. " = false ,\n")
                                else
                                    local subvalStr = type(subval) == "string" and '"' .. subval .. '"' or
                                        tostring(subval)
                                    file:write(indent .. "  " .. formatKey(subkey) .. " = " .. subvalStr .. ",\n")
                                end
                                file:flush()
                            else
                                file:write(indent .. "  " .. formatKey('spells') .. " = {\n")
                                file:flush()
                                local spells = value.spells or {}
                                for si, entry in ipairs(spells) do
                                    if type(entry) == "table" then
                                        file:write(indent .. "    {\n")
                                        file:flush()
                                        writesubTable(entry, spellSlotOrder[key], indent .. "      ")
                                        file:write(indent .. "    },\n")
                                        file:flush()
                                    end
                                end
                                file:write(indent .. "  },\n")
                                file:flush()
                            end
                        end
                    elseif key == 'pull' then
                        for _, subkey in ipairs(subOrder[key]) do
                            local subval = value[subkey]
                            if subval == nil then
                                -- omit nil keys
                            elseif subkey == 'spell' and type(subval) == "table" then
                                file:write(indent .. "  " .. formatKey('spell') .. " = {\n")
                                file:flush()
                                writesubTable(subval, spellSlotOrder.pull, indent .. "    ")
                                file:write(indent .. "  },\n")
                                file:flush()
                            elseif subkey == 'manaclass' and type(subval) == 'table' then
                                local parts = {}
                                for _, c in ipairs(subval) do
                                    parts[#parts + 1] = "'" .. tostring(c):gsub("'", "\\'") .. "'"
                                end
                                file:write(indent ..
                                    "  " .. formatKey('manaclass') .. " = { " .. table.concat(parts, ", ") .. " },\n")
                                file:flush()
                            elseif tonumber(subval) then
                                file:write(indent .. "  " .. formatKey(subkey) .. " = ", tonumber(subval), ",\n")
                            elseif subval == true then
                                file:write(indent .. "  " .. formatKey(subkey) .. " = true,\n")
                            elseif subval == false then
                                file:write(indent .. "  " .. formatKey(subkey) .. " = false ,\n")
                            else
                                local subvalStr = type(subval) == "string" and '"' .. subval .. '"' or tostring(subval)
                                file:write(indent .. "  " .. formatKey(subkey) .. " = " .. subvalStr .. ",\n")
                            end
                            file:flush()
                        end
                    else
                        writesubTable(value, subOrder[key], indent .. "  ")
                    end
                    file:write(indent .. "},\n")
                    file:flush()
                elseif value == nil then
                    -- omit nil keys to keep config sparse
                else
                    local valueStr = type(value) == "string" and '"' .. value .. '"' or tostring(value)
                    if tonumber(value) then
                        file:write(indent .. formatKey(key) .. " = ", tonumber(value), ",\n")
                    elseif value == true then
                        file:write(indent .. formatKey(key) .. " = true,\n")
                    elseif value == false then
                        file:write(indent .. formatKey(key) .. " = false ,\n")
                    else
                        file:write(indent .. formatKey(key) .. " = " .. valueStr .. ",\n")
                    end
                    file:flush()
                end
            end
        end
    end

    file:write("StoredConfig =  {\n")
    file:flush()
    writeTable(config, keyOrder)
    file:write("}\n")
    file:flush()
    file:write("return StoredConfig")
    file:flush()
    file:close()
    return true
end

function M.Load(path)
    local newconfig
    local configData, err = loadfile(path)
    if err then
        print('load failed')
        newconfig = sanitizeConfigFile(path)
    elseif configData then
        newconfig = configData()
    end
    if not newconfig then
        print('making new config')
        newconfig = {}
    end
    for k in pairs(M.config) do
        M.config[k] = nil
    end
    for k, v in pairs(newconfig) do
        M.config[k] = v
    end
    if not M.config.settings then M.config.settings = {} end
    if not M.config.melee then M.config.melee = {} end
    if not M.config.pull then M.config.pull = {} end
    if not M.config.bard then M.config.bard = {} end
    if not M.config.heal then M.config.heal = {} end
    if not M.config.buff then M.config.buff = {} end
    if not M.config.debuff then M.config.debuff = {} end
    if not M.config.script then M.config.script = {} end
    if not M.config.cure then M.config.cure = {} end
    for _, section in ipairs({ 'heal', 'buff', 'debuff', 'cure' }) do
        if not M.config[section].spells then M.config[section].spells = {} end
    end
    -- Normalize precondition to string or nil (no boolean) in all spell entries; spell to string (config may have number e.g. 0)
    for _, section in ipairs({ 'heal', 'buff', 'debuff', 'cure' }) do
        for _, entry in ipairs(M.config[section].spells or {}) do
            if type(entry.spell) ~= 'string' then entry.spell = '' end
            if type(entry.precondition) == 'boolean' then
                entry.precondition = entry.precondition and nil or 'false'
            elseif type(entry.precondition) == 'string' and (entry.precondition == '' or entry.precondition:match('^%s*$')) then
                entry.precondition = nil
            end
        end
    end
    if (M.config.settings.domelee == nil) then M.config.settings.domelee = false end
    if (M.config.settings.doheal == nil) then M.config.settings.doheal = false end
    if (M.config.settings.dobuff == nil) then M.config.settings.dobuff = false end
    if (M.config.settings.dodebuff == nil) then M.config.settings.dodebuff = false end
    if (M.config.settings.docure == nil) then M.config.settings.docure = false end
    if (M.config.settings.doraid == nil) then M.config.settings.doraid = false end
    if (M.config.settings.dodrag == nil) then M.config.settings.dodrag = false end
    if (M.config.settings.domount == nil) then M.config.settings.domount = false end
    if (M.config.settings.mountcast == nil) then M.config.settings.mountcast = 'none' end
    if (M.config.settings.dosit == nil) then M.config.settings.dosit = true end
    if (M.config.settings.doforage == nil) then M.config.settings.doforage = false end
    if (M.config.settings.sitmana == nil) then M.config.settings.sitmana = 90 end
    if (M.config.settings.sitendur == nil) then M.config.settings.sitendur = 90 end
    if (M.config.settings.sitaggro == nil) then M.config.settings.sitaggro = 60 end
    if (M.config.settings.acleash == nil) then M.config.settings.acleash = 75 end
    if (M.config.settings.followdistance == nil) then M.config.settings.followdistance = 35 end
    M.config.settings.acleashSq = (M.config.settings.acleash or 0) * (M.config.settings.acleash or 0)
    M.config.settings.followdistanceSq = (M.config.settings.followdistance or 0) *
        (M.config.settings.followdistance or 0)
    if (M.config.settings.zradius == nil) then M.config.settings.zradius = 75 end
    if (M.config.settings.campRestDistance == nil) then M.config.settings.campRestDistance = 15 end
    M.config.settings.campRestDistanceSq = (M.config.settings.campRestDistance or 0) * (M.config.settings.campRestDistance or 0)
    if M.config.settings.maCampAnchor == nil then M.config.settings.maCampAnchor = true end
    if M.config.settings.engageXTargetOnly == nil then M.config.settings.engageXTargetOnly = true end
    if (M.config.settings.TankName == nil) then M.config.settings.TankName = "automatic" end
    if (M.config.settings.TargetFilter == nil) then M.config.settings.TargetFilter = 0 end
    if M.config.settings.TargetFilter ~= nil then M.config.settings.TargetFilter = tonumber(M.config.settings
        .TargetFilter) or 0 end
    if (M.config.settings.petassist == nil) then M.config.settings.petassist = false end
    if (M.config.settings.spelldb == nil) then M.config.settings.spelldb = 'spells.db' end
    applySectionDefaults('pull', {
        radius = 400,
        zrange = 150,
        pullMinCon = 2,
        pullMaxCon = 5,
        maxLevelDiff = 6,
        usePullLevels = false,
        pullMinLevel = 1,
        pullMaxLevel = 125,
        chainpullcnt = 0,
        chainpullhp = 0,
        hunter = false,
        roam = false,
        mana = 60,
        manaclass = { 'CLR', 'DRU', 'SHM' },
        leash = 500,
        fteLockoutSec = 120,
        backupCandidates = 3,
        addAbortRadius = 50,
        usepriority = false,
    })
    if not M.config.pull.spell or type(M.config.pull.spell) ~= 'table' then
        M.config.pull.spell = { gem = 'melee', spell = '', range = nil }
    end
    local ps = M.config.pull.spell
    if ps then
        if ps.gem == nil then ps.gem = 'melee' end
        if ps.spell == nil then ps.spell = '' end
    end
    if type(M.config.pull.manaclass) ~= 'table' then
        M.config.pull.manaclass = { 'CLR', 'DRU', 'SHM' }
    end
    if M.config.pull.mana ~= nil then
        M.config.pull.mana = tonumber(M.config.pull.mana) or 60
    end
    if M.config.pull.fteLockoutSec ~= nil then
        M.config.pull.fteLockoutSec = tonumber(M.config.pull.fteLockoutSec) or 120
    end
    if M.config.pull.backupCandidates ~= nil then
        local n = tonumber(M.config.pull.backupCandidates) or 3
        if n < 1 then n = 1 elseif n > 5 then n = 5 end
        M.config.pull.backupCandidates = n
    end
    M.config.pull.radiusSq = (M.config.pull.radius or 0) * (M.config.pull.radius or 0)
    local r40 = (M.config.pull.radius or 0) + 40
    M.config.pull.radiusPlus40Sq = r40 * r40
    M.config.pull.leashSq = (M.config.pull.leash or 0) * (M.config.pull.leash or 0)
    applySectionDefaults('bard', { mez_remez_sec = 6 })
    applySectionDefaults('melee', {
        stickcmd = 'hold uw 7', stayBehind = false, behindAggroPct = 90, evadePct = 90, offtank = false, mtSticky = false,
        otoffset = 0, minmana = 0, assistpct = 99,
    })
    applySectionDefaults('heal', { rezoffset = 0, interruptlevel = 0.80, xttargets = 0 })
end

function M.Save(path)
    return writeConfigToFile(M.config, path)
end

function M.WriteToFile(config, path)
    return writeConfigToFile(config, path)
end

-- Full config load: main config, subsystem configs, script order, cz_common. Immune data is stored per zone in cz_common (zones[zone].immune).
function M.LoadConfig()
    local path = M.getPath()
    M.Load(path)
    M.RunConfigLoaders()
    ---@type RunConfig
    local runconfig = state.getRunconfig()
    for k, v in ipairs(runconfig.ScriptList) do
        runconfig.SubOrder[v] = v
    end
    for k, v in ipairs(runconfig.ScriptList) do
        table.insert(M.getSubOrder().script, v)
    end
    M.Save(path)
    M.loadCommon()
    M.loadNukeFlavorsFromZone()
end

return M
