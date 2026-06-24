-- Pre-memorize the configured gembar during downtime so combat-critical spells (slow, heals, debuffs)
-- are already loaded BEFORE they're needed under pressure.
--
-- Why this exists: when a spell's configured gem currently holds the wrong spell, the cast engine has to
-- memorize it on the fly mid-combat. A higher-priority heal can preempt that memorize over and over until
-- the 16s window expires -- the "MEMORIZETIMEOUT sub=debuff" failure where a slow never lands. Loading the
-- right spell into its gem during downtime removes the on-the-fly memorize entirely.
--
-- We only touch gems that are UNIQUELY assigned in the config. Gems the user intentionally multiplexes
-- (e.g. several buffs / both cures sharing one gem) are left to on-demand swapping, so we never thrash
-- against the buff/cure engines.

local mq = require('mq')
local botconfig = require('lib.config')
local state = require('lib.state')

local premem = {}

local SECTIONS = { 'heal', 'buff', 'debuff', 'cure' }
local THROTTLE_MS = 3000      -- normal idle re-check cadence
local POST_MEM_WAIT_MS = 10000 -- after issuing a /memspell, give it time to finish before the next gem
local _nextCheck = 0
local _debug = false

function premem.SetDebug(on) _debug = on and true or false end
function premem.IsDebug() return _debug end
function premem.requestCheck() _nextCheck = 0 end

local function dbg(fmt, ...)
    if _debug then printf('\ay[premem]\ax ' .. fmt, ...) end
end

-- gem(number) -> spellName, but only for gems referenced by exactly one configured spell. A gem shared by
-- two+ configured spells is intentionally multiplexed; leave it to on-demand memorization.
local function buildUniqueGemMap()
    local count, firstSpell = {}, {}
    local function consider(gem, spell)
        count[gem] = (count[gem] or 0) + 1
        if not firstSpell[gem] then firstSpell[gem] = spell end
    end
    local function considerEntry(entry)
        if not entry or entry.enabled == false then return end
        local gem = tonumber(entry.gem)
        if not gem or gem <= 0 or gem > 13 then return end
        local spell = entry.spell
        if type(spell) ~= 'string' or spell == '' or spell == '0' then return end
        consider(gem, spell)
    end
    for _, section in ipairs(SECTIONS) do
        local n = botconfig.getSpellCount(section)
        for i = 1, n do
            considerEntry(botconfig.getSpellEntry(section, i))
        end
    end
    -- Pull spell is stored differently (a single table, not a .spells array).
    local pull = botconfig.config.pull
    if pull and type(pull.spell) == 'table' then considerEntry(pull.spell) end

    local map = {}
    for gem, c in pairs(count) do
        if c == 1 then map[gem] = firstSpell[gem] end
    end
    return map
end

-- Only issue a /memspell when it can't interfere with anything: out of combat, no camp mobs, not casting,
-- not moving (matches the existing "abort mem to keep moving" rule), and alive.
local function safeToMem()
    if mq.TLO.Me.Combat() then return false end
    if (tonumber(state.getMobCount()) or 0) > 0 then return false end
    if mq.TLO.Me.Casting() then return false end
    if (mq.TLO.Me.CastTimeLeft() or 0) > 0 then return false end
    if mq.TLO.Me.Moving() then return false end
    if mq.TLO.Me.Dead() then return false end
    return true
end

-- Per-tick (called from doMiscTimer, ~1s). Loads at most one wrong gem per pass.
function premem.tick()
    if botconfig.config.settings.premem == false then return end
    if mq.gettime() < _nextCheck then return end
    _nextCheck = mq.gettime() + THROTTLE_MS
    if not safeToMem() then return end

    for gem, spell in pairs(buildUniqueGemMap()) do
        local inGem = mq.TLO.Me.Gem(gem)() or ''
        if string.lower(inGem) ~= string.lower(spell) then
            if mq.TLO.Me.Book(spell)() then
                dbg('memorizing %s into gem %d (had: %s)', spell, gem, (inGem ~= '' and inGem or 'empty'))
                mq.cmdf('/memspell %s "%s"', tostring(gem), spell)
                _nextCheck = mq.gettime() + POST_MEM_WAIT_MS
                return -- one gem per pass; recheck after it finishes
            else
                dbg('skip %s -> gem %d (not in spellbook)', spell, gem)
            end
        end
    end
end

return premem
