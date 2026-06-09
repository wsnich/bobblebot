-- Centralized add/spawn detection, counting, and filtering.
-- AddSpawnCheck hook, buildCampMobList, buildPullMobList, and shared helpers.

local mq = require('mq')
local botconfig = require('lib.config')
local spellstates = require('lib.spellstates')
local state = require('lib.state')
local utils = require('lib.utils')
local bardtwist = require('lib.bardtwist')

local spawnutils = {}

-- FTE (First To Engage) tracking: combat block + in-camp recheck vs pull unpullable window.
local COMBAT_FTE_RECHECK_MS = 2000
local COMBAT_FTE_INITIAL_BLOCK_MS = 2000
local COMBAT_FTE_STRIKE_BLOCK_EXTRA_MS = 5000
local FTE_STRIKE_DEBOUNCE_MS = 2000
local FTE_RECHECK_TARGET_DELAY_MS = 300
local CAMP_ACLEASH_DISABLED_RADIUS = 10000
local CAMP_ACLEASH_DISABLED_RADIUS_SQ = CAMP_ACLEASH_DISABLED_RADIUS * CAMP_ACLEASH_DISABLED_RADIUS

-- ---------------------------------------------------------------------------
-- Local helpers (DRY)
-- ---------------------------------------------------------------------------

local function spawnInArea(spawn, x, y, z, radius2DSq, radiusZ)
    if not spawn or not x or not y then return false end
    local sx, sy, sz = spawn.X(), spawn.Y(), spawn.Z()
    local pdistSq = utils.getDistanceSquared2D(sx, sy, x, y)
    if not pdistSq or not radius2DSq or pdistSq > radius2DSq then return false end
    if radiusZ and z and sz then
        local zdist = math.abs(sz - z)
        if zdist > radiusZ then return false end
    end
    return true
end

local function getSpawnsInArea(rc, radius2DSq, radiusZ)
    local cx, cy, cz
    if rc.campstatus and rc.makecamp and rc.makecamp.x and rc.makecamp.y then
        cx, cy, cz = rc.makecamp.x, rc.makecamp.y, rc.makecamp.z
    else
        cx, cy, cz = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
    end
    local function predicate(spawn)
        local spawnType = spawn and spawn.Type()
        if not spawnType or spawnType == '' then return false end
        return spawnInArea(spawn, cx, cy, cz, radius2DSq, radiusZ)
    end
    return mq.getFilteredSpawns(predicate)
end

local function isFTEEligibleSpawnType(spawnType)
    if spawnType == 'NPC' then return true end
    if spawnType == 'Pet' then return true end
    return false
end

local function getCampAnchor(rc)
    rc = rc or state.getRunconfig()
    if rc.campstatus and rc.makecamp and rc.makecamp.x and rc.makecamp.y then
        return rc.makecamp.x, rc.makecamp.y, rc.makecamp.z
    end
    return mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
end

--- Center for pull mob scans: makecamp when camp or mobile pull (roam/hunter) anchor is set.
local function getPullAreaCenter(rc)
    rc = rc or state.getRunconfig()
    if rc.campstatus and rc.makecamp and rc.makecamp.x and rc.makecamp.y then
        return rc.makecamp.x, rc.makecamp.y, rc.makecamp.z
    end
    local pull = botconfig.config.pull
    if rc.dopull and pull and (pull.roam or pull.hunter) and rc.makecamp and rc.makecamp.x and rc.makecamp.y then
        return rc.makecamp.x, rc.makecamp.y, rc.makecamp.z
    end
    return mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
end

--- True when dopull uses roam or hunter mobile anchor (no camp return).
function spawnutils.isMobilePullMode(rc)
    rc = rc or state.getRunconfig()
    local pull = botconfig.config.pull
    return rc.dopull == true and pull and (pull.roam == true or pull.hunter == true)
end

function spawnutils.isEngageTracked(spawnId, rc)
    if not spawnId then return false end
    rc = rc or state.getRunconfig()
    if not rc.engagetracker then return false end
    local now = mq.gettime()
    for k, v in pairs(rc.engagetracker) do
        if now > v then rc.engagetracker[k] = nil end
        if k == spawnId then return true end
    end
    return false
end

