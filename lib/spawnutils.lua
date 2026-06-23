-- Centralized add/spawn detection, counting, and filtering.
-- AddSpawnCheck hook, buildCampMobList, buildPullMobList, and shared helpers.

local mq = require('mq')
local botconfig = require('lib.config')
local spellstates = require('lib.spellstates')
local state = require('lib.state')
local utils = require('lib.utils')
local bardtwist = require('lib.bardtwist')
local charinfoutils = require('lib.charinfoutils')
local charm = require('lib.charm')

local spawnutils = {}

-- FTE (First To Engage) tracking: combat block + in-camp recheck vs pull unpullable window.
local COMBAT_FTE_RECHECK_MS = 2000
local COMBAT_FTE_INITIAL_BLOCK_MS = 2000
local COMBAT_FTE_STRIKE_BLOCK_EXTRA_MS = 5000
local FTE_STRIKE_DEBOUNCE_MS = 2000
local FTE_RECHECK_TARGET_DELAY_MS = 300

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

local function getMaAnchorLeash()
    local settings = botconfig.config.settings
    return tonumber(settings.maAnchorLeash) or tonumber(settings.acleash) or 75
end

local function isMaCampAnchorEnabled()
    return botconfig.config.settings.maCampAnchor ~= false
end

local function getMaAnchorContext(rc)
    if not isMaCampAnchorEnabled() then return nil end
    local tankrole = require('lib.tankrole')
    if tankrole.AmIMainAssist() then return nil end
    local maName = tankrole.GetAssistTargetName()
    if not maName or maName == '' then return nil end
    local ctx = charinfoutils.getLeaderContext(maName)
    if not ctx or not ctx.alive or not ctx.sameZone then return nil end
    local leash = getMaAnchorLeash()
    if not ctx.distance or ctx.distance > leash then return nil end
    if not ctx.x or not ctx.y then return nil end
    return ctx
end

--- MobList scan center: MA (charinfo) when nearby, else camp pin, else player.
---@return number x, number y, number z, string source 'ma'|'camp'|'player'
function spawnutils.getMobListAnchor(rc)
    rc = rc or state.getRunconfig()
    local maCtx = getMaAnchorContext(rc)
    if maCtx then
        return maCtx.x, maCtx.y, maCtx.z or mq.TLO.Me.Z(), 'ma'
    end
    if rc.campstatus and rc.makecamp and rc.makecamp.x and rc.makecamp.y then
        return rc.makecamp.x, rc.makecamp.y, rc.makecamp.z, 'camp'
    end
    return mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z(), 'player'
end

function spawnutils.getMaAnchorLeash()
    return getMaAnchorLeash()
end

local function getSpawnsInArea(rc, radius2DSq, radiusZ)
    local cx, cy, cz = spawnutils.getMobListAnchor(rc)
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

--- Center for pull mob scans: makecamp when camp or hunter anchor; roam uses player position.
local function getPullAreaCenter(rc)
    rc = rc or state.getRunconfig()
    if rc.campstatus and rc.makecamp and rc.makecamp.x and rc.makecamp.y then
        return rc.makecamp.x, rc.makecamp.y, rc.makecamp.z
    end
    local pull = botconfig.config.pull
    if pull and pull.roam then
        return mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
    end
    if rc.dopull and pull and pull.hunter and rc.makecamp and rc.makecamp.x and rc.makecamp.y then
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

--- True when dopull uses simplified roam hunt (player-centered nav + melee).
function spawnutils.isRoamPullMode(rc)
    rc = rc or state.getRunconfig()
    local pull = botconfig.config.pull
    return rc.dopull == true and pull and pull.roam == true
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

--- True when chase/assist bypasses are disabled (MobList always uses settings.acleash).
function spawnutils.isCampAcleashEnforced(rc)
    rc = rc or state.getRunconfig()
    if rc.campstatus ~= true then return true end
    if not rc.makecamp or not rc.makecamp.x or not rc.makecamp.y then return true end
    return rc.doCampAcleash ~= false
end

