local mq = require('mq')
local botconfig = require('lib.config')
local spellsdb = require('lib.spellsdb')
local immune = require('lib.immune')
local state = require('lib.state')
local spellstates = require('lib.spellstates')
local tankrole = require('lib.tankrole')
local charinfo = require("plugin.charinfo")
local bardtwist = require('lib.bardtwist')
local castutils = require('lib.castutils')
local bothooks = require('lib.bothooks')
local utils = require('lib.utils')
local casting = require('lib.casting')
local botmove = require('botmove')
local spawnutils = require('lib.spawnutils')
local spellutils = {}
local _deps = {}
local _instantDebuffCastPending = nil
local prepareImmediateCastFn = nil

function spellutils.setPrepareImmediateCastFn(fn)
    prepareImmediateCastFn = fn
end

local function invokePrepareImmediateCast(sub, index, evalId, targethit)
    if not prepareImmediateCastFn then return end
    local rc = state.getRunconfig()
    if rc.CurSpell and rc.CurSpell.corpseDragDone then return end
    prepareImmediateCastFn(sub, index, evalId, targethit)
    if rc.CurSpell then rc.CurSpell.corpseDragDone = true end
end

local CASTING_STUCK_MS = 20000
--- Delay (ms) after cast start when spell must be memorized, so casting state is visible before next tick and charState won't stand for hysteresis.
local CASTING_MEMORIZE_DELAY_MS = 200
--- Terminal casting.result() values that mean the cast pipeline may run OnCastComplete / afterCast. All others clear state without success bookkeeping.
local CASTING_LIB_SUCCESS_RESULTS = {
    CAST_SUCCESS = true,
    CAST_RESIST = true,
    CAST_IMMUNE = true,
    CAST_TAKEHOLD = true,
    CAST_FIZZLE = true,
}
--- When buff remaining time on target is below this (ms), do not interrupt with "buff already present" (allow refresh cast to complete). Should match botbuff's refresh window (e.g. 24s for self).
local BUFF_REFRESH_THRESHOLD_MS = 24000
--- When a debuff returns CAST_TAKEHOLD (blocked by another spell), skip that debuff on this spawn for this many ms.
local BLOCKED_SKIP_MS = 300000

function spellutils.GetDebuffDontStackAllowlist()
    return botconfig.DEBUFF_DONTSTACK_ALLOWED
end

function spellutils.GetDebuffStopWhenAllowlist()
    return botconfig.DEBUFF_STOPWHEN_ALLOWED
end

--- Returns the first category from the list that is present on the current target (Target[tag].ID() > 0), or nil. Only considers tags in the allowlist.
function spellutils.TargetHasDebuffCategory(categories)
    if not categories or #categories == 0 then return nil end
    for _, tag in ipairs(categories) do
        if botconfig.DEBUFF_DONTSTACK_ALLOWED[tag] and mq.TLO.Target[tag] and mq.TLO.Target[tag].ID then
            local id = mq.TLO.Target[tag].ID()
            if id and id > 0 then
                return tag
            end
        end
    end
    return nil
end

-- Refresh (remez) when Enthrall has less than this remaining.
-- Semantics: SpawnMezActive() returns true only when remaining > threshold.
--
-- For ENC/BRD we want quick refresh to avoid long mez downtimes.
local MEZ_ACTIVE_MIN_MS = 18000 -- default: remez when Enthrall remaining <= 18s

local function getMezActiveThresholdMs()
    local cls = mq.TLO.Me.Class.ShortName and mq.TLO.Me.Class.ShortName() or nil
    if cls == 'BRD' then
        local bard = botconfig.config.bard
        local sec = bard and tonumber(bard.mez_remez_sec)
        if not sec or sec <= 0 then sec = 6 end
        return sec * 1000
    end
    return MEZ_ACTIVE_MIN_MS
end

--- Debuff refresh threshold (all debuffs): re-cast when remaining <= threshold.
--- Enchanters: 18s, Bards: 6s.
function spellutils.GetDebuffRefreshThresholdMs()
    return getMezActiveThresholdMs()
end

--- Remaining ms of the longest Enthrall (mez) buff on spawn; 0 if none or expired.
function spellutils.SpawnEnthrallRemainingMs(spawnId)
    if not spawnId or spawnId <= 0 then return 0 end
    local sp = mq.TLO.Spawn(spawnId)
    if not sp or not sp.ID() or sp.ID() ~= spawnId then return 0 end
    local maxSlots = (sp.MaxBuffSlots and sp.MaxBuffSlots()) or 40
    local best = 0
    for i = 1, maxSlots do
        local b = sp.Buff(i)
        if b and b() then
            local okSub, sub = pcall(function() return b.Subcategory and b.Subcategory() end)
            if okSub and sub == 'Enthrall' then
                local okDur, dur = pcall(function() return b.Duration and b.Duration() or 0 end)
                local d = (okDur and dur) or 0
                if d > best then best = d end
            end
        end
    end
    return best
end

--- True when spawn has an Enthrall buff with more than minRemMs left (default 3s).
function spellutils.SpawnMezActive(spawnId, minRemMs)
    return spellutils.SpawnEnthrallRemainingMs(spawnId) > (minRemMs or getMezActiveThresholdMs())
end

--- True when spawn has any active attack-slow detrimental (walk buff slots; Spawn.Slowed is unreliable).
function spellutils.SpawnSlowActive(spawnId, minRemMs)
    if not spawnId or spawnId <= 0 then return false end
    local sp = mq.TLO.Spawn(spawnId)
    if not sp or not sp.ID() or sp.ID() ~= spawnId then return false end
    local threshold = minRemMs or MEZ_ACTIVE_MIN_MS
    local okSlow, slowRef = pcall(function() return sp.Slowed and sp.Slowed() end)
    if okSlow and slowRef then
        if type(slowRef) == 'string' and slowRef ~= '' then return true end
        if slowRef.ID and slowRef.ID() and slowRef.ID() > 0 then
            local okDur, dur = pcall(function() return slowRef.Duration and slowRef.Duration() or 0 end)
            local d = (okDur and dur) or 0
            if d <= 0 or d > threshold then return true end
        end
    end
    local maxSlots = (sp.MaxBuffSlots and sp.MaxBuffSlots()) or 40
    for i = 1, maxSlots do
        local b = sp.Buff(i)
        if b and b() then
            local okSub, sub = pcall(function() return b.Subcategory and b.Subcategory() end)
            if okSub and sub == 'Slow' then
                local okDur, dur = pcall(function() return b.Duration and b.Duration() or 0 end)
                local d = (okDur and dur) or 0
                if d <= 0 or d > threshold then return true end
            end
        end
    end
    return false
end

--- Returns first stopWhen category present on spawn, or nil.
function spellutils.SpawnHasStopWhenCategory(spawnId, categories)
    if not spawnId or spawnId <= 0 or not categories or #categories == 0 then return nil end
    for _, tag in ipairs(categories) do
        if botconfig.DEBUFF_STOPWHEN_ALLOWED[tag] then
            if tag == 'Slowed' then
                if spellutils.SpawnSlowActive(spawnId) then return tag end
            elseif tag == 'Mezzed' then
                if spellutils.SpawnMezActive(spawnId) then return tag end
            elseif botconfig.DEBUFF_DONTSTACK_ALLOWED[tag] then
                local found = spellutils.SpawnHasDebuffCategory(spawnId, { tag })
                if found then return found end
            end
        end
    end
    return nil
end

--- Same as TargetHasDebuffCategory but uses Spawn TLO (no retarget required).
function spellutils.SpawnHasDebuffCategory(spawnId, categories)
    if not spawnId or spawnId <= 0 or not categories or #categories == 0 then return nil end
    local sp = mq.TLO.Spawn(spawnId)
    if not sp or not sp.ID() or sp.ID() ~= spawnId then return nil end
    for _, tag in ipairs(categories) do
        if botconfig.DEBUFF_DONTSTACK_ALLOWED[tag] then
            if tag == 'Mezzed' then
                if spellutils.SpawnMezActive(spawnId) then return tag end
            else
                local cat = sp[tag]
                if cat and cat.ID then
                    local id = cat.ID()
                    if id and id > 0 then
                        local remSec = 0
                        if cat.MyDuration then
                            remSec = tonumber(cat.MyDuration.TotalSeconds()) or 0
                        end
                        if remSec <= 0 or remSec * 1000 > MEZ_ACTIVE_MIN_MS then return tag end
                    end
                end
                local ok, has = pcall(function() return cat and cat() end)
                if ok and has then return tag end
            end
        end
    end
    return nil
end

--- Record dontStack debuff timer from spawn category buff (or our spell duration as fallback).
function spellutils.RecordDontStackDebuffFromSpawn(spawnId, ourSpell, categoryTag)
    if not spawnId or not ourSpell or not categoryTag then return end
    if categoryTag == 'Mezzed' then
        local remMs = spellutils.SpawnEnthrallRemainingMs(spawnId)
        if remMs > getMezActiveThresholdMs() then
            spellstates.DebuffListUpdate(spawnId, ourSpell, mq.gettime() + remMs)
        end
        return
    end
    local sp = mq.TLO.Spawn(spawnId)
    if not sp or not sp.ID() or sp.ID() ~= spawnId then return end
    local durationSec = 0
    local spellRef = sp[categoryTag]
    if spellRef and spellRef.MyDuration then
        durationSec = tonumber(spellRef.MyDuration.TotalSeconds()) or 0
    end
    if durationSec <= 0 and mq.TLO.Spell(ourSpell)() and mq.TLO.Spell(ourSpell).MyDuration then
        durationSec = tonumber(mq.TLO.Spell(ourSpell).MyDuration.TotalSeconds()) or 0
    end
    if durationSec <= 0 then return end
    spellstates.DebuffListUpdate(spawnId, ourSpell, mq.gettime() + durationSec * 1000)
end

--- Record that our spell should be considered "on spawn" until the other spell's duration, so we don't re-attempt every tick. Call when target is current target. categoryTag = e.g. 'Snared'.
function spellutils.RecordDontStackDebuffFromTarget(targetSpawnId, ourSpell, categoryTag)
    if not targetSpawnId or not ourSpell or not categoryTag then return end
    if mq.TLO.Target.ID() == targetSpawnId then
        local spellRef = mq.TLO.Target[categoryTag]
        if spellRef and spellRef.MyDuration then
            local durationSec = tonumber(spellRef.MyDuration.TotalSeconds()) or 0
            if durationSec > 0 then
                spellstates.DebuffListUpdate(targetSpawnId, ourSpell, mq.gettime() + durationSec * 1000)
                return
            end
        end
    end
    spellutils.RecordDontStackDebuffFromSpawn(targetSpawnId, ourSpell, categoryTag)
end

--- True when spawn still needs this debuff (range, dontStack, stopWhen, stacks, duration). phase: 'matar' | 'notmatar'.
function spellutils.SpawnNeedsDebuff(entry, ctx, spawn, phase)
    if utils.isProtectedSpawn(spawn) then return false end
    local gem = entry.gem
    local myrangeSq = ctx.myrangeSq
    local spawnId = spawn and spawn.ID and spawn.ID() or nil
    local isMez = spellutils.IsMezSpell(entry)
    local function mezSkip(reason)
        if isMez and phase == 'notmatar' and spawnId then
            local name = (spawn.CleanName and spawn.CleanName()) or ('id ' .. tostring(spawnId))
            spellutils.DbgMezTrace('skip %s (id %s) - %s', name, spawnId, reason)
        end
        return false
    end

    if phase == 'notmatar' and isMez and ctx.mtTargetId and spawnId == ctx.mtTargetId then
        return mezSkip('MT target')
    end

    if entry.gem == 'ability' then
        local mr = spawn.MaxRangeTo and spawn.MaxRangeTo()
        local e = mr and math.max(0, mr - 2)
        myrangeSq = e and (e * e)
    end
    local distSq = utils.getDistanceSquared2D(mq.TLO.Me.X(), mq.TLO.Me.Y(), spawn.X(), spawn.Y())
    if ctx.minCastDistSq and distSq and distSq < ctx.minCastDistSq then
        return mezSkip('too close for targeted AE')
    end
    if myrangeSq and distSq and distSq > myrangeSq then
        return mezSkip('out of range')
    end
    local spawnLevel = spawn.Level and spawn.Level()
    if phase == 'matar' and spawnId then
        if ctx.maTargetId and spawnId == ctx.maTargetId and ctx.maTargetLvl then
            spawnLevel = ctx.maTargetLvl
        elseif ctx.mtTargetId and spawnId == ctx.mtTargetId and ctx.mtTargetLvl then
            spawnLevel = ctx.mtTargetLvl
        end
    end
    if ctx.spellid and spawnLevel and ctx.spellmaxlvl and ctx.spellmaxlvl ~= 0 and ctx.spellmaxlvl < spawnLevel and isMez then
        local name = (spawn.CleanName and spawn.CleanName()) or ('id ' .. tostring(spawn.ID()))
        printf('\ayCZBot:\ax [Mez] skipping \at%s\ax (id %s) - target level %s exceeds spell max level %s', name, spawn.ID(), spawnLevel, ctx.spellmaxlvl)
        return false
    end
    if entry.stopWhen and spawnId then
        local stopTag = spellutils.SpawnHasStopWhenCategory(spawnId, entry.stopWhen)
        if stopTag then
            return mezSkip('stopWhen ' .. stopTag)
        end
    end
    if entry.dontStack and spawnId then
        local dontTag = spellutils.SpawnHasDebuffCategory(spawnId, entry.dontStack)
        if dontTag then
            spellutils.RecordDontStackDebuffFromSpawn(spawnId, entry.spell, dontTag)
            if isMez and phase == 'notmatar' then
                return mezSkip('spawn already ' .. dontTag)
            end
            return false
        end
    end
    if isMez and phase == 'notmatar' and entry.spell and spawnId
        and spellutils.SpawnHasDebuffSpell(entry.spell, spawnId) then
        return mezSkip('our mez on spawn')
    end
    local tarstacks = spellutils.SpellStacksSpawn(entry, spawn.ID())
    if (type(gem) == 'number' or gem == 'alt' or gem == 'disc' or gem == 'item') and not tarstacks then
        if phase == 'notmatar' and isMez then
            local name = (spawn.CleanName and spawn.CleanName()) or ('id ' .. tostring(spawn.ID()))
            printf('\ayCZBot:\ax [Mez] skipping \at%s\ax (id %s) - already mezzed by another player', name, spawn.ID())
            return false
        end
        if phase == 'matar' and not spellutils.IsConcussionSpell(entry) then
            return false
        end
    end
    local debuffRefreshThresholdMs = spellutils.GetDebuffRefreshThresholdMs()
    if tonumber(ctx.spelldur) and tonumber(ctx.spelldur) > 0 and spawn.ID() and ctx.spellid
        and spellstates.HasDebuffLongerThan(spawn.ID(), ctx.spellid, debuffRefreshThresholdMs) then
        if isMez and phase == 'notmatar' and spawnId and not spellutils.SpawnMezActive(spawnId) then
            spellstates.ClearDebuffOnSpawn(spawnId, ctx.spellid)
            spellutils.DbgMezTrace('cleared expired mez tracking on id %s', spawnId)
        else
            return mezSkip('debuff still active')
        end
    end
    if ctx.aeRange and ctx.mintar and castutils.CountMobsWithinAERangeOfSpawn(ctx.mobList, spawn.ID(), ctx.aeRange) < ctx.mintar then
        return mezSkip('not enough mobs in AE range')
    end
    if isMez and phase == 'notmatar' and spawnId then
        local name = (spawn.CleanName and spawn.CleanName()) or ('id ' .. tostring(spawnId))
        spellutils.MezLog('needs cast on %s (id %s)', name, spawnId)
    end
    return true
