local mq = require('mq')
local botconfig = require('lib.config')
local combat = require('lib.combat')
local state = require('lib.state')
local bothooks = require('lib.bothooks')
local targeting = require('lib.targeting')
local utils = require('lib.utils')
local charinfo = require('plugin.charinfo')
local myconfig = botconfig.config

local botmove = {}
local CorpseID = nil
local carryCorpseID = nil
local lastFollowResolveFailTime = 0

-- ---------------------------------------------------------------------------
-- Follow / stuck helpers
-- ---------------------------------------------------------------------------

--- True when follow is active and 2D distance to leader >= settings.followdistance.
function botmove.isBeyondFollowDistance()
    local rc = state.getRunconfig()
    if not rc.followid or rc.followid == 0 then return false end
    local followSpawn = mq.TLO.Spawn(rc.followid)
    if not followSpawn or not followSpawn.ID() or followSpawn.ID() == 0 then return false end
    local meX, meY = mq.TLO.Me.X(), mq.TLO.Me.Y()
    local fx, fy = followSpawn.X(), followSpawn.Y()
    if not meX or not meY or not fx or not fy then return false end
    local dSq = utils.getDistanceSquared2D(meX, meY, fx, fy)
    local followdistanceSq = myconfig.settings.followdistanceSq
    if not dSq or not followdistanceSq then return false end
    return dSq >= followdistanceSq
end

local function followSpawnMatchesName(spawnId, followname)
    if not spawnId or spawnId == 0 then return false end
    if not followname or followname == '' then return true end
    local sp = mq.TLO.Spawn('id ' .. spawnId)
    if not sp or not sp.ID() or sp.ID() ~= spawnId then return false end
    local stype = sp.Type() or ''
    if stype == 'Corpse' then return false end
    local clean = sp.CleanName()
    if not clean or clean == '' then return false end
    return string.lower(clean) == string.lower(followname)
end

local function resolveFollowIdByName(followname)
    if not followname or followname == '' then return nil end
    local id = mq.TLO.Spawn('=' .. followname).ID()
    if id and id > 0 then return id end
    return nil
end

local function refreshFollowId()
    local rc = state.getRunconfig()
    if rc.followname and rc.followname ~= '' then
        local needsResolve = not rc.followid or rc.followid == 0
            or not followSpawnMatchesName(rc.followid, rc.followname)
        if needsResolve then
            local id = resolveFollowIdByName(rc.followname)
            if id then
                rc.followid = id
                return
            end
            rc.followid = 0
            local now = mq.gettime()
            if now >= lastFollowResolveFailTime + 15000 then
                lastFollowResolveFailTime = now
                printf('\aybobblebot:\axFollow: waiting for leader "%s" in zone.', rc.followname)
            end
        end
        return
    end
    if not rc.followid or rc.followid == 0 then return end
    local followid = rc.followid
    if not mq.TLO.Spawn('id ' .. followid).ID() or mq.TLO.Spawn('id ' .. followid).Type() == 'Corpse' then
        rc.followid = 0
    end
end

local function doFollowNav()
    local rc = state.getRunconfig()
    if mq.TLO.Me.Sneaking() then mq.cmd('/doability sneak') end
    mq.cmdf('/nav id %s log=off', rc.followid)
end

local function shouldCallFollow(rc)
    local followid = mq.TLO.Spawn(rc.followid).ID() or 0
    local followdistance = mq.TLO.Spawn(rc.followid).Distance() or 0
    local engageId = rc.engageTargetId or 0
    local followtype = mq.TLO.Spawn(rc.followid).Type() or "none"
    return followid > 0 and followdistance > 0 and engageId == 0 and followtype ~= 'Corpse' and
        followdistance >= myconfig.settings.followdistance
end

-- ---------------------------------------------------------------------------
-- UnStuck phase handlers
-- ---------------------------------------------------------------------------

local UNSTUCK_EXIT_COOLDOWN_MS = 60000
local UNSTUCK_NAV_WAIT_MS = 5000
local UNSTUCK_NUDGE_HOLD_MS = 600
local UNSTUCK_RETRY_LIMIT = 3

