local mq = require('mq')
local botconfig = require('lib.config')
local spellbands = require('lib.spellbands')
local spellutils = require('lib.spellutils')
local state = require('lib.state')
local utils = require('lib.utils')
local charinfo = require('plugin.charinfo')
local bothooks = require('lib.bothooks')
local castutils = require('lib.castutils')
local botmove = require('botmove')

local botbuff = {}
local BuffClass = {}
local bardtwist = require('lib.bardtwist')

local function defaultBuffEntry()
    return botconfig.getDefaultSpellEntry('buff')
end

function botbuff.LoadBuffConfig()
    castutils.LoadSpellSectionConfig('buff', {
        defaultEntry = defaultBuffEntry,
        bandsKey = 'buff',
        storeIn = BuffClass,
        perEntryAfterBands = function(entry, i)
            BuffClass[i].petspell = spellutils.IsPetSummonSpell(entry) or BuffClass[i].petspell
        end,
    })
end

castutils.RegisterSectionLoader('buff', 'dobuff', botbuff.LoadBuffConfig)

local function IconCheck(index, EvalID)
    local entry = botconfig.getSpellEntry('buff', index)
    if not entry then return true end
    local spellicon = entry.spellicon
    if not spellicon or spellicon == 0 then return true end
    local botname = mq.TLO.Spawn(EvalID).Name()
    local info = charinfo.GetInfo(botname)
    local hasIcon = info and spellutils.PeerHasBuff(info, spellicon)
    return not hasIcon
end

local function BuffEvalBotNeedsBuff(botid, botname, spellid, rangeSq, index, targethit)
    local spawnid = mq.TLO.Spawn(botid).ID()
    local peer = charinfo.GetInfo(botname)
    if not peer then return nil, nil end
    local botbuff = spellutils.PeerHasBuff(peer, spellid)
    local botbuffstack = peer:Stacks(spellid)
    local botfreebuffslots = peer.FreeBuffSlots
    local botspawn = spawnid and mq.TLO.Spawn(spawnid)
    local botdistSq = botspawn and utils.getDistanceSquared2D(mq.TLO.Me.X(), mq.TLO.Me.Y(), botspawn.X(), botspawn.Y())
    if not (spawnid and botbuffstack and botfreebuffslots and botfreebuffslots > 0) then
        spellutils.BuffLog('skip %s [%s]: %s', botname, targethit,
            (not spawnid) and 'no spawn' or (not botbuffstack) and 'will not stack' or 'no free buff slots')
        return nil, nil
    end
    if not IconCheck(index, spawnid) or botbuff then
        spellutils.BuffLog('skip %s [%s]: already has it', botname, targethit)
        return nil, nil
    end
    if rangeSq and botdistSq and botdistSq <= rangeSq then return botid, targethit end
    spellutils.BuffLog('skip %s [%s]: out of range', botname, targethit)
    return nil, nil
end

local function BuffEvalSelf(index, entry, spell, spellid, range, myid, myclass, tanktar)
    if not BuffClass[index] then return nil, nil end
    if myclass ~= 'BRD' then
        local mypetid = mq.TLO.Me.Pet.ID()
        if BuffClass[index].petspell and IconCheck(index, myid) and mypetid == 0 and not (mq.TLO.Me.Buff(spell)() or mq.TLO.Me.Song(spell)()) then
            return myid, 'petspell'
        end
        if BuffClass[index].petspell and mypetid > 0 then
            return nil, nil
        end
        if BuffClass[index].self then
            local buffdur = mq.TLO.Me.Buff(spell).Duration()
            local mycasttime = mq.TLO.Spell(spell).MyCastTime()
            local buff = mq.TLO.Me.Buff(spell)() or mq.TLO.Me.Song(spell)()
            local stacks = mq.TLO.Spell(spell).Stacks()
            local tartype = mq.TLO.Spell(spell).TargetType()
            local freebuffslots = mq.TLO.Me.FreeBuffSlots()
            if (not buff) or (buffdur and buffdur < spellutils.BUFF_REFRESH_THRESHOLD_MS and mycasttime > 0 and freebuffslots > 0) then
                if IconCheck(index, myid) then
                    if tartype == 'Self' and stacks then return myid, 'self' end
                    if stacks then return myid, 'self' end
                    spellutils.BuffLog('skip self %s: will not stack', spell)
                else
                    spellutils.BuffLog('skip self %s: already present (icon)', spell)
                end
            else
                spellutils.BuffLog('skip self %s: still up', spell)
            end
        end
        return nil, nil
    end
    -- BRD: all self buffs are handled by twist (lib/bardtwist). No cast from buff hook; detrimental-on-tank removed.
    if myclass == 'BRD' and BuffClass[index].self then
        return nil, nil
    end
    return nil, nil
