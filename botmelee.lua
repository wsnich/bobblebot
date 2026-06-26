local mq = require('mq')
local botconfig = require('lib.config')
local combat = require('lib.combat')
local state = require('lib.state')
local bothooks = require('lib.bothooks')
local targeting = require('lib.targeting')
local botmove = require('botmove')
local utils = require('lib.utils')
local tankrole = require('lib.tankrole')
local aggro = require('lib.aggro')
local spawnutils = require('lib.spawnutils')
local charm = require('lib.charm')
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
    if engageId and (not spawnutils.isNpcEngageTarget(mq.TLO.Spawn(engageId)) or charm.isCharmSkipped(engageId, rc)) then
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
            if not charm.isCharmSkipped(lockId, rc) then return lockId end
        elseif mezzed == true then
            return lockId
        end
    end

    if engageId and spawnIdInLosList(losList, engageId) and not charm.isCharmSkipped(engageId, rc) then
        local mezzed, _ = targetSpawnAndGetMezRemaining(engageId)
        if mezzed == false then
            clearAllMezzedLock(rc)
            return engageId
        end
    end

    local mezzedCandidates = {}
    for _, spawn in ipairs(losList) do
        local sid = spawn.ID()
        if sid and not charm.isCharmSkipped(sid, rc) then
            local mezzed, rem = targetSpawnAndGetMezRemaining(sid)
            if mezzed == false then
                clearAllMezzedLock(rc)
                return sid
            elseif mezzed == true then
                mezzedCandidates[#mezzedCandidates + 1] = { id = sid, rem = rem or MEZ_UNKNOWN_MS }
            end
        end
    end

    if #mezzedCandidates == 0 then
        clearAllMezzedLock(rc)
        for _, spawn in ipairs(losList) do
            local sid = spawn.ID()
            if sid and not charm.isCharmSkipped(sid, rc) then return sid end
        end
        return nil
    end

    local bestId = pickShortestMezzedFromCandidates(mezzedCandidates)
    rc.allMezzedEngageId = bestId
    return bestId
end

-- MobList entry is eligible for MA/MT engage selection (matches TargetFilter camp rules).
local function isEngageableMobListSpawn(spawn)
    if not spawnutils.isAliveEngageSpawn(spawn) then return false end
    local rc = state.getRunconfig()
    local sid = spawn.ID()
    if sid and charm.isCharmSkipped(sid, rc) then return false end
    if sid and spawnutils.isRoamPullMode(rc) and spawnutils.isPullUnpullable(sid, rc) then return false end
    local tfNum = tonumber(myconfig.settings.TargetFilter) or 0
    if tfNum == 2 then return true end
    return spawn.LineOfSight()
end


local function resolveOfftankTarget(assistName, mainTankName, assistpct)
    if not mainTankName or mainTankName == '' then return nil end
    local rc = state.getRunconfig()
    local _, _, maTarId, maTarHp, maFromCache = spellutils.GetAssistInfo(true, assistpct)
    if maTarId == 0 then maTarId = nil end
    local _, _, mtTarId = spellutils.GetTankInfo(true)
    if mtTarId == 0 then mtTarId = nil end
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
        if maFromCache or (maTarHp and maTarHp <= assistpct) then
            if maTarId and maTarId > 0 then return maTarId end
        end
    elseif maTarId and maTarId > 0 then
        return maTarId
    end
    return nil
end

local function hasAliveEngageTarget(rc)
    local engageId = rc.engageTargetId
    if not engageId or engageId <= 0 then return false end
    return spawnutils.isNpcEngageTarget(mq.TLO.Spawn(engageId))
        and not charm.isCharmSkipped(engageId, rc)
end

-- MA target for MT immediate follow (no assistpct gate).
local function getMaFollowTargetId()
    local rc = state.getRunconfig()
    local _, _, maTarId, _, fromCache = spellutils.GetAssistInfo(true)
    if not maTarId or maTarId <= 0 then return nil end
    if charm.isCharmSkipped(maTarId, rc) then return nil end
    if fromCache then
        if spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(maTarId)) then return maTarId end
        return nil
    end
    if not spawnutils.isCampAcleashEnforced(rc) then return maTarId end
    for _, v in ipairs(rc.MobList or {}) do
        if v.ID() == maTarId then return maTarId end
    end
    return nil
end