local function isValidFollowTarget(followid)
    if not followid or followid == 0 then return false end
    local sid = mq.TLO.Spawn('id ' .. followid).ID() or 0
    if sid == 0 then return false end
    local stype = mq.TLO.Spawn('id ' .. followid).Type() or ''
    return stype ~= 'Corpse'
end

local function clearUnstuckIfFollowInactive(rc)
    if state.getRunState() ~= state.STATES.unstuck then return false end
    local hasFollowName = rc.followname and rc.followname ~= ''
    local hasValidFollowTarget = isValidFollowTarget(rc.followid)
    if hasFollowName or hasValidFollowTarget then return false end
    rc.stucktimer = mq.gettime() + UNSTUCK_EXIT_COOLDOWN_MS
    state.clearRunState()
    return true
end

local function clearUnstuckOnFollowSuccess(rc, followid)
    if state.getRunState() ~= state.STATES.unstuck then return false end
    if not followid or followid == 0 then return false end
    local d3 = mq.TLO.Spawn(followid).Distance3D()
    local acleash = myconfig.settings.acleash
    if d3 and acleash and d3 <= acleash then
        rc.stucktimer = mq.gettime() + UNSTUCK_EXIT_COOLDOWN_MS
        state.clearRunState()
        return true
    end
    local d2 = mq.TLO.Spawn(followid).Distance()
    local followdist = myconfig.settings.followdistance
    if d2 and followdist and d2 < followdist and not mq.TLO.Navigation.Active() then
        rc.stucktimer = mq.gettime() + UNSTUCK_EXIT_COOLDOWN_MS
        state.clearRunState()
        return true
    end
    return false
end

local function updateStuckTimerWithinLeash(rc)
    local d3 = mq.TLO.Spawn(rc.followid).Distance3D()
    if d3 and d3 <= myconfig.settings.acleash then
        if not rc.stucktimer or rc.stucktimer < mq.gettime() + UNSTUCK_EXIT_COOLDOWN_MS then
            rc.stucktimer = mq.gettime() + UNSTUCK_EXIT_COOLDOWN_MS
        end
        clearUnstuckOnFollowSuccess(rc, rc.followid)
    end
end

local function normalizeHeading360(heading)
    local h = tonumber(heading) or 0
    while h < 0 do h = h + 360 end
    while h >= 360 do h = h - 360 end
    return h
end