end

function spellutils.Init(deps)
    if deps then
        _deps.AdvCombat = deps.AdvCombat
    end
end

function spellutils.MountCheck()
    local mountcast = botconfig.config.settings.mountcast
    if not mountcast or mountcast == 'none' then return end
    local mount, spelltype = mountcast:match("^%s*(.-)%s*|%s*(.-)%s*$")
    botconfig.config['mount1'] = { gem = spelltype, spell = mount }
    if not mq.TLO.Me.Mount() and not MountCastFailed then
        spellutils.CastSpell('1', 1, 'mountcast', 'mount')
    end
end

-- Returns true if the spell has no reagents or the character has >= required count of each reagent in inventory.
-- Do not store mq.TLO.Spell() proxy; use direct chains to avoid TLO quirk (stored proxy can break/hang).
function spellutils.HasReagents(Sub, ID)
    local entry = botconfig.getSpellEntry(Sub, ID)
    if not entry or not entry.spell then return true end
    local spellForReagents = entry.spell
    if entry.gem == 'item' and mq.TLO.FindItem(entry.spell)() then
        spellForReagents = mq.TLO.FindItem(entry.spell).Spell.Name()
        if not spellForReagents or spellForReagents == '' then return true end
    end
    if not mq.TLO.Spell(spellForReagents)() then return true end
    for slot = 1, 4 do
        local rid = mq.TLO.Spell(spellForReagents).ReagentID(slot)()
        if rid and rid > 0 then
            local need = mq.TLO.Spell(spellForReagents).ReagentCount(slot)() or 1
            local have = mq.TLO.FindItemCount(tostring(rid))() or 0
            if have < need then return false end
        end
    end
    return true
end

-- checks spell is loaded, minmana is met, and gem is ready, precondition is good
function spellutils.SpellCheck(Sub, ID)
    local spell = nil
    local minmana = nil
    local gem = nil
    local entry = botconfig.getSpellEntry(Sub, ID)
    if gem ~= "item" and entry and type(entry.alias) == 'string' and spellsdb and spellsdb.resolve_entry then
        local level = tonumber(mq.TLO.Me.Level()) or 1
        if (not entry.spell or entry.spell == '' or entry._resolved_level ~= level) then
            spellsdb.resolve_entry(Sub, ID, false)
        end
    end
    if entry and entry.spell then spell = entry.spell end
    if not spell then return false end
    minmana = (entry and entry.minmana ~= nil) and entry.minmana or 0
    if entry and entry.gem then gem = entry.gem end
    if mq.TLO.Window('SpellBookWnd').Open() then mq.cmd('/book') end
    if spellstates.GetReagentDelay(Sub, ID) and spellstates.GetReagentDelay(Sub, ID) > mq.gettime() then return false end
    if not spellutils.HasReagents(Sub, ID) then
        if entry then entry.enabled = false end
        spellstates.SetReagentDelay(Sub, ID, mq.gettime() + (5 * 60 * 1000)) -- 5 min before retrying this spell
        printf('\ayCZBot:\axMissing reagent for %s, disabling spell for 5 minutes', spell)
        return false
    end
    local spellmana, spellend
    if gem ~= 'ability' then
        if not mq.TLO.Spell(spell)() then return false end
        spellmana = mq.TLO.Spell(spell).Mana()
        spellend = mq.TLO.Spell(spell).EnduranceCost()
    end
    if not ((tonumber(gem) and gem <= 13 and gem > 0) or gem == 'alt' or gem == 'item' or gem == 'script' or gem == 'disc' or gem == 'ability') then return false end
    if (tonumber(gem) or gem == 'alt') and spellmana then
        if (spellmana > 0 and ((mq.TLO.Me.CurrentMana() - (mq.TLO.Me.ManaRegen() * 2)) < spellmana) or (mq.TLO.Me.PctMana() < minmana)) then return false end
    end
    if gem == 'alt' then
        if not mq.TLO.Me.AltAbilityReady(spell) then return false end
    end
    if gem == 'disc' and spellend then
        if not mq.TLO.Me.CombatAbilityReady(spell) then return false end
        if (spellend and ((mq.TLO.Me.CurrentEndurance() - (mq.TLO.Me.EnduranceRegen() * 2)) < spellend) or (mq.TLO.Me.PctMana() < minmana)) then return false end
    end
    return true
end

--Immune check
function spellutils.ImmuneCheck(Sub, ID, EvalID)
    local entry = botconfig.getSpellEntry(Sub, ID)
    if not entry then return true end
    local spell = mq.TLO.Spell(entry.spell)()
    local zone = mq.TLO.Zone.ShortName()
    local targetname = mq.TLO.Spawn(EvalID).CleanName()
    local t = immune.get()
    if t[spell] and t[spell][targetname] then return false else return true end
end

local IMMUNE_CONFIG_SECTIONS = { 'debuff', 'buff', 'cure', 'heal' }
local IMMUNE_GEM_SECTIONS = { 'debuff', 'buff', 'cure' }

local function spellNameFromEntry(entry)
    if not entry or not entry.spell or entry.spell == '' then return nil end
    return mq.TLO.Spell(entry.spell)() or entry.spell
end

--- Config entry whose spell ID matches (enabled entries with spell name).
function spellutils.findConfigEntryBySpellId(spellId)
    if not spellId or spellId <= 0 then return nil, nil, nil end
    for _, section in ipairs(IMMUNE_CONFIG_SECTIONS) do
        local cnt = botconfig.getSpellCount(section)
        for i = 1, cnt do
            local entry = botconfig.getSpellEntry(section, i)
            if entry and entry.enabled ~= false and entry.spell and entry.spell ~= '' then
                local id = mq.TLO.Spell(entry.spell).ID()
                if id and id == spellId then
                    return section, i, entry
                end
            end
        end
    end
    return nil, nil, nil
end

--- Config entry by numeric gem; if multiple share a gem, debuff wins over buff over cure.
function spellutils.findConfigEntryByGem(gem)
    if type(gem) ~= 'number' or gem < 1 or gem > 12 then return nil, nil, nil end
    for _, section in ipairs(IMMUNE_GEM_SECTIONS) do
        local cnt = botconfig.getSpellCount(section)
        for i = 1, cnt do
            local entry = botconfig.getSpellEntry(section, i)
            if entry and entry.enabled ~= false and entry.gem == gem and entry.spell and entry.spell ~= '' then
                return section, i, entry
            end
        end
    end
    return nil, nil, nil
end

--- Resolve spell context for immunity events (CurSpell, Me.Casting, config, twist-once hint).
function spellutils.resolveImmuneSpellContext()
    local rc = state.getRunconfig()
    local cur = rc and rc.CurSpell
    local ctx = {
        spellName = nil,
        spellId = nil,
        sub = nil,
        index = nil,
        curSpellTarget = cur and cur.target or nil,
        fromTwistOnceGem = false,
    }

    if cur and cur.sub and cur.spell then
        local entry = botconfig.getSpellEntry(cur.sub, cur.spell)
        if entry then
            ctx.sub = cur.sub
            ctx.index = cur.spell
            ctx.spellName = spellNameFromEntry(entry)
            if entry.spell then ctx.spellId = mq.TLO.Spell(entry.spell).ID() end
            if ctx.spellName then return ctx end
        end
    end

    local castingTlo = mq.TLO.Me.Casting()
    if castingTlo then
        local okId, castId = pcall(function() return castingTlo.ID() end)
        local okName, castName = pcall(function() return castingTlo.Name() end)
        if okId and castId and castId > 0 then
            ctx.spellId = castId
            local section, index, entry = spellutils.findConfigEntryBySpellId(castId)
            if entry then
                ctx.sub = section
                ctx.index = index
                ctx.spellName = spellNameFromEntry(entry)
            elseif okName and castName and castName ~= '' then
                ctx.spellName = mq.TLO.Spell(castName)() or castName
            end
            if ctx.spellName then return ctx end
        end
    end

    if mq.TLO.Me.Class.ShortName() == 'BRD' then
        local gem = bardtwist.getLastTwistOnceGem()
        if gem then
            local section, index, entry = spellutils.findConfigEntryByGem(gem)
            if entry then
                ctx.sub = section
                ctx.index = index
                ctx.spellName = spellNameFromEntry(entry)
                if entry.spell then ctx.spellId = mq.TLO.Spell(entry.spell).ID() end
                ctx.fromTwistOnceGem = true
                if ctx.spellName then return ctx end
            end
        end
    end

    return ctx
end

local function immuneEventMatchesOurCast(ctx)
    local spellId = ctx.spellId
    local storedId = casting.storedSpellId() or 0
    if storedId > 0 and spellId and spellId > 0 then
        return storedId == spellId
    end
    local castingTlo = mq.TLO.Me.Casting()
    if castingTlo and spellId and spellId > 0 then
        local ok, castId = pcall(function() return castingTlo.ID() end)
        if ok and castId and castId == spellId then return true end
    end
    if ctx.fromTwistOnceGem then return true end
    local curtarget = mq.TLO.Target.ID()
    if ctx.curSpellTarget and ctx.curSpellTarget > 0 then
        return ctx.curSpellTarget == curtarget
    end
    return curtarget and curtarget > 0
end

--- Handle CastImm / SlowImm when not using MQ2Cast (e.g. bard twist, empty CurSpell).
function spellutils.handleTargetImmuneEvent(_line)
    local ctx = spellutils.resolveImmuneSpellContext()
    local curtarget = mq.TLO.Target.ID()

    if not ctx.spellName or ctx.spellName == '' then
        if curtarget and curtarget > 0 then
            local name = mq.TLO.Spawn(curtarget).CleanName() or tostring(curtarget)
            printf('\ayCZBot:\ax\at%s\ax is \arimmune\ax (unknown spell)', name)
        else
            printf('\ayCZBot:\axTarget is \arimmune\ax (unknown spell)')
        end
        return
    end

    local spellId = ctx.spellId
    if not spellId and ctx.spellName then
        spellId = mq.TLO.Spell(ctx.spellName).ID()
    end
    if spellId and spellId > 0 then
        local targetType = mq.TLO.Spell(spellId).TargetType()
        if targetType == 'Targeted AE' or targetType == 'PB AE' then
            return
        end
    end

    if not immuneEventMatchesOurCast(ctx) then return end

    local immuneID = curtarget
    if immuneID and immuneID > 0 then
        immune.processList(immuneID, { spellName = ctx.spellName })
    end
end

--Check Distance (uses distance squared for comparisons)
function spellutils.DistanceCheck(Sub, ID, EvalID)
    local entry = botconfig.getSpellEntry(Sub, ID)
    if not entry then return false end
    local spell = entry.spell
    if not spell then return false end
    local spellid = nil
    local myrange = mq.TLO.Spell(spell).MyRange()
    local aeRange = mq.TLO.Spell(spell).AERange()
    local targ = mq.TLO.Spawn(EvalID)
    local distSq = utils.getDistanceSquared2D(mq.TLO.Me.X(), mq.TLO.Me.Y(), targ.X(), targ.Y())
    if aeRange and aeRange > 0 and distSq and distSq <= (aeRange * aeRange) then
        return true
    elseif distSq and myrange and distSq <= (myrange * myrange) then
        return true
    else
        return false
    end
end

-- Returns true if peer has spellid in Buff or ShortBuff (rich array scan).
function spellutils.PeerHasBuff(peerInfo, spellid)
    if not peerInfo then return false end
    local function has(list)
        if not list then return false end
        for _, b in ipairs(list) do
            if b and b.Spell and (b.Spell.ID == spellid or tostring(b.Spell.ID) == tostring(spellid)) then return true end
        end
        return false
    end
    return has(peerInfo.Buff) or has(peerInfo.ShortBuff)
end

-- Returns true if peer's pet has spellid in PetBuff.
function spellutils.PeerHasPetBuff(peerInfo, spellid)
    if not peerInfo or not peerInfo.PetBuff then return false end
    for _, b in ipairs(peerInfo.PetBuff) do
        if b and b.Spell and (b.Spell.ID == spellid or tostring(b.Spell.ID) == tostring(spellid)) then return true end
    end
    return false
end

-- Returns true if the spawn already has this heal spell (buff or shortbuff). Used for HoT spells (autodetected via IsHoTSpell)
-- to avoid recasting HoTs. Covers self and peer PCs; non-peers are treated as not having the spell (no targeting).
function spellutils.TargetHasHealSpell(entry, spawnId)
    if not entry or not entry.spell or not spawnId or spawnId <= 0 then return false end
    local myid = mq.TLO.Me.ID()
    if spawnId == myid or spawnId == 1 then
        return mq.TLO.Me.FindBuff(entry.spell)()
    end
    local name = mq.TLO.Spawn(spawnId).Name()
    local peer = charinfo.GetInfo(name)
    if peer then
        local spellid = mq.TLO.Spell(entry.spell).ID()
        return spellutils.PeerHasBuff(peer, spellid)
    end
    return false
end

