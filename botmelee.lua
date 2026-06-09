local mq = require('mq')
local botconfig = require('lib.config')
local combat = require('lib.combat')
local state = require('lib.state')
local bothooks = require('lib.bothooks')
local targeting = require('lib.targeting')
local botmove = require('botmove')
local utils = require('lib.utils')
local charinfo = require('plugin.charinfo')
local tankrole = require('lib.tankrole')
local aggro = require('lib.aggro')
local spawnutils = require('lib.spawnutils')
local spellstates = require('lib.spellstates')
local spellutils = require('lib.spellutils')
local myconfig = botconfig.config
local botmelee = {}

function botmelee.LoadMeleeConfig()
end

botconfig.RegisterConfigLoader(function() if botconfig.config.settings.domelee then botmelee.LoadMeleeConfig() end end)

state.getRunconfig().mobprobtimer = 0
local _lastEngageStickCmd = nil

local function getStayBehindStickToken()
    if mq.TLO.Me.Class.ShortName() == 'ROG' then return 'behind' end
    return '!front'
end

local function stickCmdHasBehindToken(cmd)
    if not cmd then return false end
    return cmd:match('%sbehind%s') ~= nil or cmd:match('%sbehind$') ~= nil
        or cmd:match('^behind%s') ~= nil or cmd == 'behind'
end

local function stickCmdHasStayBehindToken(cmd)
    return cmd and (cmd:find('!front', 1, true) ~= nil or stickCmdHasBehindToken(cmd))
end

local function stripStayBehindTokens(cmd)
    if not cmd then return '' end
    local s = cmd:gsub('%s+!front%s*', ' '):gsub('!front%s+', ''):gsub('%s+!front$', ''):gsub('^!front%s*', '')
    s = s:gsub('%s+behind%s+', ' '):gsub('%s+behind%s*$', ''):gsub('^behind%s+', '')
    return (s:match('^%s*(.-)%s*$')) or s
end

local function withStayBehindToken(cmd)
    local token = getStayBehindStickToken()
    if not cmd or cmd == '' then return token end
    if stickCmdHasStayBehindToken(cmd) then return cmd end
    return cmd .. ' ' .. token
end

local function getEngageStickCmd()
    local cmd = myconfig.melee.stickcmd or 'hold uw 7'
    if tankrole.AmIMainTank() then return cmd end
    if myconfig.melee.stayBehind ~= true then return cmd end
    local behindPct = tonumber(myconfig.melee.behindAggroPct) or 90
    if aggro.pctAggroAvailable() then
        local pct = aggro.getPctAggro()
        if pct ~= nil and pct > behindPct then
            return stripStayBehindTokens(cmd)
        end
    end
    return withStayBehindToken(cmd)
end

local function isCastingBusy()
    if state.getRunState() == state.STATES.casting then return true end
    if mq.TLO.Me.CastTimeLeft() > 0 then return true end
    local cs = state.getRunconfig().CurSpell
    if cs and cs.sub and cs.phase then
        if cs.phase == 'precast' or cs.phase == 'precast_wait_move' or cs.phase == 'casting'
            or cs.phase == 'cast_complete_pending_resist' then
            return true
        end
    end
    return false
end

--- Rogue: dump aggro with Hide when PctAggro is high. Returns true if evade was attempted.
local function tryRogueEvade()
    if mq.TLO.Me.Class.ShortName() ~= 'ROG' then return false end
    if not aggro.pctAggroAvailable() then return false end
    if not mq.TLO.Me.Combat() then return false end
    if tankrole.AmIMainTank() then return false end
    if mq.TLO.Me.Invis() then return false end
    if isCastingBusy() then return false end
    if not mq.TLO.Me.AbilityReady('Hide')() then return false end
    local pct = aggro.getPctAggro()
    local threshold = tonumber(myconfig.melee.evadePct) or 90
    if pct == nil or pct < threshold then return false end
    mq.cmd('/squelch /attack off')
    mq.cmd('/squelch /doability hide')
    mq.cmd('/squelch /attack on')
    if state.getRunState() ~= state.STATES.casting then
        state.getRunconfig().statusMessage = string.format('Evading (PctAggro %d%%)', pct)
    end
    return true