function spawnutils.getFTEEntry(rc, spawnId)
    rc = rc or state.getRunconfig()
    if not spawnId or not rc.FTEList then return nil end
    return rc.FTEList[spawnId]
end

function spawnutils.isCombatFTEBlocked(spawnId, rc)
    if not spawnId then return false end
    rc = rc or state.getRunconfig()
    local entry = spawnutils.getFTEEntry(rc, spawnId)
    if not entry or not entry.combatBlockedUntil then return false end
    return mq.gettime() < entry.combatBlockedUntil
end

function spawnutils.isPullUnpullable(spawnId, rc)
    if not spawnId then return false end
    rc = rc or state.getRunconfig()
    local entry = spawnutils.getFTEEntry(rc, spawnId)
    if not entry or not entry.pullUnpullableUntil then return false end
    return mq.gettime() < entry.pullUnpullableUntil
end

--- Legacy: combat FTE block or engagetracker (pull uses isPullUnpullable separately).
function spawnutils.FTECheck(spawnId, rc)
    if not spawnId then return true end
    return spawnutils.isEngageTracked(spawnId, rc) or spawnutils.isCombatFTEBlocked(spawnId, rc)
end

--- True when camp-centered acleash radius should limit mob list / in-camp checks.
function spawnutils.isCampAcleashEnforced(rc)
    rc = rc or state.getRunconfig()
    if rc.campstatus ~= true then return true end
    if not rc.makecamp or not rc.makecamp.x or not rc.makecamp.y then return true end
    return rc.doCampAcleash ~= false
end

function spawnutils.isSpawnInCampRadius(spawn, rc)
    if not spawn then return false end
    rc = rc or state.getRunconfig()
    local myconfig = botconfig.config
    local zradius = myconfig.settings.zradius or 75
    local cx, cy, cz = getCampAnchor(rc)
    if not spawnutils.isCampAcleashEnforced(rc) then
        return spawnInArea(spawn, cx, cy, cz, CAMP_ACLEASH_DISABLED_RADIUS_SQ, zradius)
    end
    local acleashSq = myconfig.settings.acleashSq
    return spawnInArea(spawn, cx, cy, cz, acleashSq, zradius)
end

function spawnutils.isSpawnInCampRadiusById(spawnId, rc)
    if not spawnId or spawnId == 0 then return false end
    local spawn = mq.TLO.Spawn(spawnId)
    if not spawn or not spawn.ID() or spawn.ID() == 0 then return false end
    return spawnutils.isSpawnInCampRadius(spawn, rc)
end

local function combatBlockMsForStrikes(strikes)
    strikes = strikes or 1
    if strikes < 1 then strikes = 1 end
    return COMBAT_FTE_INITIAL_BLOCK_MS + (strikes - 1) * COMBAT_FTE_STRIKE_BLOCK_EXTRA_MS
end

local function pullUnpullableMs(rc)
    local pull = botconfig.config.pull
    local sec = tonumber(pull and pull.fteLockoutSec) or 120
    if sec < 1 then sec = 1 end
    return sec * 1000
end

--- Record FTE on an NPC spawn. opts.combat (default true), opts.pull (pull.fteLockoutSec unpullable).
function spawnutils.recordFTE(rc, spawnId, opts)
    if not spawnId or spawnId == 0 then return end
    rc = rc or state.getRunconfig()
    if not rc.FTEList then rc.FTEList = {} end
    opts = opts or {}
    local now = mq.gettime()
    local entry = rc.FTEList[spawnId]
    if not entry then
        entry = { id = spawnId, strikes = 0 }
        rc.FTEList[spawnId] = entry
    end
    if opts.pull and spawnutils.isMobilePullMode(rc) then
        entry.pullUnpullableUntil = now + pullUnpullableMs(rc)
        return
    end
    if opts.combat ~= false then
        if not entry.lastStrikeAt or (now - entry.lastStrikeAt) >= FTE_STRIKE_DEBOUNCE_MS then
            entry.strikes = (entry.strikes or 0) + 1
            entry.lastStrikeAt = now
        end
        entry.combatBlockedUntil = now + combatBlockMsForStrikes(entry.strikes)
        entry.nextCombatRecheckAt = now + COMBAT_FTE_RECHECK_MS
    end
    if opts.pull then
        entry.pullUnpullableUntil = now + pullUnpullableMs(rc)
    end
