local mq = require('mq')
local botconfig = require('lib.config')
local spellutils = require('lib.spellutils')
local spellstates = require('lib.spellstates')
local state = require('lib.state')
local utils = require('lib.utils')
local bothooks = require('lib.bothooks')
local charm = require('lib.charm')
local castutils = require('lib.castutils')
local tankrole = require('lib.tankrole')
local aggro = require('lib.aggro')
local botmove = require('botmove')

local botdebuff = {}
local DebuffBands = {}
local bardtwist = require('lib.bardtwist')
local botmelee = require('botmelee')
local targeting = require('lib.targeting')

local function defaultDebuffEntry()
    return botconfig.getDefaultSpellEntry('debuff')
end

local function normalizeDebuffEntry(entry)
    if not entry or type(entry.dontStack) ~= 'table' then return end
    local allowed = spellutils.GetDebuffDontStackAllowlist()
    local filtered = {}
    for _, tag in ipairs(entry.dontStack) do
        if allowed[tag] then filtered[#filtered + 1] = tag end
    end
    entry.dontStack = #filtered > 0 and filtered or nil
end

function botdebuff.LoadDebuffConfig()
    castutils.LoadSpellSectionConfig('debuff', {
        defaultEntry = defaultDebuffEntry,
        bandsKey = 'debuff',
        storeIn = DebuffBands,
        perEntryNormalize = normalizeDebuffEntry,
    })
end

castutils.RegisterSectionLoader('debuff', 'dodebuff', botdebuff.LoadDebuffConfig)

local function campCountOk(mobCount, mintar, maxtar)
    -- Treat 0 as "no limit"; only enforce when > 0
    if mintar and mintar > 0 and mobCount < mintar then return false end
    if maxtar and maxtar > 0 and mobCount > maxtar then return false end
    return true
end

local function DebuffEvalBuildContext(index)
    local myconfig = botconfig.config
    local entry = botconfig.getSpellEntry('debuff', index)
    if not entry then return nil end
    local spell, spellrange, spelltartype, spellid = spellutils.GetSpellInfo(entry)
    if not spell then return nil end
    local gem = entry.gem
    local spellId, spellMaxLvl, myrange, spelldur, minCastDistSq, aeRange, minCastDist = nil, nil, nil, nil, nil, nil,
        nil
    -- Decoupled targets:
    -- - MA target drives default debuff/tanktar targeting.
    -- - MT target is available for `onlyMT` debuffs and for mez exception.
    local _tank, tankid, mtTargetId, mtTargetHp = spellutils.GetTankInfo(true)
    if mtTargetId == 0 then mtTargetId = nil end
    local mtTargetLvl = mtTargetId and mq.TLO.Spawn(mtTargetId).Level()

    local _assist, assistid, maTargetId, maTargetHp = spellutils.GetAssistInfo(true)
    if maTargetId == 0 then maTargetId = nil end
    local maTargetLvl = maTargetId and mq.TLO.Spawn(maTargetId).Level()
    if gem ~= 'ability' and gem ~= 'script' then
        local spellEntity = spellutils.GetSpellEntity(entry)
        if not spellEntity then return nil end
        spellId = spellEntity.ID()
        spellMaxLvl = spellEntity.MaxLevel()
        myrange = spellEntity.MyRange()
        if spellrange == 0 and spelltartype == 'PB AE' then
            spellrange = spellEntity.AERange()
        end
        spelldur = tonumber(spellEntity.MyDuration.TotalSeconds()) or 0 -- MyDuration() ALWAYS has TotalSeconds() we don't need to check for nil
        if spellEntity.Category() == 'Pet' then myrange = myconfig.settings.acleash end
        if spellutils.IsTargetedAESpell(entry) then
            local ar = spellEntity.AERange()
            if ar and ar > 0 then
                aeRange = ar
                minCastDist = aeRange + 2
                minCastDistSq = minCastDist * minCastDist
            end
        end
    end
    if gem == 'ability' then myrange = 20 end
    local myrangeSq = myrange and (myrange * myrange) or nil
    local db = DebuffBands[index]
    local mobMin = db and db.mobMin or 0
    local mobMax = db and db.mobMax or 100
    local aggroMin = db and db.aggroMin or 0
    local aggroMax = db and db.aggroMax or 100
    return {
        entry = entry,
        spell = spell,
        spellid = spellId,
        spellrange = spellrange,
        spelldur = spelldur,
        gem = gem,
        assistid = assistid,
        maTargetId = maTargetId,
        maTargethp = maTargetHp,
        maTargetLvl = maTargetLvl,
        mtTargetId = mtTargetId,
        mtTargethp = mtTargetHp,
        mtTargetLvl = mtTargetLvl,
        spellmaxlvl = spellMaxLvl,
        myrange = myrange,
        myrangeSq = myrangeSq,
        aeRange = aeRange,
        minCastDist = minCastDist,
        minCastDistSq = minCastDistSq,
        mobList = state.getRunconfig().MobList or {},
        mobMin = mobMin,
        mobMax = mobMax,
        aggroMin = aggroMin,
        aggroMax = aggroMax,
        mintar = db and db.mintar,
        maxtar = db and db.maxtar,
    }
end

-- Returns true if spawn is a valid target for this debuff (range, level, stacks, duration, AE mintar).
-- Performs mez skip messages (level, already mezzed) when applicable.
-- phase: 'matar' | 'notmatar' (named uses same rules as matar).
local function DebuffSpawnNeedsSpell(entry, ctx, spawn, phase)
    if utils.isProtectedSpawn(spawn) then return false end
    local gem = entry.gem
    local myrangeSq = ctx.myrangeSq
    local spawnId = spawn and spawn.ID and spawn.ID() or nil

    -- Mez exception: mez/add-only debuffs should never land on MT's target.
    -- MA target is excluded earlier by phase targeting, but MT target is excluded here.
    if phase == 'notmatar' and spellutils.IsMezSpell(entry) and ctx.mtTargetId and spawnId == ctx.mtTargetId then
        return false
    end

    if entry.gem == 'ability' then
        local mr = spawn.MaxRangeTo and spawn.MaxRangeTo()
        local e = mr and math.max(0, mr - 2)
        myrangeSq = e and (e * e)
    end
    local distSq = utils.getDistanceSquared2D(mq.TLO.Me.X(), mq.TLO.Me.Y(), spawn.X(), spawn.Y())
    if ctx.minCastDistSq and distSq and distSq < ctx.minCastDistSq then
        return false
    end
    if myrangeSq and distSq and distSq > myrangeSq then
        return false
    end
    local spawnLevel = spawn.Level and spawn.Level()
    if phase == 'matar' and spawnId then
        if ctx.maTargetId and spawnId == ctx.maTargetId and ctx.maTargetLvl then
            spawnLevel = ctx.maTargetLvl
        elseif ctx.mtTargetId and spawnId == ctx.mtTargetId and ctx.mtTargetLvl then
            spawnLevel = ctx.mtTargetLvl
        end
    end
    if ctx.spellid and spawnLevel and ctx.spellmaxlvl and ctx.spellmaxlvl ~= 0 and ctx.spellmaxlvl < spawnLevel and spellutils.IsMezSpell(entry) then
        local name = (spawn.CleanName and spawn.CleanName()) or ('id ' .. tostring(spawn.ID()))
        printf('\ayCZBot:\ax [Mez] skipping \at%s\ax (id %s) - target level %s exceeds spell max level %s', name, spawn.ID(), spawnLevel, ctx.spellmaxlvl)
        return false
    end
    local tarstacks = spellutils.SpellStacksSpawn(entry, spawn.ID())
    if (type(gem) == 'number' or gem == 'alt' or gem == 'disc' or gem == 'item') and not tarstacks then
        if phase == 'notmatar' and spellutils.IsMezSpell(entry) then
            local name = (spawn.CleanName and spawn.CleanName()) or ('id ' .. tostring(spawn.ID()))
            printf('\ayCZBot:\ax [Mez] skipping \at%s\ax (id %s) - already mezzed by another player', name, spawn.ID())
            return false
        end
        if phase == 'matar' and not spellutils.IsConcussionSpell(entry) then
            return false
        end
    end
    if tonumber(ctx.spelldur) and tonumber(ctx.spelldur) > 0 and spawn.ID() and spellstates.HasDebuffLongerThan(spawn.ID(), ctx.spellid, 6000) then
        return false
    end
    if ctx.aeRange and ctx.mintar and castutils.CountMobsWithinAERangeOfSpawn(ctx.mobList, spawn.ID(), ctx.aeRange) < ctx.mintar then
        return false
    end
    return true
end

local function DebuffEvalMatar(index, ctx)
    local entry = ctx.entry
    local db = DebuffBands[index]
    if not db or not db.matar then return nil, nil end
    if spellutils.IsMezSpell(entry) then return nil, nil end

    -- `matar` phase provides both MA and MT candidate targets.
    -- For `onlyMT` debuffs we cast on MT's target; otherwise on MA's target.
    if entry.onlyMT and not tankrole.AmIMainTank() then return nil, nil end
    local chosenTargetId = entry.onlyMT and ctx.mtTargetId or ctx.maTargetId
    if not chosenTargetId then return nil, nil end

    if not castutils.hpEvalSpawn(chosenTargetId, { min = db.mobMin, max = db.mobMax }) then return nil, nil end
    for _, v in ipairs(ctx.mobList) do
        if v.ID() == chosenTargetId then
            if DebuffSpawnNeedsSpell(entry, ctx, v, 'matar') then
                return chosenTargetId, 'matar'
            end
            return nil, nil
        end
    end
    return nil, nil
end

local function DebuffEvalNotmatar(index, ctx)
    local entry = ctx.entry
    local db = DebuffBands[index]
    if not db or not db.notmatar or not ctx.mobList[1] then return nil, nil end
    local maTargetId = ctx.maTargetId
    for _, v in ipairs(ctx.mobList) do
        local vid = v.ID and v.ID() or nil
        if vid and vid ~= maTargetId then
            if castutils.hpEvalSpawn(v, { min = db.mobMin, max = db.mobMax }) then
                if DebuffSpawnNeedsSpell(entry, ctx, v, 'notmatar') then
                    return v.ID(), 'notmatar'
                end
            end
        end
    end
    return nil, nil
end

local function DebuffEvalNamedMatar(index, ctx)
    local entry = ctx.entry
    local db = DebuffBands[index]
    if not db or not db.named then return nil, nil end
    if spellutils.IsMezSpell(entry) then return nil, nil end

    if entry.onlyMT and not tankrole.AmIMainTank() then return nil, nil end
    local chosenTargetId = entry.onlyMT and ctx.mtTargetId or ctx.maTargetId
    if not chosenTargetId then return nil, nil end

    if not castutils.hpEvalSpawn(chosenTargetId, { min = db.mobMin, max = db.mobMax }) then return nil, nil end
    for _, v in ipairs(ctx.mobList) do
        if v.ID() == chosenTargetId and v.Named() then
            if DebuffSpawnNeedsSpell(entry, ctx, v, 'matar') then
                return chosenTargetId, 'matar'
            end
            return nil, nil
        end
    end
    return nil, nil
end

local function DebuffEval(index)
    local entry = botconfig.getSpellEntry('debuff', index)
    if not entry then return nil, nil end
    local db = DebuffBands[index]
    if not campCountOk(state.getMobCount(), db and db.mintar, db and db.maxtar) then return nil, nil end
    if not aggro.inBand(db and db.aggroMin, db and db.aggroMax) then return nil, nil end
    local id, hit = charm.GetRecastRequestForIndex(index)
    if id then
        charm.ClearRecastRequest()
        return id, hit
    end
    local ctx = DebuffEvalBuildContext(index)
    if not ctx then return nil, nil end
    id, hit = charm.EvalTarget(index, ctx)
    if id then return id, hit end
    id, hit = DebuffEvalMatar(index, ctx)
    if id then return id, hit end
    id, hit = DebuffEvalNotmatar(index, ctx)
    if id then return id, hit end
    id, hit = DebuffEvalNamedMatar(index, ctx)
    if id then return id, hit end
    return nil, nil
end

local DEBUFF_PHASE_ORDER = { 'charm', 'notmatar', 'matar', 'named' }

local function debuffGetTargetsForPhase(phase, context)
    local out = {}
    local mobList = context.mobList or state.getRunconfig().MobList or {}
    if phase == 'charm' then
        if context.charmRecasts then
            for _, v in pairs(context.charmRecasts) do
                if v and v.id then out[#out + 1] = { id = v.id, targethit = v.targethit or 'charmtar' } end
            end
        end
        local count = context.debuffCount or botconfig.getSpellCount('debuff')
        for i = 1, count do
            local entry = botconfig.getSpellEntry('debuff', i)
            if entry and spellutils.IsCharmSpell(entry) then
                local dctx = DebuffEvalBuildContext(i)
                if dctx then
                    local id, hit = charm.EvalTarget(i, dctx)
                    if id then out[#out + 1] = { id = id, targethit = hit or 'charmtar' } end
                end
            end
        end
        return out
    end
    local maTargetId = context.maTargetId
    local mtTargetId = context.mtTargetId
    if phase == 'matar' then
        -- Suspend matar/named entirely when MA has no target.
        if not maTargetId or maTargetId <= 0 then return out end
        out[#out + 1] = { id = maTargetId, targethit = 'matar' }
        if mtTargetId and mtTargetId > 0 and mtTargetId ~= maTargetId then
            out[#out + 1] = { id = mtTargetId, targethit = 'matar' }
        end
        return out
    end
    if phase == 'notmatar' then
        for _, v in ipairs(mobList) do
            local vid = v.ID and v.ID() or v
            if vid and (not maTargetId or vid ~= maTargetId) then
                out[#out + 1] = { id = vid, targethit = 'notmatar' }
            end
        end
        return out
    end
    if phase == 'named' then
        -- Suspend named entirely when MA has no target.
        if not maTargetId or maTargetId <= 0 then return out end
        local ids = { maTargetId }
        if mtTargetId and mtTargetId > 0 and mtTargetId ~= maTargetId then ids[#ids + 1] = mtTargetId end
        for _, id in ipairs(ids) do
            local sp = mq.TLO.Spawn(id)
            if sp and sp.ID() == id and sp.Named() then out[#out + 1] = { id = id, targethit = 'named' } end
        end
        return out
    end
    return out
end

local function nukeFlavorAllowed(rc, flavor)
    if not flavor then return true end
    if rc.nukeFlavorsAutoDisabled and rc.nukeFlavorsAutoDisabled[flavor] then return false end
    if not rc.nukeFlavorsAllowed then return true end
    return rc.nukeFlavorsAllowed[flavor] == true
end

local function debuffTargetNeedsSpell(spellIndex, targetId, targethit, context)
    local entry = botconfig.getSpellEntry('debuff', spellIndex)
    if not entry then return nil, nil end
    local db = DebuffBands[spellIndex]
    if not campCountOk(state.getMobCount(), db and db.mintar, db and db.maxtar) then
        return nil, nil
    end
    if not aggro.inBand(db and db.aggroMin, db and db.aggroMax) then
        return nil, nil
    end
    local rc = state.getRunconfig()
    if spellutils.IsNukeSpell(entry) and not spellutils.IsConcussionSpell(entry) then
        local flavor = spellutils.GetNukeFlavor(entry)
        if not nukeFlavorAllowed(rc, flavor) then return nil, nil end
    end
    if targethit == 'charmtar' or targethit == 'charm' then
        if context.charmRecasts and context.charmRecasts[spellIndex] and context.charmRecasts[spellIndex].id == targetId then
            return targetId, context.charmRecasts[spellIndex].targethit or 'charmtar'
        end
        local ctx = DebuffEvalBuildContext(spellIndex)
        if ctx then
            local id, hit = charm.EvalTarget(spellIndex, ctx)
            if id == targetId then return id, hit or 'charmtar' end
        end
        return nil, nil
    end
    local ctx = DebuffEvalBuildContext(spellIndex)
    if not ctx then return nil, nil end
    if targethit == 'matar' then
        local id, hit = DebuffEvalMatar(spellIndex, ctx)
        if id == targetId then
            if entry.onlyMT and not tankrole.AmIMainTank() then return nil, nil end
            return id, hit
        end
        return nil, nil
    end
    if targethit == 'named' then
        local id, hit = DebuffEvalNamedMatar(spellIndex, ctx)
        if id == targetId then
            if entry.onlyMT and not tankrole.AmIMainTank() then return nil, nil end
            return id, hit
        end
        return nil, nil
    end
    if targethit == 'notmatar' then
        local entry = ctx.entry
        local db = DebuffBands[spellIndex]
        if not db or not db.notmatar then return nil, nil end
        for _, v in ipairs(ctx.mobList) do
            local vid = v.ID and v.ID() or v
            if vid == targetId then
                if castutils.hpEvalSpawn(v, { min = db.mobMin, max = db.mobMax }) and DebuffSpawnNeedsSpell(entry, ctx, v, 'notmatar') then
                    return targetId, 'notmatar'
                end
                break
            end
        end
    end
    return nil, nil
end

local function DebuffOnBeforeCast(i, EvalID, targethit)
    local myconfig = botconfig.config
    local entry = botconfig.getSpellEntry('debuff', i)
    if not entry then return false end
    if EvalID and utils.isProtectedSpawn(mq.TLO.Spawn(EvalID)) then return false end
    if not spellutils.CheckGemReadiness('debuff', i, entry) then return false end
    if not spellutils.IsConcussionSpell(entry) and entry.recast ~= nil and entry.recast > 0 and spellstates.GetRecastCounter(EvalID, i) >= entry.recast then
        return false
    end
    charm.BeforeCast(EvalID, targethit)
    if targethit == 'matar' and EvalID and EvalID > 0 then
        local rc = state.getRunconfig()
        local desiredPetTargetId = EvalID
        if tankrole.AmIMainTank() and myconfig.melee['mtSticky'] == true and not myconfig.melee.offtank then
            -- Sticky MT: keep melee/pets on MT target even if the matar debuff is aimed at MA target.
            local _, _, mtTargetId = spellutils.GetTankInfo(true)
            if mtTargetId and mtTargetId ~= 0 then
                rc.engageTargetId = mtTargetId
                desiredPetTargetId = mtTargetId
            else
                rc.engageTargetId = EvalID
            end
        elseif not myconfig.melee.offtank then
            rc.engageTargetId = EvalID
        end

        if desiredPetTargetId and mq.TLO.Pet.Target.ID() ~= desiredPetTargetId and not mq.TLO.Me.Pet.Combat() then
            mq.cmdf('/pet attack %s', desiredPetTargetId)
        end
    end
    return true
end

local function DebuffCheckBardNotmatarCast(spellIndex, EvalID, targethit, sub, _runPriority, _spellcheckResume)
    if sub ~= 'debuff' or targethit ~= 'notmatar' or mq.TLO.Me.Class.ShortName() ~= 'BRD' then return false end
    local entry = botconfig.getSpellEntry('debuff', spellIndex)
    if not entry or type(entry.gem) ~= 'number' then return false end
    local spellName = entry.spell or ('gem' .. tostring(entry.gem))
    local targetName = (mq.TLO.Spawn(EvalID) and mq.TLO.Spawn(EvalID).CleanName()) or tostring(EvalID)
    mq.cmd('/squelch /attack off')
    targeting.TargetAndWait(EvalID, 500)
    if mq.TLO.Target.ID() == EvalID and mq.TLO.Target.Mezzed() then
        printf('\ayCZBot:\ax [Mez] skipping \at%s\ax (id %s) - already mezzed by another player (detected before cast)', targetName, EvalID)
        return true
    end
    printf('\ayCZBot:\ax [Mez] casting \am%s\ax on add \at%s\ax (id %s)', spellName, targetName, EvalID)
    bardtwist.SetTwistOnceGem(entry.gem)
    local castTime = entry.spell and mq.TLO.Spell(entry.spell).MyCastTime()
    local castTimeMs = (castTime and castTime > 0) and (castTime) or 3000
    -- wait for cast to finish
    mq.delay(castTimeMs + 100)
    return true
end

local function DebuffEntryValid(i)
    local entry = botconfig.getSpellEntry('debuff', i)
    if not entry then return false end
    local gem = entry.gem
    return (entry.enabled ~= false) and ((type(gem) == 'number' and gem ~= 0) or type(gem) == 'string')
end

local function DebuffCheckAfterCast(spellIndex, EvalID, targethit, mobcountstart)
    if spellstates.GetDebuffDelay(spellIndex) and spellstates.GetDebuffDelay(spellIndex) > mq.gettime() then return false end
    if mobcountstart < state.getMobCount() then return false end
    local prevID = EvalID
    local newEvalID, newTargethit = DebuffEval(spellIndex)
    local adEntry = botconfig.getSpellEntry('debuff', spellIndex)
    if newEvalID and prevID == newEvalID and adEntry and (adEntry.recast or 0) > 0 and state.getRunconfig().CurSpell and state.getRunconfig().CurSpell.spell == spellIndex and state.getRunconfig().CurSpell.resisted then
        local newCount = spellstates.IncrementRecastCounter(EvalID, spellIndex)
        state.getRunconfig().CurSpell = {}
        if newCount >= adEntry.recast then
            local rc = state.getRunconfig()
            printf(
                '\ayCZBot:\ax\ar%s\ax has resisted spell \ar%s\ax debuff[%s] \am%s\ax times, disabling spell for this spawn',
                mq.TLO.Spawn(EvalID).CleanName(), adEntry.spell, spellIndex, adEntry.recast)
            local recastduration = 600000 + mq.gettime()
            local duration_sec = spellutils.GetSpellDurationSec(adEntry)
            if duration_sec > 0 then spellstates.DebuffListUpdate(EvalID, adEntry.spell, recastduration) end
            if spellutils.IsNukeSpell(adEntry) then
                local flavor = spellutils.GetNukeFlavor(adEntry)
                if flavor then
                    if not rc.nukeResistDisabledRecent then rc.nukeResistDisabledRecent = {} end
                    rc.nukeResistDisabledRecent[#rc.nukeResistDisabledRecent + 1] = { flavor = flavor }
                    if #rc.nukeResistDisabledRecent > 5 then
                        table.remove(rc.nukeResistDisabledRecent, 1)
                    end
                    local n = #rc.nukeResistDisabledRecent
                    if n >= 3 then
                        local f = rc.nukeResistDisabledRecent[n].flavor
                        if rc.nukeResistDisabledRecent[n - 1].flavor == f and rc.nukeResistDisabledRecent[n - 2].flavor == f then
                            if not rc.nukeFlavorsAutoDisabled then rc.nukeFlavorsAutoDisabled = {} end
                            if not rc.nukeFlavorsAutoDisabled[f] then
                                rc.nukeFlavorsAutoDisabled[f] = true
                                printf('\ayCZBot:\ax \ar%s\ax nukes auto-disabled after resists on 3 mobs in a row.', f:gsub('^%l', string.upper))
                                botconfig.saveNukeFlavorsToCommon()
                            end
                        end
                    end
                end
            end
        end
        return true
    end
    return false
end

local function debuffGetSpellIndices(phase, count, ctx, target)
    if phase == 'charm' then
        local out = {}
        for i = 1, count do
            if ctx.charmRecasts[i] then out[#out + 1] = i end
        end
        for i = 1, count do
            local entry = botconfig.getSpellEntry('debuff', i)
            if entry and spellutils.IsCharmSpell(entry) then
                local dctx = DebuffEvalBuildContext(i)
                if dctx and charm.EvalTarget(i, dctx) then
                    local found = false
                    for _, si in ipairs(out) do
                        if si == i then
                            found = true
                            break
                        end
                    end
                    if not found then out[#out + 1] = i end
                end
            end
        end
        return out
    end
    local base = spellutils.getSpellIndicesForPhase(count, phase, DebuffBands)
    if not base or #base == 0 then return base end
    local rc = state.getRunconfig()
    local nonNuke, nukeIndices = {}, {}
    for _, i in ipairs(base) do
        local entry = botconfig.getSpellEntry('debuff', i)
        if entry and spellutils.IsNukeSpell(entry) then
            local flavor = spellutils.GetNukeFlavor(entry)
            if nukeFlavorAllowed(rc, flavor) then nukeIndices[#nukeIndices + 1] = i end
        else
            nonNuke[#nonNuke + 1] = i end
    end
    if #nukeIndices == 0 then return nonNuke end
    local n = #nukeIndices
    local startPos = 1
    if rc.lastNukeIndex then
        for pos, spellIdx in ipairs(nukeIndices) do
            if spellIdx == rc.lastNukeIndex then
                startPos = (pos % n) + 1
                break
            end
        end
    end
    local rotated = {}
    for j = 0, n - 1 do
        rotated[#rotated + 1] = nukeIndices[((startPos - 1 + j) % n) + 1]
    end
    for _, i in ipairs(rotated) do nonNuke[#nonNuke + 1] = i end
    local fullBase = nonNuke
    if (phase == 'matar' or phase == 'named') and target and target.id then
        local concussionIndex, concussionRecast = nil, nil
        for _, i in ipairs(fullBase) do
            local entry = botconfig.getSpellEntry('debuff', i)
            if entry and spellutils.IsConcussionSpell(entry) and (entry.recast or 0) > 0 then
                concussionIndex = i
                concussionRecast = entry.recast
                break
            end
        end
        if concussionIndex and concussionRecast then
            local c = spellstates.GetConcussionCounter(target.id)
            if c >= concussionRecast then
                return { concussionIndex }
            end
            local out = {}
            for _, i in ipairs(fullBase) do
                local entry = botconfig.getSpellEntry('debuff', i)
                if not entry or not spellutils.IsConcussionSpell(entry) or (entry.recast or 0) <= 0 then
                    out[#out + 1] = i
                end
            end
            return out
        end
    end
    return fullBase
end

--- Single place for debuff hook context:
--- MA/MT targets are computed here so `matar`/`notmatar`/`named` phase targeting can be decoupled.
local function debuffBuildContext(rc)
    rc = rc or state.getRunconfig()
    local count = botconfig.getSpellCount('debuff')
    local _, _, maTargetId = spellutils.GetAssistInfo(true)
    if maTargetId == 0 then maTargetId = nil end
    local _, _, mtTargetId = spellutils.GetTankInfo(true)
    if mtTargetId == 0 then mtTargetId = nil end
    local charmRecasts = {}
    for i = 1, count do
        local id, hit = charm.GetRecastRequestForIndex(i)
        if id then charmRecasts[i] = { id = id, targethit = hit or 'charmtar' } end
    end
    return {
        maTargetId = maTargetId,
        mtTargetId = mtTargetId,
        charmRecasts = charmRecasts,
        debuffCount = count,
        mobList = rc.MobList or {},
        mobcountstart = state.getMobCount(),
    }
end

function botdebuff.DebuffCheck(runPriority)
    if state.getRunconfig().SpellTimer > mq.gettime() then return false end
    ---@type RunConfig
    local rc = state.getRunconfig()
    if spellutils.handleSpellCheckReentry('debuff', { runPriority = runPriority, skipInterruptForBRD = true }) then
        return false
    end
    if state.getMobCount() <= 0 then return false end
    if rc.MobList and rc.MobList[1] then
        local desiredPetTargetId = rc.engageTargetId
        local _, _, maTargetId = spellutils.GetAssistInfo(true)
        if maTargetId == 0 then maTargetId = nil end
        local _, _, mtTargetId = spellutils.GetTankInfo(true)
        if mtTargetId == 0 then mtTargetId = nil end

        -- Sticky MT mode: pets stay on MT's target even when a tanktar debuff is aimed at MA.
        if not (desiredPetTargetId and desiredPetTargetId > 0) then
            if tankrole.AmIMainTank() and botconfig.config.melee and botconfig.config.melee['mtSticky'] == true and not botconfig.config.melee.offtank then
                desiredPetTargetId = mtTargetId
            else
                desiredPetTargetId = maTargetId
            end
        end

        if desiredPetTargetId and desiredPetTargetId > 0 and mq.TLO.Pet.Target.ID() ~= desiredPetTargetId and not mq.TLO.Me.Pet.Combat() then
            botmelee.AdvCombat()
        end
    end
    local ctx = debuffBuildContext(rc)
    local count = ctx.debuffCount
    if count <= 0 then return false end
    local options = {
        skipInterruptForBRD = true,
        runPriority = runPriority,
        immuneCheck = true,
        beforeCast = DebuffOnBeforeCast,
        customCastFn = DebuffCheckBardNotmatarCast,
        entryValid = DebuffEntryValid,
        afterCast = function(i, EvalID, targethit)
            return DebuffCheckAfterCast(i, EvalID, targethit, ctx.mobcountstart)
        end,
    }
    local function getSpellIndices(phase, target)
        return debuffGetSpellIndices(phase, count, ctx, target)
    end
    return spellutils.RunPhaseFirstSpellCheck('debuff', 'doDebuff', DEBUFF_PHASE_ORDER, debuffGetTargetsForPhase,
        getSpellIndices, debuffTargetNeedsSpell, ctx, options)
end

function botdebuff.getHookFn(name)
    if name == 'doDebuff' then
        return function(hookName)
            if utils.isNearPrimaryBindPoint() then
                local rc = state.getRunconfig()
                if state.getRunState() == state.STATES.resume_doDebuff then
                    state.clearRunState()
                    rc.CurSpell = {}
                    rc.statusMessage = ''
                end
                if state.getRunState() == state.STATES.casting and rc.CurSpell and rc.CurSpell.sub == 'debuff' then
                    spellutils.clearCastingStateOrResume()
                end
                utils.enforceBindStealth()
                return
            end
            if state.isTravelMode() and not state.isTravelAttackOverriding() then return end
            if botmove.isBeyondFollowDistance() then return end
            if utils.isNonCombatZone(mq.TLO.Zone.ShortName()) then return end
            local myconfig = botconfig.config
            if not (myconfig.settings.dodebuff or state.isTravelAttackOverriding()) or not (myconfig.debuff.spells and #myconfig.debuff.spells > 0) then return end
            local rc = state.getRunconfig()
            if not rc.MobList[1] then
                if state.getRunState() == state.STATES.resume_doDebuff then
                    state.clearRunState()
                    rc.CurSpell = {}
                    rc.statusMessage = ''
                    return
                end
                if state.getRunState() == state.STATES.casting and rc.CurSpell and rc.CurSpell.sub == 'debuff' then
                    spellutils.clearCastingStateOrResume()
                    return
                end
                return
            end
            if state.getRunState() == state.STATES.idle then rc.statusMessage = 'Debuff Check' end
            botdebuff.DebuffCheck(bothooks.getPriority(hookName))
        end
    end
    return nil
end

return botdebuff