-- Ensure we have buff data for this spawn (for non-peer buff/cure checks). Buffs only populate after
-- targeting the spawn for a few ms. If not already targeted with BuffsPopulated, /tar and block up to 1s.
-- Returns true when we can read buffs (targeted and BuffsPopulated). Optional args (spellIndex, etc.) kept for API compatibility.
function spellutils.EnsureSpawnBuffsPopulated(spawnId, sub, spellIndex, targethit, cureTypeList, resumePhase,
                                              resumeGroupIndex)
    if not spawnId or not sub then return false end
    if sub == 'buff' then
        local sp = mq.TLO.Spawn(spawnId)
        if sp and sp.Type and sp.Type() == 'Corpse' then return false end
    end
    -- Caster's own buffs: Me.BuffsPopulated() is valid without targeting self; avoid /tar so MT keeps mob targeted.
    if spawnId == mq.TLO.Me.ID() then
        if mq.TLO.Me.BuffsPopulated() then return true end
        state.getRunconfig().statusMessage = string.format('Waiting for target buffs (id %s)', spawnId)
        mq.delay(1000, function() return mq.TLO.Me.BuffsPopulated() == true end)
        local ok = mq.TLO.Me.BuffsPopulated()
        if not ok then state.getRunconfig().statusMessage = '' end
        return ok
    end
    if mq.TLO.Target.ID() == spawnId then
        local sp = mq.TLO.Spawn(spawnId)
        if sp and sp.BuffsPopulated and sp.BuffsPopulated() then return true end
    end
    mq.cmdf('/tar id %s', spawnId)
    state.getRunconfig().statusMessage = string.format('Waiting for target buffs (id %s)', spawnId)
    mq.delay(1000, function() return mq.TLO.Target.BuffsPopulated() == true end)
    local sp = mq.TLO.Spawn(spawnId)
    local ok = sp and sp.BuffsPopulated and sp.BuffsPopulated() and mq.TLO.Target.ID() == spawnId
    if not ok then state.getRunconfig().statusMessage = '' end
    return ok
end

-- Spawn: does this spawn need the buff? Buffs are only available on Spawn (like mobs); you must have
-- targeted the spawn for a few ms until BuffsPopulated is true, then Spawn.Buff() is valid.
-- Call EnsureSpawnBuffsPopulated(spawnId, 'buff') first; if it returns false, do not cast.
-- Returns true only when BuffsPopulated and they do not have the buff. Returns false when not
-- populated or when they already have the buff.
function spellutils.SpawnNeedsBuff(spawnId, spellName, spellicon)
    if not spawnId or not spellName or spellName == '' then return false end
    local sp = mq.TLO.Spawn(spawnId)
    if not sp or not sp.ID() or sp.ID() == 0 then return false end
    if not sp.BuffsPopulated or not sp.BuffsPopulated() then return false end
    -- MQ2 `Buff(spellName)` can return a different buff on partial-name matches.
    -- Only treat it as "has this buff" when the matched buff's spell id equals the configured spell id.
    local spellid
    do
        local ok, id = pcall(function() return mq.TLO.Spell(spellName).ID() end)
        spellid = ok and id or nil
    end

    local buff = sp.Buff(spellName)
    local hasAnyBuffMatchByName = buff and buff() or false
    if not hasAnyBuffMatchByName then return true end
    if not spellid then
        -- Can't resolve spell id: preserve legacy behavior (presence by name means we consider it "already buffed").
        return false
    end

    local matchedBuffId = buff.ID() or nil
    return matchedBuffId ~= spellid
end

-- Spawn: does this spawn have a matching detrimental? Same as buffs: only valid after targeting
-- the spawn until BuffsPopulated is true. Spawn has no Detrimentals/CountXXX; we walk sp.Buff(i)
-- and use TotalCounters to find curable debuffs, then CountersPoison/CountersDisease/etc. on each buff.
function spellutils.SpawnDetrimentalsForCure(spawnId, cureTypeList)
    if not spawnId or not cureTypeList or type(cureTypeList) ~= 'table' then return false end
    local sp = mq.TLO.Spawn(spawnId)
    if not sp or not sp.ID() or sp.ID() == 0 then return false end
    if not sp.BuffsPopulated or not sp.BuffsPopulated() then return false end
    local maxSlots = (sp.MaxBuffSlots and sp.MaxBuffSlots()) or 40
    local countPoison, countDisease, countCurse, countCorruption = 0, 0, 0, 0
    local hasCurable = false
    for i = 1, maxSlots do
        local b = sp.Buff(i)
        if b then
            local total = b.TotalCounters and b.TotalCounters() or 0
            if total > 0 then
                hasCurable = true
                countPoison = countPoison + (b.CountersPoison and b.CountersPoison() or 0)
                countDisease = countDisease + (b.CountersDisease and b.CountersDisease() or 0)
                countCurse = countCurse + (b.CountersCurse and b.CountersCurse() or 0)
                countCorruption = countCorruption + (b.CountersCorruption and b.CountersCorruption() or 0)
            end
        end
    end
    if not hasCurable then return false end
    for _, v in ipairs(cureTypeList) do
        local vlower = string.lower(tostring(v))
        if vlower == 'all' then return true end
        if vlower == 'poison' and countPoison > 0 then return true end
        if vlower == 'disease' and countDisease > 0 then return true end
        if vlower == 'curse' and countCurse > 0 then return true end
        if vlower == 'corruption' and countCorruption > 0 then return true end
    end
    return false
end

local function buffSlotHasSpell(b)
    if not b then return false end
    local ok, id = pcall(function() return b.ID and b.ID() or 0 end)
    return ok and id and id > 0
end

local function isBuffDetrimental(b)
    if not b then return false end
    -- SpellType is authoritative; some debuffs (e.g. rez sickness) mis-report Beneficial().
    local okType, spellType = pcall(function() return b.SpellType and b.SpellType() or '' end)
    if okType and spellType ~= '' then
        if spellType:find('Detrimental') then return true end
        if spellType:find('Beneficial') then return false end
    end
    local ok, beneficial = pcall(function() return b.Beneficial and b.Beneficial() end)
    if ok and beneficial ~= nil then return not beneficial end
    return false
end

local function nonCurableDebuffNameFromBuff(b)
    if not buffSlotHasSpell(b) then return nil end
    if not isBuffDetrimental(b) then return nil end
    local ok, total = pcall(function() return b.TotalCounters and b.TotalCounters() or 0 end)
    if not ok or (total or 0) > 0 then return nil end
    local okName, name = pcall(function() return b.Name and b.Name() or nil end)
    return (okName and name) or 'debuff'
end

local ME_REZ_SICKNESS_SET = {
    ['Resurrection Sickness'] = true,
    ['Revival Sickness'] = true,
}
local ME_CATEGORY_DEBUFFS = { 'Snared', 'Rooted', 'Mezzed', 'Slowed', 'Feared', 'Silenced', 'Charmed', 'Crippled' }

local function meRezSicknessFromSlots()
    local maxBuff = (mq.TLO.Me.MaxBuffSlots and mq.TLO.Me.MaxBuffSlots()) or 40
    for i = 1, maxBuff do
        local b = mq.TLO.Me.Buff(i)
        if buffSlotHasSpell(b) then
            local okName, name = pcall(function() return b.Name and b.Name() or nil end)
            if okName and name and ME_REZ_SICKNESS_SET[name] then return true, name end
        end
    end
    local maxSong = (mq.TLO.Me.MaxSongSlots and mq.TLO.Me.MaxSongSlots()) or 20
    for i = 1, maxSong do
        local b = mq.TLO.Me.Song(i)
        if buffSlotHasSpell(b) then
            local okName, name = pcall(function() return b.Name and b.Name() or nil end)
            if okName and name and ME_REZ_SICKNESS_SET[name] then return true, name end
        end
    end
    return false
end

--- True when the player has a detrimental without counters (snare, rez sickness, etc.).
--- Curable debuffs (poison/disease/curse/corruption with counters) return false.
---@return boolean hasDebuff
---@return string|nil debuffName
function spellutils.MeHasNonCurableDebuff()
    -- Rez sickness is a long buff with no counters; Me.Beneficial can be wrong — match by name via slot index.
    local hasRez, rezName = meRezSicknessFromSlots()
    if hasRez then return true, rezName end

    for _, cat in ipairs(ME_CATEGORY_DEBUFFS) do
        local ok, b = pcall(function()
            local m = mq.TLO.Me[cat]
            return m and m()
        end)
        if ok and b then
            if type(b) == 'string' and b ~= '' then return true, b end
            if buffSlotHasSpell(b) then
                local okName, name = pcall(function() return b.Name and b.Name() or nil end)
                return true, (okName and name) or cat
            end
            return true, cat
        end
    end

    if not mq.TLO.Me.BuffsPopulated or not mq.TLO.Me.BuffsPopulated() then return false end

    local maxBuff = (mq.TLO.Me.MaxBuffSlots and mq.TLO.Me.MaxBuffSlots()) or 40
    for i = 1, maxBuff do
        local name = nonCurableDebuffNameFromBuff(mq.TLO.Me.Buff(i))
        if name then return true, name end
    end
    local maxSong = (mq.TLO.Me.MaxSongSlots and mq.TLO.Me.MaxSongSlots()) or 20
    for i = 1, maxSong do
        local name = nonCurableDebuffNameFromBuff(mq.TLO.Me.Song(i))
        if name then return true, name end
    end
    return false
end

-- Default class order for bot list: healers, tanks, casters, DPS. Used when config does not override.
-- Config: botconfig.getCommon().botListClassOrder = { 'clr', 'shm', 'dru', ... } (lowercase class short names).
spellutils.DEFAULT_BOTLIST_CLASS_ORDER = { 'clr', 'shm', 'dru', 'war', 'shd', 'pal', 'enc', 'wiz', 'mag', 'nec', 'brd',
    'mnk', 'rog', 'bst', 'rng', 'bzk' }

local function _getBotListClassPriority()
    local order = spellutils.DEFAULT_BOTLIST_CLASS_ORDER
    local common = botconfig.getCommon()
    if common and common.botListClassOrder and type(common.botListClassOrder) == 'table' and #common.botListClassOrder > 0 then
        order = common.botListClassOrder
    end
    local priority = {}
    for i, cls in ipairs(order) do
        priority[string.lower(tostring(cls))] = i
    end
    return priority
end

--- Returns priority number for a class short name (lower = earlier in rez/target order). Unknown class returns 9999.
function spellutils.GetClassOrderPriority(classShortName)
    local priority = _getBotListClassPriority()
    return priority[string.lower(tostring(classShortName or ''))] or 9999
end

--- Returns table of bot names from charinfo.GetPeers(), sorted by class order (healers first, then tanks, casters, DPS).
--- Order is configurable via botconfig.getCommon().botListClassOrder (array of lowercase class short names).
function spellutils.GetBotListOrdered()
    local bots = charinfo.GetPeers()
    if not bots or #bots == 0 then return bots end
    local priority = _getBotListClassPriority()
    table.sort(bots, function(a, b)
        local acls = mq.TLO.Spawn('pc =' .. a).Class.ShortName()
        local bcls = mq.TLO.Spawn('pc =' .. b).Class.ShortName()
        acls = acls and string.lower(acls) or ''
        bcls = bcls and string.lower(bcls) or ''
        local ap = priority[acls] or 9999
        local bp = priority[bcls] or 9999
        if ap ~= bp then return ap < bp end
        return (a or '') < (b or '')
    end)
    return bots
end

-- Returns table of bot names from charinfo.GetPeers(), Fisher-Yates shuffled. Prefer GetBotListOrdered for deterministic targeting.
function spellutils.GetBotListShuffled()
    local bots = charinfo.GetPeers()
    for i = #bots, 2, -1 do
        local j = math.random(1, i)
        bots[i], bots[j] = bots[j], bots[i]
    end
    return bots
end

-- Resolve spell name, range, target type from config entry; if gem == 'item' use FindItem spell.
-- entry must have .spell and .gem. Returns spell (name), range, tartype, and optionally spellid.
function spellutils.GetSpellInfo(entry)
    if not entry or not entry.spell then return nil, nil, nil, nil end
    local gem = entry.gem
    local spell = entry.spell
    local range = mq.TLO.Spell(spell).MyRange()
    local tartype = mq.TLO.Spell(spell).TargetType()
    if gem == 'item' then
        spell = mq.TLO.FindItem(spell).Spell.Name()
        if mq.TLO.FindItem(entry.spell)() then
            range = mq.TLO.FindItem(entry.spell).Spell.MyRange()
            tartype = mq.TLO.FindItem(entry.spell).Spell.TargetType()
        end
    end
    local spellid = mq.TLO.Spell(spell).ID() or
        (gem == 'item' and mq.TLO.FindItem(entry.spell)() and mq.TLO.FindItem(entry.spell).Spell.ID())
    return spell, range, tartype, spellid
end

-- Return spell ID for entry, handling gem == 'item' via FindItem.Spell.ID().
function spellutils.GetSpellId(entry)
    if not entry or not entry.spell then return nil end
    local id = mq.TLO.Spell(entry.spell).ID()
    if id then return id end
    if entry.gem == 'item' and mq.TLO.FindItem(entry.spell)() then
        return mq.TLO.FindItem(entry.spell).Spell.ID()
    end
    return nil
end

-- Return the spell TLO for the entry (Spell or FindItem.Spell for items). Nil if neither applies.
function spellutils.GetSpellEntity(entry)
    if not entry or not entry.spell then return nil end
    if entry.gem == 'item' then
        if not mq.TLO.FindItem(entry.spell)() then return nil end
        return mq.TLO.FindItem(entry.spell).Spell
    end
    if entry.gem == 'alt' then
        local aa = mq.TLO.Me.AltAbility(entry.spell)
        if not aa or not aa() then return nil end
        local sp = aa.Spell
        if sp and sp() then return sp end
        return nil
    end
    return mq.TLO.Spell(entry.spell)
end

-- True when MQ spell data says TargetType Self (self-only; no need to retarget to cast).
function spellutils.IsSelfTargetSpell(entry)
    local e = spellutils.GetSpellEntity(entry)
    if not e or not e.TargetType then return false end
    local tt = e.TargetType()
    return type(tt) == 'string' and tt == 'Self'
end

-- Group AE heals: TargetType Group v1 / Group v2 — no forced target; HP-threshold interrupt does not apply.
function spellutils.IsGroupV1OrV2HealEntry(entry)
    local e = spellutils.GetSpellEntity(entry)
    if not e or not e.TargetType then return false end
    local tt = e.TargetType()
    return tt == 'Group v1' or tt == 'Group v2'
end

-- Return duration in seconds for the entry's spell (handles item). Returns 0 if none or invalid.
-- MyDuration() returns ticks (1 tick = 6 sec); use MyDuration.TotalSeconds() for seconds.
function spellutils.GetSpellDurationSec(entry)
    local e = spellutils.GetSpellEntity(entry)
    if not e or not e.MyDuration then return 0 end
    return tonumber(e.MyDuration.TotalSeconds()) or
        0 -- MyDuration() ALWAYS has TotalSeconds() we don't need to check for nil