end

function spawnutils.markPullUnpullable(rc, spawnId)
    if not spawnId or spawnId == 0 then return end
    rc = rc or state.getRunconfig()
    if not rc.FTEList then rc.FTEList = {} end
    local now = mq.gettime()
    local entry = rc.FTEList[spawnId]
    if not entry then
        entry = { id = spawnId, strikes = 0 }
        rc.FTEList[spawnId] = entry
    end
    entry.pullUnpullableUntil = now + pullUnpullableMs(rc)
end

function spawnutils.clearCombatFTE(rc, spawnId)
    rc = rc or state.getRunconfig()
    if not rc.FTEList or not spawnId then return end
    local entry = rc.FTEList[spawnId]
    if not entry then return end
    entry.combatBlockedUntil = nil
    entry.nextCombatRecheckAt = nil
    local pullActive = entry.pullUnpullableUntil and mq.gettime() < entry.pullUnpullableUntil
    if not pullActive then
        rc.FTEList[spawnId] = nil
    end
end

function spawnutils.clearFTE(rc, spawnId)
    rc = rc or state.getRunconfig()
    if not rc.FTEList then return end
    if spawnId then
        rc.FTEList[spawnId] = nil
    else
        rc.FTEList = {}
    end
end

function spawnutils.pruneFTEList(rc)
    rc = rc or state.getRunconfig()
    if not rc.FTEList then return end
    local now = mq.gettime()
    for spawnId, entry in pairs(rc.FTEList) do
        local combatActive = entry.combatBlockedUntil and now < entry.combatBlockedUntil
        local pullActive = entry.pullUnpullableUntil and now < entry.pullUnpullableUntil
        local spawn = mq.TLO.Spawn(spawnId)
        local gone = not spawn.ID() or spawn.ID() == 0 or spawn.Type() == 'Corpse'
        if gone or (not combatActive and not pullActive) then
            rc.FTEList[spawnId] = nil
        end
    end
end

local function resolveFTESpawnIdFromTarget(rc)
    local targetId = mq.TLO.Target.ID()
    local targetType = mq.TLO.Target.Type()
    if targetId and targetId > 0 and isFTEEligibleSpawnType(targetType) then
        return targetId
    end
    if targetType == 'PC' then
        if rc.engageTargetId and rc.engageTargetId > 0 then
            local t = mq.TLO.Spawn(rc.engageTargetId).Type()
            if isFTEEligibleSpawnType(t) then return rc.engageTargetId end
        end
        if rc.pullAPTargetID and rc.pullAPTargetID > 0 then
            local t = mq.TLO.Spawn(rc.pullAPTargetID).Type()
            if isFTEEligibleSpawnType(t) then return rc.pullAPTargetID end
        end
    end
    return nil
end

--- Called from botevents when FTE chat line fires. Returns resolved NPC spawn id or nil.
function spawnutils.resolveFTELockedSpawnId(rc)
    rc = rc or state.getRunconfig()
    return resolveFTESpawnIdFromTarget(rc)
end

function spawnutils.filterSpawnExclude(spawn, rc)
    rc = rc or state.getRunconfig()
    local spawnname = spawn.CleanName() or 'none'
    local list = rc.ExcludeList or {}
    for _, n in ipairs(list) do
        if n == spawnname then return false end
    end
    return true
end

function spawnutils.filterSpawnProtected(spawn)
    return not utils.isProtectedSpawn(spawn)
end

function spawnutils.filterSpawnExcludeAndFTE(spawn, rc)
    if not spawnutils.filterSpawnExclude(spawn, rc) then return false end
    local sid = spawn.ID()
    if spawnutils.isEngageTracked(sid, rc) then return false end
    if spawnutils.isCombatFTEBlocked(sid, rc) then return false end
    return true
end

function spawnutils.filterSpawnExcludeAndPullFTE(spawn, rc)
    if not spawnutils.filterSpawnExclude(spawn, rc) then return false end
    local sid = spawn.ID()
    if spawnutils.isEngageTracked(sid, rc) then return false end
    if spawnutils.isPullUnpullable(sid, rc) then return false end
    return true