end

-- When I am MT and my target is a PC: clear combat state.
local function clearTankCombatState()
    local rc = state.getRunconfig()
    rc.engageTargetId = nil
    rc.allMezzedEngageId = nil
    combat.ResetCombatState()
end

local MEZ_UNKNOWN_MS = 999999999

local function clearAllMezzedLock(rc)
    rc.allMezzedEngageId = nil
end

local function spawnIdInLosList(losList, id)
    if not id then return false end
    for _, v in ipairs(losList) do
        if v.ID() == id then return true end
    end
    return false
end

local _mezSpellIdsCache = nil

local function getMezSpellIds()
    if _mezSpellIdsCache then return _mezSpellIdsCache end
    local ids = {}
    local debuff = myconfig.debuff
    if debuff and debuff.spells then
        for _, entry in ipairs(debuff.spells) do
            if entry and spellutils.IsMezSpell(entry) and entry.spell then
                local ok, spellid = pcall(function()
                    if entry.gem == 'item' then
                        return mq.TLO.FindItem(entry.spell).Spell.ID()
                    end
                    return mq.TLO.Spell(entry.spell).ID()
                end)
                if ok and spellid then ids[#ids + 1] = spellid end
            end
        end
    end
    _mezSpellIdsCache = ids
    return ids
end

botconfig.RegisterConfigLoader(function() _mezSpellIdsCache = nil end)

local function getTargetMezRemainingMs()
    if not mq.TLO.Target.Mezzed() then return 0 end
    local maxSlots = (mq.TLO.Target.MaxBuffSlots and mq.TLO.Target.MaxBuffSlots()) or 40
    local minDur = nil
    for i = 1, maxSlots do
        local b = mq.TLO.Target.Buff(i)
        if b and b() then
            local ok, sub = pcall(function() return b.Subcategory and b.Subcategory() end)
            if ok and sub == 'Enthrall' then
                local ok2, dur = pcall(function() return b.Duration and b.Duration() or 0 end)
                local d = (ok2 and dur) or 0
                if d > 0 and (not minDur or d < minDur) then minDur = d end
            end
        end
    end
    return minDur or MEZ_UNKNOWN_MS
end

local function getSpawnMezRemainingMs(spawnId)
    local now = mq.gettime()
    local best = nil
    for _, spellid in ipairs(getMezSpellIds()) do
        local expire = spellstates.GetDebuffExpire(spawnId, spellid)
        if expire then
            local rem = expire - now
            if rem > 0 and (not best or rem < best) then best = rem end
        end
    end
    return best
end

local function targetSpawnAndGetMezRemaining(spawnId)
    if not targeting.TargetAndWaitBuffsPopulated(spawnId, 1000) then return nil, nil end
    if not mq.TLO.Target.Mezzed() then return false, 0 end
    local tracked = getSpawnMezRemainingMs(spawnId)
    return true, tracked or getTargetMezRemainingMs()
end

local function pickShortestMezzedFromCandidates(candidates)
    if not candidates[1] then return nil end
    local bestId = candidates[1].id
    local bestRem = candidates[1].rem
    for i = 2, #candidates do
        local c = candidates[i]
        if c.rem < bestRem then
            bestRem = c.rem
            bestId = c.id
        end
    end
    return bestId
end

-- Shared MA/MT target pick from a sorted LOS list. Skip mezzed; if all mezzed, pick shortest remaining mez and stick.
local function selectEngageTargetFromLosList(losList, engageId)
    local rc = state.getRunconfig()
    if engageId and not spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(engageId)) then
        engageId = nil
    end

    local lockId = rc.allMezzedEngageId
    if lockId then
        if not spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(lockId)) or not spawnIdInLosList(losList, lockId) then
            clearAllMezzedLock(rc)
            lockId = nil
        end
    end

    if lockId then
        local mezzed, _ = targetSpawnAndGetMezRemaining(lockId)
        if mezzed == false then
            clearAllMezzedLock(rc)
            return lockId
        elseif mezzed == true then
            return lockId
        end
    end

    if engageId and spawnIdInLosList(losList, engageId) then
        local mezzed, _ = targetSpawnAndGetMezRemaining(engageId)
        if mezzed == false then
            clearAllMezzedLock(rc)
            return engageId
        end
    end

    local mezzedCandidates = {}
    for _, spawn in ipairs(losList) do
        local sid = spawn.ID()
        local mezzed, rem = targetSpawnAndGetMezRemaining(sid)
        if mezzed == false then
            clearAllMezzedLock(rc)
            return sid
        elseif mezzed == true then
            mezzedCandidates[#mezzedCandidates + 1] = { id = sid, rem = rem or MEZ_UNKNOWN_MS }
        end
    end

    if #mezzedCandidates == 0 then
        clearAllMezzedLock(rc)
        return losList[1] and losList[1].ID() or nil
    end

    local bestId = pickShortestMezzedFromCandidates(mezzedCandidates)
    rc.allMezzedEngageId = bestId
    return bestId
end

-- MobList entry is eligible for MA/MT engage selection (matches TargetFilter camp rules).
local function isEngageableMobListSpawn(spawn)
    if not spawnutils.isAliveEngageSpawn(spawn) then return false end
    local tfNum = tonumber(myconfig.settings.TargetFilter) or 0
    if tfNum == 2 then return true end
    return spawn.LineOfSight()
end

-- MT only: pick from MobList (closest LOS). Prefer Puller's target when present. Skip mezzed; if all mezzed, return shortest remaining mez.
-- Returns mtPick spawn, engageTargetRefound.
local function selectTankTarget(mainTankName)
    if mainTankName ~= mq.TLO.Me.Name() then return nil, false end
    local gmt = mq.TLO.Group.MainTank
    local groupMTName = (gmt and gmt.Name) and gmt.Name() or nil
    if not (mq.TLO.Raid.Members() or not mq.TLO.Group() or groupMTName == mq.TLO.Me.Name()) then return nil, false end
    if mq.TLO.Me.Combat() then return nil, false end
    local pullerTarID = tankrole.GetPullerTargetID()
    local rc = state.getRunconfig()
    local losList = {}
    for _, v in ipairs(rc.MobList) do
        if isEngageableMobListSpawn(v) then table.insert(losList, v) end
    end
    if #losList == 0 then return nil, false end
    local meX, meY = mq.TLO.Me.X(), mq.TLO.Me.Y()
    local engageId = rc.engageTargetId
    if engageId and not spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(engageId)) then
        engageId = nil
    end
    table.sort(losList, function(a, b)
        local aId, bId = a.ID(), b.ID()
        if aId == pullerTarID and bId ~= pullerTarID then return true end
        if aId ~= pullerTarID and bId == pullerTarID then return false end
        if engageId and aId == engageId and bId ~= engageId then return true end
        if engageId and aId ~= engageId and bId == engageId then return false end
        local da = utils.getDistanceSquared2D(meX, meY, a.X(), a.Y())
        local db = utils.getDistanceSquared2D(meX, meY, b.X(), b.Y())
        return (da or 0) < (db or 0)
    end)
    local id = selectEngageTargetFromLosList(losList, engageId)
    return id, (id and id == engageId) or false