-- Separate MT bot: follow MA immediately; mtSticky keeps current target once engaged.
local function resolveMtFollowTarget()
    local rc = state.getRunconfig()
    if hasAliveEngageTarget(rc) and myconfig.melee.mtSticky then
        return rc.engageTargetId
    end
    local maTarId = getMaFollowTargetId()
    if maTarId then return maTarId end
    if hasAliveEngageTarget(rc) then return rc.engageTargetId end
    return nil
end

-- DPS: return MA's target when MA is engaging and in MobList at assistpct; else cached target when MA dead/hover.
local function resolveMeleeAssistTarget(assistName, assistpct)
    local rc = state.getRunconfig()
    local _, _, maTarId, maTarHp, fromCache = spellutils.GetAssistInfo(true, assistpct)
    if not maTarId or maTarId <= 0 then return nil end
    if charm.isCharmSkipped(maTarId, rc) then return nil end

    if fromCache then
        if spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(maTarId)) then
            return maTarId
        end
        return nil
    end

    local hp = maTarHp or mq.TLO.Spawn(maTarId).PctHPs()
    if not spawnutils.isCampAcleashEnforced(rc) and hp and (hp <= assistpct) then
        return maTarId
    end
    for _, v in ipairs(rc.MobList) do
        if v.ID() == maTarId and hp and (hp <= assistpct) then
            return maTarId
        end
    end
    return nil
end

-- Closest engageable named in mobList, or nil.
local function findClosestEngageableNamed(mobList)
    local meX, meY = mq.TLO.Me.X(), mq.TLO.Me.Y()
    local namedSpawn = nil
    for _, v in ipairs(mobList) do
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
    return namedSpawn and namedSpawn.ID() or nil
end

