local mq = require('mq')
local botconfig = require('lib.config')
local spellbands = require('lib.spellbands')
local spellutils = require('lib.spellutils')
local state = require('lib.state')
local charinfo = require('plugin.charinfo')
local bothooks = require('lib.bothooks')
local castutils = require('lib.castutils')
local botmove = require('botmove')

local botcure = {}
local CureClass = {}
local CureType = {}

local function defaultCureEntry()
    return botconfig.getDefaultSpellEntry('cure')
end

function botcure.LoadCureConfig()
    castutils.LoadSpellSectionConfig('cure', {
        defaultEntry = defaultCureEntry,
        bandsKey = 'cure',
        storeIn = CureClass,
        perEntryAfterBands = function(entry, i)
            CureType[i] = {}
            local list = entry.curetype
            if not list or #list == 0 then list = { 'all' } end
            for _, word in ipairs(list) do
                CureType[i][word] = word
            end
        end,
    })
end

castutils.RegisterSectionLoader('cure', 'docure', botcure.LoadCureConfig)

local function CureTypeList(index)
    local list = {}
    for k in pairs(CureType[index] or {}) do list[#list + 1] = k end
    return list
end

local CureTypeToPeerKey = {
    poison = "CountPoison",
    disease = "CountDisease",
    curse = "CountCurse",
    corruption = "CountCorruption",
}

local function CureEvalForTarget(index, botname, botid, botclass, targethit, spelltartype, resumePhase, resumeGroupIndex)
    local cureindex = CureClass[index]
    if not cureindex then return nil, nil end
    for _, v in pairs(CureType[index] or {}) do
        if not botname then
            local curetype = mq.TLO.Me[v] and mq.TLO.Me[v]()
            if string.lower(v) ~= 'all' and curetype then
                if spelltartype == 'Self' then return mq.TLO.Me.ID(), 'self' end
                return mq.TLO.Me.ID(), 'self'
            end
        else
            local peer = charinfo.GetInfo(botname)
            if peer then
                local detrimentals = peer.Detrimentals or nil
                local key = (string.lower(v) ~= 'all') and CureTypeToPeerKey[string.lower(v)]
                local curetype = key and (peer[key] or nil) or nil
                if string.lower(v) == 'all' and detrimentals and detrimentals > 0 then
                    if targethit == 'tank' then return botid, 'tank' end
                    if targethit == 'groupmember' and spellutils.DistanceCheck('cure', index, botid) then
                        return botid, 'groupmember'
                    end
                    if targethit == botclass and cureindex[botclass] and spellutils.DistanceCheck('cure', index, botid) then
                        return botid, botclass
                    end
                end
                if string.lower(v) ~= 'all' and curetype and curetype > 0 then
                    if targethit == 'tank' and mq.TLO.Spawn(botid).Type() == 'PC' and spellutils.DistanceCheck('cure', index, botid) then
                        return botid, 'tank'
                    end
                    if targethit == 'groupmember' and spellutils.DistanceCheck('cure', index, botid) then
                        return botid, 'groupmember'
                    end
                    if targethit == botclass and cureindex[botclass] and spellutils.DistanceCheck('cure', index, botid) then
                        return botid, botclass
                    end
                end
            end
        end
    end
    if botname and botid and not charinfo.GetInfo(botname) then
        if not spellutils.EnsureSpawnBuffsPopulated(botid, 'cure', index, targethit, CureTypeList(index), resumePhase, resumeGroupIndex) then
            return nil, nil
        end
        local typelist = CureTypeList(index)
        local needCure = spellutils.SpawnDetrimentalsForCure(botid, typelist)
        if needCure and spellutils.DistanceCheck('cure', index, botid) then
            if targethit == 'tank' then return botid, 'tank' end
            if targethit == 'groupmember' then return botid, 'groupmember' end
        end
    end
    return nil, nil
end

local function CureEvalGroupCure(index, entry)
    local typelist = CureTypeList(index)
    local function needCure(grpmember, grpid, grpname, peer)
        if peer then
            for _, v in pairs(CureType[index] or {}) do
                local detrimentals = peer.Detrimentals or nil
                local key = (string.lower(v) ~= 'all') and CureTypeToPeerKey[string.lower(v)]
                local curetype = key and (peer[key] or nil) or nil
                if (string.lower(v) == 'all' and detrimentals and detrimentals > 0) or (string.lower(v) ~= 'all' and curetype and curetype > 0) then
                    return true
                end
            end
            return false
        end
        return spellutils.SpawnDetrimentalsForCure(grpid, typelist)
    end
    return castutils.evalGroupAECount(entry, 'groupcure', index, CureClass, 'groupcure', needCure, {})
end

local function CureEval(index)
    local entry = botconfig.getSpellEntry('cure', index)
    local spell, _, spelltartype = spellutils.GetSpellInfo(entry)
    if not spell then return nil, nil end
    local bots = spellutils.GetBotListOrdered()
    local botcount = charinfo.GetPeerCnt()
    local tank, tankid = spellutils.GetTankInfo(false)
    local cureindex = CureClass[index]
    if not cureindex then return nil, nil end
    if cureindex.self then
        local id, hit = CureEvalForTarget(index, nil, nil, nil, 'self', spelltartype)
        if id then return id, hit end
    end
    if cureindex.tank and tankid then
        local id, hit = CureEvalForTarget(index, tank, tankid, nil, 'tank', spelltartype, 'after_tank', nil)
        if id then return id, hit end
    end
    if cureindex.groupcure then
        local id, hit = CureEvalGroupCure(index, entry)
        if id then return id, hit end
    end
    if cureindex.groupmember then
        for i = 1, botcount do
            local botname = bots[i]
            local botid = mq.TLO.Spawn('pc =' .. botname).ID()
            local botclass = mq.TLO.Spawn('pc =' .. botname).Class.ShortName()
            if botclass then botclass = string.lower(botclass) end
            if cureindex[botclass] and botid and mq.TLO.Group.Member(botname).ID() then
                local id, hit = CureEvalForTarget(index, botname, botid, botclass, 'groupmember', spelltartype)
                if id then return id, hit end
            end
        end
        for i = 1, mq.TLO.Group.Members() do
            local grpmember = mq.TLO.Group.Member(i)
            if grpmember and grpmember.Class then
                local grpname = grpmember.Name()
                local grpid = grpmember.ID()
                local grpclass = grpmember.Class.ShortName()
                if grpclass then grpclass = string.lower(grpclass) end
                if grpid and grpid > 0 and cureindex[grpclass] and not charinfo.GetInfo(grpname) then
                    local id, hit = CureEvalForTarget(index, grpname, grpid, grpclass, 'groupmember', spelltartype,
                        'groupmember', i)
                    if id then return id, hit end
                end
            end
        end
    end
    if cureindex.pc and botcount then
        for i = 1, botcount do
            local botname = bots[i]
            if botname then
                local botid = mq.TLO.Spawn('pc =' .. botname).ID()
                local botclass = mq.TLO.Spawn('pc =' .. botname).Class.ShortName()
                if botclass then botclass = string.lower(botclass) end
                if botclass and cureindex[botclass] then
                    local id, hit = CureEvalForTarget(index, botname, botid, botclass, botclass, spelltartype)
                    if id then return id, hit end
                end
            end
        end
    end
    return nil, nil
end

local CURE_PHASE_ORDER = { 'self', 'tank', 'groupcure', 'groupmember', 'pc' }
local CURE_PHASE_ORDER_PRIORITY = { 'priority' }

--- Single place for cure context: tank, tankid, class-ordered bots, botcount. Both priorityCure and doCure use this.
local function cureBuildContext()
    local tank, tankid = spellutils.GetTankInfo(false)
    local bots = spellutils.GetBotListOrdered()
    return { tank = tank, tankid = tankid, bots = bots, botcount = #bots }
end

local function cureGetTargetsForPhase(phase, context)
    if phase == 'priority' then
        local count = botconfig.getSpellCount('cure')
        if count <= 0 then return {} end
        local priorityIndices = spellutils.getSpellIndicesForPhase(count, 'priority', CureClass)
        if not priorityIndices or #priorityIndices == 0 then return {} end
        local needTypes = {}
        for _, i in ipairs(priorityIndices) do
            local band = CureClass[i]
            if band then
                for _, targetType in ipairs(CURE_PHASE_ORDER) do
                    if band[targetType] then needTypes[targetType] = true end
                end
            end
        end
        local out = {}
        for _, targetType in ipairs(CURE_PHASE_ORDER) do
            if needTypes[targetType] then
                local list = cureGetTargetsForPhase(targetType, context)
                for _, t in ipairs(list) do out[#out + 1] = t end
            end
        end
        return out
    end
    if phase == 'self' then return castutils.getTargetsSelf() end
    if phase == 'tank' then return castutils.getTargetsTank(context) end
    if phase == 'groupcure' then return castutils.getTargetsGroupCaster('groupcure') end
    if phase == 'groupmember' then return castutils.getTargetsGroupMember(context, { botsFirst = true, excludeBotsFromGroup = true }) end
    if phase == 'pc' then return castutils.getTargetsPc(context) end
    return {}
end

local function cureTargetNeedsSpell(spellIndex, targetId, targethit, context)
    local entry = botconfig.getSpellEntry('cure', spellIndex)
    if not entry or not CureClass[spellIndex] then return nil, nil end
    local spell, _, spelltartype = spellutils.GetSpellInfo(entry)
    if not spell then return nil, nil end
    local botname = (targethit ~= 'self') and mq.TLO.Spawn(targetId).CleanName() or nil
    local botclass = targethit
    if targethit == 'self' then
        return CureEvalForTarget(spellIndex, nil, nil, nil, 'self', spelltartype)
    end
    if targethit == 'tank' then
        local id, hit = CureEvalForTarget(spellIndex, context.tank, context.tankid, nil, 'tank', spelltartype, nil, nil)
        if id == targetId then return id, hit end
        return nil, nil
    end
    if targethit == 'groupcure' then
        return CureEvalGroupCure(spellIndex, entry)
    end
    local id, hit = CureEvalForTarget(spellIndex, botname, targetId, botclass, targethit, spelltartype, nil, nil)
    if id == targetId then return id, hit end
    return nil, nil
end

function botcure.CureCheck(runPriority, phaseOrder, hookName)
    phaseOrder = phaseOrder or CURE_PHASE_ORDER
    hookName = hookName or 'doCure'
    local myconfig = botconfig.config
    if state.getRunconfig().SpellTimer > mq.gettime() then return false end
    local count = botconfig.getSpellCount('cure')
    if count <= 0 then return false end
    local ctx = cureBuildContext()
    local options = {
        skipInterruptForBRD = true,
        runPriority = runPriority,
        afterCast = (hookName == 'doCure') and function(i)
            local e, c = CureEval(i)
            return e and c
        end or nil,
        entryValid = function(i)
            local entry = botconfig.getSpellEntry('cure', i)
            if not entry then return false end
            local gem = entry.gem
            return (entry.enabled ~= false) and ((type(gem) == 'number' and gem ~= 0) or type(gem) == 'string')
        end,
    }
    local function getSpellIndices(phase, _target)
        return spellutils.getSpellIndicesForPhase(count, phase, CureClass)
    end
    return spellutils.RunPhaseFirstSpellCheck('cure', hookName, phaseOrder, cureGetTargetsForPhase, getSpellIndices,
        cureTargetNeedsSpell, ctx, options)
end

function botcure.getHookFn(name)
    if name == 'priorityCure' then
        return function(hookName)
            local myconfig = botconfig.config
            if state.isTravelMode() and not state.isTravelAttackOverriding() then return end
            if botmove.isBeyondFollowDistance() then return end
            if not (myconfig.settings.docure or state.isTravelAttackOverriding()) or not (myconfig.cure.spells and #myconfig.cure.spells > 0) then return end
            local count = botconfig.getSpellCount('cure')
            if count <= 0 then return end
            local priorityIndices = spellutils.getSpellIndicesForPhase(count, 'priority', CureClass)
            if not priorityIndices or #priorityIndices == 0 then return end
            if state.getRunState() == state.STATES.idle then state.getRunconfig().statusMessage = 'Cure Check' end
            botcure.CureCheck(bothooks.getPriority(hookName), CURE_PHASE_ORDER_PRIORITY, 'priorityCure')
        end
    end
    if name == 'doCure' then
        return function(hookName)
            local myconfig = botconfig.config
            if state.isTravelMode() and not state.isTravelAttackOverriding() then return end
            if botmove.isBeyondFollowDistance() then return end
            if not (myconfig.settings.docure or state.isTravelAttackOverriding()) or not (myconfig.cure.spells and #myconfig.cure.spells > 0) then return end
            if state.getRunState() == state.STATES.idle then state.getRunconfig().statusMessage = 'Cure Check' end
            botcure.CureCheck(bothooks.getPriority(hookName), CURE_PHASE_ORDER, 'doCure')
        end
    end
    return nil
end

return botcure