end

-- Offtank: if MT target == MA target pick add (Nth other mob); else tank MA's target. Returns chosen id or nil.
local function resolveOfftankTarget(assistName, mainTankName, assistpct)
    if not mainTankName or mainTankName == '' then return nil end
    local rc = state.getRunconfig()
    local maInfo = charinfo.GetInfo(assistName)
    local maTarId = (maInfo and maInfo.ID and maInfo.Target) and maInfo.Target.ID or nil
    if not maTarId and mq.TLO.Spawn('pc =' .. assistName).ID() then
        maTarId = botmelee.GetPCTarget(assistName)
    end
    local mtInfo = charinfo.GetInfo(mainTankName)
    local mtTarId = (mtInfo and mtInfo.ID and mtInfo.Target) and mtInfo.Target.ID or nil
    if not mtTarId and mq.TLO.Spawn('pc =' .. mainTankName).ID() then
        mtTarId = botmelee.GetPCTarget(mainTankName)
    end
    if mtTarId == maTarId then
        local otoffset = myconfig.melee.otoffset or 0
        local nthSpawn = spawnutils.selectNthAdd(rc.MobList, maTarId, otoffset + 1)
        if nthSpawn then
            local actarid = nthSpawn.ID()
            if actarid ~= mq.TLO.Target.ID() then
                printf('\ayCZBot:\ax\arOff-tanking\ax a \ag%s id %s', nthSpawn.CleanName(), actarid)
            end
            return actarid
        end
        if maInfo and maInfo.TargetHP and (maInfo.TargetHP <= assistpct) and maTarId and maTarId > 0 then
            return maTarId
        end
    elseif maTarId and maTarId > 0 then
        return maTarId
    end
    return nil
