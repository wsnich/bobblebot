local mq = require('mq')
local botconfig = require('lib.config')
local combat = require('lib.combat')
local state = require('lib.state')
local bothooks = require('lib.bothooks')
local spawnutils = require('lib.spawnutils')
local botmelee = require('botmelee')
local botmove = require('botmove')
local utils = require('lib.utils')
local spellutils = require('lib.spellutils')
local casting = require('lib.casting')
local charinfo = require('plugin.charinfo')
local myconfig = botconfig.config

local botpull = {}
local bardtwist = require('lib.bardtwist')

local PULLEDMOB_NO_CLOSER_MS = 10000
local RETURNING_AFTER_ABORT_WAIT_MS = 5000
local PULL_RETURN_EXTRA_WAIT_MS = 5000
local RETURNING_AFTER_ABORT_TIMEOUT_MS = 30000
local PULL_SPAWN_FTE_WAIT_MS = 5000
local PULL_RANGED_AGRO_WAIT_MS = 1500

-- Pull state machine. rc fields: pullState, pullAPTargetID, pullCandidateIds, pullCandidateIndex, pullTagTimer, pullReturnTimer, pullPhase, pullDeadline,
-- pullNavStartHP, pullAggroingStartTime, pullAtCampSince, pullSpawnWaitSince, pullRadiusHadTarget, pullHealerManaWait, pullDebuffWait, pullRangedStoredItem, pullRangedAttempted;
-- pulledmob, pulledmobLastDistSq, pulledmobLastCloserTime, pullreturntimer. All cleared in clearPullState().
botpull.PULL_STATES = { 'returning_after_abort', 'navigating', 'aggroing', 'returning', 'waiting_combat' }

local ROAM_NO_TARGET_STATUS_MS = 5000
local _roamNoTargetStatusLast = 0
local _roamPrevMobCount = nil

local function isRoamMode()
    return myconfig.pull and myconfig.pull.roam == true
end

--- True when any MobList spawn with LoS is within acleash of the player (roam in-face engage).
local function roamMobInMeleeRange(rc)
    if not rc.MobList or not rc.MobList[1] then return false end
    local tfNum = tonumber(myconfig.settings.TargetFilter) or 0
    local meX, meY, meZ = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
    local acleashSq = myconfig.settings.acleashSq
    if not acleashSq then return false end
    for _, v in ipairs(rc.MobList) do
        if spawnutils.isAliveEngageSpawn(v) then
            if tfNum == 2 or v.LineOfSight() then
                local dSq = utils.getDistanceSquared3D(meX, meY, meZ, v.X(), v.Y(), v.Z())
                if dSq and dSq <= acleashSq then return true end
            end
        end
    end
    return false
end

local function clearRoamNav(rc)
    rc.roamNavTargetId = nil
    if mq.TLO.Navigation.Active() then mq.cmd('/nav stop log=off') end
end

local function isRoamNavTargetPullable(rc, spawnId)
    if not spawnId or spawnId <= 0 then return false end
    local spawn = mq.TLO.Spawn(spawnId)
    if not spawnutils.isAliveEngageSpawn(spawn) or spawn.Type() ~= 'NPC' then return false end
    for _, s in ipairs(spawnutils.buildPullMobList(rc)) do
        if s.ID() == spawnId then return true end
    end
    return false
end

--- Returns effective pull range in units for the given pull spell entry.
local function getPullRange(entry)
    if not entry then return 50 end
    if entry.range and type(entry.range) == 'number' and entry.range > 0 then return entry.range end
    local gem = entry.gem
    local spell = entry.spell
    if gem == 'melee' then return 10 end
    if gem == 'ranged' then
        if spell and spell ~= '' and mq.TLO.FindItem(spell)() then
            local r = mq.TLO.FindItem(spell).Range()
            if r and r > 0 then return r end
        end
        return entry.range and entry.range > 0 and entry.range or 200
    end
    if type(gem) == 'number' and gem >= 1 and gem <= 12 then
        local name = spell or (mq.TLO.Me.Gem(gem)())
        if name and name ~= '' then
            local r = mq.TLO.Spell(name).MyRange()
            if r and r > 0 then return math.max(0, r - 5) end
        end
    end
    if gem == 'item' and spell and mq.TLO.FindItem(spell)() then
        local r = mq.TLO.FindItem(spell).Spell.MyRange()
        if r and r > 0 then return r end
    end
    if gem == 'alt' and spell and mq.TLO.Me.AltAbility(spell)() then
        local r = mq.TLO.Me.AltAbility(spell).Spell.MyRange()
        if r and r > 0 then return r end
    end
    if gem == 'ability' then
        return entry.range and entry.range > 0 and entry.range or 10
    end
    if gem == 'disc' then
        if spell and spell ~= '' then
            local r = mq.TLO.Spell(spell).MyRange()
            if r and r > 0 then return r end
        end
        return entry.range and entry.range > 0 and entry.range or 50
    end
    if gem == 'script' then
        return entry.range and entry.range > 0 and entry.range or 50
    end
    return 50
end

local function getEffectiveAbilityRange()
    local entry = botpull.GetPullSpell()
    return getPullRange(entry)
end

local lastAppliedSpellRadius = nil
local lastAppliedCastRadius = nil

--- Sync MQ2Map SpellRadius (green ring) and CastRadius while dopull is on.
---@param force boolean|nil when true, re-apply even if last-applied values match
function botpull.syncPullMapFilter(force)
    local rc = state.getRunconfig()
    if rc.dopull ~= true then return end
    local desiredSpell = myconfig.pull.radius or 0
    local desiredCast = getEffectiveAbilityRange() or 0
    if force or desiredSpell ~= lastAppliedSpellRadius then
        mq.cmdf('/squelch /mapfilter SpellRadius %s', desiredSpell)
        lastAppliedSpellRadius = desiredSpell
    end
    if force or desiredCast ~= lastAppliedCastRadius then
        mq.cmdf('/squelch /mapfilter CastRadius %s', desiredCast)
        lastAppliedCastRadius = desiredCast
    end
end

--- Builds a set (id -> true) of NPCs in an XTarget "Auto Hater" slot (things with aggro on us).
--- Filtering to Auto-Hater NPCs avoids counting benign slots (pet/group/current-target) as hostiles,
--- which would otherwise trigger false add-aborts and false pull-aggro confirmations.
local function getCurrentXTargetIdSet()
    local set = {}
    local n = mq.TLO.Me.XTarget() or 0
    for i = 1, n do
        local xt = mq.TLO.Me.XTarget(i)
        if spawnutils.isAutoHaterXTarget(xt) then
            set[xt.ID()] = true
        end
    end
    return set
end

--- Returns true if spawnId is on extended target as an Auto Hater NPC.
local function isSpawnOnXTarget(spawnId)
    if not spawnId or spawnId == 0 then return false end
    local n = mq.TLO.Me.XTarget() or 0
    for i = 1, n do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and xt.ID() == spawnId and spawnutils.isAutoHaterXTarget(xt) then
            return true
        end
    end
    return false
end

-- Returns true when the pull target's current target is the player (confirmed agro). Nil-safe.
-- Requires the puller to have the pull mob targeted so Me.TargetOfTarget is valid.
local function pullMobHasAgroOnMe(spawn)
    local meId = mq.TLO.Me.ID()
    if not meId then return false end
    if mq.TLO.Target.ID() == spawn.ID() then
        local totId = mq.TLO.Me.TargetOfTarget.ID()
        return totId and totId == meId
    end
    return false
end

local function pullTargetHasAgro(rc, spawn)
    return isSpawnOnXTarget(rc.pullAPTargetID) or pullMobHasAgroOnMe(spawn)
end