end

-- Returns true if the debuff entry is a nuke (no duration / direct damage). Used for rotation and flavor filtering.
function spellutils.IsNukeSpell(entry)
    if not entry or not entry.spell then return false end
    if entry.gem == 'disc' or entry.gem == 'ability' then return false end
    return spellutils.GetSpellDurationSec(entry) == 0
end

-- MQ Spell.ResistType() -> normalized flavor string. Returns nil if unknown or no entity.
local RESIST_TYPE_TO_FLAVOR = {
    ['Cold'] = 'ice',
    ['Fire'] = 'fire',
    ['Magic'] = 'magic',
    ['Poison'] = 'poison',
    ['Disease'] = 'disease',
    ['Chromatic'] = 'chromatic',
    ['Prismatic'] = 'prismatic',
    ['Unresistable'] = 'unresistable',
    ['Corruption'] = 'corruption',
}

function spellutils.GetNukeFlavor(entry)
    local e = spellutils.GetSpellEntity(entry)
    if not e then return nil end
    local rt = e.ResistType and e.ResistType() or e.ResistType
    if type(rt) == 'function' then rt = rt(e) end
    if not rt or type(rt) ~= 'string' then return nil end
    return RESIST_TYPE_TO_FLAVOR[rt] or rt:lower()
end

-- Return whether the spell stacks on the given spawn (handles item). Nil/false if no stack or no entity.
function spellutils.SpellStacksSpawn(entry, spawnId)
    local e = spellutils.GetSpellEntity(entry)
    return e and e.StacksSpawn(spawnId)()
end

-- SPA 22 = Charm (MacroQuest spelleffects.h). Returns true if the spell for entry has the Charm effect.
-- Do not store mq.TLO.Spell() proxy; use direct chains (see HasReagents comment).
function spellutils.IsCharmSpell(entry)
    if not entry or not entry.spell then return false end
    if entry.gem == 'item' then
        if not mq.TLO.FindItem(entry.spell)() then return false end
        local ok, hasCharm = pcall(function() return mq.TLO.FindItem(entry.spell).Spell.HasSPA(22)() end)
        if ok and hasCharm then return true end
        local ok2, cat = pcall(function() return mq.TLO.FindItem(entry.spell).Spell.Category() end)
        local ok3, sub = pcall(function() return mq.TLO.FindItem(entry.spell).Spell.Subcategory() end)
        if cat and type(cat) == 'string' and cat:lower():find('charm') then return true end
        if sub and type(sub) == 'string' and sub:lower():find('charm') then return true end
        return false
    end
    if not mq.TLO.Spell(entry.spell)() then return false end
    local ok, hasCharm = pcall(function() return mq.TLO.Spell(entry.spell).HasSPA(22)() end)
    if ok and hasCharm then return true end
    local ok2, cat = pcall(function() return mq.TLO.Spell(entry.spell).Category() end)
    local ok3, sub = pcall(function() return mq.TLO.Spell(entry.spell).Subcategory() end)
    if cat and type(cat) == 'string' and cat:lower():find('charm') then return true end
    if sub and type(sub) == 'string' and sub:lower():find('charm') then return true end
    return false
end

-- Returns true if the spell is a mez (Enthrall subcategory). Used for GUI label and level checks.
function spellutils.IsMezSpell(entry)
    if not entry or not entry.spell then return false end
    local e = spellutils.GetSpellEntity(entry)
    if not e then return false end
    local sub = e.Subcategory and e.Subcategory() or e.Subcategory
    if type(sub) == 'function' then sub = sub(e) end
    return sub and type(sub) == 'string' and sub == 'Enthrall'
end

-- Returns true if the spell is targeted AE (radius around target) with AERange > 0.
function spellutils.IsTargetedAESpell(entry)
    if not entry or not entry.spell then return false end
    local spell, _, tartype = spellutils.GetSpellInfo(entry)
    if not spell or tartype ~= 'Targeted AE' then return false end
    local aerange = 0
    if entry.gem == 'item' then
        if mq.TLO.FindItem(entry.spell)() then aerange = mq.TLO.FindItem(entry.spell).Spell.AERange() or 0 end
    else
        aerange = mq.TLO.Spell(spell).AERange() or 0
    end
    return aerange > 0
end

-- True only for single-target group-only spells (e.g. Shrink, alliance). Requires TargetType Single and SpellType containing (Group). Excludes Beneficial(Group) group buffs (Group v1/v2) that can be cast via target-group-buff AAs.
function spellutils.IsGroupOnlySpell(entry)
    local e = spellutils.GetSpellEntity(entry)
    if not e then return false end
    local okSt, st = pcall(function() return e.SpellType() end)
    if not okSt or not st or type(st) ~= 'string' or not st:find('%(Group%)') then return false end
    local okTt, tt = pcall(function() return e.TargetType() end)
    if not okTt or not tt or type(tt) ~= 'string' or tt ~= 'Single' then return false end
    return true
end

-- Returns true if spawnId is the caster or any group member (Member(0) is self).
function spellutils.IsSpawnInMyGroup(spawnId)
    if not spawnId or spawnId <= 0 then return false end
    local members = mq.TLO.Group.Members()
    if not members or members < 0 then return false end
    for i = 0, members do
        local grpid = mq.TLO.Group.Member(i).ID()
        if grpid and grpid == spawnId then return true end
    end
    return false
end

-- SPA 100 = HoT Heals (MacroQuest spelleffects.h). Returns true if the spell for entry has the HoT effect.
-- Do not store mq.TLO.Spell() proxy; use direct chains (see HasReagents comment).
function spellutils.IsHoTSpell(entry)
    if not entry or not entry.spell then return false end
    if entry.gem == 'item' then
        if not mq.TLO.FindItem(entry.spell)() then return false end
        local ok, hasHoT = pcall(function() return mq.TLO.FindItem(entry.spell).Spell.HasSPA(100)() end)
        return ok and hasHoT
    end
    if not mq.TLO.Spell(entry.spell)() then return false end
    local ok, hasHoT = pcall(function() return mq.TLO.Spell(entry.spell).HasSPA(100)() end)
    return ok and hasHoT
end

-- Returns true if the spell is a pet summon (Category Pet, or SPA 33 SUMMON_PET / SPA 103 CALL_PET).
-- Do not store mq.TLO.Spell() proxy; use direct chains (see HasReagents comment).
function spellutils.IsPetSummonSpell(entry)
    if not entry or not entry.spell then return false end
    if entry.gem == 'item' then
        if not mq.TLO.FindItem(entry.spell)() then return false end
        local okCat, cat = pcall(function() return mq.TLO.FindItem(entry.spell).Spell.Category() end)
        if okCat and cat and type(cat) == 'string' and cat == 'Pet' then return true end
        local ok33, has33 = pcall(function() return mq.TLO.FindItem(entry.spell).Spell.HasSPA(33)() end)
        if ok33 and has33 then return true end
        local ok103, has103 = pcall(function() return mq.TLO.FindItem(entry.spell).Spell.HasSPA(103)() end)
        return ok103 and has103
    end
    if not mq.TLO.Spell(entry.spell)() then return false end
    local okCat, cat = pcall(function() return mq.TLO.Spell(entry.spell).Category() end)
    if okCat and cat and type(cat) == 'string' and cat == 'Pet' then return true end
    local ok33, has33 = pcall(function() return mq.TLO.Spell(entry.spell).HasSPA(33)() end)
    if ok33 and has33 then return true end
    local ok103, has103 = pcall(function() return mq.TLO.Spell(entry.spell).HasSPA(103)() end)
    return ok103 and has103
end

-- SPA 92 = Concussion / aggro reduction (MacroQuest spelleffects.h). Returns true if the spell for entry has the Concussion effect.
-- Do not store mq.TLO.Spell() proxy; use direct chains (see HasReagents comment).
function spellutils.IsConcussionSpell(entry)
    if not entry or not entry.spell then return false end
    if entry.gem == 'item' then
        if not mq.TLO.FindItem(entry.spell)() then return false end
        local ok, hasConc = pcall(function() return mq.TLO.FindItem(entry.spell).Spell.HasSPA(92)() end)
        return ok and hasConc
    end
    if not mq.TLO.Spell(entry.spell)() then return false end
    local ok, hasConc = pcall(function() return mq.TLO.Spell(entry.spell).HasSPA(92)() end)
    return ok and hasConc
end

--- When MT/MA is self, charinfo may lag; use Target if it is in MobList.
local function selfTargetIdFromMobList()
    local tid = mq.TLO.Target.ID()
    if not tid or tid == 0 then return nil, nil end
    local ml = state.getRunconfig().MobList
    if not ml then return nil, nil end
    for _, v in ipairs(ml) do
        if v.ID() == tid then
            return tid, mq.TLO.Target.PctHPs()
        end
    end
    return nil, nil
end

-- Tank = Main Tank only (heals). Uses GetPCTarget for MT's target when needed. Assist/MA is not used here.
function spellutils.GetTankInfo(includeTarget)
    local mainTankName = state.getRunconfig().TankName
    if mainTankName == 'automatic' then
        local mtn = tankrole.GetMainTankName()
        if mtn then mainTankName = mtn end
    end
    if not mainTankName or mainTankName == '' then return nil, nil, nil, nil end
    local tankid = mq.TLO.Spawn('pc =' .. mainTankName).ID()
    if not includeTarget then return mainTankName, tankid, nil, nil end
    local tanktar, tanktarhp
    local info = charinfo.GetInfo(mainTankName)
    if info and info.ID then
        tanktar = info.Target and info.Target.ID or nil
        tanktarhp = info.TargetHP
    elseif tankid then
        local botmelee = require('botmelee')
        tanktar = botmelee.GetPCTarget(mainTankName)
        tanktarhp = tanktar and mq.TLO.Spawn(tanktar).PctHPs() or nil
    end
    if includeTarget and mainTankName == mq.TLO.Me.Name() and (not tanktar or tanktar == 0) then
        local t, h = selfTargetIdFromMobList()
        if t then tanktar, tanktarhp = t, h end
    end
    if tanktar == 0 then tanktar = nil end
    return mainTankName, tankid, tanktar, tanktarhp
end

--- True when the MA spawn is missing, dead, or hovering (no reliable live target).
local function isAssistUnavailable(assistName, assistid)
    if not assistid or assistid == 0 then
        assistid = assistName and mq.TLO.Spawn('pc =' .. assistName).ID() or nil
    end
    if not assistid or assistid == 0 then return true end
    local spawn = mq.TLO.Spawn(assistid)
    return spawn.Dead() or spawn.Hovering()
end

--- Clear lastAssistTargetId when the cached spawn is no longer alive.
local function clearLastAssistTargetIfDead(rc)
    local cached = rc.lastAssistTargetId
    if cached and not spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(cached)) then
        rc.lastAssistTargetId = nil
    end
end

-- Assist = Main Assist only (whose target DPS/OT follow).
-- Mirrors GetTankInfo but resolves from AssistName (and does not depend on MT).
-- Optional assistpct updates the last-target cache when MA is actively assisting.
-- Returns fromCache (5th value) when the target came from lastAssistTargetId (MA dead/hover).
function spellutils.GetAssistInfo(includeTarget, assistpct)
    local assistName = tankrole.GetAssistTargetName()
    if not assistName or assistName == '' then return nil, nil, nil, nil end

    local assistid = mq.TLO.Spawn('pc =' .. assistName).ID()
    if not includeTarget then return assistName, assistid, nil, nil end

    local rc = state.getRunconfig()
    clearLastAssistTargetIfDead(rc)

    local unavailable = isAssistUnavailable(assistName, assistid)
    local assistar, assistarhp
    local info = charinfo.GetInfo(assistName)
    if info and info.ID then
        assistar = info.Target and info.Target.ID or nil
        assistarhp = info.TargetHP
    elseif assistid and not unavailable then
        local botmelee = require('botmelee')
        assistar = botmelee.GetPCTarget(assistName)
        assistarhp = assistar and mq.TLO.Spawn(assistar).PctHPs() or nil
    end
    if includeTarget and assistName == mq.TLO.Me.Name() and (not assistar or assistar == 0) then
        local t, h = selfTargetIdFromMobList()
        if t then assistar, assistarhp = t, h end
    end

    if assistar == 0 then assistar = nil end

    local pct = assistpct
    if pct == nil then
        pct = (botconfig.config.melee and botconfig.config.melee.assistpct) or 99
    end

    if assistar and assistar > 0 then
        local hp = assistarhp or mq.TLO.Spawn(assistar).PctHPs()
        if hp and hp <= pct then
            rc.lastAssistTargetId = assistar
        end
    end

    local fromCache = false
    if unavailable and (not assistar or assistar == 0) then
        local cached = rc.lastAssistTargetId
        if cached and spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(cached)) then
            assistar = cached
            assistarhp = mq.TLO.Spawn(cached).PctHPs()
            fromCache = true
        end
    end

    if assistar == 0 then assistar = nil end
    return assistName, assistid, assistar, assistarhp, fromCache
end

-- Canonicalize debuff targetphase tokens.
-- Back-compat: accepts legacy `tanktar`/`notanktar` and normalizes them.
function spellutils.NormalizeDebuffTargetPhase(token)
    if token == 'tanktar' then return 'matar' end
    if token == 'notanktar' then return 'notmatar' end
    return token
end