end

-- DPS: return MA's target when MA is engaging and in MobList at assistpct; else GetPCTarget. Returns id or nil.
local function resolveMeleeAssistTarget(assistName, assistpct)
    local rc = state.getRunconfig()
    local maInfo = charinfo.GetInfo(assistName)
    local maTarId = maInfo and maInfo.Target and maInfo.Target.ID or nil
    if maInfo and maInfo.ID then
        if not spawnutils.isCampAcleashEnforced(rc) and maTarId and maTarId > 0
            and maInfo.TargetHP and (maInfo.TargetHP <= assistpct) then
            return maTarId
        end
        for _, v in ipairs(rc.MobList) do
            if v.ID() == maTarId and maInfo.TargetHP and (maInfo.TargetHP <= assistpct) then
                return maTarId
            end
        end
        return nil
    end
    return botmelee.GetPCTarget(assistName)
end

-- MA bot only: choose target from MobList independent of MT.
-- Returns chosen id or nil.
local function selectMATarget()
    local rc = state.getRunconfig()
    if not rc.MobList or not rc.MobList[1] then return nil end

    local meX, meY = mq.TLO.Me.X(), mq.TLO.Me.Y()

    -- 1) Prefer named (closest engageable named).
    local namedSpawn = nil
    for _, v in ipairs(rc.MobList) do
        if isEngageableMobListSpawn(v) and v.Named() then
            if not namedSpawn then
                namedSpawn = v
            else
                local vDistSq = utils.getDistanceSquared2D(meX, meY, v.X(), v.Y())
                local nDistSq = utils.getDistanceSquared2D(meX, meY, namedSpawn.X(), namedSpawn.Y())
                if vDistSq and nDistSq and vDistSq < nDistSq then namedSpawn = v end
            end
        end
    end
    if namedSpawn then return namedSpawn.ID() end

    -- 2) Otherwise pick the closest engageable mob (prefer the existing engage target to avoid thrash).
    local losList = {}
    for _, v in ipairs(rc.MobList) do
        if isEngageableMobListSpawn(v) then losList[#losList + 1] = v end
    end
    if #losList == 0 then return nil end

    local engageId = rc.engageTargetId
    if engageId and not spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(engageId)) then
        engageId = nil
    end
    table.sort(losList, function(a, b)
        local aId, bId = a.ID(), b.ID()
        if engageId and aId == engageId and bId ~= engageId then return true end
        if engageId and aId ~= engageId and bId == engageId then return false end
        local da = utils.getDistanceSquared2D(meX, meY, a.X(), a.Y())
        local db = utils.getDistanceSquared2D(meX, meY, b.X(), b.Y())
        return (da or 0) < (db or 0)
    end)

    return selectEngageTargetFromLosList(losList, engageId)
end