end

local function isCampNpcSpawn(spawn)
    local spawnType = spawn and spawn.Type()
    if not spawnType or spawnType == '' then return false end
    return spawnType == 'NPC' or (spawnType == 'Pet' and spawn.Master.Type() ~= 'PC')
end

local function filterSpawnTargetFilter(spawn, targetFilterNum)
    if not isCampNpcSpawn(spawn) then return false end
    if targetFilterNum == 2 then return true end
    if targetFilterNum == 1 then return spawn.LineOfSight() end
    if targetFilterNum == 0 then return spawn.Aggressive() and spawn.LineOfSight() end
    return false
end

--- True when spawn is a valid live combat target (not corpse, not dead).
function spawnutils.isAliveEngageSpawn(spawn)
    if not spawn or not spawn.ID() or spawn.ID() == 0 then return false end
    local spawnType = spawn.Type()
    if not spawnType or spawnType == '' then return false end
    if spawnType == 'Corpse' then return false end
    if spawn.Dead() then return false end
    return true
end

local function filterSpawnForCamp(spawn, rc)
    if not spawnutils.isAliveEngageSpawn(spawn) then return false end
    local myconfig = botconfig.config
    local zradius = myconfig.settings.zradius or 75
    local cx, cy, cz
    if rc.campstatus and rc.makecamp and rc.makecamp.x and rc.makecamp.y then
        cx, cy, cz = rc.makecamp.x, rc.makecamp.y, rc.makecamp.z
    else
        cx, cy, cz = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
    end
    if spawnutils.isCampAcleashEnforced(rc) then
        local acleashSq = myconfig.settings.acleashSq
        if not spawnInArea(spawn, cx, cy, cz, acleashSq, zradius) then return false end
    else
        if not spawnInArea(spawn, cx, cy, cz, CAMP_ACLEASH_DISABLED_RADIUS_SQ, zradius) then return false end
    end
    if not spawnutils.filterSpawnProtected(spawn) then return false end
    if not spawnutils.filterSpawnExcludeAndFTE(spawn, rc) then return false end
    local tfNum = myconfig.settings.TargetFilter or 0
    return filterSpawnTargetFilter(spawn, tfNum)
end

local function spawnInPullArc(spawn, rc)
    if not spawn or not rc.pullarc or rc.pullarc <= 0 then return true end
    local campx, campy = rc.makecamp and rc.makecamp.x, rc.makecamp and rc.makecamp.y
    if not campx or not campy then return true end
    local fdir = mq.TLO.Me.Heading.Degrees()
    local arcLside, arcRside
    if (fdir - (rc.pullarc * 0.5)) < 0 then
        arcLside = 360 - ((rc.pullarc * 0.5) - fdir)
    else
        arcLside = fdir - (rc.pullarc * 0.5)
    end
    if (fdir + (rc.pullarc * 0.5)) > 360 then
        arcRside = ((rc.pullarc * 0.5) + fdir) - 360
    else
        arcRside = fdir + (rc.pullarc * 0.5)
    end
    local dirToMob = spawn.HeadingTo(campy, campx).Degrees()
    if arcLside >= arcRside then
        if dirToMob < arcLside and dirToMob > arcRside then return false end
    else
        if dirToMob < arcLside or dirToMob > arcRside then return false end
    end
    return true
end