---@param opts table|nil { clearTarget?: boolean }
local function transitionPullToReturning(rc, spawn, opts)
    if opts and opts.clearTarget then
        mq.cmd('/multiline ; /squelch /mqtarget clear ; /nav stop log=off')
    end
    rawset(rc, 'pullAttemptedIds', {})
    rc.pullState = 'returning'
    rc.statusMessage = string.format('Returning to camp with %s (%s)', spawn.Name(), spawn.ID())
    rc.pullPhase = nil
    rc.pulledmob = rc.pullAPTargetID
    rc.pullreturntimer = mq.gettime() + 60000
    rc.pulledmobLastDistSq = utils.getDistanceSquared3D(mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z(), spawn.X(),
        spawn.Y(), spawn.Z())
    rc.pulledmobLastCloserTime = mq.gettime()
    if rc.pullRangedStoredItem and rc.pullRangedStoredItem ~= '' then
        mq.cmdf('/exchange "%s" Ranged', rc.pullRangedStoredItem)
        rc.pullRangedStoredItem = nil
    end
    combat.ResetCombatState({ clearTarget = false, clearPet = false })
    botmove.NavToCamp({ dist = 0, echoMsg = 'Returning to camp' })
end

local function startRangedAggroWait(rc)
    rc.pullPhase = 'aggro_wait_ranged'
    rc.pullDeadline = mq.gettime() + PULL_RANGED_AGRO_WAIT_MS
    rc.pullRangedAttempted = true
    mq.cmd('/stick off')
end

local function clearEngageIfPullTargetGone(rc, pullTargetId)
    if not pullTargetId or pullTargetId <= 0 then return end
    if rc.engageTargetId ~= pullTargetId then return end
    if spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(pullTargetId)) then return end
    rc.engageTargetId = nil
    rc.attackCommandEngage = nil
    combat.ResetCombatState({ clearTarget = true, clearPet = false })
end

local function pullWaitBlocksStatus(rc)
    return rc.pullHealerManaWait ~= nil or rc.pullDebuffWait ~= nil
end

local function clearPullState(reason)
    local rc = state.getRunconfig()
    local endingPullId = rc.pullAPTargetID
    rc.pullState = nil
    rc.pullAPTargetID = nil
    rc.pullTagTimer = nil
    rc.pullReturnTimer = nil
    rc.pullPhase = nil
    rc.pullDeadline = nil
    rc.pullNavStartHP = nil
    rc.pullXTargetIdsAtStart = nil
    rc.pullAggroingStartTime = nil
    rc.pullAtCampSince = nil
    rc.pullRadiusHadTarget = nil
    rc.pullSpawnWaitSince = nil
    rawset(rc, 'pullListSignature', nil)
    rawset(rc, 'pullAbortReturnDeadline', nil)
    rc.pullCandidateIds = nil
    rc.pullCandidateIndex = nil
    rc.pullHealerManaWait = nil
    rc.pullDebuffWait = nil
    rc.pullRangedStoredItem = nil
    rc.pullRangedAttempted = nil
    rc.pulledmob = nil
    rc.pullreturntimer = nil
    rc.pulledmobLastDistSq = nil
    rc.pulledmobLastCloserTime = nil
    clearEngageIfPullTargetGone(rc, endingPullId)
    if reason == 'waiting_combat: AP in camp or timer' or reason == 'returning: warp' then
        rc.statusMessage = ''
    elseif reason and reason ~= '' then
        rc.statusMessage = string.format('Pull aborted: %s', reason)
    else
        rc.statusMessage = ''
    end
    state.clearRunState()
    if mq.TLO.Me.Class.ShortName() == 'BRD' then
        bardtwist.EnsureTwistForMode('combat')
    end
end

--- Turn off runtime pull (dopull), clear pull target/state, and stop nav/combat movement.
---@param reason string|nil e.g. zone, death, follow, command
function botpull.DisablePull(reason)
    local rc = state.getRunconfig()
    local wasOn = rc.dopull == true
    local activePull = rc.pullState ~= nil and rc.pullState ~= ''
        or state.getRunState() == state.STATES.pulling
    if not wasOn and not activePull then return end

    rc.dopull = false
    lastAppliedSpellRadius = nil
    lastAppliedCastRadius = nil
    rc.roamNavTargetId = nil
    rc.roamBuffCheckPending = nil
    _roamPrevMobCount = nil
    if APTarget and APTarget.ID() then APTarget = nil end
    if activePull then
        clearPullState(reason)
    end
    if botconfig.config.pull.hunter then
        rc.makecamp = { x = nil, y = nil, z = nil }
    end
    mq.cmd('/squelch /mqtarget clear ; /nav stop ; /stick off ; /attack off')
    if wasOn then
        printf('\ayCZBot:\axDisabling pull (%s)', reason or 'off')
    end
end

function botpull.LoadPullConfig()
    local rc = state.getRunconfig()
    rc.pulledmob = nil
    rc.pullreturntimer = nil
    rc.pulledmobLastDistSq = nil
    rc.pulledmobLastCloserTime = nil
    if not rawget(rc, 'pullAttemptedIds') then
        rawset(rc, 'pullAttemptedIds', {})
    end
    if not rc.pullarc then rc.pullarc = nil end
end

botconfig.RegisterConfigLoader(function() botpull.LoadPullConfig() end)

--- Returns the single pull spell block from config, or nil if missing/empty (treat as melee).
function botpull.GetPullSpell()
    local pull = myconfig.pull
    if not pull or not pull.spell or type(pull.spell) ~= 'table' then return nil end
    local ps = pull.spell
    if not ps or (ps.gem == nil and ps.spell == nil) then return nil end
    return ps
end

function botpull.TagTimeCalc(trip, spawnId, x, y, z)
    if trip == 'pull' and spawnId then
        return (((mq.TLO.Navigation.PathLength('id ' .. spawnId)() + 100) / 100) * 9000) + mq.gettime()
    end
    if trip == 'return' and x and y and z then
        return (((mq.TLO.Navigation.PathLength('locxyz ' .. x .. ',' .. y .. ',' .. z)() + 100) / 100) * 18000) +
            PULL_RETURN_EXTRA_WAIT_MS + mq.gettime()
    end
    return mq.gettime() + 60000
end

function botpull.SetPullArc(arc)
    local rc = state.getRunconfig()
    if not arc and rc.pullarc then
        print('\ayCZBot:\ax \arTurning off Directional Pulling.')
        rc.pullarc = 0
    else
        rc.pullarc = tonumber(arc)
    end
    if arc then printf('Setting Pull Arc to %s at heading %s', arc, mq.TLO.Me.Heading.Degrees()) end -- not debug, keep
end

function botpull.FTECheck(spawnid)
    return spawnutils.FTECheck(spawnid, state.getRunconfig())
end

function botpull.EngageCheck()
    local tarSpawn = mq.TLO.Target

    local target = tarSpawn.CleanName()
    local targetid = tarSpawn.ID()
    if not targetid or targetid == 0 then return false end
    if not mq.TLO.Me.TargetOfTarget.ID() or mq.TLO.Me.TargetOfTarget.ID() == 0 then return false end
    local totSpawn = mq.TLO.Me.TargetOfTarget
    local totID = totSpawn.ID()
    local totType = totSpawn.Type()
    local info = totSpawn and charinfo.GetInfo(totID)
    local bot = info and info.ID
    local rc = state.getRunconfig()
    if bot then
        local tspawn = mq.TLO.Spawn(targetid)
        local targetDistSq = utils.getDistanceSquared3D(tspawn.X(), tspawn.Y(), tspawn.Z(), rc.makecamp.x, rc.makecamp.y,
            rc.makecamp.z)
        local range = getEffectiveAbilityRange()
        local rangeSq = range and (range * range) or nil
        if targetDistSq and rangeSq and targetDistSq > rangeSq and not myconfig.pull.hunter and not myconfig.pull.roam then return false end
    end
    if totID and totID > 0 and totID ~= mq.TLO.Me.ID() and (totType ~= 'NPC') and totType ~= 'Corpse' then
        printf('\ayCZBot:\ax\arUh Oh, \ag%s\ax is \arengaged\ax by someone else! Returning to camp!', target)
        rc.engagetracker[targetid] = (mq.gettime() + 60000)
        mq.cmd('/multiline ; /squelch /mqtarget clear ; /nav stop log=off')
        return true
    end
    return false
