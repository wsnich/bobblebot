-- Spell-upgrade detection (Option C). When a better version of a configured spell is available in your
-- spellbook, surface it and let you apply it with one click/command -- no dataset needed.
--
-- How it works: MQ exposes Spell.SpellGroup -- every rank of a spell line shares one group id (so all
-- Cannibalize ranks, Togor's/Turgur's, etc. group together). We scan your spellbook once, keep the
-- highest-level scribed member of each group, and compare it to each configured spell. If your book has a
-- higher-level member of that line than what's configured, it's an upgrade suggestion.
--
-- Defensive: if this server's spell data leaves SpellGroup = 0 for a spell, we skip it (no false hits).

local mq = require('mq')
local botconfig = require('lib.config')

local spellupgrade = {}

local SECTIONS = { 'heal', 'buff', 'debuff', 'cure' }
local SCAN_MAX_SLOT = 512        -- spellbook slots to scan (covers emu books)
local AUTO_THROTTLE_MS = 60000   -- background downtime re-scan cadence
local _nextAuto = 0
local _pending = {}              -- { {section, index, old, new, oldLevel, newLevel, group}, ... }
local _lastLevel = 0
local _debug = false

function spellupgrade.SetDebug(on) _debug = on and true or false end
function spellupgrade.IsDebug() return _debug end
local function dbg(fmt, ...) if _debug then printf('\ay[upgrade]\ax ' .. fmt, ...) end end

-- group id + level for a spell name via the MQ Spell TLO. group 0 means "no group data" (skip).
-- SpellGroup is wrapped in pcall in case a given MQ build doesn't expose that member.
local function spellGroupLevel(name)
    if not name or name == '' then return 0, 0 end
    local s = mq.TLO.Spell(name)
    if not s() then return 0, 0 end
    local okG, g = pcall(function() return s.SpellGroup() end)
    local okL, l = pcall(function() return s.Level() end)
    local group = (okG and tonumber(g)) or 0
    local level = (okL and tonumber(l)) or 0
    return group, level
end

-- Collect the SpellGroups referenced by configured spells so the book scan only cares about those lines.
-- Returns careGroups (set), and entries = { {section, index, spell, group, level}, ... }.
local function collectConfigGroups()
    local careGroups, entries = {}, {}
    for _, section in ipairs(SECTIONS) do
        local n = botconfig.getSpellCount(section)
        for i = 1, n do
            local entry = botconfig.getSpellEntry(section, i)
            local spell = entry and entry.spell
            -- Only real, gem-cast spells (skip item/alt/disc/ability and blanks).
            if entry and type(spell) == 'string' and spell ~= '' and spell ~= '0' and tonumber(entry.gem) then
                local group, level = spellGroupLevel(spell)
                if group ~= 0 then
                    careGroups[group] = true
                    entries[#entries + 1] = { section = section, index = i, spell = spell, group = group, level = level }
                end
            end
        end
    end
    return careGroups, entries
end

-- Best (highest-level, castable, scribed) spell per group, limited to groups we care about.
local function scanBookByGroup(careGroups)
    local myLevel = tonumber(mq.TLO.Me.Level()) or 1
    local best = {}
    for slot = 1, SCAN_MAX_SLOT do
        local name = mq.TLO.Me.Book(slot)()
        if name and name ~= '' then
            local group, level = spellGroupLevel(name)
            if group ~= 0 and careGroups[group] and level <= myLevel then
                local cur = best[group]
                if not cur or level > cur.level then best[group] = { name = name, level = level } end
            end
        end
    end
    return best
end

-- Recompute the pending-upgrade list. Returns the list.
function spellupgrade.scan()
    _pending = {}
    local careGroups, entries = collectConfigGroups()
    if not next(careGroups) then return _pending end
    local best = scanBookByGroup(careGroups)
    for _, e in ipairs(entries) do
        local b = best[e.group]
        if b and b.name and string.lower(b.name) ~= string.lower(e.spell) and b.level > e.level then
            _pending[#_pending + 1] = {
                section = e.section, index = e.index,
                old = e.spell, new = b.name,
                oldLevel = e.level, newLevel = b.level, group = e.group,
            }
            dbg('%s[%d]: %s (L%d) -> %s (L%d)', e.section, e.index, e.spell, e.level, b.name, b.level)
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
    printf('\ayCZBot:\axUpgraded %s spell %d: %s -> %s', u.section, u.index, u.old, u.new)
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
        printf('\ayCZBot:\ax%d spell upgrade(s) available -- Status tab or /cz upgrades', #_pending)
    end
end

return spellupgrade