local function beginUnstuckNudge(followid, stuckdistance, attempts)
    local heading = normalizeHeading360(mq.TLO.Me.Heading() or 0)
    local offsets = { 25, -25, 45, -45, 65, -65, 90, -90 }
    local idxMax = math.min(#offsets, math.max(2, (attempts or 1) * 2))
    local offset = offsets[math.random(1, idxMax)]
    local targetHeading = normalizeHeading360(heading + offset)

    mq.cmd('/squelch /nav stop')
    mq.cmdf('/squelch /multiline ; /face fast heading %s ; /stand ; /keypress forward hold', targetHeading)

    if state.canStartBusyState(state.STATES.unstuck) then
        state.setRunState(state.STATES.unstuck,
            {
                phase = 'nudge_wait',
                deadline = mq.gettime() + UNSTUCK_NUDGE_HOLD_MS,
                followid = followid,
                stuckdistance = stuckdistance,
                attempts = attempts or 1,
                priority = bothooks.getPriority('doMiscTimer')
            })
    end
end

local function tickUnstuckPhase(p, followid, stuckdistance)
    local rc = state.getRunconfig()
    if clearUnstuckOnFollowSuccess(rc, followid) then return true end
    if not p or p.followid ~= followid then
        rc.stucktimer = mq.gettime() + UNSTUCK_EXIT_COOLDOWN_MS
        state.clearRunState()
        return true
    end
    if mq.gettime() < (p.deadline or 0) then return true end
    local nowdist = mq.TLO.Spawn(followid).Distance3D()
    if p.phase == 'nav_wait5' then
        if nowdist and p.stuckdistance and p.stuckdistance >= nowdist + 10 then
            rc.stucktimer = mq.gettime() + UNSTUCK_EXIT_COOLDOWN_MS
            state.clearRunState()
            return true
        end

        local attempts = (p.attempts or 0) + 1
        if attempts > UNSTUCK_RETRY_LIMIT then
            rc.stucktimer = mq.gettime() + UNSTUCK_EXIT_COOLDOWN_MS
            state.clearRunState()
            return true
        end

        beginUnstuckNudge(followid, nowdist or p.stuckdistance, attempts)
    elseif p.phase == 'nudge_wait' then
        mq.cmd('/squelch /keypress forward')
        mq.cmdf('/squelch /nav id %s los=on dist=15 log=off', followid)
        local restartDist = mq.TLO.Spawn(followid).Distance3D() or stuckdistance
        if state.canStartBusyState(state.STATES.unstuck) then
            state.setRunState(state.STATES.unstuck,
                {
                    phase = 'nav_wait5',
                    deadline = mq.gettime() + UNSTUCK_NAV_WAIT_MS,
                    followid = followid,
                    stuckdistance = restartDist,
                    attempts = p.attempts or 1,
                    priority = bothooks.getPriority('doMiscTimer')
                })
        end
    end
    return true
end

local function tryPathExistsUnstuck(followid)
    if not followid or followid == 0 then return false end
    if not mq.TLO.Navigation.PathExists('id ' .. followid)() then return false end
    mq.cmdf('/nav id %s los=on dist=15 log=off', followid)
    if state.canStartBusyState(state.STATES.unstuck) then
        state.setRunState(state.STATES.unstuck,
            {
                phase = 'nav_wait5',
                deadline = mq.gettime() + UNSTUCK_NAV_WAIT_MS,
                followid = followid,
                stuckdistance = mq.TLO.Spawn(followid).Distance3D() or 100,
                attempts = 0,
                priority = bothooks.getPriority(
                    'doMiscTimer')
            })
    end
    return true
end

-- Unstuck nudge: stop nav, turn slightly left/right, move forward briefly.
local function doWiggleUnstuck(followid, stuckdistance)
    beginUnstuckNudge(followid, stuckdistance, 1)
end

-- ---------------------------------------------------------------------------
-- Engage return-to-follow phase handlers
-- ---------------------------------------------------------------------------

local function tickEngageReturnDelay400(p)
    local now = mq.gettime()
    if now < (p.deadline or 0) then return end
    if state.canStartBusyState(state.STATES.engage_return_follow) then
        state.setRunState(state.STATES.engage_return_follow,
            { phase = 'nav_wait', deadline = now + 10000, priority = bothooks.getPriority('doMiscTimer') })
    end
end

local function tickEngageReturnNavWait(p)
    local now = mq.gettime()
    if not mq.TLO.Navigation.Active() or now >= (p.deadline or 0) then
        state.clearRunState()
    end
end

-- ---------------------------------------------------------------------------
-- MakeCamp leash helpers
-- ---------------------------------------------------------------------------

local function campDistanceOk(rc)
    local campCloseSq = myconfig.settings.campRestDistanceSq
    local distSq = utils.getDistanceSquared2D(mq.TLO.Me.X(), mq.TLO.Me.Y(), rc.makecamp.x, rc.makecamp.y)
    return distSq and campCloseSq and distSq <= campCloseSq
end

local function campLOSOk(rc)
    local makecamp = rc and rc.makecamp
    if not makecamp then return false end
    local campX, campY, campZ = makecamp.x, makecamp.y, makecamp.z
    if not campX or not campY or not campZ then return false end
    local meX, meY, meZ = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
    if not meX or not meY or not meZ then return false end
    local losStr = string.format('%s,%s,%s:%s,%s,%s', meX, meY, meZ, campX, campY, campZ)
    return mq.TLO.LineOfSight(losStr)()
end

local function hasCampSet(rc)
    return rc and rc.campstatus and rc.makecamp and rc.makecamp.x and rc.makecamp.y and rc.makecamp.z
end

local function isCampDragWorkflowActive()
    if state.getRunState() ~= state.STATES.dragging then return false end
    local p = state.getRunStatePayload()
    return p and p.mode == 'camp_fetch'
end

local function isCorpseAtCamp(corpseID, rc)
    if not corpseID or not hasCampSet(rc) then return false end
    local corpseX = mq.TLO.Spawn(corpseID).X()
    local corpseY = mq.TLO.Spawn(corpseID).Y()
    if not corpseX or not corpseY then return false end
    local campCloseSq = myconfig.settings.campRestDistanceSq
    local distSq = utils.getDistanceSquared2D(corpseX, corpseY, rc.makecamp.x, rc.makecamp.y)
    return distSq and campCloseSq and distSq <= campCloseSq
end

local function doLeashResetCombat()
    combat.ResetCombatState()
end

-- Navigate to camp location (makecamp.x/y/z). opts: dist (number|nil), echoMsg (string|nil).
local function doNavToCamp(opts)
    opts = opts or {}
    local rc = state.getRunconfig()
    if not rc.makecamp.x or not rc.makecamp.y or not rc.makecamp.z then return end
    if opts.echoMsg then printf('\aybobblebot:\ax %s', opts.echoMsg) end
    if opts.dist ~= nil then
        mq.cmdf('/nav locxyz %s %s %s log=off dist=%s', rc.makecamp.x, rc.makecamp.y, rc.makecamp.z, opts.dist)
    else
        mq.cmdf('/nav locxyz %s %s %s log=off', rc.makecamp.x, rc.makecamp.y, rc.makecamp.z)
    end
end

-- ---------------------------------------------------------------------------
-- MakeCamp (on / off / return) helpers
-- ---------------------------------------------------------------------------

local function setCampHere()
    local rc = state.getRunconfig()
    rc.makecamp.x = mq.TLO.Me.X()
    rc.makecamp.y = mq.TLO.Me.Y()
    rc.makecamp.z = mq.TLO.Me.Z()
end

local function makeCampOn()
    if mq.TLO.Stick.Active() then mq.cmd('/stick off') end
    if mq.TLO.Navigation.Active() then mq.cmd('/nav stop log=off') end
    if not mq.TLO.Navigation.MeshLoaded() then
        printf('\aybobblebot:\axCannot use makecamp (no mesh loaded)')
        return false
    end
    setCampHere()
    state.getRunconfig().campstatus = true
    local rc = state.getRunconfig()
    rc.followid = 0
    rc.followname = ''
    printf('\aybobblebot:\axhanging out using mq2nav')
    return true
end

local function makeCampOff()
    local rc = state.getRunconfig()
    rc.campstatus = false
    if not myconfig.pull.hunter and not myconfig.pull.roam then
        rc.makecamp = { x = nil, y = nil, z = nil }
    end
    printf('\aybobblebot:\axmakecamp \aroff\ax')
end

local function makeCampReturn()
    doLeashResetCombat()
    doNavToCamp()
    if state.canStartBusyState(state.STATES.camp_return) then
        state.setRunState(state.STATES.camp_return,
            { deadline = mq.gettime() + 5000, priority = bothooks.getPriority('doMiscTimer') })
    end
end

-- ---------------------------------------------------------------------------
-- DragCheck helpers
-- ---------------------------------------------------------------------------

local DragDist = 1500

local function tickSumcorpsePending()
    if state.getRunState() ~= state.STATES.sumcorpse_pending then return false end
    local p = state.getRunStatePayload()
    if p and p.corpseID then
        targeting.TargetAndWait(p.corpseID, 500)
        mq.cmd('/sumcorpse')
    end
    state.clearRunState()
    return true
end

local function tickDragging(payload)
    if not payload or not payload.corpseID then
        state.clearRunState()
        return true
    end
    local rc = state.getRunconfig()
    local cid = payload.corpseID
    if payload.phase == 'init' then
        if mq.gettime() < (payload.deadline or 0) then return true end
        mq.cmd('/hidec none')
        mq.cmd('/multiline ; /attack off ; /stick off')
        targeting.TargetAndWait(cid, 500)
        if state.canStartBusyState(state.STATES.dragging) then
            state.setRunState(state.STATES.dragging,
                {
                    phase = 'sneak',
                    mode = payload.mode,
                    corpseID = cid,
                    priority = bothooks.getPriority('doMiscTimer')
                })
        end
        return true
    end
    if payload.phase == 'sneak' then
        if mq.TLO.Me.Class.ShortName() == 'ROG' and (not mq.TLO.Me.Invis() or not mq.TLO.Me.Sneaking()) then
            if not mq.TLO.Me.Sneaking() then mq.cmd('/squelch /doability sneak') end
            if mq.TLO.Me.AbilityReady("Hide")() then mq.cmd('/squelch /doability hide') end
            return true
        end
        mq.cmdf('/nav id %s', cid)
        if state.canStartBusyState(state.STATES.dragging) then
            state.setRunState(state.STATES.dragging,
                {
                    phase = 'navigating',
                    mode = payload.mode,
                    corpseID = cid,
                    priority = bothooks.getPriority('doMiscTimer')
                })
        end
        return true
    end
    if payload.phase == 'navigating' then
        if not mq.TLO.Navigation.Active() then
            state.clearRunState()
            return true
        end
        local corpsedist = mq.TLO.Spawn(cid).Distance3D()
        if mq.TLO.Spawn(cid).ID() and corpsedist and corpsedist < 90 then
            if not targeting.TargetAndWait(cid, 1000) then
                return true
            end
            mq.cmd('/multiline ; /corpsedrag ; /nav stop')
            if payload.mode == 'carry' then
                carryCorpseID = cid
                state.clearRunState()
                CorpseID = nil
                return true
            end
            if payload.mode == 'camp_fetch' and hasCampSet(rc) then
                doNavToCamp({ dist = myconfig.settings.campRestDistance or 15 })
                if state.canStartBusyState(state.STATES.dragging) then
                    state.setRunState(state.STATES.dragging,
                        {
                            phase = 'returning_camp',
                            mode = 'camp_fetch',
                            corpseID = cid,
                            deadline = mq.gettime() + 20000,
                            priority = bothooks.getPriority('doMiscTimer')
                        })
                end
                return true
            end
            state.clearRunState()
            CorpseID = nil
            return true
        end
    end
    if payload.phase == 'returning_camp' then
        if hasCampSet(rc) and campDistanceOk(rc) and campLOSOk(rc) then
            if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
            if not targeting.TargetAndWait(cid, 1000) then
                return true
            end
            mq.cmd('/corpsedrop')
            state.clearRunState()
            CorpseID = nil
            return true
        end
        if not mq.TLO.Navigation.Active() or mq.gettime() >= (payload.deadline or 0) then
            state.clearRunState()
            CorpseID = nil
            return true
        end
    end
    return true
end

local function findCorpseCandidates(maxDist, mode)
    local rc = state.getRunconfig()
    local bots = charinfo.GetPeers()
    local searchDist = maxDist or DragDist
    local candidates = {}
    for cor = 1, charinfo.GetPeerCnt() do
        local bot = bots[cor]
        if bot then
            local corpseSpawn = mq.TLO.Spawn(bot .. "'s corpse")
            local corpseType = corpseSpawn.Type()
            local corpsedist = corpseSpawn.Distance()
            local corpseID = corpseSpawn.ID()
            local inRange = corpseType == 'Corpse' and corpsedist and corpsedist > 10 and corpsedist < searchDist
            if inRange and corpseID then
                local atCamp = mode == 'camp_fetch' and isCorpseAtCamp(corpseID, rc)
                if not atCamp then
                    candidates[#candidates + 1] = { id = corpseID, dist = corpsedist }
                end
            end
        end
    end
    table.sort(candidates, function(a, b)
        return a.dist > b.dist
    end)
    return candidates
end

local function startDrag(corpseId, justDidSumcorpse, mode)
    local rc = state.getRunconfig()
    if rc.DragHack and corpseId and not justDidSumcorpse then
        targeting.TargetAndWait(corpseId, 500)
        mq.cmd('/sumcorpse')
        return true
    end
    if corpseId and mq.TLO.Navigation.PathExists('id ' .. corpseId)() then
        mq.cmd('/mqtarget clear')
        if state.canStartBusyState(state.STATES.dragging) then
            state.setRunState(state.STATES.dragging,
                {
                    phase = 'init',
                    mode = mode,
                    corpseID = corpseId,
                    deadline = mq.gettime() + 2000,
                    priority = bothooks.getPriority(
                        'doMiscTimer')
                })
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function botmove.ClearFollowMovementState()
    local current = state.getRunState()
    if current == state.STATES.unstuck or current == state.STATES.engage_return_follow then
        state.clearRunState()
    end
    if mq.TLO.Navigation.Active() then mq.cmd('/nav stop log=off') end
end

function botmove.FollowCall()
    if MasterPause then return false end
    local rc = state.getRunconfig()
    refreshFollowId()
    clearUnstuckIfFollowInactive(rc)
    if not rc.followid or rc.followid == 0 then return false end
    if not rc.stucktimer then rc.stucktimer = 0 end
    if rc.stucktimer <= mq.gettime() then botmove.UnStuck() end
    if not isValidFollowTarget(rc.followid) then return false end
    if mq.TLO.Me.Sitting() then mq.cmd('/stand') end
    doFollowNav()
    return true
end

function botmove.UnStuck()
    local rc = state.getRunconfig()
    clearUnstuckIfFollowInactive(rc)
    local followid = rc.followid
    if not followid or followid == 0 then return false end
    if not isValidFollowTarget(followid) then return false end

    if state.getRunState() == state.STATES.unstuck then
        botmove.TickUnstuck()
        return false
    end

    if not mq.TLO.Navigation.Active() then return false end
    local stuckdistance = mq.TLO.Spawn(followid).Distance3D() or 100
    local acleash = myconfig.settings.acleash
    if stuckdistance < acleash then return false end

    if tryPathExistsUnstuck(followid) then return false end

    print('I appear to be stuck, attempting to get unstuck')

    doWiggleUnstuck(followid, stuckdistance)
    return false
end

function botmove.StartReturnToFollowAfterEngage()
    local rc = state.getRunconfig()
    if not rc.followid or rc.followid == 0 then return end
    local followid = mq.TLO.Spawn(rc.followid).ID() or 0
    local followtype = mq.TLO.Spawn(rc.followid).Type() or "none"
    local followdistance = mq.TLO.Spawn(rc.followid).Distance() or 0
    if followdistance < myconfig.settings.followdistance or not followid or followtype == 'Corpse' then return end
    mq.cmd('/multiline ; /stick off ; /squelch /attack off ; /mqtarget self')
    botmove.FollowCall()
    if state.canStartBusyState(state.STATES.engage_return_follow) then
        state.setRunState(state.STATES.engage_return_follow,
            { phase = 'delay_400', deadline = mq.gettime() + 400, priority = bothooks.getPriority('doMiscTimer') })
    end
end

function botmove.TickReturnToFollowAfterEngage()
    if state.getRunState() ~= state.STATES.engage_return_follow then return end
    local p = state.getRunStatePayload()
    if not p then
        state.clearRunState()
        return
    end
    if p.phase == 'delay_400' then
        tickEngageReturnDelay400(p)
        return
    end
    if p.phase == 'nav_wait' then
        tickEngageReturnNavWait(p)
    end
end

function botmove.TickUnstuck()
    if state.getRunState() ~= state.STATES.unstuck then return end
    local rc = state.getRunconfig()
    local followid = rc.followid
    if not followid or followid == 0 then
        state.clearRunState()
        return
    end
    if clearUnstuckOnFollowSuccess(rc, followid) then return end
    local p = state.getRunStatePayload()
    tickUnstuckPhase(p, followid, mq.TLO.Spawn(followid).Distance3D() or 100)
end

-- Follow nav + stuck detection and unstuck state machine. Called from doMovementCheck (runWhenBusy).
function botmove.FollowAndStuckCheck()
    botmove.TickReturnToFollowAfterEngage()
    botmove.TickUnstuck()
    local rc = state.getRunconfig()
    if (rc.followid and rc.followid > 0) or (rc.followname and rc.followname ~= '') then
        refreshFollowId()
    end
    clearUnstuckIfFollowInactive(rc)
    if not (rc.followid and rc.followid > 0) then return end
    local followid = mq.TLO.Spawn(rc.followid).ID() or 0
    if followid > 0 and followid ~= rc.followid then
        rc.followid = followid
    end
    if shouldCallFollow(rc) then
        botmove.FollowCall()
    end
    updateStuckTimerWithinLeash(rc)
end

-- Camp return and leash. Called from doMovementCheck (runWhenBusy).
function botmove.MakeCampLeashCheck()
    local rc = state.getRunconfig()
    if not hasCampSet(rc) then return end
    if rc.engageTargetId then return end
    if isCampDragWorkflowActive() then return end
    if mq.TLO.Me.Class.ShortName() ~= 'BRD' and mq.TLO.Me.Casting.ID() then return end
    if state.getRunState() == state.STATES.pulling then return end
    if campDistanceOk(rc) and campLOSOk(rc) then return end
    print("\ar Exceeded ACLeash\ax, resetting combat") -- not debug, real status message
    doLeashResetCombat()
    botmove.MakeCamp('return')
end

function botmove.NavToCamp(opts)
    doNavToCamp(opts)
end

--- Returns true when the current position is at camp (within camp-close distance and LOS).
function botmove.AtCamp()
    local rc = state.getRunconfig()
    if not hasCampSet(rc) then return false end
    return campDistanceOk(rc) and campLOSOk(rc)
end

function botmove.SetCampHere()
    setCampHere()
end

--- Clear camp status and stored anchor. Always nils makecamp (including hunter anchor).
---@param reason string|nil e.g. death, zone
---@return boolean true if camp was cleared
function botmove.ClearCamp(reason)
    local rc = state.getRunconfig()
    local hadCampStatus = rc.campstatus == true
    local hadCoords = rc.makecamp and (rc.makecamp.x or rc.makecamp.y or rc.makecamp.z)
    if not hadCampStatus and not hadCoords then return false end

    if mq.TLO.Stick.Active() then mq.cmd('/stick off') end
    if mq.TLO.Navigation.Active() then mq.cmd('/nav stop log=off') end
    rc.campstatus = false
    rc.makecamp = { x = nil, y = nil, z = nil }
    if reason == 'death' then
        printf('\aybobblebot:\ax\arCamp cleared (death)\ax')
    end
    return true
end

--- Set or clear camp. mode: 'on' | 'off' | 'return' or nil (toggle).
function botmove.MakeCamp(...)
    local args = { ... }
    local mode = args[1]
    if not mode then
        mode = state.getRunconfig().campstatus and 'off' or 'on'
    end
    if mode == 'on' then
        return makeCampOn()
    elseif mode == 'off' then
        makeCampOff()
    elseif mode == 'return' then
        print('return called') -- not debug, but needs reformatting / context to be meaningful
        makeCampReturn()
    end
end

function botmove.DragCheck()
    local just_did_sumcorpse = tickSumcorpsePending()
    local rc = state.getRunconfig()
    local mode = hasCampSet(rc) and 'camp_fetch' or 'carry'

    if state.getRunState() == state.STATES.dragging then
        local payload = state.getRunStatePayload()
        if tickDragging(payload) then return end
    end

    if mode == 'carry' and carryCorpseID then
        if mq.TLO.Spawn(carryCorpseID).ID() then return false end
        carryCorpseID = nil
    end

    CorpseID = nil
    local searchDist = (mode == 'carry') and (myconfig.settings.acleash or 75) or DragDist
    local candidates = findCorpseCandidates(searchDist, mode)
    if #candidates == 0 then return false end
    for _, corpse in ipairs(candidates) do
        if startDrag(corpse.id, just_did_sumcorpse, mode) then
            CorpseID = corpse.id
            return true
        end
    end
    return false
end

return botmove