-- MA bot only: choose target from MobList independent of MT.
-- Sticky: keep current alive target unless a named appears while on a non-named.
-- Returns chosen id or nil.
local function selectMATarget()
    local rc = state.getRunconfig()
    local engageId = rc.engageTargetId
    if engageId and spawnutils.isNpcEngageTarget(mq.TLO.Spawn(engageId)) and not charm.isCharmSkipped(engageId, rc) then
        if not spawnutils.isCampAcleashEnforced(rc) then
            local inMobList = false
            for _, v in ipairs(rc.MobList or {}) do
                if v.ID() == engageId then inMobList = true break end
            end
            if not inMobList then return engageId end
        end
        local currentSpawn = mq.TLO.Spawn(engageId)
        if not currentSpawn.Named() then
            local namedId = findClosestEngageableNamed(rc.MobList)
            if namedId then return namedId end
        end
        return engageId
    end

    if mq.TLO.Me.Combat() then
        local curId = mq.TLO.Target.ID()
        local meId = mq.TLO.Me.ID()
        if curId and curId > 0 and curId ~= meId and spawnutils.isNpcEngageTarget(mq.TLO.Spawn(curId))
            and not charm.isCharmSkipped(curId, rc) then
            local curSpawn = mq.TLO.Spawn(curId)
            if curSpawn.Named() then
                return curId
            end
            local namedId = findClosestEngageableNamed(rc.MobList)
            if namedId then return namedId end
            return curId
        end
    end

    if not rc.MobList or not rc.MobList[1] then return nil end

    -- Initial pick: named first, then closest engageable (mez/distance rules).
    local namedId = findClosestEngageableNamed(rc.MobList)
    if namedId then return namedId end

    local meX, meY = mq.TLO.Me.X(), mq.TLO.Me.Y()
    local pullerTarID = tankrole.GetPullerTargetID()
    local losList = {}
    for _, v in ipairs(rc.MobList) do
        if isEngageableMobListSpawn(v) then losList[#losList + 1] = v end
    end
    if #losList == 0 then return nil end

    engageId = nil
    table.sort(losList, function(a, b)
        local aId, bId = a.ID(), b.ID()
        if pullerTarID then
            if aId == pullerTarID and bId ~= pullerTarID then return true end
            if aId ~= pullerTarID and bId == pullerTarID then return false end
        end
        local da = utils.getDistanceSquared2D(meX, meY, a.X(), a.Y())
        local db = utils.getDistanceSquared2D(meX, meY, b.X(), b.Y())
        return (da or 0) < (db or 0)
    end)

    return selectEngageTargetFromLosList(losList, engageId)
end

local function resolveMaBotTarget(rc)
    if rc.attackCommandEngage and rc.engageTargetId then
        return rc.engageTargetId
    end
    return selectMATarget()
end

-- When no engageTargetId: stick off, attack off, pet back. Clear NPC target only when auto-attack is on (releasing a fight).
local function disengageCombat()
    _lastEngageStickCmd = nil
    local rc = state.getRunconfig()
    rc.allMezzedEngageId = nil
    if state.getRunState() ~= state.STATES.casting then rc.statusMessage = '' end
    combat.ResetCombatState({ clearTarget = mq.TLO.Me.Combat() })
    if state.getRunState() == state.STATES.melee then state.clearRunState() end
end

-- Stand, attack, and stick to the engage target for final melee positioning. Stops nav first.
-- Idempotent: only re-issues /stick when the active stick target or command differs.
local function applyEngageStick(engageTargetId)
    if mq.TLO.Navigation.Active() then mq.cmd('/nav stop log=off') end
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
end

-- When the engage target is out of line of sight, approach it WITHOUT straight-line /stick (which
-- runs into walls/floors). If the navmesh has a route, pathfind (/nav) around the obstruction and let
-- /stick take over on arrival; if there is NO route, stop and hold so we don't grind into the wall,
-- waiting for LoS or a path to open (the mob or group moving). Returns true when LoS is blocked (the
-- caller must not /stick); false when LoS is clear (caller sticks normally).
-- Note: we intentionally do NOT gate on aggro here. Proactive no-LoS targeting is prevented upstream
-- (the MT only auto-selects mobs it can see; no-LoS picks come from the XTarget Auto-Hater path), and
-- an assist target is the group's committed mob — both are legitimate things to path to.
local function navToEngageTargetIfBlocked(engageTargetId)
    if mq.TLO.Target.LineOfSight() then return false end
    if mq.TLO.Navigation.PathExists('id ' .. engageTargetId)() then
        if mq.TLO.Stick.Active() then mq.cmd('/squelch /stick off') end
        _lastEngageStickCmd = nil
        if mq.TLO.Me.Sitting() then mq.cmd('/stand on') end
        if not mq.TLO.Navigation.Active() then
            mq.cmdf('/squelch /nav id %s log=off', engageTargetId)
        end
    else
        -- Unreachable from here: stop moving so we don't /stick straight into the wall.
        if mq.TLO.Navigation.Active() then mq.cmd('/nav stop log=off') end
        if mq.TLO.Stick.Active() then mq.cmd('/squelch /stick off') end
        _lastEngageStickCmd = nil
    end
    return true
end

-- When engageTargetId is set: pet attack, target (blocking TargetAndWait), stand, attack on, stick. Uses melee phase moving_closer.
local function engageTarget()
    local engageTargetId = state.getRunconfig().engageTargetId
    if not engageTargetId then return end

    if not spawnutils.isEngageAllowedSpawn(mq.TLO.Spawn(engageTargetId), state.getRunconfig()) then
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
                applyEngageStick(engageTargetId)
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
            -- Still out of range: if blocked by LoS, keep pathing around the obstruction.
            if myconfig.settings.domelee and mq.TLO.Target.ID() == engageTargetId then
                navToEngageTargetIfBlocked(engageTargetId)
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

    if mq.TLO.Target.ID() ~= engageTargetId then return end

    -- Blocked by LoS but reachable: pathfind around the obstruction; stick takes over on arrival.
    if navToEngageTargetIfBlocked(engageTargetId) then
        if mq.TLO.Me.Class.ShortName() ~= 'BRD' then
            if state.canStartBusyState(state.STATES.melee) then
                state.setRunState(state.STATES.melee, { phase = 'moving_closer', deadline = mq.gettime() + 8000, priority = bothooks.getPriority('doMelee') })
            end
        end
        return
    end

    applyEngageStick(engageTargetId)

    if mq.TLO.Me.Class.ShortName() ~= 'BRD' then
        if state.canStartBusyState(state.STATES.melee) then
            state.setRunState(state.STATES.melee, { phase = 'moving_closer', deadline = mq.gettime() + 5000, priority = bothooks.getPriority('doMelee') })
        end
    end
end

-- Reactive engage selection (settings.engageXTargetOnly): pick the engage target ONLY from mobs on our
-- XTarget Auto-Hater list (aggro'd on the group). Closest-first, prefers the current engage target;
-- mez handling via selectEngageTargetFromLosList. Deliberately skips the /assist-based role resolution
-- so we don't spam /assist (and the "Auto attack on assist" game message) or proactively grab MobList NPCs.
local function selectXTargetEngageTarget(rc)
    local cands = spawnutils.getXTargetAutoHaterEngageables(rc)
    if #cands == 0 then return nil end
    local engageId = rc.engageTargetId
    if engageId and not spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(engageId)) then engageId = nil end
    local meX, meY = mq.TLO.Me.X(), mq.TLO.Me.Y()
    table.sort(cands, function(a, b)
        local aId, bId = a.ID(), b.ID()
        if engageId and aId == engageId and bId ~= engageId then return true end
        if engageId and aId ~= engageId and bId == engageId then return false end
        local da = utils.getDistanceSquared2D(meX, meY, a.X(), a.Y())
        local db = utils.getDistanceSquared2D(meX, meY, b.X(), b.Y())
        return (da or 0) < (db or 0)
    end)
    return selectEngageTargetFromLosList(cands, engageId)
end

-- AE-tank (settings.tankAllMobs, default off): when enabled and this bot is the MT with NO mezzer
-- (ENC/BRD) in group, actively grab aggro on XTarget Auto-Hater mobs near camp that aren't currently
-- on us by taunting them in turn. Auto-suppresses when a mezzer is present unless aeTankIgnoreMezzer.
local _aeTauntNextTime = 0
local _aeDebug = false
local _aeDebugNextTime = 0

function botmelee.SetAeTankDebug(on) _aeDebug = on and true or false end
function botmelee.IsAeTankDebug() return _aeDebug end

local function aeDbg(fmt, ...)
    if not _aeDebug then return end
    if mq.gettime() < _aeDebugNextTime then return end
    _aeDebugNextTime = mq.gettime() + 2000
    printf('\ay[aetank]\ax ' .. fmt, ...)
end

local function mezzerInGroup()
    local n = tonumber(mq.TLO.Group.Members()) or 0
    for i = 0, n do
        local m = mq.TLO.Group.Member(i)
        local cls = m and m.Class and m.Class.ShortName()
        if cls == 'ENC' or cls == 'BRD' then return true end
    end
    return false
end

local AE_HATE_ABILITIES = { 'Taunt', 'Bash', 'Kick' }

-- Returns the id of a loose auto-hater mob for melee to engage until it's on us, or nil when inactive.
local function aeTankGrab(rc)
    if myconfig.settings.tankAllMobs ~= true then return nil end
    if rc.attackCommandEngage then aeDbg('idle: /cz attack engage is active'); return nil end
    if not tankrole.AmIMainTank() then
        aeDbg('idle: not Main Tank (TankName=%s, me=%s)', tostring(tankrole.GetMainTankName()), tostring(mq.TLO.Me.Name()))
        return nil
    end
    if mezzerInGroup() and myconfig.settings.aeTankIgnoreMezzer ~= true then
        aeDbg('idle: Enchanter/Bard in group -> AE-tank auto-suppressed (enable "Ignore mezzer" to override)')
        return nil
    end
    local meId = mq.TLO.Me.ID()
    local engageables = spawnutils.getXTargetAutoHaterEngageables(rc)
    local target = nil
    for _, spawn in ipairs(engageables) do
        local sid = spawn.ID()
        if sid and ((spawn.Target and spawn.Target.ID()) or 0) ~= meId then target = spawn; break end
    end
    if not target then
        aeDbg('idle: %d engageable XTarget mob(s), all already on me', #engageables)
        return nil
    end
    local sid = target.ID()
    if mq.gettime() >= _aeTauntNextTime then
        local cmds, names = {}, {}
        for _, ab in ipairs(AE_HATE_ABILITIES) do
            if mq.TLO.Me.AbilityReady(ab)() then
                cmds[#cmds + 1] = '/squelch /doability ' .. ab
                names[#names + 1] = ab
            end
        end
        if #cmds > 0 then
            mq.cmdf('/multiline ; /squelch /target id %s ; %s', sid, table.concat(cmds, ' ; '))
            aeDbg('grabbing %s (%s): %s + auto-attack', tostring((target.CleanName and target.CleanName()) or sid), tostring(sid), table.concat(names, '+'))
        else
            aeDbg('grabbing %s (%s): auto-attack (Taunt/Bash/Kick on cooldown)', tostring((target.CleanName and target.CleanName()) or sid), tostring(sid))
        end
        _aeTauntNextTime = mq.gettime() + 1000
    end
    return sid
end

-- Resolve engageTargetId from role (MA picker / MT follower / OT / DPS), then engage or disengage.
function botmelee.AdvCombat()
    local assistName = tankrole.GetAssistTargetName()
    local mainTankName = tankrole.GetMainTankName()
    local assistpct = myconfig.melee.assistpct or 99
    local rc = state.getRunconfig()
    local aeLooseId = aeTankGrab(rc)

    if mainTankName == mq.TLO.Me.Name() and mq.TLO.Target.Type() == 'PC' then
        clearTankCombatState()
    end
    if tankrole.AmIMainAssist() and not rc.attackCommandEngage then
        local tid = rc.engageTargetId or mq.TLO.Target.ID()
        if tid and tid > 0 and charm.isCharmSkipped(tid, rc) then
            rc.engageTargetId = nil
            rc.allMezzedEngageId = nil
            combat.ResetCombatState({ clearTarget = mq.TLO.Me.Combat() })
        end
    end

    local id = nil
    if rc.attackCommandEngage and rc.engageTargetId then
        id = rc.engageTargetId
    elseif myconfig.settings.engageXTargetOnly == true and not rc.attackCommandEngage then
        id = selectXTargetEngageTarget(rc)
    elseif tankrole.AmIMainAssist() then
        id = resolveMaBotTarget(rc)
    elseif myconfig.melee.offtank and assistName and mainTankName then
        id = resolveOfftankTarget(assistName, mainTankName, assistpct)
    elseif tankrole.AmIMainTank() and assistName and not tankrole.AmIMainAssist() then
        id = resolveMtFollowTarget()
    elseif assistName then
        id = resolveMeleeAssistTarget(assistName, assistpct)
    end
    if aeLooseId then id = aeLooseId end
    if id and charm.isCharmSkipped(id, rc) then id = nil end
    if id and utils.isProtectedSpawn(mq.TLO.Spawn(id)) then id = nil end
    rc.engageTargetId = id

    if rc.engageTargetId then
        local name = mq.TLO.Spawn(rc.engageTargetId).CleanName() or tostring(rc.engageTargetId)
        local cs = rc.CurSpell
        local curSpellBusy = cs and cs.sub and cs.phase and
            (cs.phase == 'precast' or cs.phase == 'precast_wait_move' or cs.phase == 'casting' or cs.phase == 'cast_complete_pending_resist')
        local skipAssistStatus = state.getRunState() == state.STATES.casting or curSpellBusy
        if not skipAssistStatus then
            if tankrole.AmIMainTank() and myconfig.melee.mtSticky == true and not myconfig.melee.offtank
                and not tankrole.AmIMainAssist() then
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
    if rc.engageTargetId then
        spawnutils.mergeEngageTargetIntoMobList(rc)
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
            local rc = state.getRunconfig()
            if rc.bardTwistOnceWait and mq.TLO.Me.Class.ShortName() == 'BRD' then return end
            if botmove.isBeyondFollowDistance() and not spawnutils.shouldChaseOutsideCamp(rc) then
                rc.engageTargetId = nil
                rc.attackCommandEngage = nil
                disengageCombat()
                return
            end
            if state.getRunState() == state.STATES.engage_return_follow then
                botmove.TickReturnToFollowAfterEngage()
                return
            end
            if state.getRunState() == state.STATES.pulling then return end
            if not (myconfig.settings.domelee or state.isTravelAttackOverriding()) then
                if state.getRunState() == state.STATES.melee then state.clearRunState() end
                local rc = state.getRunconfig()
                rc.engageTargetId = nil
                rc.attackCommandEngage = nil
                if state.getRunState() ~= state.STATES.casting then rc.statusMessage = '' end
                return
            end
            if utils.isNonCombatZone(mq.TLO.Zone.ShortName()) then return end
            local chaseEngage = spawnutils.shouldChaseOutsideCamp(rc)
            if not rc.MobList[1] and not chaseEngage then
                rc.engageTargetId = nil
                rc.attackCommandEngage = nil
                disengageCombat()
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