end

-- Bot peers: charinfo PctMana (MQ Group.Member/Spawn PctMana can report 100% incorrectly).
-- Non-bot groupmates: Group.Member.PctMana().
local function resolveMemberManaPct(member, memberName)
    if memberName and memberName ~= '' then
        local peer = charinfo.GetInfo(memberName)
        if peer and peer.PctMana ~= nil then
            return tonumber(peer.PctMana)
        end
    end
    if member and member.PctMana then
        return tonumber(member.PctMana())
    end
    return nil
end

-- Group checks: offline/corpse always block; healer mana gate when manaclass non-empty and pull.mana > 0.
-- Sets rc.pullHealerManaWait on mana failure. Returns true if pull must not start.
local function groupBlocksPull(rc)
    local members = mq.TLO.Group.Members()
    if not members or members <= 0 then return false end

    local threshold = tonumber(myconfig.pull.mana) or 0
    local manaclass = myconfig.pull.manaclass
    local manaGateEnabled = threshold > 0 and type(manaclass) == 'table' and #manaclass > 0
    local checked
    if manaGateEnabled then
        checked = {}
        for _, c in ipairs(manaclass) do
            checked[string.upper(tostring(c))] = true
        end
    end

    for i = 1, members do
        local member = mq.TLO.Group.Member(i)
        if member then
            local memberId = member.ID()
            if not memberId or memberId == 0 then return true end
            local spawn = member.Spawn
            if spawn and spawn.Type() and string.lower(spawn.Type()) == 'corpse' then return true end
            if manaGateEnabled and member.Class and member.Class.ShortName() then
                local cls = string.upper(member.Class.ShortName() or '')
                if checked[cls] then
                    local memberName = member.Name()
                    local pct = resolveMemberManaPct(member, memberName)
                    if pct == nil then pct = 0 end
                    if pct <= threshold then
                        local name = (spawn and spawn.CleanName()) or memberName or 'healer'
                        rc.pullHealerManaWait = { name = name, pct = threshold, current = pct }
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- Pre-checks: return false if we should not start a pull.
local function canStartPull(rc)
    rc.pullHealerManaWait = nil
    rc.pullDebuffWait = nil
    if not isRoamMode() and rc.pulledmob then
        local pmob = mq.TLO.Spawn(rc.pulledmob)
        if not pmob or not pmob.ID() or pmob.Type() == 'Corpse' then
            rc.pulledmob = nil
            rc.pulledmobLastDistSq = nil
            rc.pulledmobLastCloserTime = nil
        else
            local pulledDistSq = utils.getDistanceSquared3D(mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z(), pmob.X(),
                pmob.Y(), pmob.Z())
            if not pulledDistSq or not myconfig.settings.acleashSq then
                -- no distance or no acleash, clear and continue
                rc.pulledmob = nil
                rc.pulledmobLastDistSq = nil
                rc.pulledmobLastCloserTime = nil
            elseif pulledDistSq < myconfig.settings.acleashSq then
                -- inside acleash: mob at camp, clear and allow pull (hook decides if StartPull or doMelee)
                rc.pulledmob = nil
                rc.pulledmobLastDistSq = nil
                rc.pulledmobLastCloserTime = nil
            else
                -- outside acleash: only clear if mob hasn't gotten closer for 10s
                local lastDistSq = rc.pulledmobLastDistSq or math.huge
                if pulledDistSq < lastDistSq then
                    rc.pulledmobLastDistSq = pulledDistSq
                    rc.pulledmobLastCloserTime = mq.gettime()
                    return false
                end
                if rc.pulledmobLastDistSq == nil then
                    rc.pulledmobLastDistSq = pulledDistSq
                    rc.pulledmobLastCloserTime = mq.gettime()
                    return false
                end
                local now = mq.gettime()
                if (now - (rc.pulledmobLastCloserTime or 0)) > PULLEDMOB_NO_CLOSER_MS then
                    rc.pulledmob = nil
                    rc.pulledmobLastDistSq = nil
                    rc.pulledmobLastCloserTime = nil
                else
                    return false
                end
            end
        end
    end
    if MasterPause then return false end
    if mq.TLO.Me.PctHPs() and mq.TLO.Me.PctHPs() <= 45 then return false end
    if not mq.TLO.Navigation.MeshLoaded() then
        printf(
            '\ayCZBot:\axI have DoPull set TRUE but have \arno MQ2Nav Mesh loaded\ax, please generate a NavMesh before using DoPull, \arsetting DoPull to FALSE\ax')
        state.getRunconfig().dopull = false
        return false
    end
    if groupBlocksPull(rc) then return false end
    local hasDebuff, debuffName = spellutils.MeHasNonCurableDebuff()
    if hasDebuff then
        rc.pullDebuffWait = { name = debuffName or 'debuff' }
        return false
    end
    return true
end

-- True when we are not in a pull state and chain-pull conditions say we should start a pull (and canStartPull passes).
-- Only run canStartPull (and thus set pullHealerManaWait) when we might actually pull; when mob in camp and no chain pull, skip so status stays correct.
local function shouldStartPull(rc)
    if state.getRunState() == state.STATES.pulling then return false end
    local mobCount = state.getMobCount()
    local engageId = rc.engageTargetId

    local wantToPull = false
    if mobCount > 0 and not engageId then
        wantToPull = false
    elseif mobCount == 0 and not engageId then
        wantToPull = true
    elseif mobCount < (myconfig.pull.chainpullcnt or 0) then
        wantToPull = true
    elseif (mobCount <= myconfig.pull.chainpullcnt or myconfig.pull.chainpullcnt == 0) and engageId and mq.TLO.Spawn(engageId).PctHPs() then
        local tempcnt = myconfig.pull.chainpullcnt == 0 and 1 or myconfig.pull.chainpullcnt
        if tonumber(mq.TLO.Spawn(engageId).PctHPs()) <= myconfig.pull.chainpullhp and mobCount <= tempcnt then
            wantToPull = true
        end
    end

    if not wantToPull then
        rc.pullHealerManaWait = nil
        rc.pullDebuffWait = nil
        return false
    end
    if not canStartPull(rc) then return false end
    return true
end

-- Camp/hunter/roam setup and mapfilter; no mq.delay.
local function ensureCampAndAnchor(rc)
    botpull.syncPullMapFilter(false)
    if isRoamMode() then
        if myconfig.pull.hunter then
            print('\ayCZBot:\ax Roam hunt enabled; hunter mode ignored')
        end
        if rc.campstatus then botmove.MakeCamp('off') end
    elseif not myconfig.pull.hunter and not myconfig.pull.roam and not rc.campstatus then
        botmove.MakeCamp('on')
    elseif myconfig.pull.hunter and (not rc.makecamp.x or not rc.makecamp.y) then
        print('\ayCZBot:\ax setting HunterMode anchor')
        botmove.SetCampHere()
        if rc.campstatus then botmove.MakeCamp('off') end
    end
    if myconfig.pull.hunter and not isRoamMode() and rc.campstatus then
        print('Disabling makecamp because dopull is on with HunterMode enabled') -- not debug, real error message
        botmove.MakeCamp('off')
    end
end