local function filterSpawnForPull(spawn, rc)
    local myconfig = botconfig.config
    local pull = myconfig.pull
    if not pull then return false end
    if spawn.Type() ~= 'NPC' then return false end
    -- Level/con filtering: usePullLevels => min/max level; else con range + maxLevelDiff
    if pull.usePullLevels then
        local minl = pull.pullMinLevel or 0
        local maxl = pull.pullMaxLevel or 255
        local sl = spawn.Level()
        if not sl or sl < minl or sl > maxl then return false end
    else
        local conName = spawn.ConColor()
        local conLevel = conName and botconfig.ConColorsNameToId[conName:upper()] or 0
        if conLevel < 1 then conLevel = 1 end
        local minCon = pull.pullMinCon or 1
        local maxCon = pull.pullMaxCon or 7
        if conLevel < minCon or conLevel > maxCon then return false end
        local myLevel = mq.TLO.Me.Level()
        local spawnLvl = spawn.Level()
        if not spawnLvl then return false end
        local maxLvl = myLevel and (myLevel + (pull.maxLevelDiff or 6))
        if maxLvl and spawnLvl > maxLvl then return false end
    end
    local radiusSq = pull.radiusSq
    local zrange = pull.zrange or 200
    local cx = (rc.makecamp and rc.makecamp.x) or mq.TLO.Me.X()
    local cy = (rc.makecamp and rc.makecamp.y) or mq.TLO.Me.Y()
    local cz = (rc.makecamp and rc.makecamp.z) or mq.TLO.Me.Z()
    if not spawnInArea(spawn, cx, cy, cz, radiusSq, zrange) then return false end
    if not spawnutils.filterSpawnProtected(spawn) then return false end
    if not spawnInPullArc(spawn, rc) then return false end
    if not spawnutils.filterSpawnExcludeAndPullFTE(spawn, rc) then return false end
    if not mq.TLO.Navigation.PathExists('id ' .. spawn.ID())() then return false end
    if rc.MobList then
        for _, v in pairs(rc.MobList) do
            if v.ID() == spawn.ID() then return false end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function spawnutils.buildCampMobList(rc)
    rc = rc or state.getRunconfig()
    local myconfig = botconfig.config
    local acleashSq = spawnutils.isCampAcleashEnforced(rc)
        and myconfig.settings.acleashSq
        or CAMP_ACLEASH_DISABLED_RADIUS_SQ
    local zradius = myconfig.settings.zradius or 75
    local raw = getSpawnsInArea(rc, acleashSq, zradius)
    local out = {}
    for _, spawn in ipairs(raw) do
        if filterSpawnForCamp(spawn, rc) then
            table.insert(out, spawn)
        end
    end
    table.sort(out, function(a, b) return a.ID() < b.ID() end)
    return out, #out
end

function spawnutils.buildPullMobList(rc)
    rc = rc or state.getRunconfig()
    local myconfig = botconfig.config
    local pull = myconfig.pull
    if not pull then return {} end
    local radiusSq = pull.radiusSq
    local zrange = pull.zrange or 200
    local cx, cy, cz = getPullAreaCenter(rc)
    local function predicate(spawn)
        return spawnInArea(spawn, cx, cy, cz, radiusSq, zrange)
    end
    local raw = mq.getFilteredSpawns(predicate)
    local out = {}
    for _, spawn in ipairs(raw) do
        if filterSpawnForPull(spawn, rc) then
            table.insert(out, spawn)
        end
    end
    return out
end

function spawnutils.selectNthAdd(mobList, excludeId, n)
    if not mobList or not n or n < 1 then return nil end
    local idx = 0
    for _, v in ipairs(mobList) do
        local id = v.ID and v.ID() or v
        if id and id ~= excludeId then
            idx = idx + 1
            if idx == n then return v end
        end
    end
    return nil
end

function spawnutils.validateAcmTarget(rc)
    rc = rc or state.getRunconfig()
    if rc.engageTargetId then
        if not spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(rc.engageTargetId)) then
            rc.engageTargetId = nil
            rc.attackCommandEngage = nil
            if state.getRunState() ~= state.STATES.casting then rc.statusMessage = '' end
            if state.getRunState() == state.STATES.melee then state.clearRunState() end
        end
    end
    if utils.isNonCombatZone(mq.TLO.Zone.ShortName()) then return false end
    return true
end

--- Build camp mob list and assign rc.MobList. Single source of truth for "mobs in camp"; replaced each tick.
function spawnutils.buildAndSetCampMobList(rc)
    rc = rc or state.getRunconfig()
    local list = spawnutils.buildCampMobList(rc)
    rc.MobList = list
end

--- If global KillTarget is set and valid, add that spawn to rc.MobList when not already present.
function spawnutils.mergeKillTargetIntoMobList(rc)
    rc = rc or state.getRunconfig()
    local KillTarget = rawget(_G, 'KillTarget')
    if not KillTarget then return end
    if mq.TLO.Spawn(KillTarget).Type() == 'Corpse' or not mq.TLO.Spawn(KillTarget).ID() then
        _G.KillTarget = nil
        return
    end
    if utils.isProtectedSpawn(mq.TLO.Spawn(KillTarget)) then return end
    for _, v in ipairs(rc.MobList) do
        if v.ID() == KillTarget then return end
    end
    table.insert(rc.MobList, mq.TLO.Spawn(KillTarget))