-- When no engageTargetId: stick off, attack off, pet back, clear NPC target.
local function disengageCombat()
    _lastEngageStickCmd = nil
    local rc = state.getRunconfig()
    rc.allMezzedEngageId = nil
    if state.getRunState() ~= state.STATES.casting then rc.statusMessage = '' end
    combat.ResetCombatState()
    if state.getRunState() == state.STATES.melee then state.clearRunState() end
end

-- When engageTargetId is set: pet attack, target (blocking TargetAndWait), stand, attack on, stick. Uses melee phase moving_closer.
local function engageTarget()
    local engageTargetId = state.getRunconfig().engageTargetId
    if not engageTargetId then return end

    if not spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(engageTargetId)) then
        local rc = state.getRunconfig()
        rc.engageTargetId = nil
        rc.attackCommandEngage = nil
        disengageCombat()
        return
    end

    if utils.isProtectedSpawn(mq.TLO.Spawn(engageTargetId)) then
        local rc = state.getRunconfig()
        rc.engageTargetId = nil
        rc.attackCommandEngage = nil
        disengageCombat()
        return
    end

    if state.getRunState() == state.STATES.melee then
        local p = state.getRunStatePayload()
        if p and p.phase == 'moving_closer' then
            local targetDistSq = utils.getDistanceSquared2D(mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Target.X(), mq.TLO.Target.Y())
            local maxMeleeTo = mq.TLO.Target.MaxMeleeTo()
            if targetDistSq and maxMeleeTo and targetDistSq < (maxMeleeTo * maxMeleeTo) then
                if state.canStartBusyState(state.STATES.melee) then
                    state.setRunState(state.STATES.melee, { phase = 'idle', priority = bothooks.getPriority('doMelee') })
                end
                return
            end
            if p.deadline and mq.gettime() >= p.deadline then
                if state.canStartBusyState(state.STATES.melee) then
                    state.setRunState(state.STATES.melee, { phase = 'idle', priority = bothooks.getPriority('doMelee') })
                end
                return
            end
            return
        end
    end

    if mq.TLO.Me.Pet.ID() and myconfig.settings.petassist and not mq.TLO.Pet.Aggressive() then
        mq.cmdf('/pet attack %s', engageTargetId)
    end

    if not myconfig.settings.domelee then return end

    if mq.TLO.Target.ID() ~= engageTargetId then
        targeting.TargetAndWait(engageTargetId, 500)
    end

    if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
    if mq.TLO.Me.Sitting() then mq.cmd('/stand on') end
    if not mq.TLO.Me.Combat() then mq.cmd('/squelch /attack on') end
    local stickCmd = getEngageStickCmd()
    local needRestick = false
    if mq.TLO.Stick.Active() and mq.TLO.Stick.StickTarget() == engageTargetId then
        if _lastEngageStickCmd ~= stickCmd then
            mq.cmd('/squelch /stick off')
            needRestick = true
        end
    else
        needRestick = true
    end
    if needRestick then
        mq.cmdf('/squelch /multiline ; /attack on ; /stick %s', stickCmd)
        _lastEngageStickCmd = stickCmd
    end

    if mq.TLO.Me.Class.ShortName() ~= 'BRD' then
        if state.canStartBusyState(state.STATES.melee) then
            state.setRunState(state.STATES.melee, { phase = 'moving_closer', deadline = mq.gettime() + 5000, priority = bothooks.getPriority('doMelee') })
        end
    end
end

