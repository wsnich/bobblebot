-- Spell-upgrade detection (Option C). When a better version of a configured spell is in your spellbook,
-- surface it and let you apply it with one click/command -- no dataset needed.
--
-- How it works (ported from MAUI's GetSpellUpgrade): SpellGroup is 0 on many emus, so instead of spell-line
-- ids we match by spell CHARACTERISTICS. The upgrade for a configured spell is the highest-level spell in
-- your book that shares its TargetType, Subcategory and NumEffects and is a higher level than it. We index
-- the whole book once per scan, so any number of configured spells is one pass.

local mq = require('mq')
local botconfig = require('lib.config')

local spellupgrade = {}

local SECTIONS = { 'heal', 'buff', 'debuff', 'cure' }
local SCAN_MAX_SLOT = 1120       -- spellbook slots to scan (MAUI uses 1120)
local AUTO_THROTTLE_MS = 60000   -- background downtime re-scan cadence
local _nextAuto = 0
local _pending = {}              -- { {section, index, old, new, oldLevel, newLevel}, ... }
local _lastLevel = 0
local _debug = false

function spellupgrade.SetDebug(on) _debug = on and true or false end
function spellupgrade.IsDebug() return _debug end
local function dbg(fmt, ...) if _debug then printf('\ay[upgrade]\ax ' .. fmt, ...) end end

-- The match-key + level for a spell NAME (the configured spell), via the MQ Spell TLO. nil if not a spell.
local function spellMeta(name)
    if not name or name == '' then return nil end
    local s = mq.TLO.Spell(name)
    if not s() then return nil end
    return {
        targetType = tostring(s.TargetType()),
        subCat = tostring(s.Subcategory()),
        numEffects = tonumber(s.NumEffects()) or 0,
        level = tonumber(s.Level()) or 0,
    }
end

function spellupgrade.describe(name)
    local m = spellMeta(name)
    if not m then return nil end
    return string.format('TargetType=%s Subcategory=%s NumEffects=%d Level=%d',
        m.targetType, m.subCat, m.numEffects, m.level)
end

-- Index the spellbook by characteristic key -> highest-level scribed spell you can use { name, level }.
local function indexBookByCharacteristics()
    local myLevel = tonumber(mq.TLO.Me.Level()) or 1
    local index = {}
    for i = 1, SCAN_MAX_SLOT do
        local s = mq.TLO.Me.Book(i)
        if s.ID() then
            local lvl = tonumber(s.Level()) or 0
            if lvl <= myLevel then
                local key = tostring(s.TargetType()) .. '|' .. tostring(s.Subcategory()) .. '|' ..
                    tostring(s.NumEffects())
                local cur = index[key]
                if not cur or lvl > cur.level then
                    index[key] = { name = (s.Name() or ''):gsub(' Rk%..*', ''), level = lvl }
                end
            end
        end
    end
    return index
end

-- Recompute the pending-upgrade list. Returns the list.
function spellupgrade.scan()
    _pending = {}
    local index = indexBookByCharacteristics()
    for _, section in ipairs(SECTIONS) do
        local n = botconfig.getSpellCount(section)
        for i = 1, n do
            local entry = botconfig.getSpellEntry(section, i)
            local spell = entry and entry.spell
            -- Only real, gem-cast spells (skip item/alt/disc/ability and blanks).
            if entry and type(spell) == 'string' and spell ~= '' and spell ~= '0' and tonumber(entry.gem) then
                local m = spellMeta(spell)
                if m then
                    local key = m.targetType .. '|' .. m.subCat .. '|' .. m.numEffects
                    local best = index[key]
                    if _debug then
                        dbg('config %s[%d] "%s": %s L%d -> best same-type in book = %s', section, i, spell, key,
                            m.level, best and string.format('"%s" L%d', best.name, best.level) or 'none')
                    end
                    if best and best.level > m.level and string.lower(best.name) ~= string.lower(spell) then
                        _pending[#_pending + 1] = {
                            section = section, index = i, old = spell, new = best.name,
                            oldLevel = m.level, newLevel = best.level,
                        }
                        dbg('upgrade: %s[%d] %s (L%d) -> %s (L%d)', section, i, spell, m.level, best.name, best.level)
                    end
                end
            end
        end
    end
    return _pending
end

function spellupgrade.getPending() return _pending end
function spellupgrade.count() return #_pending end


-- Apply one pending upgrade by 1-based list position: rewrite the config entry's spell + persist.
function spellupgrade.apply(n)
    local u = _pending[n]
    if not u then return false end
    local entry = botconfig.getSpellEntry(u.section, u.index)
    if not entry then return false end
    entry.spell = u.new
    entry._resolved_level = nil
    entry._resolved_alias = nil
    botconfig.ApplyAndPersist()
    printf('\aybobblebot:\axUpgraded %s spell %d: %s -> %s', u.section, u.index, u.old, u.new)
    -- Re-scan so the list reflects the change (and catches any chained upgrades).
    spellupgrade.scan()
    return true
end

function spellupgrade.applyAll()
    -- Apply repeatedly from the top since each apply re-scans and rebuilds the list.
    local applied = 0
    local guard = 0
    while #_pending > 0 and guard < 64 do
        guard = guard + 1
        if spellupgrade.apply(1) then applied = applied + 1 else break end
    end
    return applied
end

-- Background tick (from doMiscTimer): during downtime, re-scan on a slow cadence and on level-up, and
-- announce once when new upgrades appear. Gated by settings.upgradeCheck (default on).
function spellupgrade.tick()
    if botconfig.config.settings.upgradeCheck == false then return end
    local lvl = tonumber(mq.TLO.Me.Level()) or 1
    local leveled = (lvl ~= _lastLevel)
    if not leveled and mq.gettime() < _nextAuto then return end
    -- Only scan when idle/safe (avoid book reads mid-combat churn).
    if mq.TLO.Me.Combat() then return end
    if (tonumber(require('lib.state').getMobCount()) or 0) > 0 then return end
    _lastLevel = lvl
    _nextAuto = mq.gettime() + AUTO_THROTTLE_MS
    local before = #_pending
    spellupgrade.scan()
    if #_pending > before and #_pending > 0 then
        printf('\aybobblebot:\ax%d spell upgrade(s) available -- Status tab or /cz upgrades', #_pending)
    end
end

return spellupgrade