--- True when an alive engageTargetId should be kept outside MobList (doCampAcleash off + camp set).
function spawnutils.shouldChaseOutsideCamp(rc)
    if spawnutils.isCampAcleashEnforced(rc) then return false end
    rc = rc or state.getRunconfig()
    local id = rc.engageTargetId
    if not id or id <= 0 then return false end
    return spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(id))
end

--- True when an alive engageTargetId should not be cleared just because it left MobList.
function spawnutils.shouldPreserveStickyEngage(rc)
    rc = rc or state.getRunconfig()
    if not rc.engageTargetId or rc.engageTargetId <= 0 then return false end
    if not spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(rc.engageTargetId)) then return false end
    if spawnutils.shouldChaseOutsideCamp(rc) then return true end
    local tankrole = require('lib.tankrole')
    local botconfig = require('lib.config')
    if tankrole.AmIMainAssist() then return true end
    if tankrole.AmIMainTank() and botconfig.config.melee.mtSticky and mq.TLO.Me.Combat() then
        return true
    end
    for _, v in ipairs(rc.MobList or {}) do
        if v.ID() == rc.engageTargetId then return true end
    end
    return false
end

function spawnutils.isSpawnInCampRadius(spawn, rc)
    if not spawn then return false end
    rc = rc or state.getRunconfig()
    local myconfig = botconfig.config
    local zradius = myconfig.settings.zradius or 75
    local cx, cy, cz = spawnutils.getMobListAnchor(rc)
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
    if opts.pull and spawnutils.isRoamPullMode(rc) then
        entry.pullUnpullableUntil = now + pullUnpullableMs(rc)
        entry.combatBlockedUntil = nil
        entry.nextCombatRecheckAt = nil
        return
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
        if rc.roamNavTargetId and rc.roamNavTargetId > 0 then
            local t = mq.TLO.Spawn(rc.roamNavTargetId).Type()
            if isFTEEligibleSpawnType(t) then return rc.roamNavTargetId end
        end
    end
    if rc.roamNavTargetId and rc.roamNavTargetId > 0 then
        local t = mq.TLO.Spawn(rc.roamNavTargetId).Type()
        if isFTEEligibleSpawnType(t) then return rc.roamNavTargetId end
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

--- True when spawn is a valid melee engage target (NPC or non-PC pet; excludes self/PC).
function spawnutils.isNpcEngageTarget(spawn)
    if not spawnutils.isAliveEngageSpawn(spawn) then return false end
    local t = spawn.Type()
    return t == 'NPC' or (t == 'Pet' and spawn.Master.Type() ~= 'PC')
end

--- True when melee may engage spawn (normal NPC rules, or /cz attack override on a PC pet).
function spawnutils.isEngageAllowedSpawn(spawn, rc)
    rc = rc or state.getRunconfig()
    if not spawn or not spawn.ID() or spawn.ID() == 0 then return false end
    local sid = spawn.ID()
    if rc.attackCommandEngage and rc.engageTargetId == sid and spawnutils.isAliveEngageSpawn(spawn) then
        return true
    end
    return spawnutils.isNpcEngageTarget(spawn)
end

local function filterSpawnForCamp(spawn, rc)
    if not spawnutils.isAliveEngageSpawn(spawn) then return false end
    local sid = spawn.ID()
    if sid and charm.isCharmSkipped(sid, rc) then return false end
    local myconfig = botconfig.config
    local zradius = myconfig.settings.zradius or 75
    local cx, cy, cz = spawnutils.getMobListAnchor(rc)
    local acleashSq = myconfig.settings.acleashSq
    if not spawnInArea(spawn, cx, cy, cz, acleashSq, zradius) then return false end
    if not spawnutils.filterSpawnProtected(spawn) then return false end
    if not spawnutils.filterSpawnExcludeAndFTE(spawn, rc) then return false end
    local sid = spawn.ID()
    if rc.dopull == true and sid and spawnutils.isPullUnpullable(sid, rc) then return false end
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
    local cx, cy, cz = getPullAreaCenter(rc)
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
    local acleashSq = myconfig.settings.acleashSq
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
    local rc = state.getRunconfig()
    local idx = 0
    for _, v in ipairs(mobList) do
        local id = v.ID and v.ID() or v
        if id and id ~= excludeId and not charm.isCharmSkipped(id, rc) then
            idx = idx + 1
            if idx == n then return v end
        end
    end
    return nil