-- Resolve engageTargetId from role (MT/MA/OT/DPS), then engage or disengage. Only sets melee busy state via canStartBusyState.
function botmelee.AdvCombat()
    local assistName = tankrole.GetAssistTargetName()
    local mainTankName = tankrole.GetMainTankName()
    local assistpct = myconfig.melee.assistpct or 99
    local rc = state.getRunconfig()

    if myconfig.pull and myconfig.pull.roam and rc.pullState == 'roam_fighting' and rc.pullAPTargetID then
        local pullSpawn = mq.TLO.Spawn(rc.pullAPTargetID)
        if not spawnutils.isAliveEngageSpawn(pullSpawn) or utils.isProtectedSpawn(pullSpawn) then
            rc.engageTargetId = nil
            disengageCombat()
            return
        end
        rc.engageTargetId = rc.pullAPTargetID
        local name = mq.TLO.Spawn(rc.pullAPTargetID).CleanName() or tostring(rc.pullAPTargetID)
        rc.statusMessage = string.format('Fighting %s (%s)', name, rc.pullAPTargetID)
        engageTarget()
        return
    end

    if mainTankName == mq.TLO.Me.Name() and mq.TLO.Target.Master.Type() == 'PC' then
        clearTankCombatState()
    end

    local id = nil
    local engageTargetRefound = false
    if tankrole.AmIMainTank() then
        if myconfig.melee.offtank and assistName and mainTankName then
            -- An offtank MT does not follow MA (this bot's melee is independent).
            id = resolveOfftankTarget(assistName, mainTankName, assistpct)
        elseif tankrole.AmIMainAssist() and not myconfig.melee.offtank then
            -- Combined MT+MA: MA target selection (resolveMeleeAssistTarget cannot /assist self).
            id = selectMATarget()
        elseif myconfig.melee.mtSticky and not myconfig.melee.offtank then
            -- Sticky MT: keep tanking its own target.
            id, engageTargetRefound = selectTankTarget(mainTankName)
            -- When MT is in combat, selectTankTarget returns nil; preserve engageTargetId so we don't call disengageCombat and clear target.
            if id == nil and mq.TLO.Me.Combat() and rc.engageTargetId and spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(rc.engageTargetId)) then
                if not spawnutils.isCampAcleashEnforced(rc) then
                    id = rc.engageTargetId
                elseif rc.MobList then
                    for _, v in ipairs(rc.MobList) do
                        if v.ID() == rc.engageTargetId and spawnutils.isAliveEngageSpawn(v) then
                            id = rc.engageTargetId
                            break
                        end
                    end
                end
            end
            if engageTargetRefound then
                botmove.StartReturnToFollowAfterEngage()
            end
        else
            -- Default MT behavior: assist MA like other melee bots.
            if assistName then
                id = resolveMeleeAssistTarget(assistName, assistpct)
            end
            -- If MA isn't set/resolvable, fall back to legacy behavior so we can still engage.
            if not id and not assistName then
                id, engageTargetRefound = selectTankTarget(mainTankName)
            end
        end
    elseif tankrole.AmIMainAssist() then
        id = selectMATarget()
    else
        if rc.attackCommandEngage and rc.engageTargetId then
            id = rc.engageTargetId
        elseif myconfig.melee.offtank and assistName and mainTankName then
            id = resolveOfftankTarget(assistName, mainTankName, assistpct)
        elseif assistName then
            id = resolveMeleeAssistTarget(assistName, assistpct)
        end
    end
    if id and utils.isProtectedSpawn(mq.TLO.Spawn(id)) then id = nil end
    rc.engageTargetId = id

    if rc.engageTargetId then
        local name = mq.TLO.Spawn(rc.engageTargetId).CleanName() or tostring(rc.engageTargetId)
        local cs = rc.CurSpell
        local curSpellBusy = cs and cs.sub and cs.phase and
            (cs.phase == 'precast' or cs.phase == 'precast_wait_move' or cs.phase == 'casting' or cs.phase == 'cast_complete_pending_resist')
        local skipAssistStatus = state.getRunState() == state.STATES.casting or curSpellBusy
        if not skipAssistStatus then
            if tankrole.AmIMainTank() and myconfig.melee.mtSticky == true and not myconfig.melee.offtank then
                rc.statusMessage = string.format('Tanking %s (%s)', name, rc.engageTargetId)
            elseif myconfig.melee.offtank then
                rc.statusMessage = string.format('Off-tanking %s (%s)', name, rc.engageTargetId)
            else
                rc.statusMessage = string.format('Assisting on %s (%s)', name, rc.engageTargetId)
            end
        end
        engageTarget()
    else
        disengageCombat()
    end
end