end

local function BuffEvalTank(index, entry, spell, spellid, rangeSq, tank, tankid)
    if not tank or not entry or not BuffClass[index].tank or not tankid or tankid <= 0 then return nil, nil end
    if not IconCheck(index, tankid) then return nil, nil end
    local peer = charinfo.GetInfo(tank)
    if peer then
        return BuffEvalBotNeedsBuff(tankid, tank, spellid, rangeSq, index, 'tank')
    end
    local tankspawn = mq.TLO.Spawn(tankid)
    local tankdistSq = utils.getDistanceSquared2D(mq.TLO.Me.X(), mq.TLO.Me.Y(), tankspawn.X(), tankspawn.Y())
    if not rangeSq or not tankdistSq or tankdistSq > rangeSq then return nil, nil end
    if not spellutils.EnsureSpawnBuffsPopulated(tankid, 'buff', index, 'tank', nil, 'after_tank', nil) then
        return nil, nil
    end
    if spellutils.SpawnNeedsBuff(tankid, spell, entry.spellicon) then return tankid, 'tank' end
    if not mq.TLO.Group.Member(tank).Index() then return tankid, 'tank' end
    return nil, nil
end

-- Avoid storing mq.TLO.Spell/FindItem.Spell proxy; use direct chains (TLO quirk).
local function getSpellRanges(entry)
    if not entry or not entry.spell then return nil, nil end
    if entry.gem == 'item' then
        if not mq.TLO.FindItem(entry.spell)() then return nil, nil end
        return mq.TLO.FindItem(entry.spell).Spell.MyRange(), mq.TLO.FindItem(entry.spell).Spell.AERange()
    end
    return mq.TLO.Spell(entry.spell).MyRange(), mq.TLO.Spell(entry.spell).AERange()
end

local function BuffEvalGroupBuff(index, entry, spell, spellid, range)
    local _, aeRange = getSpellRanges(entry)
    if not aeRange or aeRange <= 0 then return nil, nil end
    local aeRangeSq = aeRange * aeRange
    local function needBuff(grpmember, grpid, grpname, peer)
        if peer then
            local hasBuff = spellutils.PeerHasBuff(peer, spellid)
            local stacks = peer:Stacks(spellid)
            local free = peer.FreeBuffSlots
            return not hasBuff and stacks and free and free > 0
        end
        return spellutils.SpawnNeedsBuff(grpid, spell, entry.spellicon)
    end
    return castutils.evalGroupAECount(entry, 'groupbuff', index, BuffClass, 'groupbuff', needBuff, { aeRangeSq = aeRangeSq })
end

local function BuffEvalMyPet(index, entry, spell, spellid, rangeSq)
    if not BuffClass[index].mypet then return nil, nil end
    local mypetid = mq.TLO.Me.Pet.ID()
    local petbuff = mq.TLO.Me.Pet.Buff(spell)()
    local mypetSq = utils.getDistanceSquared2D(mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Pet.X(), mq.TLO.Me.Pet.Y())
    local myPeer = charinfo.GetInfo(mq.TLO.Me.Name())
    local petstacks = myPeer and myPeer:StacksPet(spellid)
    if mypetid > 0 and petstacks and not petbuff and mypetSq and rangeSq and mypetSq <= rangeSq then
        return mypetid, 'mypet'
    end
    return nil, nil
end