-- Normalize an array of targetphase tokens (or return as-is when not an array).
function spellutils.NormalizeDebuffTargetPhaseList(tokens)
    if type(tokens) ~= 'table' then return tokens end
    local out = {}
    for _, t in ipairs(tokens) do
        out[#out + 1] = spellutils.NormalizeDebuffTargetPhase(t)
    end
    return out
end

local _mezDbgNextTime = 0
local MEZ_DBG_INTERVAL_MS = 2000

--- Mez diagnostic with session ms timestamp (unthrottled).
function spellutils.MezLog(fmt, ...)
    printf('\ayCZBot:\ax [Mez t=%s] ' .. fmt, tostring(mq.gettime()), ...)
end

--- Throttled mez/debuff resume diagnostic (see botdebuff multi-mez debugging).
function spellutils.DbgMezTrace(fmt, ...)
    local now = mq.gettime()
    if now < _mezDbgNextTime then return end
    _mezDbgNextTime = now + MEZ_DBG_INTERVAL_MS
    spellutils.MezLog(fmt, ...)
end

--- True when spawn has the named detrimental (uses Spawn TLO, not current Target).
function spellutils.SpawnHasDebuffSpell(spellName, spawnId)
    if not spawnId or spawnId <= 0 or not spellName or spellName == '' then return false end
    local sp = mq.TLO.Spawn(spawnId)
    if not sp or not sp.ID() or sp.ID() ~= spawnId then return false end
    local buff = sp.Buff(spellName)
    if buff and buff() and buff.ID() and buff.ID() > 0 then
        local ok, dur = pcall(function() return buff.Duration and buff.Duration() or 0 end)
        return (ok and dur or 0) > MEZ_ACTIVE_MIN_MS
    end
    return false
end

local function spawnHasDebuffSpell(spellName, spawnId)
    return spellutils.SpawnHasDebuffSpell(spellName, spawnId)
end

local function resolveSpellcheckResumePayload(p)
    if not p then return nil end
    if p.spellcheckResume and p.spellcheckResume.hook then
        return p.spellcheckResume
    end
    if state.isResumeState(state.getRunState()) and p.hook then
        return p
    end
    return nil
end

local function shouldSetHookResumeAfterCast(sr)
    return sr and sr.hook and sr.hook ~= 'doDebuff' and state.RESUME_BY_HOOK[sr.hook] ~= nil
end

--- Debuff casts use CurSpell.target; Target TLO is often cleared mid-cast — do not abort completion polling.
local function castTargetDriftBlocksReentry(rc)
    if not rc.CurSpell or not rc.CurSpell.target then return false end
    if rc.CurSpell.target == mq.TLO.Me.ID() then return false end
    if mq.TLO.Target.ID() == rc.CurSpell.target then return false end
    if rc.CurSpell.sub == 'debuff' then return false end
    return true
end

-- Post-cast logic when CastTimeLeft() has reached 0 (called from handleSpellCheckReentry / phase-first re-entry).
function spellutils.OnCastComplete(index, EvalID, targethit, sub)
    local rc = state.getRunconfig()
    local entry = botconfig.getSpellEntry(sub, index)
    if not entry then return end
    local spell = string.lower(entry.spell or '')
    local spellid = mq.TLO.Spell(spell).ID()
    if not rc.CurSpell.viaMQ2Cast and not rc.CurSpell.viaCastingLib and SpellResisted then
        rc.CurSpell.resisted = true
        SpellResisted = false
    end
    if sub == 'debuff' then
        if entry.delay and entry.delay > 0 then
            spellstates.SetDebuffDelay(index, mq.gettime() + (entry.delay * 1000))
        end
        if spellutils.IsNukeSpell(entry) and not spellutils.IsConcussionSpell(entry) then
            rc.lastNukeIndex = index
        end
        local durationSec = spellutils.GetSpellDurationSec(entry)
        if durationSec > 0 then
            local buffPresent = spawnHasDebuffSpell(spell, EvalID)
            if not buffPresent and mq.TLO.Me.Class.ShortName() == 'BRD' and not rc.MissedNote then
                buffPresent = true
            end
            if not buffPresent and EvalID and spellutils.IsMezSpell(entry)
                and not spellutils.SpellStacksSpawn(entry, EvalID) then
                buffPresent = true
            end
            if buffPresent then
                local myduration = durationSec * 1000 + mq.gettime()
                if EvalID and spellutils.IsMezSpell(entry) then
                    local remMs = spellutils.SpawnEnthrallRemainingMs(EvalID)
                    if remMs > 0 then
                        myduration = mq.gettime() + remMs
                    end
                end
                if not rc.CurSpell.resisted then
                    spellstates.DebuffListUpdate(EvalID, entry.spell, myduration)
                    spellstates.ResetRecastCounter(EvalID, index)
                end
            end
        end
        if spellutils.IsConcussionSpell(entry) then
            if EvalID then spellstates.ResetConcussionCounter(EvalID) end
        elseif not rc.CurSpell.resisted and EvalID then
            spellstates.IncrementConcussionCounter(EvalID)
        end
    end
    if rc.MissedNote then rc.MissedNote = false end
end

-- ---------------------------------------------------------------------------
-- Phase-first spell-check utilities (small, reusable)
-- ---------------------------------------------------------------------------

--- Returns resume cursor if run state is this hook's resume state (numeric), else nil.
function spellutils.getResumeCursor(hookName)
    if state.getRunState() ~= state.RESUME_BY_HOOK[hookName] then return nil end
    return state.getRunStatePayload()
end

--- True when spawn exists, is targetable, and (optionally) is in camp mob list.
function spellutils.isSpawnValidCastTarget(spawnId, mobList)
    if not spawnId or spawnId <= 0 then return false end
    local sp = mq.TLO.Spawn(spawnId)
    if not sp or not sp.ID() or sp.ID() ~= spawnId then return false end
    local typ = sp.Type and sp.Type()
    if typ == 'Corpse' or typ == 'Untargetable' then return false end
    if mobList then
        for _, v in ipairs(mobList) do
            local vid = v.ID and v.ID() or v
            if vid == spawnId then return true end
        end
        return false
    end
    return true
end

local HOOK_SETTING_AND_SECTION = {
    doHeal = { setting = 'doheal', section = 'heal', travelAllowed = true },
    doDebuff = { setting = 'dodebuff', section = 'debuff', travelAllowed = true },
    doBuff = { setting = 'dobuff', section = 'buff', travelAllowed = false },
    doCure = { setting = 'docure', section = 'cure', travelAllowed = true },
    priorityCure = { setting = 'docure', section = 'cure', travelAllowed = true },
}

--- Mirrors hook early-return guards: true when the hook would run spell check this tick.
function spellutils.isSpellHookActive(hookName)
    local cfg = HOOK_SETTING_AND_SECTION[hookName]
    if not cfg then return true end
    local myconfig = botconfig.config
    if state.isTravelMode() then
        if not cfg.travelAllowed then return false end
        if not state.isTravelAttackOverriding() then return false end
    end
    if hookName == 'doDebuff' and utils.isNonCombatZone(mq.TLO.Zone.ShortName()) then return false end
    if (hookName == 'doDebuff' or hookName == 'doBuff') and utils.isNearPrimaryBindPoint() then return false end
    if botmove.isBeyondFollowDistance() then return false end
    local settingOn = myconfig.settings[cfg.setting] or state.isTravelAttackOverriding()
    if hookName == 'doBuff' and state.isTravelMode() then return false end
    if not settingOn then return false end
    local spells = myconfig[cfg.section] and myconfig[cfg.section].spells
    return spells and #spells > 0
end

--- Clear resume/casting spell state when the owning hook is inactive or debuff camp is empty.
function spellutils.clearOrphanedSpellStateIfNeeded()
    local rc = state.getRunconfig()
    local rs = state.getRunState()

    for hookName, resumeNum in pairs(state.RESUME_BY_HOOK) do
        if rs == resumeNum and not spellutils.isSpellHookActive(hookName) then
            state.clearRunState()
            rc.CurSpell = {}
            rc.statusMessage = ''
            return
        end
    end

    if rs == state.STATES.casting and rc.CurSpell and rc.CurSpell.sub then
        local subToHook = { heal = 'doHeal', debuff = 'doDebuff', buff = 'doBuff', cure = 'doCure' }
        local hookName = subToHook[rc.CurSpell.sub]
        if hookName and not spellutils.isSpellHookActive(hookName) then
            spellutils.clearCastingStateOrResume()
        end
    end
end

local function tryClearBlockedDebuffAbilityResume(hookName, sub, cursor, getTargetsFn, context)
    if hookName ~= 'doDebuff' or sub ~= 'debuff' or not cursor or not cursor.spellIndex or not cursor.phase then
        return false
    end
    local entry = botconfig.getSpellEntry('debuff', cursor.spellIndex)
    if not entry or (entry.gem ~= 'ability' and entry.gem ~= 'disc') then return false end
    local targets = getTargetsFn(cursor.phase, context)
    local target = targets and targets[cursor.targetIndex or 1]
    local targetId = target and target.id
    local mobList = context and context.mobList
    if not spellutils.isSpawnValidCastTarget(targetId, mobList)
        or not spellutils.CheckGemReadiness('debuff', cursor.spellIndex, entry) then
        state.clearRunState()
        return true
    end
    return false
end

--- When another sub owns CurSpell, clear if precast/cast deadline expired (foreign hook may not run).
local function clearForeignCurSpellIfExpired(sub, rc)
    if not rc.CurSpell or not rc.CurSpell.sub or rc.CurSpell.sub == sub then return false end
    if spellutils.IsMemorizing() then return false end
    local phase = rc.CurSpell.phase
    if phase ~= 'precast' and phase ~= 'precast_wait_move' and phase ~= 'casting' then return false end
    local deadlinePassed = mq.gettime() >= (rc.CurSpell.deadline or 0)
    if state.getRunState() == state.STATES.casting and state.runStateDeadlinePassed() then
        deadlinePassed = true
    end
    if not deadlinePassed then return false end
    if phase == 'casting' and (mq.TLO.Me.CastTimeLeft() or 0) > 0 then return false end
    spellutils.clearCastingStateOrResume()
    return true
end

--- Single exit from casting: clears CurSpell/statusMessage, then sets hookName_resume (if spellcheckResume) or clearRunState().
--- All code that leaves the "casting" busy state must call this so CurSpell and runState stay in sync.
function spellutils.clearCastingStateOrResume()
    local rc = state.getRunconfig()
    local hadSub = rc.CurSpell and rc.CurSpell.sub
    if mq.TLO.Me.Class.ShortName() == 'BRD' and hadSub and (hadSub == 'buff' or hadSub == 'debuff' or hadSub == 'cure') then
        bardtwist.ResumeTwist()
    end
    rc.CurSpell = {}
    rc.statusMessage = ''
    casting.clear()
    local sr = resolveSpellcheckResumePayload(state.getRunStatePayload())
    if shouldSetHookResumeAfterCast(sr) then
        state.setRunState(state.RESUME_BY_HOOK[sr.hook], sr)
    else
        state.clearRunState()
    end
end

--- True when MQ2Cast is memorizing (spell into gem). Cast.Status() contains 'M'; no cast bar yet (CastTimeLeft 0) to distinguish from HoT channeling.
function spellutils.IsMemorizing()
    local rc = state.getRunconfig()
    if not rc.CurSpell or (not rc.CurSpell.viaMQ2Cast and not rc.CurSpell.viaCastingLib) then return false end
    return casting.isMemorizing()
end

--- When resuming a cast, use bothooks priority for spellcheckResume.hook so an earlier hook (e.g. doHeal) does not pass wrong runPriority to another sub's CurSpell (e.g. buff).
local function spellRunPriorityForResume(options, rc)
    local sr = rc.CurSpell and rc.CurSpell.spellcheckResume
    if sr and sr.hook then
        local hp = bothooks.getPriority(sr.hook)
        if hp then return hp end
    end
    return options and options.runPriority
end

local _buffResumeDbgNextTime = 0
local BUFF_RESUME_DBG_INTERVAL_MS = 1000
local function dbgBuffResumeTrace(phase, callerSub, options, rc)
    local cs = rc.CurSpell
    if not cs or cs.sub ~= 'buff' then return end
    local optPri = options and options.runPriority
    local resolved = spellRunPriorityForResume(options, rc)
    if optPri == resolved and callerSub == 'buff' then return end
    local now = mq.gettime()
    if now < _buffResumeDbgNextTime then return end
    _buffResumeDbgNextTime = now + BUFF_RESUME_DBG_INTERVAL_MS
    local hook = cs.spellcheckResume and cs.spellcheckResume.hook
    printf('\ayCZBot:\ax [buff-resume] %s callerSub=%s optPri=%s resolvedPri=%s resumeHook=%s', tostring(phase),
        tostring(callerSub), tostring(optPri), tostring(resolved), tostring(hook))
end

--- Handles CurSpell re-entry (casting, precast, precast_wait_move). Returns true if handled (caller should return), false to run the phase-first loop.
function spellutils.handleSpellCheckReentry(sub, options)
    options = options or {}
    local skipInterruptForBRD = options.skipInterruptForBRD ~= false
    local rc = state.getRunconfig()
    casting.tick()

    -- Stuck casting recovery: clear if we've been in casting state past deadline. Do not clear while memorizing or bard mez wait.
    if state.getRunState() == state.STATES.casting and state.runStateDeadlinePassed() then
        if not rc.bardNotmatarWait and not spellutils.IsMemorizing() then
            spellutils.clearCastingStateOrResume()
            return false
        end
    end

    -- Heal: clear casting state when target is above interrupt threshold (e.g. 100%), even if Cast.Status() has 'M' (HoT) or completion wasn't detected. Skip when memorizing.
    if not spellutils.IsMemorizing() and rc.CurSpell and rc.CurSpell.phase == 'casting' and rc.CurSpell.sub == 'heal' and rc.CurSpell.target and mq.TLO.Target.ID() == rc.CurSpell.target then
        local entry = botconfig.getSpellEntry('heal', rc.CurSpell.spell)
        if entry then
            spellutils.InterruptCheckHealThreshold(rc, 'heal', rc.CurSpell.targethit, rc.CurSpell.spell, mq.TLO.Target,
                rc.CurSpell.target, entry)
            if not rc.CurSpell.phase then
                return false
            end
        end
    end

    if rc.CurSpell and rc.CurSpell.phase == 'cast_complete_pending_resist' then
        spellutils.OnCastComplete(rc.CurSpell.spell, rc.CurSpell.target, rc.CurSpell.targethit, rc.CurSpell.sub)
        if options.afterCast then
            options.afterCast(rc.CurSpell.spell, rc.CurSpell.target, rc.CurSpell.targethit)
        end
        spellutils.clearCastingStateOrResume()
        return true
    end

    -- MQ2Cast completion: poll Cast.Status and Cast.Result; do not use CastTimeLeft.
    if rc.CurSpell and rc.CurSpell.phase == 'casting' and (rc.CurSpell.viaMQ2Cast or rc.CurSpell.viaCastingLib) then
        if castTargetDriftBlocksReentry(rc) then
            spellutils.clearCastingStateOrResume()
            return false
        end
        if (not skipInterruptForBRD or mq.TLO.Me.Class.ShortName() ~= 'BRD') and not spellutils.IsMemorizing() then
            spellutils.InterruptCheck()
        end
        local status = casting.status() or ''
        local storedId = casting.storedSpellId() or 0
        local castResult = casting.result() or ''
        local idleLike = (not string.find(status, 'C') and not string.find(status, 'M') and storedId == (rc.CurSpell.spellid or 0))
        local complete = idleLike and CASTING_LIB_SUCCESS_RESULTS[castResult]
        if idleLike and not complete then
            printf('\ayCZBot:\ax cast lib finished without success (\ar%s\ax) sub=\at%s\ax spellidx=\at%s\ax', castResult,
                tostring(rc.CurSpell.sub), tostring(rc.CurSpell.spell))
            spellutils.clearCastingStateOrResume()
            return false
        end
        if complete then
            rc.CurSpell.resisted = (castResult == 'CAST_RESIST')
            if castResult == 'CAST_IMMUNE' and rc.CurSpell.target then
                immune.processList(rc.CurSpell.target)
            end
            if castResult == 'CAST_TAKEHOLD' and rc.CurSpell.sub == 'debuff' and rc.CurSpell.target then
                local entry = botconfig.getSpellEntry('debuff', rc.CurSpell.spell)
                if entry and entry.spell then
                    spellstates.DebuffListUpdate(rc.CurSpell.target, entry.spell, mq.gettime() + BLOCKED_SKIP_MS)
                    local spawnName = mq.TLO.Spawn(rc.CurSpell.target).CleanName() or tostring(rc.CurSpell.target)
                    printf('\ayCZBot:\ax %s did not take hold on \at%s\ax (blocked); skipping for %d min', entry.spell,
                        spawnName, math.floor(BLOCKED_SKIP_MS / 60000))
                end
            end
            spellutils.OnCastComplete(rc.CurSpell.spell, rc.CurSpell.target, rc.CurSpell.targethit, rc.CurSpell.sub)
            if options.afterCast then
                options.afterCast(rc.CurSpell.spell, rc.CurSpell.target, rc.CurSpell.targethit)
            end
            spellutils.clearCastingStateOrResume()
            return true
        end
        if sub == rc.CurSpell.sub then
            return true
        end
    end

    if rc.CurSpell and rc.CurSpell.sub and rc.CurSpell.phase == 'casting' and not rc.CurSpell.viaMQ2Cast and not rc.CurSpell.viaCastingLib then
        if castTargetDriftBlocksReentry(rc) then
            spellutils.clearCastingStateOrResume()
            return false
        end
        if mq.TLO.Me.CastTimeLeft() > 0 and (not skipInterruptForBRD or mq.TLO.Me.Class.ShortName() ~= 'BRD') then
            spellutils.InterruptCheck()
        end
        if mq.TLO.Me.CastTimeLeft() > 0 then
            if sub == rc.CurSpell.sub then
                return true
            end
        else
            local entry = botconfig.getSpellEntry(rc.CurSpell.sub, rc.CurSpell.spell)
            local gem = entry and entry.gem
            if rc.CurSpell.sub == 'debuff' and (gem == 'ability' or gem == 'disc') then
                spellutils.OnCastComplete(rc.CurSpell.spell, rc.CurSpell.target, rc.CurSpell.targethit, rc.CurSpell.sub)
                if options.afterCast then
                    options.afterCast(rc.CurSpell.spell, rc.CurSpell.target, rc.CurSpell.targethit)
                end
                spellutils.clearCastingStateOrResume()
                return true
            elseif rc.CurSpell.sub ~= 'debuff' then
                spellutils.OnCastComplete(rc.CurSpell.spell, rc.CurSpell.target, rc.CurSpell.targethit, rc.CurSpell.sub)
                if options.afterCast then
                    options.afterCast(rc.CurSpell.spell, rc.CurSpell.target, rc.CurSpell.targethit)
                end
                spellutils.clearCastingStateOrResume()
                return true
            end
            rc.CurSpell.phase = 'cast_complete_pending_resist'
            return true
        end
    end

    if rc.CurSpell and rc.CurSpell.phase == 'precast_wait_move' then
        if rc.CurSpell.sub ~= sub then
            if clearForeignCurSpellIfExpired(sub, rc) then return false end
            return true
        end
        if mq.TLO.Me.Moving() then
            if mq.gettime() < (rc.CurSpell.deadline or 0) then return true end
            spellutils.clearCastingStateOrResume()
            return true
        end
        local rp = spellRunPriorityForResume(options, rc)
        dbgBuffResumeTrace('precast_wait_move', sub, options, rc)
        spellutils.CastSpell(rc.CurSpell.spell, rc.CurSpell.target, rc.CurSpell.targethit, rc.CurSpell.sub, rp,
            rc.CurSpell.spellcheckResume)
        return true
    end

    if rc.CurSpell and rc.CurSpell.phase == 'precast' then
        if rc.CurSpell.sub ~= sub then
            if clearForeignCurSpellIfExpired(sub, rc) then return false end
            return true
        end
        local preEntry = botconfig.getSpellEntry(rc.CurSpell.sub, rc.CurSpell.spell)
        local skipPrecastTargetWait = preEntry and rc.CurSpell.target == mq.TLO.Me.ID() and
            (spellutils.IsSelfTargetSpell(preEntry) or
                (rc.CurSpell.sub == 'heal' and spellutils.IsGroupV1OrV2HealEntry(preEntry)))
        if mq.TLO.Target.ID() ~= rc.CurSpell.target and not skipPrecastTargetWait then
            if mq.gettime() < (rc.CurSpell.deadline or 0) then return true end
            spellutils.clearCastingStateOrResume()
            return true
        end
        local rp = spellRunPriorityForResume(options, rc)
        dbgBuffResumeTrace('precast', sub, options, rc)
        spellutils.CastSpell(rc.CurSpell.spell, rc.CurSpell.target, rc.CurSpell.targethit, rc.CurSpell.sub, rp,
            rc.CurSpell.spellcheckResume)
        return true
    end

    -- Another sub is casting; do not run our phase loop or we overwrite CurSpell and get stuck (e.g. heal fizzles, we set CurSpell=buff, storedId stays heal).
    if rc.CurSpell and rc.CurSpell.phase == 'casting' and rc.CurSpell.sub and rc.CurSpell.sub ~= sub then
        if clearForeignCurSpellIfExpired(sub, rc) then return false end
        return true
    end

    return false
end

--- Returns list of spell indices (1..count) for which the band has the phase.
--- bandHasPhaseFnOrTable: function(spellIndex, phase) or band table (uses castutils.bandHasPhaseSimple).
function spellutils.getSpellIndicesForPhase(count, phase, bandHasPhaseFnOrTable)
    if not bandHasPhaseFnOrTable then return {} end
    local out = {}
    local check = type(bandHasPhaseFnOrTable) == 'function'
        and bandHasPhaseFnOrTable
        or function(i, p) return castutils.bandHasPhaseSimple(bandHasPhaseFnOrTable, i, p) end
    for i = 1, count do
        if check(i, phase) then
            out[#out + 1] = i
        end
    end
    return out
end

--- For one target, finds first spell in spellIndices that needs to be cast. Returns spellIndex, EvalID, targethit or nil.
--- phase: optional; when provided (e.g. heal), passed to targetNeedsSpellFn as fifth argument for per-phase logic.
function spellutils.checkIfTargetNeedsSpells(sub, spellIndices, targetId, targethit, context, options, targetNeedsSpellFn,
                                             phase)
    if not targetNeedsSpellFn or not spellIndices then return nil end
    options = options or {}
    local rc = state.getRunconfig()
    for _, spellIndex in ipairs(spellIndices) do
        if MasterPause then return nil end
        local spellNotInBook = rc.spellNotInBook and rc.spellNotInBook[sub] and rc.spellNotInBook[sub][spellIndex]
        local entryValid = not options.entryValid or options.entryValid(spellIndex)
        if not spellNotInBook and entryValid then
            local EvalID, hit = targetNeedsSpellFn(spellIndex, targetId, targethit, context, phase)
            if EvalID and hit then
                local entry = botconfig.getSpellEntry(sub, spellIndex)
                local mezDbg = options.mezDebug and sub == 'debuff' and phase == 'notmatar'
                    and entry and spellutils.IsMezSpell(entry)
                if not options.beforeCast or options.beforeCast(spellIndex, EvalID, hit) then
                    if not options.immuneCheck or spellutils.ImmuneCheck(sub, spellIndex, EvalID) then
                        if spellutils.PreCondCheck(sub, spellIndex, EvalID) then
                            return spellIndex, EvalID, hit
                        elseif mezDbg then
                            spellutils.MezLog('reject idx=%s id=%s: precondition failed', spellIndex, EvalID)
                        end
                    elseif mezDbg then
                        spellutils.MezLog('reject idx=%s id=%s: immune', spellIndex, EvalID)
                    end
                elseif mezDbg then
                    spellutils.MezLog('reject idx=%s id=%s: beforeCast', spellIndex, EvalID)
                end
            end
        end
    end
    return nil
end

--- Thin phase-first orchestrator. phaseOrder = ordered list of phase names; getTargetsFn(phase, context) returns list of { id, targethit }; getSpellIndicesFn(phase) returns list of indices; targetNeedsSpellFn(spellIndex, targetId, targethit, context) returns EvalID, targethit or nil.
function spellutils.RunPhaseFirstSpellCheck(sub, hookName, phaseOrder, getTargetsFn, getSpellIndicesFn,
                                            targetNeedsSpellFn, context, options)
    options = options or {}
    local runPriority = options.runPriority
    local rc = state.getRunconfig()

    if spellutils.handleSpellCheckReentry(sub, options) then
        return false
    end

    if options.noResume and state.getRunState() == state.RESUME_BY_HOOK[hookName] then
        state.clearRunState()
    end

    local cursor = options.noResume and nil or spellutils.getResumeCursor(hookName)
    if sub == 'debuff' and cursor then
        spellutils.DbgMezTrace('unexpected resume cursor phase=%s targetIndex=%s spellIndex=%s',
            tostring(cursor.phase), tostring(cursor.targetIndex), tostring(cursor.spellIndex))
    end
    local startPhaseIdx = 1
    local startTargetIdx = 1
    local startSpellIdx = 1
    if cursor and cursor.phase and cursor.targetIndex and cursor.spellIndex then
        for pi, p in ipairs(phaseOrder) do
            if p == cursor.phase then
                startPhaseIdx = pi
                startTargetIdx = cursor.targetIndex or 1
                startSpellIdx = cursor.spellIndex or 1
                break
            end
        end
    end
    if cursor and options.entryValid and cursor.spellIndex and not options.entryValid(cursor.spellIndex) then
        state.clearRunState()
        cursor = nil
        startPhaseIdx = 1
        startTargetIdx = 1
        startSpellIdx = 1
    end
    if tryClearBlockedDebuffAbilityResume(hookName, sub, cursor, getTargetsFn, context) then
        cursor = nil
        startPhaseIdx = 1
        startTargetIdx = 1
        startSpellIdx = 1
    end

    for phaseIdx = startPhaseIdx, #phaseOrder do
        local phase = phaseOrder[phaseIdx]
        local targets = getTargetsFn(phase, context)
        if targets and #targets > 0 then
            local targetStart = (phaseIdx == startPhaseIdx) and startTargetIdx or 1
            for targetIdx = targetStart, #targets do
                local target = targets[targetIdx]
                if target and target.id then
                    local spellIndices = getSpellIndicesFn(phase, target)
                    if spellIndices and #spellIndices > 0 then
                        local spellStart = (phaseIdx == startPhaseIdx and targetIdx == targetStart) and startSpellIdx or
                            1
                        local fromSpellIndices = {}
                        for _, si in ipairs(spellIndices) do
                            if si >= spellStart then fromSpellIndices[#fromSpellIndices + 1] = si end
                        end
                        if #fromSpellIndices > 0 then
                            local spellIndex, EvalID, targethit = spellutils.checkIfTargetNeedsSpells(sub,
                                fromSpellIndices, target.id, target.targethit, context, options, targetNeedsSpellFn,
                                phase)
                            if not spellIndex and options.mezDebug and sub == 'debuff' and phase == 'notmatar' then
                                spellutils.MezLog('no spell passed gates for id=%s (indices tried: %s)', target.id,
                                    table.concat(fromSpellIndices, ','))
                            end
                            if spellIndex and EvalID and targethit then
                                local entry = botconfig.getSpellEntry(sub, spellIndex)
                                if entry and spellutils.IsGroupOnlySpell(entry) and targethit ~= 'self' and not spellutils.IsSpawnInMyGroup(EvalID) then
                                    spellIndex, EvalID, targethit = nil, nil, nil
                                end
                            end
                            if spellIndex and EvalID and targethit then
                                if rc.CurSpell and rc.CurSpell.phase == 'casting' and rc.CurSpell.sub ~= sub and mq.TLO.Me.CastTimeLeft() > 0 and not spellutils.IsMemorizing() then
                                    mq.cmd('/stopcast')
                                    spellutils.clearCastingStateOrResume()
                                end
                                local spellcheckResume = nil
                                if not options.noResume then
                                    spellcheckResume = {
                                        hook = hookName,
                                        phase = phase,
                                        targetIndex = targetIdx,
                                        spellIndex = spellIndex,
                                    }
                                end
                                if options.customCastFn and options.customCastFn(spellIndex, EvalID, targethit, sub, runPriority, spellcheckResume) then
                                    return false
                                end
                                if spellutils.CastSpell(spellIndex, EvalID, targethit, sub, runPriority, spellcheckResume) then
                                    if _instantDebuffCastPending and options.afterCast then
                                        local ic = _instantDebuffCastPending
                                        _instantDebuffCastPending = nil
                                        options.afterCast(ic.spell, ic.target, ic.targethit)
                                    end
                                    return false
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    -- Clear _resume state when loop completes without starting a new cast (so we don't stay stuck in doHeal_resume etc.)
    if state.getRunState() == state.RESUME_BY_HOOK[hookName] then
        state.clearRunState()
    end
    return false
end

-- precondition check: precondition is string or nil. Literal 'true'/'false' skip Lua eval.
function spellutils.PreCondCheck(Sub, ID, spawnID)
    local entry = botconfig.getSpellEntry(Sub, ID)
    if not entry then return false end
    if entry.precondition == nil then return true end
    if type(entry.precondition) ~= 'string' then
        EvalID = nil; return true
    end
    local precond = entry.precondition:match('^%s*(.-)%s*$') or entry.precondition
    if precond == 'true' then
        EvalID = nil; return true
    end
    if precond == 'false' then
        EvalID = nil; return false
    end
    EvalID = spawnID
    local loadprecond, loadError = load('local mq = require("mq") ' .. precond)
    if loadprecond then
        local env = { EvalID = EvalID }
        setmetatable(env, { __index = _G })
        local output = loadprecond()
        EvalID = nil
        return output
    else
        print('problem loading precond') -- TODO add more context to make this a meaningful error message
    end
    EvalID = nil
    return true
end

-- Internal: load script from config.script[script]; if run then execute. Returns (success, output or nil).
local function loadAndOptionalRun(script, run)
    if not botconfig.config.script or type(botconfig.config.script[script]) ~= 'string' then
        return false, nil
    end
    local chunk, loadError = load('local mq = require("mq") ' .. botconfig.config.script[script])
    if not chunk then
        print('problem loading precond') -- TODO add more context to make this a meaningful error message
        return false, nil
    end
    if not run then
        return true, nil
    end
    local output = chunk()
    return true, output
end

--checks if a precondition is valid
function spellutils.ProcessScript(script, Sub, ID)
    if type(botconfig.config[script]) == 'boolean' then
        if botconfig.config[script] then return true end
    end
    if botconfig.config.script and type(botconfig.config.script[script]) == 'string' then
        local ok = loadAndOptionalRun(script, false)
        if not ok then
            local entry = botconfig.getSpellEntry(Sub, ID)
            if entry then entry.enabled = false end
            return false
        end
        return true
    end
end

--runs script
function spellutils.RunScript(script, Sub, ID)
    if type(botconfig.config[script]) == 'boolean' then
        if botconfig.config[script] then return true end
    end
    if botconfig.config.script and type(botconfig.config.script[script]) == 'string' then
        local ok, output = loadAndOptionalRun(script, true)
        if not ok then
            local entry = botconfig.getSpellEntry(Sub, ID)
            if entry then entry.enabled = false end
            return false
        end
        return output
    end
end

--- Stop the in-game cast bar. Uses casting lib (/stopcast) when viaCastingLib; legacy path uses /stopcast directly.
function spellutils.interruptActiveCast(rc)
    rc = rc or state.getRunconfig()
    if rc.CurSpell and (rc.CurSpell.viaMQ2Cast or rc.CurSpell.viaCastingLib) then
        casting.interrupt()
    else
        mq.cmd('/stopcast')
    end
end

function spellutils.InterruptCheckTargetLost(rc, targetSpawn, criteria, spelltartype)
    if mq.TLO.Me.Class.ShortName() == 'BRD' then return end
    if not targetSpawn.ID() or string.lower(spelltartype) == 'self' then return end
    local lostOrCorpse = (targetSpawn.ID() == 0) or
        (string.find(targetSpawn.Name() or '', 'corpse') and criteria ~= 'corpse')
    if not lostOrCorpse then return end
    mq.cmd('/squelch /multiline; /stick off ; /mqtarget clear')
    if mq.TLO.Me.CastTimeLeft() > 0 and rc.CurSpell.target ~= mq.TLO.Me.ID() and criteria ~= 'groupheal' and criteria ~= 'groupbuff' and criteria ~= 'groupcure' then
        mq.cmd('/echo I lost my target, interrupting')
        spellutils.interruptActiveCast(rc)
        if mq.TLO.Me.CastTimeLeft() > 0 and mq.TLO.Me.Combat() then mq.cmd('/attack off') end
    end
    if state.getRunconfig().domelee and _deps.AdvCombat then _deps.AdvCombat() end
end

function spellutils.InterruptCheckHealThreshold(rc, sub, criteria, spell, targetSpawn, target, entry)
    if sub ~= 'heal' or criteria == 'corpse' then return end
    if entry and spellutils.IsGroupV1OrV2HealEntry(entry) then return end
    if criteria == 'self' and entry and entry.healResource == 'mana' then return end
    local th = AHThreshold and spell and AHThreshold[spell] and AHThreshold[spell][criteria]
    if not th or not targetSpawn.PctHPs() or targetSpawn.ID() ~= target then return end
    local maxVal = type(th) == 'table' and th.max or th
    if (maxVal + (math.abs(maxVal - 100) * botconfig.config.heal.interruptlevel)) <= targetSpawn.PctHPs() then
        printf('\ayCZBot:\axInterrupting Spell %s, target is above the threshold', entry.spell)
        spellutils.interruptActiveCast(rc)
        spellutils.clearCastingStateOrResume()
    end
end

function spellutils.InterruptCheckDontStack(entry, target, spellname)
    if not (entry.dontStack and #entry.dontStack > 0) then return end
    if mq.TLO.Me.CastTimeLeft() <= 0 then return end
    local tag = spellutils.SpawnHasDebuffCategory(target, entry.dontStack)
    if not tag and mq.TLO.Target.ID() == target and mq.TLO.Target.BuffsPopulated() then
        local tTag = spellutils.TargetHasDebuffCategory(entry.dontStack)
        if tTag and tTag ~= 'Mezzed' then
            tag = tTag
        elseif tTag == 'Mezzed' and spellutils.SpawnMezActive(target) then
            tag = tTag
        end
    end
    if not tag then return end
    printf('\ayCZBot:\axInterrupt %s, target already %s', spellname, tag)
    spellutils.RecordDontStackDebuffFromSpawn(target, entry.spell, tag)
    spellutils.interruptActiveCast(state.getRunconfig())
    spellutils.clearCastingStateOrResume()
end

function spellutils.InterruptCheckBuffDebuffAlreadyPresent(rc, sub, entry, spellname, spellid, spelldurMs, target,
                                                           targetname)
    local durMs = tonumber(spelldurMs) or 0
    if mq.TLO.Me.CastTimeLeft() <= 0 or (sub ~= 'debuff' and sub ~= 'buff') or not spelldurMs or durMs <= 0 or mq.TLO.Me.Class.ShortName() == 'BRD' then return end
    local selfBuffNoRetarget = (sub == 'buff' and entry and spellutils.IsSelfTargetSpell(entry) and target == mq.TLO.Me.ID())
    if selfBuffNoRetarget then
        if not mq.TLO.Me.BuffsPopulated() then return end
    else
        if mq.TLO.Target.ID() ~= target or not mq.TLO.Target.BuffsPopulated() then return end
    end
    local criteria = rc.CurSpell and rc.CurSpell.targethit or nil
    local isSelfTarget = target == mq.TLO.Me.ID()
    local isSelfGroupBuff = (criteria == 'groupbuff' and isSelfTarget)
    local function meBuffDuration(slot)
        if not slot or not slot.Duration then return 0 end
        local ok, v = pcall(function() return slot.Duration() end)
        return (ok and v) or 0
    end
    local function meBuffId(slot)
        if not slot or not slot.ID then return false end
        local ok, v = pcall(function() return slot.ID() end)
        return ok and v or false
    end
    local buffid, buffdur
    if selfBuffNoRetarget then
        local mb = mq.TLO.Me.Buff(spellname)
        local ms = mq.TLO.Me.Song(spellname)
        if mb() then
            buffid = meBuffId(mb)
            buffdur = meBuffDuration(mb)
        elseif ms() then
            buffid = meBuffId(ms)
            buffdur = meBuffDuration(ms)
        else
            buffid, buffdur = false, 0
        end
    else
        buffid = mq.TLO.Target.Buff(spellname).ID() or false
        buffdur = mq.TLO.Target.Buff(spellname).Duration() or 0
    end
    -- MQ2 `Buff(spellName)` can return a different buff on partial-name matches.
    -- Only treat it as "present" when it matches the configured spell id.
    local buffPresent = (buffid and spellid and buffid == spellid) and buffdur > (durMs * 0.10)
    local stacks = mq.TLO.Spell(spellid).StacksTarget()
    local spellTargetType = mq.TLO.Spell(spellid).TargetType() or ''

    if sub == 'buff' then
        if not stacks and spellTargetType ~= 'Self' then
            printf('\ayCZBot:\axInterrupt %s, buff does not stack on target: %s', spellname, targetname)
            spellutils.interruptActiveCast(rc)
            if not rc.interruptCounter[spellid] then rc.interruptCounter[spellid] = { 0, 0 } end
            rc.interruptCounter[spellid] = { rc.interruptCounter[spellid][1] + 1, mq.gettime() + 10000 }
            spellutils.clearCastingStateOrResume()
        elseif buffPresent and buffdur >= BUFF_REFRESH_THRESHOLD_MS and not isSelfGroupBuff then
            -- Buff present with enough time left: interrupt. Below threshold we allow refresh cast to complete.
            printf('\ayCZBot:\axInterrupt %s, buff already present', spellname)
            spellutils.interruptActiveCast(rc)
            if not rc.interruptCounter[spellid] then rc.interruptCounter[spellid] = { 0, 0 } end
            rc.interruptCounter[spellid] = { rc.interruptCounter[spellid][1] + 1, mq.gettime() + 10000 }
            spellutils.clearCastingStateOrResume()
        end
    elseif sub == 'debuff' then
        -- For refresh casters: only interrupt if the existing debuff has MORE time left than we want.
        -- This prevents getting interrupted mid-refresh when remaining is already below the recast threshold.
        if buffPresent then
            local thresholdMs = spellutils.GetDebuffRefreshThresholdMs()
            if (buffdur or 0) > thresholdMs then
                printf('\ayCZBot:\axInterrupt %s on MobID %s, debuff remaining %sms > %sms', spellname, target,
                    tostring(buffdur or 0), tostring(thresholdMs))
                local expire = (mq.TLO.Target.Buff(spellname).Duration() or 0) + mq.gettime()
                spellstates.DebuffListUpdate(target, spellid, expire)
                spellutils.interruptActiveCast(rc)
                spellutils.clearCastingStateOrResume()
            end
        end
    end
end

function spellutils.InterruptCheck()
    local rc = state.getRunconfig()
    if not rc.CurSpell.sub then return false end
    local sub = rc.CurSpell.sub
    local spell = rc.CurSpell.spell
    local entry = botconfig.getSpellEntry(sub, spell)
    if not entry then return false end
    local spellname = entry.spell or (entry.gem == 'item' and mq.TLO.FindItem(entry.spell).Spell())
    if not spellname then return false end
    local criteria = rc.CurSpell.targethit
    local target = rc.CurSpell.target
    local spelltartype = mq.TLO.Spell(spellname).TargetType() or ''
    local targetname = mq.TLO.Spawn(target).CleanName()
    local spellid = spellutils.GetSpellId(entry)
    if not spellid then return false end
    local spelldur = spellutils.GetSpellDurationSec(entry) * 1000
    if not criteria then return false end
    if not target or not spell or not criteria or not sub then return false end

    -- Group v1/v2 heal: re-check evalGroupAECount mid-cast; interrupt if band/tarcnt no longer satisfied.
    if sub == 'heal' and criteria == 'groupheal' and entry and spellutils.IsGroupV1OrV2HealEntry(entry) then
        local botheal = require('botheal')
        local gid, _ghit = botheal.EvalGroupHealIfNeeded(spell)
        if not gid then
            spellutils.interruptActiveCast(rc)
            spellutils.clearCastingStateOrResume()
            return
        end
    end

    if not mq.TLO.Target.ID() or mq.TLO.Target.ID() == 0 then return false end
    local targetSpawn = mq.TLO.Target

    -- Heal threshold must run even when Cast.Status() contains 'M' (e.g. HoT channeling), so we clear when target is above band.
    if sub == 'heal' then
        spellutils.InterruptCheckHealThreshold(rc, sub, criteria, spell, targetSpawn, target, entry)
    end
    if spellutils.IsMemorizing() then return false end

    spellutils.InterruptCheckTargetLost(rc, targetSpawn, criteria, spelltartype)
    if criteria ~= 'corpse' and targetSpawn.Type() == 'Corpse' then
        printf('\ayCZBot:\axMy target is dead, interrupting')
        spellutils.interruptActiveCast(rc)
        mq.cmd('/squelch /mqtarget clear')
        spellutils.clearCastingStateOrResume()
    end
    spellutils.InterruptCheckHealThreshold(rc, sub, criteria, spell, targetSpawn, target, entry)
    if sub == 'debuff' then
        spellutils.InterruptCheckDontStack(entry, target, spellname)
    end
    spellutils.InterruptCheckBuffDebuffAlreadyPresent(rc, sub, entry, spellname, spellid, spelldur, target, targetname)
end

-- CastSpell helpers (used by CastSpell only or by re-entry flow).

--- True if the configured gem slot (1–12) holds this entry's spell. Empty/wrong spell = not memmed here (MQ2Cast may memorize).
local function spellMemmedInConfiguredGemSlot(entry)
    local gem = entry.gem
    local spellName = entry.spell
    if not spellName or spellName == '' then return false end
    local slot = nil
    if type(gem) == 'number' and gem >= 1 and gem <= 12 then
        slot = gem
    elseif type(gem) == 'string' then
        local n = tonumber(gem)
        if n and n >= 1 and n <= 12 then slot = n end
    end
    if not slot then return false end
    local gemTlo = mq.TLO.Me.Gem(slot)
    if not gemTlo then return false end
    local ok, inSlot = pcall(function() return gemTlo() end)
    if not ok or not inSlot or inSlot == '' then return false end
    return string.lower(inSlot) == string.lower(spellName)
end

--- If true, CastSpell should return false before CurSpell: MQ2Cast would only wait on reuse (Lua would mirror that busy window).
--- Only when the spell is already in the target gem; if the slot is empty or another spell, MQ2Cast may need to memorize — do not defer.
function spellutils.ShouldDeferMQ2CastForGemCooldown(entry)
    if not entry or type(entry.gem) ~= 'number' then return false end
    if entry.gem < 1 or entry.gem > 12 then return false end
    if not spellMemmedInConfiguredGemSlot(entry) then return false end
    local spell = string.lower(entry.spell or '')
    if spell == '' then return false end
    local sr = mq.TLO.Me.SpellReady(spell)
    if not sr then return false end
    local ok, ready = pcall(function() return sr() end)
    if not ok or ready then return false end
    return true
end

function spellutils.CheckGemReadiness(sub, index, entry)
    local rc = state.getRunconfig()
    local spell = entry.spell
    local gem = entry.gem
    if type(gem) == 'number' then
        if not mq.TLO.Me.Book(spell)() then
            printf('\ayCZBot:\ax %s[%s]: Spell %s not found in your book', sub, index, spell)
            entry.enabled = false
            if not rc.spellNotInBook then rc.spellNotInBook = {} end
            if not rc.spellNotInBook[sub] then rc.spellNotInBook[sub] = {} end
            rc.spellNotInBook[sub][index] = true
            return false
        end
    elseif gem == 'item' then
        if not mq.TLO.Me.ItemReady(spell)() then return false end
    elseif gem == 'disc' then
        if not mq.TLO.Me.CombatAbilityReady(spell)() then return false end
    elseif gem == 'ability' then
        if not mq.TLO.Me.AbilityReady(spell)() then return false end
    elseif gem == 'alt' then
        if not mq.TLO.Me.AltAbilityReady(spell)() then return false end
    elseif gem == 'script' then
        if not spellutils.ProcessScript(spell, sub, index) then return false end
    end
    return true
end

function spellutils.SetCastStatusMessage(sub, targetname, spellname, entry)
    local rc = state.getRunconfig()
    if sub == 'heal' then
        rc.statusMessage = string.format('Healing %s with %s', targetname, spellname)
    elseif sub == 'buff' then
        rc.statusMessage = string.format('Buffing %s with %s', targetname, spellname)
    elseif sub == 'debuff' or sub == 'ad' then
        if entry and (entry.gem == 'ability' or entry.gem == 'disc') then
            rc.statusMessage = string.format('Using %s on %s', spellname, targetname)
        elseif entry and spellutils.IsMezSpell(entry) then
            rc.statusMessage = string.format('Mezzing %s with %s', targetname, spellname)
        elseif entry and spellutils.IsNukeSpell(entry) then
            rc.statusMessage = string.format('Nuking %s with %s', targetname, spellname)
        else
            rc.statusMessage = string.format('Casting %s on %s', spellname, targetname)
        end
    elseif sub == 'cure' then
        rc.statusMessage = string.format('Curing %s with %s', targetname, spellname)
    else
        rc.statusMessage = string.format('Casting %s on %s', spellname, targetname)
    end
end

function spellutils.ShouldWaitForMovement(entry)
    if not entry or not entry.spell then return false end
    local spell = string.lower(entry.spell or '')
    local castTime = mq.TLO.Spell(spell).MyCastTime()
    if not castTime or castTime <= 0 then return false end
    if mq.TLO.Me.Class.ShortName() == 'BRD' then return false end
    return mq.TLO.Me.Moving() or mq.TLO.Navigation.Active() or mq.TLO.Stick.Active()
end

function spellutils.RequireTargetThenDontStackDebuff(entry, EvalID)
    if not (entry and entry.dontStack and #entry.dontStack > 0) then return false end
    local tag = spellutils.SpawnHasDebuffCategory(EvalID, entry.dontStack)
    if tag then
        spellutils.RecordDontStackDebuffFromSpawn(EvalID, entry.spell, tag)
        if spellutils.IsMezSpell(entry) then
            spellutils.MezLog('dontStack skip id=%s (spawn already %s)', tostring(EvalID), tag)
        end
        return true
    end
    if not spellutils.SpellStacksSpawn(entry, EvalID) then
        if mq.TLO.Target.ID() ~= EvalID then
            mq.cmdf('/tar id %s', EvalID)
            mq.delay(500, function() return mq.TLO.Target.BuffsPopulated() == true end)
        end
        if mq.TLO.Target.ID() == EvalID and mq.TLO.Target.BuffsPopulated() then
            tag = spellutils.TargetHasDebuffCategory(entry.dontStack)
            if tag then
                spellutils.RecordDontStackDebuffFromTarget(EvalID, entry.spell, tag)
                if spellutils.IsMezSpell(entry) then
                    spellutils.MezLog('dontStack skip id=%s (target already %s)', tostring(EvalID), tag)
                end
            end
        end
        return true
    end
    return false
end

--- Empty cursor into inventory when needed so casting can proceed (hands-full blocks cast commands).
function spellutils.AutoinvIfCursorBlockingCast()
    if mq.TLO.Cursor.ID() and mq.TLO.Me.FreeInventory() and mq.TLO.Me.FreeInventory() > 0 then
        mq.cmd('/autoinv')
    end
end

function spellutils.BuildCastRequest(entry, EvalID, sub)
    local maxTries = (sub == 'debuff') and 2 or 1
    return {
        spellName = entry.spell,
        gemType = entry.gem,
        targetId = EvalID,
        sub = sub,
        maxTries = maxTries,
        allowNoTarget = (sub == 'heal' and spellutils.IsGroupV1OrV2HealEntry(entry)),
        isSelfTarget = spellutils.IsSelfTargetSpell(entry),
        spellId = spellutils.GetSpellId(entry),
    }
end

-- Throttled printf when entering a cast pipeline phase (see hookregistry [busy] cap when hooks skip).
local _castPhaseDbgNextTime = 0
local CAST_PHASE_DBG_INTERVAL_MS = 1000
local function dbgCastPhase(phase, sub, index, runPriority)
    local now = mq.gettime()
    if now < _castPhaseDbgNextTime then return end
    _castPhaseDbgNextTime = now + CAST_PHASE_DBG_INTERVAL_MS
    printf('\ayCZBot:\ax [cast t=%s] %s sub=%s idx=%s runPriority=%s', tostring(now), tostring(phase),
        tostring(sub), tostring(index), tostring(runPriority))
end

--- Only for cast types MQ2Cast does not support. Called from CastSpell when gem is script/disc/ability.
function spellutils.ExecuteNativeCast(gem, spell, sub, index)
    if gem == 'script' then
        spellutils.RunScript(spell, sub, index)
    elseif gem == 'disc' and mq.TLO.Me.CombatAbilityReady(spell)() then
        mq.cmdf('/squelch /disc %s', spell)
    elseif gem == 'ability' then
        mq.cmdf('/squelch /face fast')
        mq.cmdf('/doability %s', spell)
    end
end

--- EvalID is the spawn ID of the cast target; for self/group it is Me.ID().
function spellutils.CastSpell(index, EvalID, targethit, sub, runPriority, spellcheckResume)
    local rc = state.getRunconfig()
    local meId = mq.TLO.Me.ID()
    local entry = botconfig.getSpellEntry(sub, index)
    if not entry then return false end
    local mezCastDbg = sub == 'debuff' and targethit == 'notmatar' and spellutils.IsMezSpell(entry)
    local function mezBlocked(reason)
        if mezCastDbg then
            spellutils.MezLog('CastSpell blocked idx=%s id=%s: %s', index, tostring(EvalID), reason)
        end
    end
    local resuming = (rc.CurSpell and rc.CurSpell.phase and rc.CurSpell.spell == index and rc.CurSpell.sub == sub)
    if not resuming then
        if not state.canStartBusyState(state.STATES.casting) then mezBlocked('busy state'); return false end
        if not spellutils.SpellCheck(sub, index) then mezBlocked('SpellCheck'); return false end
        if mq.TLO.Me.Class.ShortName() ~= 'BRD' and mq.TLO.Me.CastTimeLeft() > 0 then mezBlocked('CastTimeLeft'); return false end
        if not spellutils.CheckGemReadiness(sub, index, entry) then mezBlocked('gem not ready'); return false end
        if spellutils.ShouldDeferMQ2CastForGemCooldown(entry) then mezBlocked('gem cooldown'); return false end
        rc.CurSpell = {
            sub = sub,
            spell = index,
            target = EvalID,
            targethit = targethit,
            resisted = false,
            spellcheckResume = spellcheckResume,
        }
        if targethit == 'charmtar' then rc.charmid = EvalID end
    else
        if spellcheckResume then rc.CurSpell.spellcheckResume = spellcheckResume end
    end
    local spell = string.lower(entry.spell or '')
    local gem = entry.gem
    local targetname
    if targethit == 'self' or EvalID == meId then
        targetname = mq.TLO.Me.CleanName() or 'Unknown'
    else
        local spawn = mq.TLO.Spawn(EvalID)
        targetname = (spawn and spawn.CleanName()) or 'Unknown'
    end
    local spellname = entry.spell or spell
    if not resuming then
        spellutils.SetCastStatusMessage(sub, targetname, spellname, (sub == 'debuff' or sub == 'ad') and entry or nil)
    end

    if not resuming and spellutils.ShouldWaitForMovement(entry) then
        mq.cmd('/multiline ; /nav stop log=off ; /stick off')
        rc.CurSpell.phase = 'precast_wait_move'
        rc.CurSpell.deadline = mq.gettime() + 3000
        dbgCastPhase('precast_wait_move', sub, index, runPriority)
        state.setRunState(state.STATES.casting,
            { deadline = mq.gettime() + 3000, priority = runPriority, spellcheckResume = rc.CurSpell.spellcheckResume })
        return true
    end
    if (sub == 'debuff' and targethit == 'notmatar' and mq.TLO.Me.Combat()) then mq.cmd('/squelch /attack off') end
    if bardtwist and bardtwist.StopTwist then bardtwist.StopTwist() end
    if mq.TLO.Me.Class.ShortName() == 'BRD' then
        if (botconfig.config.settings.domelee and state.getMobCount() > 0 and targethit ~= 'notmatar' and not mq.TLO.Me.Combat()) then
            if _deps.AdvCombat then _deps.AdvCombat() end
        end
        if type(gem) == 'number' and mq.TLO.Me.SpellReady(spell)() then mq.cmd('/squelch /stopcast') end
    end
    local useCastingLib = (type(gem) == 'number' or gem == 'item' or gem == 'alt')
    local mtSelfCastInCombat = (EvalID == meId and mq.TLO.Me.Combat())
    if mtSelfCastInCombat then
        local _, tankid = spellutils.GetTankInfo(true)
        if tankid ~= meId then mtSelfCastInCombat = false end
    end
    local skipSelfRetarget = (EvalID == meId and spellutils.IsSelfTargetSpell(entry)) or
        (sub == 'heal' and spellutils.IsGroupV1OrV2HealEntry(entry)) or
        (sub == 'debuff' and (gem == 'ability' or gem == 'disc') and EvalID == rc.engageTargetId and mq.TLO.Target.ID() == EvalID)
    if not useCastingLib and mq.TLO.Target.ID() ~= EvalID and not mtSelfCastInCombat and not skipSelfRetarget then
        mq.cmdf('/tar id %s', EvalID)
        rc.CurSpell.phase = 'precast'
        rc.CurSpell.deadline = mq.gettime() + 1000
        dbgCastPhase('precast', sub, index, runPriority)
        state.setRunState(state.STATES.casting,
            {
                deadline = mq.gettime() + CASTING_STUCK_MS,
                priority = runPriority,
                spellcheckResume = rc.CurSpell
                    .spellcheckResume
            })
        return true
    end
    if sub == 'debuff' and spellutils.RequireTargetThenDontStackDebuff(entry, EvalID) then
        mezBlocked('dontStack on target')
        spellutils.clearCastingStateOrResume()
        return false
    end
    invokePrepareImmediateCast(sub, index, EvalID, targethit)
    if entry.announce then
        printf("\ayCZBot:\axCasting \ag%s\ax on >\ay%s\ax<", spell, targetname)
    end
    -- Stand to cast only when not about to memorize: standing interrupts MQ2Cast memorization.
    if mq.TLO.Me.Sitting() and not mq.TLO.Me.Mount() and (not rc.CurSpell or rc.CurSpell.phase ~= 'casting') then
        local standToCast = true
        if useCastingLib and type(gem) == 'number' and not mq.TLO.Me.SpellReady(spell)() then
            standToCast = false
        end
        if standToCast then mq.cmd('/stand') end
    end
    if useCastingLib then
        local castSpellId = spellutils.GetSpellId(entry)
        local castRequest = spellutils.BuildCastRequest(entry, EvalID, sub)
        local needDelay = (type(gem) == 'number' and not mq.TLO.Me.SpellReady(spell)())
        rc.CurSpell.viaMQ2Cast = true
        rc.CurSpell.viaCastingLib = true
        rc.CurSpell.spellid = castSpellId
        spellutils.AutoinvIfCursorBlockingCast()
        if not casting.start(castRequest) then
            mezBlocked('casting.start failed')
            rc.CurSpell = {}
            rc.statusMessage = ''
            return false
        end
        if mezCastDbg then
            spellutils.MezLog('CastSpell started idx=%s id=%s gem=%s', index, tostring(EvalID), tostring(gem))
        end
        rc.CurSpell.phase = 'casting'
        dbgCastPhase('casting', sub, index, runPriority)
        state.setRunState(state.STATES.casting,
            {
                deadline = mq.gettime() + CASTING_STUCK_MS,
                priority = runPriority,
                spellcheckResume = rc.CurSpell
                    .spellcheckResume
            })
        if needDelay then mq.delay(CASTING_MEMORIZE_DELAY_MS) end
        return true
    end
    spellutils.ExecuteNativeCast(gem, spell, sub, index)
    if sub == 'debuff' and (gem == 'ability' or gem == 'disc') then
        rc.CurSpell.phase = 'casting'
        spellutils.OnCastComplete(index, EvalID, targethit, sub)
        _instantDebuffCastPending = { spell = index, target = EvalID, targethit = targethit }
        spellutils.clearCastingStateOrResume()
        return true
    end
    rc.CurSpell.phase = 'casting'
    dbgCastPhase('casting(native)', sub, index, runPriority)
    state.setRunState(state.STATES.casting,
        {
            deadline = mq.gettime() + CASTING_STUCK_MS,
            priority = runPriority,
            spellcheckResume = rc.CurSpell
                .spellcheckResume
        })
    return true
end

function spellutils.RefreshSpells()
    local enabled, disabled = 0, 0
    local function refresh_section(section)
        local cnt = botconfig.getSpellCount(section)
        if not cnt or cnt <= 0 then return end
        for i = 1, cnt do
            local entry = botconfig.getSpellEntry(section, i)
            if entry and type(entry.alias) == 'string' and entry.alias ~= '' then
                if spellsdb and spellsdb.resolve_entry then spellsdb.resolve_entry(section, i, true) end
                local known = false
                if entry.gem == 'disc' then
                    known = entry.spell and entry.spell ~= '' and
                        mq.TLO.Me.CombatAbility(entry.spell)() ~= nil
                else
                    known = entry.spell and mq.TLO.Me.Book(entry.spell)()
                end
                if known then
                    if entry.enabled == false then
                        entry.enabled = (entry._saved_enabled ~= false) and (entry._saved_enabled or true)
                        entry._saved_enabled = nil
                        enabled = enabled + 1
                    end
                else
                    if entry._saved_enabled == nil then entry._saved_enabled = entry.enabled end
                    if entry.enabled then disabled = disabled + 1 end
                    entry.enabled = false
                end
            end
        end
    end
    refresh_section('heal')
    refresh_section('buff')
    refresh_section('debuff')
    refresh_section('cure')
    printf('Refreshed alias spells. Enabled:%s Disabled:%s', enabled, disabled)
end

spellutils.BUFF_REFRESH_THRESHOLD_MS = BUFF_REFRESH_THRESHOLD_MS

return spellutils