-- Return target ID of PC pcName (used for MA's or MT's target depending on caller). Uses charinfo when peer, else /assist + blocking delay until target set.
function botmelee.GetPCTarget(pcName)
    if not pcName or not mq.TLO.Spawn('pc =' .. pcName).ID() then return nil end

    if mq.TLO.Me.Assist() then mq.cmd('/squelch /assist off') end
    mq.cmdf('/assist %s', pcName)
    state.getRunconfig().statusMessage = string.format('Waiting for assist target (%s)', pcName)
    mq.delay(500, function()
        local id = mq.TLO.Target.ID()
        return id ~= nil and id ~= 0
    end)
    if state.getRunState() ~= state.STATES.casting then state.getRunconfig().statusMessage = '' end
    local rc = state.getRunconfig()
    local targetId = mq.TLO.Target.ID()
    if not spawnutils.isCampAcleashEnforced(rc) and targetId and targetId > 0
        and spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(targetId)) then
        return targetId
    end
    for _, v in ipairs(rc.MobList) do
        if targetId == v.ID() then return targetId end
    end
    return nil
end

function botmelee.getHookFn(name)
    if name == 'doMelee' then
        return function(hookName)
            if state.isDeadOrHover() then return end
            if utils.isNearPrimaryBindPoint() then
                utils.enforceBindStealth()
                if state.getRunState() == state.STATES.melee then state.clearRunState() end
                local rc = state.getRunconfig()
                if state.getRunState() ~= state.STATES.casting then rc.statusMessage = '' end
                return
            end
            if state.isTravelMode() and not state.isTravelAttackOverriding() then return end
            if botmove.isBeyondFollowDistance() then
                local rc = state.getRunconfig()
                rc.engageTargetId = nil
                rc.attackCommandEngage = nil
                disengageCombat()
                return
            end
            if state.getRunState() == state.STATES.engage_return_follow then
                botmove.TickReturnToFollowAfterEngage()
                return
            end
            if state.getRunState() == state.STATES.pulling then
                local rc = state.getRunconfig()
                local roam = myconfig.pull and myconfig.pull.roam
                local tagging = rc.pullState == 'roam_aggroing' or rc.pullState == 'aggroing'
                local roamCanMelee = roam and not tagging and rc.MobList and rc.MobList[1]
                if not (rc.pullState == 'roam_fighting' or roamCanMelee) then return end
            end
            if not (myconfig.settings.domelee or state.isTravelAttackOverriding()) then
                if state.getRunState() == state.STATES.melee then state.clearRunState() end
                local rc = state.getRunconfig()
                rc.engageTargetId = nil
                rc.attackCommandEngage = nil
                if state.getRunState() ~= state.STATES.casting then rc.statusMessage = '' end
                return
            end
            if utils.isNonCombatZone(mq.TLO.Zone.ShortName()) then return end
            local rc = state.getRunconfig()
            local chaseEngage = not spawnutils.isCampAcleashEnforced(rc)
                and rc.engageTargetId
                and spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(rc.engageTargetId))
            if not rc.MobList[1] and not chaseEngage then
                if state.getRunState() == state.STATES.melee then state.clearRunState() end
                rc.engageTargetId = nil
                rc.attackCommandEngage = nil
                if state.getRunState() ~= state.STATES.casting then rc.statusMessage = '' end
                return
            end
            tryRogueEvade()
            local payload = (state.getRunState() == state.STATES.melee) and state.getRunStatePayload() or nil
            state.setRunState(state.STATES.melee, payload and payload or { phase = 'idle', priority = bothooks.getPriority('doMelee') })
            if tankrole.AmIMainTank() or tankrole.AmIMainAssist() then
                botmelee.AdvCombat()
                return
            end
            if myconfig.melee.minmana == 0 then
                botmelee.AdvCombat()
                return
            end
            if (tonumber(myconfig.melee.minmana) < mq.TLO.Me.PctMana() or mq.TLO.Me.MaxMana() == 0) then
                botmelee.AdvCombat()
            end
        end
    end
    return nil
end

return botmelee