local function BuffEvalPets(index, entry, spellid, rangeSq, bots, botcount)
    if not BuffClass[index].pet then return nil, nil end
    for i = 1, botcount do
        if bots[i] then
            local peer = charinfo.GetInfo(bots[i])
            if peer then
                local petSpawnProxy = mq.TLO.Spawn('pc =' .. bots[i]).Pet
                local petid = petSpawnProxy.ID()
                if not petid or petid == 0 then
                    -- skip: no pet or proxy not valid
                else
                    local petdistSq = utils.getDistanceSquared2D(mq.TLO.Me.X(), mq.TLO.Me.Y(), petSpawnProxy.X(), petSpawnProxy.Y())
                    local petbuff = spellutils.PeerHasPetBuff(peer, spellid)
                    local spawnid = mq.TLO.Spawn('pc =' .. bots[i]).ID()
                    local petstacks = peer:StacksPet(spellid)
                    if spawnid and spawnid > 0 and petstacks and IconCheck(index, spawnid) and not petbuff and rangeSq and petdistSq and petdistSq <= rangeSq then
                        return petid, 'pet'
                    end
                end
            end
        end
    end
    return nil, nil
end

local BUFF_PHASE_ORDER = { 'self', 'byname', 'tank', 'groupbuff', 'groupmember', 'pc', 'mypet', 'pet' }