end

function spawnutils.validateAcmTarget(rc)
    rc = rc or state.getRunconfig()
    if rc.engageTargetId then
        if not spawnutils.isEngageAllowedSpawn(mq.TLO.Spawn(rc.engageTargetId), rc) then
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

--- If engageTargetId is set and alive, add that spawn to rc.MobList when not already present.
function spawnutils.mergeEngageTargetIntoMobList(rc)
    rc = rc or state.getRunconfig()
    local id = rc.engageTargetId
    if not id or id <= 0 then return end
    if not spawnutils.isEngageAllowedSpawn(mq.TLO.Spawn(id), rc) then return end
    for _, v in ipairs(rc.MobList or {}) do
        if v.ID() == id then return end
    end
    local sp = mq.TLO.Spawn(id)
    if sp and sp.ID() then table.insert(rc.MobList, sp) end
end

--- NPCs occupying an XTarget "Auto Hater" slot (spawns that have us/our group on THEIR hate list),
--- within the camp area, that pass the normal engage safety filters. Line of sight is intentionally
--- NOT required here: this lets the tank engage nearby mobs that are blocked by a wall/corner (the
--- MobList filter requires LoS for TargetFilter 0/1, so those mobs are otherwise invisible to the MT).
--- The "Auto Hater" slot type excludes friendly PCs/NPCs and group/pet/mez-target slots by definition.
--- Mirrors MuleAssist's GetHostilesOnXTarget + TankAllMobs; engageTarget navs (pathfinds) to these.
function spawnutils.getXTargetAutoHaterEngageables(rc)
    rc = rc or state.getRunconfig()
    local out = {}
    local n = mq.TLO.Me.XTarget() or 0
    if n == 0 then return out end
    local myconfig = botconfig.config
    local zradius = myconfig.settings.zradius or 75
    local acleash = tonumber(myconfig.settings.acleash) or 75
    local acleashSq = myconfig.settings.acleashSq or (acleash * acleash)
    local cx, cy, cz = spawnutils.getMobListAnchor(rc)
    local seen = {}
    for i = 1, n do
        local xt = mq.TLO.Me.XTarget(i)
        local xtid = xt and xt.ID() or nil
        if xtid and xtid > 0 and not seen[xtid]
            and xt.TargetType() == 'Auto Hater' and xt.Type() == 'NPC' then
            seen[xtid] = true
            local spawn = mq.TLO.Spawn(xtid)
            if spawnutils.isNpcEngageTarget(spawn)
                and spawnInArea(spawn, cx, cy, cz, acleashSq, zradius)
                and spawnutils.filterSpawnProtected(spawn)
                and spawnutils.filterSpawnExcludeAndFTE(spawn, rc)
                and not charm.isCharmSkipped(xtid, rc)
                and not (spawnutils.isRoamPullMode(rc) and spawnutils.isPullUnpullable(xtid, rc)) then
                out[#out + 1] = spawn
            end
        end
    end
    return out
end

--- True if spawnId currently occupies an XTarget "Auto Hater" slot (i.e. has aggro on us/our group).
--- Used to gate non-LoS pathfinding so the tank only chases mobs that are actually attacking us,
--- not unaggro'd NPCs the camp MobList may include under TargetFilter "All NPCs".
function spawnutils.isOnXTargetAutoHater(spawnId)
    if not spawnId or spawnId <= 0 then return false end
    local n = mq.TLO.Me.XTarget() or 0
    for i = 1, n do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and xt.ID() == spawnId and xt.TargetType() == 'Auto Hater' and not xt.Dead() then
            return true
        end
    end
    return false
end

local function mobListContainsId(mobList, spawnId)
    for _, v in ipairs(mobList or {}) do
        if v.ID() == spawnId then return true end
    end
    return false
end

local function leaderInjectEligible(rc, ctx, targetId)
    if not ctx or not ctx.inAttack or not ctx.targetId then return false end
    if ctx.targetId ~= targetId then return false end
    local leash = getMaAnchorLeash()
    if not ctx.sameZone or not ctx.distance or ctx.distance > leash then return false end
    local sp = mq.TLO.Spawn(targetId)
    if not spawnutils.isAliveEngageSpawn(sp) then return false end
    if not spawnutils.isEngageAllowedSpawn(sp, rc) then return false end
    if charm.isCharmSkipped(targetId, rc) then return false end
    if utils.isProtectedSpawn(sp) then return false end
    if not spawnutils.filterSpawnExclude(sp, rc) then return false end
    if spawnutils.isRoamPullMode(rc) and spawnutils.isPullUnpullable(targetId, rc) then return false end
    return true
end

local function tryInjectLeaderCombatTarget(rc, ctx)
    if not leaderInjectEligible(rc, ctx, ctx and ctx.targetId) then return false end
    local targetId = ctx.targetId
    if mobListContainsId(rc.MobList, targetId) then return false end
    table.insert(rc.MobList, mq.TLO.Spawn(targetId))
    return true
end

--- Force-inject MA (then MT) NPC target when leader has ATTACK state and is within maAnchorLeash.
function spawnutils.mergeLeaderCombatTarget(rc)
    rc = rc or state.getRunconfig()
    if not isMaCampAnchorEnabled() then return end
    local tankrole = require('lib.tankrole')
    local maName = tankrole.GetAssistTargetName()
    local mtName = tankrole.GetMainTankName()
    if maName and maName ~= '' then
        local maCtx = charinfoutils.getLeaderContext(maName)
        if tryInjectLeaderCombatTarget(rc, maCtx) then return end
    end
    if mtName and mtName ~= '' and mtName ~= maName then
        local mtCtx = charinfoutils.getLeaderContext(mtName)
        tryInjectLeaderCombatTarget(rc, mtCtx)
    end
end

local function formatStateList(peer)
    if not peer or not peer.State then return '(none)' end
    local parts = {}
    for _, v in ipairs(peer.State) do
        parts[#parts + 1] = tostring(v)
    end
    if #parts == 0 then return '(none)' end
    return table.concat(parts, ', ')
end

--- Print diagnostic lines for why a spawn is or is not in MobList.
function spawnutils.explainMobFilter(spawnId)
    spawnId = tonumber(spawnId) or mq.TLO.Target.ID()
    if not spawnId or spawnId == 0 then
        printf('\aybobblebot:\ax mobfilter: no target (pass spawn id or select a spawn)')
        return
    end
    local rc = state.getRunconfig()
    local myconfig = botconfig.config
    local spawn = mq.TLO.Spawn(spawnId)
    if not spawn or not spawn.ID() or spawn.ID() == 0 then
        printf('\aybobblebot:\ax mobfilter: spawn id %s not found', tostring(spawnId))
        return
    end
    local ax, ay, az, anchorSource = spawnutils.getMobListAnchor(rc)
    local zradius = myconfig.settings.zradius or 75
    local acleashSq = myconfig.settings.acleashSq
    local inArea = spawnInArea(spawn, ax, ay, az, acleashSq, zradius)
    local tfNum = myconfig.settings.TargetFilter or 0
    local inList = mobListContainsId(rc.MobList, spawnId)

    printf('\aybobblebot:\ax mobfilter for %s (id %s)', spawn.CleanName() or '?', tostring(spawnId))
    printf('  MobList anchor: %s at %.1f, %.1f, %.1f', anchorSource, ax or 0, ay or 0, az or 0)
    printf('  In MobList: %s', inList and 'yes' or 'no')
    printf('  alive: %s', spawnutils.isAliveEngageSpawn(spawn) and 'yes' or 'no')
    printf('  inArea (2D+Z from anchor): %s', inArea and 'yes' or 'no')
    printf('  protected: %s', utils.isProtectedSpawn(spawn) and 'yes' or 'no')
    printf('  exclude list: %s', spawnutils.filterSpawnExclude(spawn, rc) and 'pass' or 'FAIL')
    printf('  engagetracker: %s', spawnutils.isEngageTracked(spawnId, rc) and 'FAIL' or 'pass')
    printf('  FTE combat block: %s', spawnutils.isCombatFTEBlocked(spawnId, rc) and 'FAIL' or 'pass')
    printf('  roam unpullable: %s',
        (spawnutils.isRoamPullMode(rc) and spawnutils.isPullUnpullable(spawnId, rc)) and 'FAIL' or 'pass')
    printf('  TargetFilter (%d): %s', tfNum, filterSpawnTargetFilter(spawn, tfNum) and 'pass' or 'FAIL')
    printf('  filterSpawnForCamp: %s', filterSpawnForCamp(spawn, rc) and 'pass' or 'FAIL')

    local tankrole = require('lib.tankrole')
    local maName = tankrole.GetAssistTargetName()
    if maName and maName ~= '' then
        local maCtx = charinfoutils.getLeaderContext(maName)
        if maCtx then
            printf('  MA %s (%s): dist=%s inAttack=%s targetId=%s',
                maName, maCtx.source,
                maCtx.distance and string.format('%.1f', maCtx.distance) or 'nil',
                maCtx.inAttack and 'yes' or 'no',
                maCtx.targetId and tostring(maCtx.targetId) or 'nil')
            if maCtx.peer then
                printf('    State: %s', formatStateList(maCtx.peer))
                printf('    CombatState: %s', tostring(maCtx.peer.CombatState))
            end
            local injectOk = leaderInjectEligible(rc, maCtx, spawnId)
            if injectOk and not inList then
                printf('    inject: would add this spawn')
            elseif injectOk then
                printf('    inject: eligible (already in list)')
            else
                printf('    inject: no')
            end
        else
            printf('  MA %s: no leader context', maName)
        end
    end
    printf('  maCampAnchor: %s  maAnchorLeash: %s',
        isMaCampAnchorEnabled() and 'on' or 'off', tostring(getMaAnchorLeash()))
end

local function shouldSkipFTERecheck(rc)
    if state.getRunState() == state.STATES.pulling then return true end
    if state.getRunState() == state.STATES.casting then return true end
    if rc.fteRecheckInProgress then return true end
    local pull = botconfig.config.pull
    if pull and pull.hunter and rc.pullState then
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
        if spawnutils.isRoamPullMode(rc) and entry.pullUnpullableUntil and now < entry.pullUnpullableUntil then
            entry.nextCombatRecheckAt = nil
            entry.combatBlockedUntil = nil
        elseif spawnutils.isMobilePullMode(rc) and entry.pullUnpullableUntil and now < entry.pullUnpullableUntil then
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
                    if engageId and spawnutils.isNpcEngageTarget(mq.TLO.Spawn(engageId)) then
                        mq.cmdf('/squelch /tar id %s', engageId)
                    else
                        mq.cmd('/squelch /mqtarget clear')
                    end
                end
            end
        end
    end
end

function spawnutils.AddSpawnCheck()
    local rc = state.getRunconfig()
    charm.pruneCharmSkipIds(rc)
    spawnutils.pruneFTEList(rc)
    if not spawnutils.validateAcmTarget(rc) then return end
    spawnutils.tickCombatFTERechecks(rc)
    spawnutils.buildAndSetCampMobList(rc)
    spawnutils.mergeLeaderCombatTarget(rc)
    spawnutils.mergeKillTargetIntoMobList(rc)
    spawnutils.mergeEngageTargetIntoMobList(rc)
    spellstates.PruneDebuffStateNotInMobList(rc.MobList)
    if mq.TLO.Me.Class.ShortName() == 'BRD' then
        if utils.isNearPrimaryBindPoint() and #(rc.MobList or {}) == 0 then
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