end

local ROAM_PULL_STATES = {
    roam_navigating = true,
    roam_aggroing = true,
    roam_fighting = true,
}

local function shouldSkipFTERecheck(rc)
    if state.getRunState() == state.STATES.pulling then return true end
    if state.getRunState() == state.STATES.casting then return true end
    if rc.fteRecheckInProgress then return true end
    if spawnutils.isMobilePullMode(rc) and rc.pullState then
        if ROAM_PULL_STATES[rc.pullState] then return true end
        if rc.pullState == 'navigating' or rc.pullState == 'aggroing' or rc.pullState == 'returning' then
            return true
        end
    end
    return false
end

function spawnutils.tickCombatFTERechecks(rc)
    rc = rc or state.getRunconfig()
    if shouldSkipFTERecheck(rc) then return end
    if not rc.FTEList then return end
    local now = mq.gettime()
    for spawnId, entry in pairs(rc.FTEList) do
        if spawnutils.isMobilePullMode(rc) and entry.pullUnpullableUntil and now < entry.pullUnpullableUntil then
            entry.nextCombatRecheckAt = nil
        elseif entry.nextCombatRecheckAt and now >= entry.nextCombatRecheckAt then
            if not spawnutils.isSpawnInCampRadiusById(spawnId, rc) then
                entry.nextCombatRecheckAt = nil
            elseif entry.combatBlockedUntil and now < entry.combatBlockedUntil then
                entry.nextCombatRecheckAt = now + COMBAT_FTE_RECHECK_MS
            else
                local engageId = rc.engageTargetId
                local curTar = mq.TLO.Target.ID()
                local busyOnOther = mq.TLO.Me.Combat()
                    and (
                        (engageId and engageId ~= spawnId and mq.TLO.Spawn(engageId).ID() and mq.TLO.Spawn(engageId).Type() == 'NPC')
                        or (curTar and curTar > 0 and curTar ~= spawnId and mq.TLO.Target.Type() == 'NPC')
                    )
                if busyOnOther then
                    entry.nextCombatRecheckAt = now + COMBAT_FTE_RECHECK_MS
                else
                    rc.fteRecheckInProgress = true
                    rc.fteRecheckProbeId = spawnId
                    mq.cmdf('/squelch /tar id %s', spawnId)
                    mq.delay(FTE_RECHECK_TARGET_DELAY_MS, function()
                        return mq.TLO.Target.ID() == spawnId
                    end)
                    if rc.fteRecheckProbeId == spawnId and mq.TLO.Target.ID() == spawnId and isFTEEligibleSpawnType(mq.TLO.Target.Type()) then
                        spawnutils.clearCombatFTE(rc, spawnId)
                    else
                        entry.nextCombatRecheckAt = now + COMBAT_FTE_RECHECK_MS
                    end
                    rc.fteRecheckProbeId = nil
                    rc.fteRecheckInProgress = false
                end
            end
        end
    end
end

function spawnutils.AddSpawnCheck()
    local rc = state.getRunconfig()
    spawnutils.pruneFTEList(rc)
    if not spawnutils.validateAcmTarget(rc) then return end
    spawnutils.tickCombatFTERechecks(rc)
    spawnutils.buildAndSetCampMobList(rc)
    spawnutils.mergeKillTargetIntoMobList(rc)
    spellstates.PruneDebuffStateNotInMobList(rc.MobList)
    if mq.TLO.Me.Class.ShortName() == 'BRD' and #(rc.MobList or {}) == 0 then
        if utils.isNearPrimaryBindPoint() then
            bardtwist.StopTwist()
        else
            bardtwist.EnsureDefaultTwistRunning()
        end
    end
end

function spawnutils.getHookFn(name)
    if name == 'AddSpawnCheck' then
        return function()
            spawnutils.AddSpawnCheck()
        end
    end
    return nil
end

return spawnutils