--- Single place for buff context: tank, tankid, class-ordered bots, botcount, buffCount. Used by BuffCheck and getTargets/needsSpell.
local function buffBuildContext()
    local tank, tankid = spellutils.GetTankInfo(false)
    local bots = spellutils.GetBotListOrdered()
    local count = botconfig.getSpellCount('buff')
    return { tank = tank, tankid = tankid, bots = bots, botcount = #bots, buffCount = count }
end

local function filterCorpses(targets)
    if not targets or #targets == 0 then return targets end
    local out = {}
    for i = 1, #targets do
        local t = targets[i]
        if t and t.id and mq.TLO.Spawn(t.id).Type() ~= 'Corpse' then
            out[#out + 1] = t
        end
    end
    return out
end

local function buffGetTargetsForPhase(phase, context)
    if phase == 'self' then return castutils.getTargetsSelf() end
    if phase == 'tank' then return filterCorpses(castutils.getTargetsTank(context)) end
    if phase == 'groupbuff' then return castutils.getTargetsGroupCaster('groupbuff') end
    if phase == 'groupmember' then return filterCorpses(castutils.getTargetsGroupMember(context, { excludeSelfAndTank = true })) end
    if phase == 'pc' then return filterCorpses(castutils.getTargetsPc(context, { excludeTank = true })) end
    if phase == 'mypet' then return castutils.getTargetsMypet() end
    if phase == 'pet' then return castutils.getTargetsPet(context) end
    if phase == 'byname' and context.buffCount then
        local out = {}
        local seen = {}
        local function addByName(name)
            local n = type(name) == 'string' and (name:match('^%s*(.-)%s*$') or '') or ''
            if n == '' or seen[n] then return end
            seen[n] = true
            local botid = mq.TLO.Spawn('pc =' .. n).ID()
            if botid and botid > 0 then out[#out + 1] = { id = botid, targethit = 'byname' } end
        end
        for idx = 1, context.buffCount do
            -- Managed per-buff name list (clean UI). Resolved by spawn name, so it covers PCs that are
            -- NOT in the bot network (e.g. guildmates) as well as networked characters.
            local entry = botconfig.getSpellEntry('buff', idx)
            if entry and type(entry.buffNames) == 'table' then
                for _, name in ipairs(entry.buffNames) do addByName(name) end
            end
            -- Legacy key-based byname (backward compat): network peers only.
            if BuffClass[idx] and BuffClass[idx].name then
                for name, c in pairs(BuffClass[idx]) do
                    if name ~= 'name' and name ~= 'classes' and name ~= 'classesAll' and type(name) == 'string' and charinfo.GetInfo(name) then
                        addByName(name)
                    end
                end
            end
        end
        return filterCorpses(out)
    end
    return {}
end

local function buffHasNameList(spellIndex)
    local entry = botconfig.getSpellEntry('buff', spellIndex)
    return entry and type(entry.buffNames) == 'table' and #entry.buffNames > 0 or false
end

local function buffBandHasPhase(spellIndex, phase)
    if phase == 'byname' then
        if buffHasNameList(spellIndex) then return true end
        return BuffClass[spellIndex] and BuffClass[spellIndex].name and true or false
    end
    return castutils.bandHasPhaseSimple(BuffClass, spellIndex, phase)
end

local function buffTargetNeedsSpell(spellIndex, targetId, targethit, context)
    local entry = botconfig.getSpellEntry('buff', spellIndex)
    if not entry or not BuffClass[spellIndex] then return nil, nil end
    local spell, _, _, spellid = spellutils.GetSpellInfo(entry)
    if not spell or not spellid then return nil, nil end
    local sid = (spellid == 1536) and 1538 or spellid
    local myRange, aeRange = getSpellRanges(entry)
    local range = (myRange and myRange > 0) and myRange or aeRange
    local rangeSq = range and (range * range) or nil
    local tank, tankid, tanktar = spellutils.GetTankInfo(false)
    tanktar = tanktar or
    (tank and charinfo.GetInfo(tank) and charinfo.GetInfo(tank).Target and charinfo.GetInfo(tank).Target.ID or nil)
    local myid = mq.TLO.Me.ID()
    local myclass = mq.TLO.Me.Class.ShortName()

    if targethit == 'self' then
        return BuffEvalSelf(spellIndex, entry, spell, sid, range, myid, myclass, tanktar)
    end
    if targethit == 'tank' then
        local id, hit = BuffEvalTank(spellIndex, entry, spell, sid, rangeSq, context.tank, context.tankid)
        if id == targetId then return id, hit end
        return nil, nil
    end
    if targethit == 'groupbuff' then
        return BuffEvalGroupBuff(spellIndex, entry, spell, sid, range)
    end
    if targethit == 'mypet' then
        local id, hit = BuffEvalMyPet(spellIndex, entry, spell, sid, rangeSq)
        if id == targetId then return id, hit end
        return nil, nil
    end
    if targethit == 'pet' then
        local id, hit = BuffEvalPets(spellIndex, entry, sid, rangeSq, context.bots,
            context.botcount or #(context.bots or {}))
        if id == targetId then return id, hit end
        return nil, nil
    end
    if targethit == 'byname' then
        local name = mq.TLO.Spawn(targetId).CleanName()
        if not name then return nil, nil end
        if charinfo.GetInfo(name) then
            -- Networked character: use peer buff data (no retarget needed).
            local id, hit = BuffEvalBotNeedsBuff(targetId, name, sid, rangeSq, spellIndex, 'byname')
            if id then return id, hit end
        elseif IconCheck(spellIndex, targetId)
            and spellutils.EnsureSpawnBuffsPopulated(targetId, 'buff', spellIndex, 'byname', nil, nil, nil)
            and spellutils.SpawnNeedsBuff(targetId, spell, entry.spellicon) then
            -- Non-network PC (e.g. guildmate): inspect via spawn; only cast when in range.
            local sp = mq.TLO.Spawn(targetId)
            local dSq = sp and utils.getDistanceSquared2D(mq.TLO.Me.X(), mq.TLO.Me.Y(), sp.X(), sp.Y())
            if not rangeSq or (dSq and dSq <= rangeSq) then
                return targetId, 'byname'
            end
        end
        return nil, nil
    end
    if BuffClass[spellIndex].groupmember or BuffClass[spellIndex].pc then
        local grpname = mq.TLO.Spawn(targetId).CleanName()
        local lc = targethit
        if (BuffClass[spellIndex].classes == 'all' or (BuffClass[spellIndex].classes and BuffClass[spellIndex].classes[lc])) and IconCheck(spellIndex, targetId) then
            local peer = charinfo.GetInfo(grpname)
            if peer then
                local id, hit = BuffEvalBotNeedsBuff(targetId, grpname, sid, rangeSq, spellIndex, lc)
                if id then return id, hit end
            else
                if spellutils.EnsureSpawnBuffsPopulated(targetId, 'buff', spellIndex, lc, nil, nil, nil) and spellutils.SpawnNeedsBuff(targetId, spell, entry.spellicon) then
                    return targetId, lc
                end
            end
        end
    end
    return nil, nil
end

function botbuff.BuffCheck(runPriority)
    local myconfig = botconfig.config
    local inCombatContext = state.isCombatContextForBuff()
    if mq.TLO.Me.Class.ShortName() == 'BRD' and myconfig.settings.dobuff and not utils.isNearPrimaryBindPoint() then
        bardtwist.EnsureDefaultTwistRunning()
    end
    local ctx = buffBuildContext()
    local count = ctx.buffCount
    if count <= 0 then return false end
    local options = {
        skipInterruptForBRD = true,
        runPriority = runPriority,
        entryValid = function(i)
            local entry = botconfig.getSpellEntry('buff', i)
            if not entry then return false end
            local gem = entry.gem
            if entry.enabled == false then return false end
            if not ((type(gem) == 'number' and gem ~= 0) or type(gem) == 'string') then return false end
            local bc = BuffClass[i]
            if mq.TLO.Me.Class.ShortName() ~= 'BRD' and bc and bc.combatOnly == true then
                return inCombatContext
            end
            return (not inCombatContext) or (inCombatContext and bc and bc.inCombat == true)
        end,
    }
    local function getSpellIndices(phase, _target)
        return spellutils.getSpellIndicesForPhase(count, phase, buffBandHasPhase)
    end
    return spellutils.RunPhaseFirstSpellCheck('buff', 'doBuff', BUFF_PHASE_ORDER, buffGetTargetsForPhase, getSpellIndices,
        buffTargetNeedsSpell, ctx, options)
end

--- True when a PC corpse within acleash belongs to a current group member (cleric defers buff for rez focus).
local function clericDeferBuffForGroupCorpse(acleash)
    if not mq.TLO.Group.Members() or mq.TLO.Group.Members() == 0 then
        return false
    end
    local count = mq.TLO.SpawnCount('pccorpse radius ' .. acleash)()
    if not count or count == 0 then return false end
    for i = 1, count do
        local spawn = mq.TLO.NearestSpawn(i, 'pccorpse radius ' .. acleash)
        local name = spawn.CleanName()
        if name then
            name = string.gsub(name, "'s corpse", "")
            if mq.TLO.Group.Member(name).Index() then
                return true
            end
        end
    end
    return false
end

function botbuff.getHookFn(name)
    if name == 'doBuff' then
        return function(hookName)
            if utils.isNearPrimaryBindPoint() then return end
            if state.isTravelMode() then return end
            if botmove.isBeyondFollowDistance() then return end
            local myconfig = botconfig.config
            local rc = state.getRunconfig()
            if not myconfig.settings.dobuff or not (myconfig.buff.spells and #myconfig.buff.spells > 0) then return end
            local pull = myconfig.pull
            if pull and pull.roam and rc.dopull and rc.roamNavTargetId then return end
            if mq.TLO.Me.Class.ShortName() == 'CLR' and clericDeferBuffForGroupCorpse(myconfig.settings.acleash or 75) then return end
            if state.getRunState() == state.STATES.idle then
                local msg = rc.statusMessage or ''
                local roamBuffWindow = pull and pull.roam and rc.dopull and rc.roamBuffCheckPending
                if roamBuffWindow or (not msg:find('Roaming to', 1, true) and not msg:find('No pull targets', 1, true)
                    and not msg:find('Waiting for pull', 1, true) and not msg:find('Pulling ', 1, true)) then
                    rc.statusMessage = 'Buff Check'
                end
            end
            botbuff.BuffCheck(bothooks.getPriority(hookName))
            if pull and pull.roam and rc.dopull and rc.roamBuffCheckPending then
                local rs = state.getRunState()
                if rs ~= state.STATES.casting and rs ~= state.STATES.resume_doBuff
                    and (mq.TLO.Me.CastTimeLeft() or 0) == 0 then
                    rc.roamBuffCheckPending = false
                end
            end
        end
    end
    return nil
end

return botbuff