function botpull.ensurePullCampState(rc)
    ensureCampAndAnchor(rc or state.getRunconfig())
end

local function pullListSignature(apmoblist)
    if not apmoblist or not apmoblist[1] then return '' end
    local ids = {}
    for _, v in ipairs(apmoblist) do
        local id = v.ID()
        if id and id > 0 then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return table.concat(ids, ',')
end

-- Rank spawns by path length; if usepriority, filter to PriorityList first; skip pullAttemptedIds.
local function selectPullTargets(apmoblist, rc, maxCount)
    if not apmoblist or not apmoblist[1] then return {} end
    maxCount = maxCount or 1
    local candidates = apmoblist
    if myconfig.pull.usepriority and rc.PriorityList and #rc.PriorityList > 0 then
        local prioritySet = {}
        for _, n in ipairs(rc.PriorityList) do prioritySet[n] = true end
        local filtered = {}
        for _, v in ipairs(apmoblist) do
            if prioritySet[v.CleanName()] then filtered[#filtered + 1] = v end
        end
        if #filtered > 0 then candidates = filtered end
    end
    local attempted = rawget(rc, 'pullAttemptedIds') or {}
    local pullable = {}
    for _, v in ipairs(candidates) do
        local sid = v.ID()
        if sid and sid > 0 and not spawnutils.isPullUnpullable(sid, rc) then
            pullable[#pullable + 1] = v
        end
    end
    if #pullable == 0 then return {} end
    candidates = pullable
    local unattempted = {}
    local skippedAttemptedCount = 0
    for _, v in ipairs(candidates) do
        if not attempted[v.ID()] then
            unattempted[#unattempted + 1] = v
        else
            skippedAttemptedCount = skippedAttemptedCount + 1
        end
    end
    if skippedAttemptedCount > 0 then
        printf('\ayCZBot:\ax [Pull] skipping %d recently-attempted pull target(s)', skippedAttemptedCount)
    end
    if #unattempted > 0 then
        candidates = unattempted
    else
        -- Before retrying attempted targets, prefer any never-attempted pullable spawn in the full list.
        local freshUnattempted = {}
        for _, v in ipairs(apmoblist) do
            local sid = v.ID()
            if sid and sid > 0 and not spawnutils.isPullUnpullable(sid, rc) and not attempted[sid] then
                freshUnattempted[#freshUnattempted + 1] = v
            end
        end
        if #freshUnattempted > 0 then
            candidates = freshUnattempted
        end
    end
    local ps = myconfig.pull.spell
    local isWarp = ps and ps.gem == 'script' and ps.spell
        and string.lower(tostring(ps.spell)) == 'warp'
    local applyNavFilter = spawnutils.isFixedCampPullMode(rc) and not isWarp
    local maxNavDist = (myconfig.pull.radius or 0) + 40
    local ranked = {}
    for _, v in ipairs(candidates) do
        local pl = mq.TLO.Navigation.PathLength('id ' .. v.ID())()
        if applyNavFilter and (not pl or pl <= 0 or pl > maxNavDist) then
            -- fixed camp: skip targets whose nav path exceeds pull radius + 40
        elseif pl and pl > 0 then
            ranked[#ranked + 1] = { spawn = v, pathLen = pl }
        else
            ranked[#ranked + 1] = { spawn = v, pathLen = math.huge }
        end
    end
    table.sort(ranked, function(a, b) return a.pathLen < b.pathLen end)
    local out = {}
    for i = 1, math.min(maxCount, #ranked) do
        out[i] = ranked[i].spawn
    end
    return out
end

local function selectPullTarget(apmoblist, rc)
    local targets = selectPullTargets(apmoblist, rc, 1)
    return targets[1]
end

local function roamNavDeferredForBuff(rc)
    if not myconfig.settings.dobuff or not rc.roamBuffCheckPending then return false end
    if state.getRunState() == state.STATES.casting then return true end
    if state.getRunState() == state.STATES.resume_doBuff then return true end
    if rc.CurSpell and rc.CurSpell.sub == 'buff'
        and (mq.TLO.Me.Casting() or (mq.TLO.Me.CastTimeLeft() or 0) > 0) then
        return true
    end
    return true
end

local function tickRoamNav(rc)
    local mobCount = state.getMobCount()
    if (_roamPrevMobCount or 0) > 0 and mobCount == 0 and myconfig.settings.dobuff then
        rc.roamBuffCheckPending = true
    end
    _roamPrevMobCount = mobCount

    local engageId = rc.engageTargetId
    if engageId and not spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(engageId)) then
        engageId = nil
    end

    if mobCount > 0 or mq.TLO.Me.Combat() or engageId then
        clearRoamNav(rc)
        return
    end
    if roamMobInMeleeRange(rc) then
        clearRoamNav(rc)
        return
    end
    if not canStartPull(rc) then
        if rc.pullDebuffWait then clearRoamNav(rc) end
        return
    end

    if roamNavDeferredForBuff(rc) then
        if state.getRunState() == state.STATES.idle and not pullWaitBlocksStatus(rc) then
            rc.statusMessage = 'Buff Check'
        end
        return
    end

    local targetId = rc.roamNavTargetId
    if targetId and not isRoamNavTargetPullable(rc, targetId) then
        targetId = nil
        rc.roamNavTargetId = nil
    end
    if not targetId then
        local targets = selectPullTargets(spawnutils.buildPullMobList(rc), rc, 1)
        local spawn = targets[1]
        if not spawn then
            local now = mq.gettime()
            if now - _roamNoTargetStatusLast >= ROAM_NO_TARGET_STATUS_MS then
                _roamNoTargetStatusLast = now
                if not pullWaitBlocksStatus(rc) then
                    rc.statusMessage = 'No pull targets nearby'
                end
            end
            clearRoamNav(rc)
            return
        end
        targetId = spawn.ID()
        rc.roamNavTargetId = targetId
        rc.roamBuffCheckPending = false
    end

    local spawn = mq.TLO.Spawn(targetId)
    if not spawn or not spawn.ID() then
        clearRoamNav(rc)
        return
    end
    if not pullWaitBlocksStatus(rc) then
        rc.statusMessage = string.format('Roaming to %s (%s)', spawn.CleanName() or spawn.Name(), targetId)
    end
    if not mq.TLO.Navigation.Active() then
        mq.cmdf('/nav id %s dist=7 log=off los=on', targetId)
    end
end

local function gatePullSpawnWait(rc, apmoblist)
    local sig = pullListSignature(apmoblist)
    local hasTarget = apmoblist and apmoblist[1] ~= nil
    if not hasTarget then
        rc.pullRadiusHadTarget = nil
        rc.pullSpawnWaitSince = nil
        rawset(rc, 'pullListSignature', nil)
        return true
    end
    local prevSig = rawget(rc, 'pullListSignature')
    if prevSig ~= sig then
        rc.pullRadiusHadTarget = nil
        rc.pullSpawnWaitSince = nil
        rawset(rc, 'pullListSignature', sig)
    end
    if not rc.pullRadiusHadTarget then
        rc.pullRadiusHadTarget = true
        rc.pullSpawnWaitSince = mq.gettime()
    end
    if rc.pullSpawnWaitSince and (mq.gettime() - rc.pullSpawnWaitSince) < PULL_SPAWN_FTE_WAIT_MS then
        if not pullWaitBlocksStatus(rc) then
            rc.statusMessage = 'Waiting before pull...'
        end
        return true
    end
    rc.pullSpawnWaitSince = nil
    return false
end

function botpull.StartPull()
    local rc = state.getRunconfig()
    if not canStartPull(rc) then return end
    if not state.canStartBusyState(state.STATES.pulling) then return end

    ensureCampAndAnchor(rc)
    local apmoblist = spawnutils.buildPullMobList(rc)
    if gatePullSpawnWait(rc, apmoblist) then return end
    local maxCandidates = tonumber(myconfig.pull.backupCandidates) or 3
    local targets = selectPullTargets(apmoblist, rc, maxCandidates)
    if not targets[1] then return end
    local spawn = targets[1]
    local candidateIds = {}
    for i, s in ipairs(targets) do
        candidateIds[i] = s.ID()
    end
    rc.pullCandidateIds = candidateIds
    rc.pullCandidateIndex = 1

    local entry = botpull.GetPullSpell()
    local isWarp = entry and entry.gem == 'script' and entry.spell and string.lower(tostring(entry.spell)) == 'warp'

    local distance = spawn.Distance() and math.floor(spawn.Distance()) or 0
    printf('\ayCZBot:\axAttempting to pull \ar%s \arid %s \auat %s', spawn.Name(), spawn.ID(), distance)
    mq.cmd('/multiline ; /attack off ; /stick off ; /squelch /mqtarget clear')
    mq.cmdf('/nav id %s dist=7 log=off los=on', spawn.ID())
    if isWarp then mq.cmdf('/warp id %s', spawn.ID()) end

    rc.pullAPTargetID = spawn.ID()
    rc.pullTagTimer = botpull.TagTimeCalc('pull', spawn.ID())
    rc.pullReturnTimer = botpull.TagTimeCalc('return', nil, rc.makecamp.x, rc.makecamp.y, rc.makecamp.z)
    rc.pullState = 'navigating'
    rc.pullPhase = nil
    rc.pullDeadline = nil
    rc.pullNavStartHP = mq.TLO.Me.PctHPs()
    rc.pullXTargetIdsAtStart = getCurrentXTargetIdSet()
    state.setRunState(state.STATES.pulling, { priority = bothooks.getPriority('doPull') })
    rc.statusMessage = string.format('Pulling %s (%s)', spawn.Name(), spawn.ID())
end

local function isPullWarp()
    local entry = botpull.GetPullSpell()
    return entry and entry.gem == 'script' and entry.spell and string.lower(tostring(entry.spell)) == 'warp'
end

local function markPullTargetAttempted(rc, reason)
    if not rc.pullAPTargetID or rc.pullAPTargetID <= 0 then return end
    local shouldMarkAttempted = reason == 'Pull target below 100% HP, picking another'
        or reason == 'No agro after 15s, returning to camp.'
        or reason == 'No agro after 15s, picking another target.'
        or reason == 'navigating: EngageCheck (mob engaged by other)'
        or reason == 'aggroing: EngageCheck (mob engaged by other)'
        or reason == 'FTE lock detected'
    if shouldMarkAttempted then
        local attempted = rawget(rc, 'pullAttemptedIds')
        if not attempted then
            attempted = {}
            rawset(rc, 'pullAttemptedIds', attempted)
        end
        attempted[rc.pullAPTargetID] = true
    end
end

local function abortRoamHunt(reason)
    mq.cmd('/multiline ; /squelch /mqtarget clear ; /nav stop log=off')
    local rc = state.getRunconfig()
    markPullTargetAttempted(rc, reason)
    rc.engageTargetId = nil
    clearPullState(reason or 'roam hunt aborted')
    if reason then printf('\ayCZBot:\ax [Roam hunt] abort: %s', reason) end
end

local function abortPullAndReturnToCamp(reason)
    mq.cmd('/multiline ; /squelch /mqtarget clear ; /nav stop log=off')
    local rc = state.getRunconfig()
    markPullTargetAttempted(rc, reason)
    rc.engageTargetId = nil
    rc.pullCandidateIds = nil
    rc.pullCandidateIndex = nil
    rc.pullState = 'returning_after_abort'
    rc.pullAPTargetID = nil
    rc.pullAtCampSince = nil
    rawset(rc, 'pullAbortReturnDeadline', mq.gettime() + RETURNING_AFTER_ABORT_TIMEOUT_MS)
    rc.statusMessage = 'Returning to camp after abort'
    botmove.NavToCamp({ dist = 0, echoMsg = 'Add aggro, returning to camp' })
    if reason then printf('\ayCZBot:\ax [Pull] abort: %s', reason) end
end

local function ensurePullingRunState()
    if state.getRunState() ~= state.STATES.pulling then
        state.setRunState(state.STATES.pulling, { priority = bothooks.getPriority('doPull') })
    end
end

local function isQueueEntryViable(spawnId, rc)
    if not spawnId or spawnId <= 0 then return false end
    local spawn = mq.TLO.Spawn(spawnId)
    if not spawn or not spawn.ID() or spawn.ID() == 0 or spawn.Type() == 'Corpse' then return false end
    if spawnutils.isPullUnpullable(spawnId, rc) then return false end
    local attempted = rawget(rc, 'pullAttemptedIds') or {}
    if attempted[spawnId] then return false end
    return true
end

--- Active pull target, queued backups, and already-tried candidates for this outing.
--- Proximity add-abort must ignore these; only unknown nearby aggressives are adds.
local function isKnownPullOutingSpawn(spawnId, rc)
    if not spawnId or spawnId <= 0 then return false end
    if spawnId == rc.pullAPTargetID then return true end
    local queue = rc.pullCandidateIds
    if queue then
        for _, qid in ipairs(queue) do
            if qid == spawnId then return true end
        end
    end
    local attempted = rawget(rc, 'pullAttemptedIds')
    return attempted and attempted[spawnId] or false
end

local function beginPullCandidate(rc, spawn, reason)
    local spawnId = spawn.ID()
    rc.pullAPTargetID = spawnId
    rc.pullTagTimer = botpull.TagTimeCalc('pull', spawnId)
    rc.pullPhase = nil
    rc.pullDeadline = nil
    rc.pullAggroingStartTime = nil
    rc.pullNavStartHP = mq.TLO.Me.PctHPs()
    rc.pullXTargetIdsAtStart = getCurrentXTargetIdSet()
    rc.pullState = 'navigating'
    mq.cmd('/multiline ; /attack off ; /stick off ; /squelch /mqtarget clear')
    mq.cmdf('/nav id %s dist=7 log=off los=on', spawnId)
    rc.statusMessage = string.format('Pulling %s (%s)', spawn.Name(), spawnId)
    if reason then
        printf('\ayCZBot:\ax [Pull] %s; trying backup target %s (%s)', reason, spawn.Name(), spawnId)
    end
end

local function advanceToNextPullCandidate(rc, reason)
    markPullTargetAttempted(rc, reason)
    local queue = rc.pullCandidateIds
    if not queue or #queue == 0 then return false end
    local idx = (rc.pullCandidateIndex or 1) + 1
    while idx <= #queue do
        local spawnId = queue[idx]
        if isQueueEntryViable(spawnId, rc) then
            rc.pullCandidateIndex = idx
            beginPullCandidate(rc, mq.TLO.Spawn(spawnId), reason)
            ensurePullingRunState()
            return true
        end
        idx = idx + 1
    end
    return false
end

local function rebuildPullCandidatesFromArea(rc, reason)
    local excludeId = rc.pullAPTargetID
    local apmoblist = spawnutils.buildPullMobList(rc)
    local maxCandidates = tonumber(myconfig.pull.backupCandidates) or 3
    local targets = selectPullTargets(apmoblist, rc, maxCandidates)
    local filtered = {}
    for _, s in ipairs(targets) do
        local sid = s.ID()
        if sid and sid > 0 and sid ~= excludeId and isQueueEntryViable(sid, rc) then
            filtered[#filtered + 1] = s
        end
    end
    if not filtered[1] then return false end
    local candidateIds = {}
    for i, s in ipairs(filtered) do
        candidateIds[i] = s.ID()
    end
    rc.pullCandidateIds = candidateIds
    rc.pullCandidateIndex = 1
    beginPullCandidate(rc, filtered[1], reason)
    ensurePullingRunState()
    return true
end

---@return boolean true when a backup pull was started (no camp return)
local function abortPullSoftFailure(reason)
    local rc = state.getRunconfig()
    if advanceToNextPullCandidate(rc, reason) then return true end
    if rebuildPullCandidatesFromArea(rc, reason) then return true end
    if myconfig.pull.hunter then
        abortRoamHunt(reason)
    else
        abortPullAndReturnToCamp(reason)
    end
    return false
end

local function hasCampAnchor(rc)
    return rc.makecamp and rc.makecamp.x and rc.makecamp.y and rc.makecamp.z
end

-- Abort-return should tolerate camp LOS edge cases; distance is sufficient to recover state.
local function isAtCampEnoughForAbortReturn(rc)
    if not hasCampAnchor(rc) then return false end
    local meToCampSq = utils.getDistanceSquared2D(rc.makecamp.x, rc.makecamp.y, mq.TLO.Me.X(), mq.TLO.Me.Y())
    local campCloseSq = myconfig.settings.campRestDistanceSq
    return meToCampSq and campCloseSq and meToCampSq <= campCloseSq
end

-- One tick of returning_after_abort: nav to camp, then wait at camp before allowing next pull.
local function tickReturningAfterAbort(rc)
    if not hasCampAnchor(rc) then
        clearPullState('returning_after_abort: no camp anchor')
        return
    end
    if rc.pullAbortReturnDeadline and mq.gettime() >= rc.pullAbortReturnDeadline then
        clearPullState('returning_after_abort: timeout failsafe')
        return
    end
    if not isAtCampEnoughForAbortReturn(rc) then
        rc.pullAtCampSince = nil
        if not mq.TLO.Navigation.Active() then
            botmove.NavToCamp({ dist = 0 })
        end
        return
    end
    if not rc.pullAtCampSince then
        rc.pullAtCampSince = mq.gettime()
    end
    if (mq.gettime() - rc.pullAtCampSince) >= RETURNING_AFTER_ABORT_WAIT_MS then
        clearPullState('returning_after_abort: at camp, wait done')
    end
end

local function abortNavDuringPull(reason)
    if myconfig.pull.hunter then
        abortRoamHunt(reason)
    else
        abortPullAndReturnToCamp(reason)
    end
end

-- One tick of navigating state.
local function tickNavigating(rc, spawn)
    local spawnDistSq = utils.getDistanceSquared2D(mq.TLO.Me.X(), mq.TLO.Me.Y(), spawn.X(), spawn.Y())
    local range = getEffectiveAbilityRange() or 0
    local rangeSq = range * range
    local inRange2D = spawnDistSq and rangeSq and spawnDistSq <= rangeSq
    local spawnLoS = spawn.LineOfSight()
    local haveTarget = (mq.TLO.Target.ID() == rc.pullAPTargetID)
    local outsideCamp = nil
    if rc.campstatus then
        local meToCampSq = utils.getDistanceSquared3D(rc.makecamp.x, rc.makecamp.y, rc.makecamp.z, mq.TLO.Me.X(),
            mq.TLO.Me.Y(), mq.TLO.Me.Z())
        outsideCamp = meToCampSq and myconfig.pull.radiusPlus40Sq and meToCampSq > myconfig.pull.radiusPlus40Sq
    end

    -- Pull target below 100% HP (e.g. someone else on it): unpullable only, not combat FTE block.
    if spawn.PctHPs() and spawn.PctHPs() < 100 then
        local sid = rc.pullAPTargetID
        if sid and sid > 0 then spawnutils.markPullUnpullable(rc, sid) end
        abortPullSoftFailure('Pull target below 100% HP, picking another')
        return
    end

    -- XTarget authoritative: new mob on XTarget = add (abort) or pull target (transition to returning)
    local xtAtStart = rc.pullXTargetIdsAtStart or {}
    local currentXt = getCurrentXTargetIdSet()
    for id, _ in pairs(currentXt) do
        if not xtAtStart[id] then
            if id == rc.pullAPTargetID then
                -- Pull target just appeared on XTarget: we have aggro, return to camp
                transitionPullToReturning(rc, spawn, { clearTarget = true })
                return
            else
                abortNavDuringPull(myconfig.pull.hunter and 'Add aggro (XTarget), aborting hunt.' or 'Add aggro (XTarget), returning to camp.')
                return
            end
        end
    end

    -- Add-abort: HP dropped (we took damage) — unless our own pull target is already on XTarget, in
    -- which case the damage is from the tagged pull target. Let the XTarget transition block above
    -- turn that into a return-to-camp instead of misclassifying our successful tag as an add.
    if rc.pullNavStartHP and mq.TLO.Me.PctHPs() and mq.TLO.Me.PctHPs() < rc.pullNavStartHP
        and not isSpawnOnXTarget(rc.pullAPTargetID) then
        abortNavDuringPull(myconfig.pull.hunter and 'Add aggro / took damage, aborting hunt.' or 'Add aggro / took damage, returning to camp.')
        return
    end
    -- Add-abort: nearby NPC (not pull target, not grey, Aggressive) with LoS
    local addRadius = myconfig.pull.addAbortRadius or 50
    local addFilter = 'npc radius ' .. addRadius
    local ncount = mq.TLO.SpawnCount(addFilter)()
    if ncount and ncount > 0 then
        for i = 1, ncount do
            local sid = mq.TLO.NearestSpawn(i, addFilter).ID()
            if sid and not isKnownPullOutingSpawn(sid, rc) and mq.TLO.NearestSpawn(i, addFilter).Aggressive() then
                local conName = mq.TLO.NearestSpawn(i, addFilter).ConColor()
                local conId = conName and botconfig.ConColorsNameToId[conName:upper()] or 0
                if conId ~= 1 and mq.TLO.NearestSpawn(i, addFilter).LineOfSight() then -- not Grey, has LoS
                    abortNavDuringPull(myconfig.pull.hunter and 'Add aggro, aborting hunt.' or 'Add aggro, returning to camp.')
                    return
                end
            end
        end
    end

    if rc.pullTagTimer and mq.gettime() >= rc.pullTagTimer then
        printf('\ayCZBot:\ax\arI have timed out trying to pull \ay%s', spawn.Name())
        if isPullWarp() then
            mq.cmdf('/warp loc %s %s %s', rc.makecamp.y, rc.makecamp.x, rc.makecamp.z)
        end
        clearPullState('navigating: tag timeout')
        return
    end
    if mq.TLO.Me.PctHPs() and mq.TLO.Me.PctHPs() <= 45 then
        clearPullState('navigating: low HP')
        return
    end
    if rc.campstatus then
        local meToCampSq = utils.getDistanceSquared3D(rc.makecamp.x, rc.makecamp.y, rc.makecamp.z, mq.TLO.Me.X(),
            mq.TLO.Me.Y(), mq.TLO.Me.Z())
        if meToCampSq and myconfig.pull.radiusPlus40Sq and meToCampSq > myconfig.pull.radiusPlus40Sq then
            clearPullState('navigating: outside camp radius')
            return
        end
    end
    if (spawnDistSq and rangeSq and spawnDistSq <= rangeSq and spawn.LineOfSight()) or (mq.TLO.Target.ID() == rc.pullAPTargetID) then
        if mq.TLO.Target.ID() ~= rc.pullAPTargetID then
            mq.cmdf('/squelch /tar id %s', rc.pullAPTargetID)
        end
        if mq.TLO.Me.TargetOfTarget.ID() and mq.TLO.Target.ID() and mq.TLO.Target.Type() == 'NPC' and spawnDistSq and spawnDistSq <= rangeSq then
            if botpull.EngageCheck() then
                abortPullSoftFailure('navigating: EngageCheck (mob engaged by other)')
                return
            end
        end
        if spawnDistSq and rangeSq and spawnDistSq < rangeSq and spawn.LineOfSight() then
            rc.pullState = 'aggroing'
            rc.statusMessage = string.format('Aggroing %s (%s)', spawn.Name(), spawn.ID())
            rc.pullAggroingStartTime = mq.gettime()
            rc.pullPhase = 'aggro_wait_target'
            rc.pullDeadline = mq.gettime() + 1000
            mq.cmd('/nav stop log=off')
            mq.cmdf('/squelch /tar id %s', rc.pullAPTargetID)
            if mq.TLO.Me.Class.ShortName() == 'BRD' then
                local entry = botconfig.config.pull.spell
                if entry and type(entry.gem) == 'number' then
                    bardtwist.SetTwistOnceGem(entry.gem)
                    local castTime = entry.spell and mq.TLO.Spell(entry.spell).MyCastTime()
                    local castTimeMs = (castTime and castTime > 0) and (castTime) or 3000
                    -- wait for cast to finish
                    mq.delay(castTimeMs + 100)
                end
            end
            return
        end
    end
    if not mq.TLO.Navigation.Active() and spawnDistSq and rangeSq and spawnDistSq > rangeSq then
        mq.cmdf('/nav id %s dist=7 log=off los=on', rc.pullAPTargetID)
    end
end

-- Returns true when we have clear line of sight to spawn (spawn check + coordinate ray). Used to avoid agro through walls/tents.
local function pullHasLoS(spawn)
    if not spawn or not spawn.LineOfSight() then return false end
    local mx, my, mz = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
    local sx, sy, sz = spawn.X(), spawn.Y(), spawn.Z()
    if not mx or not sx then return false end
    local losStr = string.format('%s,%s,%s:%s,%s,%s', mx, my, mz, sx, sy, sz)
    return mq.TLO.LineOfSight(losStr)()
end

-- One tick of aggroing state (with sub-phases aggro_wait_target, aggro_wait_cast, aggro_wait_stop_moving, aggro_wait_ranged).
local function tickAggroing(rc, spawn)
    -- Spawn gone or dead: clear immediately so we do not stay stuck in "Aggroing ...".
    if not spawn or not spawn.ID() or spawn.Type() == 'Corpse' then
        clearPullState('aggroing: spawn gone or corpse')
        return
    end
    -- Mob engaged by someone else (e.g. MA): clear so puller is effectively assisting, not "aggroing".
    if botpull.EngageCheck() then
        abortPullSoftFailure('aggroing: EngageCheck (mob engaged by other)')
        return
    end
    if rc.pullPhase == 'aggro_wait_target' then
        if mq.gettime() >= (rc.pullDeadline or 0) then
            clearPullState('aggroing: aggro_wait_target timeout')
            return
        end
        if not pullHasLoS(spawn) then
            mq.cmdf('/nav id %s dist=5 log=off los=on', tostring(rc.pullAPTargetID))
            return
        end
        if mq.TLO.Target.ID() ~= rc.pullAPTargetID then
            mq.cmdf('/squelch /tar id %s', rc.pullAPTargetID)
            return
        end
        rc.pullPhase = nil
    end
    if rc.pullPhase == 'aggro_wait_cast' then
        if mq.TLO.Me.CastTimeLeft() and mq.TLO.Me.CastTimeLeft() > 0 then return end
        startRangedAggroWait(rc)
        return
    end
    if rc.pullPhase == 'aggro_wait_stop_moving' then
        if mq.gettime() >= (rc.pullDeadline or 0) or not mq.TLO.Me.Moving() then
            rc.pullPhase = nil
        else
            return
        end
    end
    if rc.pullPhase == 'aggro_wait_ranged' then
        if pullTargetHasAgro(rc, spawn) then
            transitionPullToReturning(rc, spawn)
            return
        end
        if mq.gettime() < (rc.pullDeadline or 0) then
            return
        end
        rc.pullPhase = nil
    end

    -- Ensure puller has the pull mob targeted so Me.TargetOfTarget (aggro check) works.
    if mq.TLO.Target.ID() ~= rc.pullAPTargetID then
        mq.cmdf('/squelch /tar id %s', rc.pullAPTargetID)
        mq.delay(50)
    end

    -- Aggroing timeout: no agro after 15s -> abort (XTarget authoritative: only timeout when pull target not on XTarget)
    local aggroingElapsed = mq.gettime() - (rc.pullAggroingStartTime or 0)
    if aggroingElapsed > 15000 and not isSpawnOnXTarget(rc.pullAPTargetID) then
        abortPullSoftFailure(myconfig.pull.hunter and 'No agro after 15s, picking another target.' or 'No agro after 15s, returning to camp.')
        return
    end
    -- Transition when pull target has aggro (XTarget or ToT) and min wait (1.5s) has passed
    if pullTargetHasAgro(rc, spawn) and aggroingElapsed >= 1500 then
        transitionPullToReturning(rc, spawn)
        return
    end

    local entry = botpull.GetPullSpell()
    local gem = entry and entry.gem
    local spell = entry and entry.spell and tostring(entry.spell) or ''
    if rc.pullPhase then return end

    -- Require LoS before any agro (targeting/melee/cast); nav closer if blocked (spawn + coordinate check for walls/tents)
    if not pullHasLoS(spawn) then
        if not isBardSongPull then
            mq.cmdf('/nav id %s dist=5 log=off los=on', tostring(spawn.ID()))
        end
        return
    end

    -- Melee (default or explicit), or melee fallback after ranged pull attempt
    if not entry or gem == 'melee' or rc.pullRangedAttempted then
        if mq.TLO.Target.ID() ~= rc.pullAPTargetID then
            mq.cmdf('/squelch /tar id %s', rc.pullAPTargetID)
            return
        end
        mq.cmd('/multiline ; /squelch /nav stop log=off ; /attack on')
        if not mq.TLO.Stick.Active() then mq.cmdf('/stick 5 uw moveback id %s', tostring(spawn.ID())) end
        return
    end

    -- Ranged (bow): swap in bow if needed, ranged attack, swap back after (on returning)
    if gem == 'ranged' and spell ~= '' and not rc.pullRangedAttempted then
        local rangeSlotName = mq.TLO.InvSlot('Ranged').Item.Name() and mq.TLO.InvSlot('Ranged').Item.Name() or ''
        if rangeSlotName ~= spell then
            if rangeSlotName ~= '' then
                rc.pullRangedStoredItem = rangeSlotName
            else
                rc.pullRangedStoredItem = nil
            end
            mq.cmdf('/exchange "%s" Ranged', spell)
        end
        mq.cmdf('/multiline ; /squelch /nav stop log=off ; /face fast ; /squelch attack off ; /ranged on')
        startRangedAggroWait(rc)
        return
    end

    -- Gem-based cast dispatch (numeric gem = spell slot)
    if not rc.pullRangedAttempted and type(gem) == 'number' and gem >= 1 and gem <= 12 then
        local spellName = (spell and spell ~= '') and spell or mq.TLO.Me.Gem(gem)() or ''
        if spellName ~= '' and mq.TLO.Me.SpellReady(spellName)() then
            mq.cmd('/nav stop log=off')
            if mq.TLO.Me.Moving() then
                rc.pullPhase = 'aggro_wait_stop_moving'
                rc.pullDeadline = mq.gettime() + 2000
                return
            end
            spellutils.AutoinvIfCursorBlockingCast()
            casting.start({
                spellName = spellName,
                gemType = gem,
                targetId = rc.pullAPTargetID,
                maxTries = 1,
            })
            rc.pullPhase = 'aggro_wait_cast'
            rc.pullDeadline = mq.gettime() + 8000
            return
        end
    end
    if not rc.pullRangedAttempted and gem == 'disc' and spell ~= '' and mq.TLO.Me.CombatAbilityReady(spell)() then
        mq.cmdf('/multiline ; /nav stop log=off ; /disc %s', spell)
        startRangedAggroWait(rc)
        return
    end
    if not rc.pullRangedAttempted and gem == 'ability' and spell ~= '' and mq.TLO.Me.AbilityReady(spell)() then
        mq.cmdf('/multiline ; /nav stop log=off ; /attack on ; /doability %s', spell)
        startRangedAggroWait(rc)
        return
    end
    if not rc.pullRangedAttempted and gem == 'alt' and spell ~= '' and mq.TLO.Me.AltAbilityReady(spell)() then
        mq.cmd('/nav stop log=off')
        if mq.TLO.Me.Moving() then
            rc.pullPhase = 'aggro_wait_stop_moving'
            rc.pullDeadline = mq.gettime() + 2000
            return
        end
        mq.cmdf('/multiline ; /nav stop log=off ; /alt act %s', mq.TLO.Me.AltAbility(spell)())
        rc.pullPhase = 'aggro_wait_cast'
        rc.pullDeadline = mq.gettime() + 8000
        return
    end
    if not rc.pullRangedAttempted and gem == 'item' and spell ~= '' and mq.TLO.Me.ItemReady(spell)() then
        mq.cmd('/nav stop log=off')
        if mq.TLO.Me.Moving() then
            rc.pullPhase = 'aggro_wait_stop_moving'
            rc.pullDeadline = mq.gettime() + 2000
            return
        end
        spellutils.AutoinvIfCursorBlockingCast()
        mq.cmdf('/multiline ; /nav stop log=off ; /cast item "%s"', spell)
        rc.pullPhase = 'aggro_wait_cast'
        rc.pullDeadline = mq.gettime() + 8000
        return
    end
    if gem == 'script' and spell ~= '' then
        if spellutils.RunScript then
            mq.cmd('/nav stop log=off')
            spellutils.RunScript(spell, 'pull', spawn.ID())
        end
        return
    end

    if not isBardSongPull and not spawn.Aggressive() and mq.TLO.Target.ID() == spawn.ID() and (not mq.TLO.Stick.Active() or not pullHasLoS(spawn)) then
        mq.cmdf('/nav id %s dist=5 log=off los=on', tostring(spawn.ID()))
    end
end

-- One tick of returning state.
local function tickReturning(rc, spawn)
    if not mq.TLO.Navigation.Active() then
        if botmove.AtCamp() then
            rc.pullState = 'waiting_combat'
            rc.statusMessage = string.format('Waiting for combat with %s (%s)', spawn.Name(), spawn.ID())
        else
            botmove.NavToCamp({ dist = 0 })
        end
        return
    end
    if rc.pullReturnTimer and mq.gettime() >= rc.pullReturnTimer then
        clearPullState('returning: return timer')
        return
    end
    if isPullWarp() then
        mq.cmdf('/warp loc %s %s %s', rc.makecamp.y, rc.makecamp.x, rc.makecamp.z)
        clearPullState('returning: warp')
        return
    end
    local retSpawnDistSq = utils.getDistanceSquared2D(mq.TLO.Me.X(), mq.TLO.Me.Y(), spawn.X(), spawn.Y())
    if retSpawnDistSq and myconfig.pull.leashSq and retSpawnDistSq > myconfig.pull.leashSq and not mq.TLO.Navigation.Paused() then
        mq.cmd('/nav pause on log=off')
    elseif retSpawnDistSq and myconfig.pull.leashSq and retSpawnDistSq < myconfig.pull.leashSq and mq.TLO.Navigation.Paused() then
        mq.cmd('/nav pause off log=off')
    end
    if mq.TLO.Me.CombatState() == 'COMBAT' and botmove.AtCamp() then
        rc.pullState = 'waiting_combat'
        rc.statusMessage = string.format('Waiting for combat with %s (%s)', spawn.Name(), spawn.ID())
    end
end

-- One tick of waiting_combat state.
local function tickWaitingCombat(rc)
    local function isAPTarInCamp()
        for _, v in ipairs(rc.MobList or {}) do
            if v.ID() == rc.pullAPTargetID then return true end
        end
        return false
    end
    if (rc.MobList and rc.MobList[1]) and myconfig.settings.domelee then botmelee.AdvCombat() end
    if isAPTarInCamp() or (rc.pullReturnTimer and mq.gettime() >= rc.pullReturnTimer) then
        clearPullState('waiting_combat: AP in camp or timer')
    end
end

function botpull.PullTick()
    local rc = state.getRunconfig()
    if rc.pullState == 'returning_after_abort' then
        tickReturningAfterAbort(rc)
        return
    end
    if not rc.pullState or not rc.pullAPTargetID then return end
    local spawn = mq.TLO.Spawn(rc.pullAPTargetID)
    if not spawnutils.isAliveEngageSpawn(spawn) then
        clearPullState('PullTick: no spawn or corpse')
        return
    end
    if MasterPause then
        clearPullState('PullTick: MasterPause')
        return
    end
    if rc.pullState == 'navigating' or rc.pullState == 'aggroing' then
        if spellutils.MeHasNonCurableDebuff() then
            abortNavDuringPull('Non-curable debuff')
            return
        end
    end

    if rc.pullState == 'navigating' then
        tickNavigating(rc, spawn)
        return
    end
    if rc.pullState == 'aggroing' then
        tickAggroing(rc, spawn)
        return
    end
    if rc.pullState == 'returning' then
        tickReturning(rc, spawn)
        return
    end
    if rc.pullState == 'waiting_combat' then
        tickWaitingCombat(rc)
    end
end

function botpull.getHookFn(name)
    if name == 'doPull' then
        return function(hookName)
            if utils.isNearPrimaryBindPoint() then return end
            local rc = state.getRunconfig()
            if not rc.dopull then return end
            if state.isTravelMode() then return end
            if utils.isNonCombatZone(mq.TLO.Zone.ShortName()) then return end
            if state.getRunState() == state.STATES.raid_mechanic then return end
            if isRoamMode() then
                botpull.syncPullMapFilter(false)
                if rc.campstatus then botmove.MakeCamp('off') end
                tickRoamNav(rc)
                return
            end
            botpull.ensurePullCampState(rc)
            if state.getRunState() == state.STATES.pulling then
                botpull.PullTick()
                return
            end
            if shouldStartPull(rc) then
                botpull.StartPull()
            end
        end
    end
    return nil
end

--- Abort active pull when FTE lock fires (clears APTarget and returns to camp when navigating/aggroing).
---@param reason string|nil
---@param spawnId number|nil FTE-locked NPC spawn id
---@return boolean true when a backup pull was started instead of returning to camp
function botpull.AbortPullForFTE(reason, spawnId)
    local rc = state.getRunconfig()
    if APTarget then APTarget = false end
    if isRoamMode() and rc.dopull then
        if spawnId and rc.roamNavTargetId == spawnId then
            clearRoamNav(rc)
        elseif spawnId and rc.roamNavTargetId then
            clearRoamNav(rc)
        end
        if not rc.pullHealerManaWait and not rc.pullDebuffWait then
            rc.statusMessage = 'FTE locked, finding another target'
        end
        return false
    end
    local inActivePull = rc.pullState == 'navigating' or rc.pullState == 'aggroing'
    if inActivePull and rc.pullAPTargetID then
        return abortPullSoftFailure(reason or 'FTE lock detected')
    elseif rc.pullAPTargetID then
        rc.pullAPTargetID = nil
    end
    return false
end

return botpull
