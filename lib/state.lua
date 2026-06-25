---@class RunConfig
---@field ScriptList table
---@field SubOrder table
---@field zonename string
---@field engageTargetId number|nil
---@field lastAssistTargetId number|nil session-only MA target remembered while MA is dead/hovering
---@field lastResolvedAssistName string|nil session-only tracker for MA identity changes
---@field MaList table cz_common ma_list mirror
---@field MtList table cz_common mt_list mirror
---@field allMezzedEngageId number|nil spawn id locked while entire camp is mezzed (shortest remaining mez)
---@field attackCommandEngage boolean|nil when true, engageTargetId was set by /cz attack; do not overwrite in AdvCombat for DPS/OT.
---@field AlertList number
---@field followid number
---@field followname string
---@field TankName string
---@field AssistName string
---@field ExcludeList table
---@field PriorityList table
---@field CharmList table
---@field MobList table
---@field engagetracker table
---@field campstatus boolean
---@field makecamp {x:number|nil, y:number|nil, z:number|nil}
---@field doCampAcleash boolean|nil when false and makecamp on, allow chase/assist outside Radius; MobList still uses Radius; session-only, default on
---@field charmid number|nil
---@field charmSkipIds table|nil spawnId -> true; session charm pets to exclude from engage/mez until dead or /cz attack
---@field domelee boolean|nil
---@field dopull boolean|nil
---@field dosongs boolean|nil session-only bard twist; default on at start, not saved to config
---@field bardNotmatarWait table|nil BRD notmatar twist-once wait (mez/add debuff flow)
---@field burnUntil number|nil mq.gettime() end of the burn window; nil = not burning. Exposed to spell preconditions as `burn`.
---@field pulledmob number|nil
---@field pullreturntimer number|nil
---@field pulledmobLastDistSq number|nil cached distance-squared from puller to pulled mob when last saw it closer
---@field pulledmobLastCloserTime number|nil mq.gettime() when we last observed pulled mob get closer (10s timeout)
---@field pullNavStartHP number|nil PctHPs when we started navigating (for add-abort on damage)
---@field pullXTargetIdsAtStart table|nil set of XTarget spawn IDs at pull start (id -> true), for add detection while navigating
---@field pullarc number|nil
---@field FTEList table spawnId -> { id, strikes?, combatBlockedUntil?, nextCombatRecheckAt?, pullUnpullableUntil?, lastStrikeAt? }
---@field FTECount number
---@field fteRecheckProbeId number|nil spawn id being probed for in-camp FTE recheck
---@field fteRecheckInProgress boolean|nil true while AddSpawnCheck is running a recheck target probe
---@field CurSpell table When casting: phase (e.g. casting, precast, precast_wait_move), sub, spell (index), target, targethit, spellcheckResume; casting backend fields: viaCastingLib (alias viaMQ2Cast for compatibility), spellid, castToken.
---@field HoverTimer number
---@field DragHack boolean
---@field HoverEchoTimer number
---@field SpellTimer number
---@field interruptCounter table
---@field PreCH table
---@field gmtimer number
---@field MyPetID number|nil
---@field IgnoreMobBuff boolean
---@field YellTimer number
---@field MissedNote boolean
---@field terminate boolean
---@field runState number
---@field runStateDeadline number|nil
---@field runStatePhase string|nil
---@field runStatePayload table|nil
---@field pullState string|nil
---@field roamNavTargetId number|nil spawn ID for simplified roam nav when camp bubble is empty
---@field roamBuffCheckPending boolean|nil when true, roam nav defers until doBuff completes one idle cycle after camp clears
---@field pullAPTargetID number|nil
---@field pullTagTimer number|nil
---@field pullReturnTimer number|nil
---@field pullPhase string|nil
---@field pullDeadline number|nil
---@field pullAggroingStartTime number|nil mq.gettime() when entered aggroing state (for timeout)
---@field pullAtCampSince number|nil mq.gettime() when we reached camp in returning_after_abort (for wait before next pull)
---@field pullSpawnWaitSince number|nil mq.gettime() when a new spawn appeared in pull.radius (FTE wait)
---@field pullRadiusHadTarget boolean|nil true once a pull target was seen in radius this idle cycle
---@field pullAbortReturnDeadline number|nil mq.gettime() failsafe deadline for returning_after_abort
---@field pullCandidateIds number[]|nil spawn IDs queued for current pull outing (backup targets)
---@field pullCandidateIndex number|nil 1-based index into pullCandidateIds for active target
---@field pullRangedStoredItem string|nil item name swapped out of Ranged slot during pull (restored on return)
---@field stucktimer number|nil
---@field unstuckWiggleIndex number|nil current step (1–9) in unstuck wiggle sequence; nil when not wiggling or after sequence
---@field mobprobtimer number
---@field sitTimer number|nil mq.gettime() until which we should not auto-sit (set when hit; cleared when expired or no mobs in camp)
---@field spellNotInBook table|nil
---@field statusMessage string User-facing activity line for GUI
---@field pullHealerManaWait { name: string, pct: number, current?: number }|nil when set, puller is waiting on this healer's mana before next pull; status tab shows it
---@field pullDebuffWait { name: string }|nil when set, puller has a non-curable debuff and will not pull until it fades
---@field maCastInterruptPending { targetId: number, mobName: string, requestedAt: number }|nil deferred MA-target mez/stun interrupt
---@field OutOfSpace boolean|nil true when inventory was full (cursor item); cleared when space available again
---@field forageExpectCursor boolean|nil after /doability Forage: expect item on cursor; CharState /autoinv only while set
---@field forageCursorUntil number|nil mq.gettime() deadline for stale clear when forage yields nothing
---@field forageSawCursor boolean|nil true once cursor had an item after forage (clears flag when cursor empties before deadline)
--- CHChain state (set by commands.cmd_chchain / chchainSetupContinuation; read by lib.chchain).
---@field doChchain boolean
---@field chchainCurtank number
---@field chchainPause number
---@field chchainTank string
---@field chchainTanklist table
---@field chnextClr string|boolean|nil
---@field chchainList string|nil
--- Abort flags: true when abort turned off domelee/dodebuff so "abort off" can restore them.
---@field meleeAbort boolean
---@field debuffAbort boolean
--- Nuke rotation and flavor: last cast nuke index; recent resist-disables for global auto-disable; allowed/auto-disabled flavors (loaded from common per zone).
---@field lastNukeIndex number|nil
---@field nukeResistDisabledRecent table|nil last N entries { flavor = string }; used to detect 3-in-a-row same flavor -> global auto-disable
---@field nukeFlavorsAllowed table|nil flavor -> true (allowed); nil = all allowed
---@field nukeFlavorsAutoDisabled table|nil flavor -> true (auto-disabled due to resist streak)
---@field travelMode boolean|nil when true, only follow active; other bot logic disabled unless /cz attack override
---@field followmeMode string|nil 'group' or 'raid' when this toon is leading a followme broadcast
---@field wasDeadOrHover boolean|nil true while character was dead/hovering on prior tick (rez transition detection)

local M = {}

-- runState is always a number. No string state support; no string comparisons; no regex.
-- Fixed states 1..11; resume states 1000+ (state >= 1000 means resume).
-- See RESUME_BY_HOOK for setting resume from spellutils (hook name -> state number).

M.STATES = {
    idle = 1,
    dead = 2,
    pulling = 3,
    raid_mechanic = 4,
    casting = 5,
    melee = 6,
    camp_return = 7,
    engage_return_follow = 8,
    unstuck = 9,
    dragging = 10,
    chchain = 11,
    sumcorpse_pending = 12,
    resume_doHeal = 1001,
    resume_doDebuff = 1002,
    resume_doBuff = 1003,
    resume_doCure = 1004,
    resume_priorityCure = 1005,
}

M.RESUME_BY_HOOK = {
    doHeal = 1001,
    doDebuff = 1002,
    doBuff = 1003,
    doCure = 1004,
    priorityCure = 1005,
}

local BUSY_STATE_NUMS = {
    [M.STATES.pulling] = true,
    [M.STATES.raid_mechanic] = true,
    [M.STATES.casting] = true,
    [M.STATES.dragging] = true,
    [M.STATES.camp_return] = true,
    [M.STATES.engage_return_follow] = true,
    [M.STATES.unstuck] = true,
    [M.STATES.chchain] = true,
}

local ALLOWED_STATE_NUMS = {}
for _, v in pairs(M.STATES) do
    ALLOWED_STATE_NUMS[v] = true
end

local STATE_NUM_TO_NAME = {
    [1] = 'idle',
    [2] = 'dead',
    [3] = 'pulling',
    [4] = 'raid_mechanic',
    [5] = 'casting',
    [6] = 'melee',
    [7] = 'camp_return',
    [8] = 'engage_return_follow',
    [9] = 'unstuck',
    [10] = 'dragging',
    [11] = 'chchain',
    [12] = 'sumcorpse_pending',
    [1001] = 'doHeal_resume',
    [1002] = 'doDebuff_resume',
    [1003] = 'doBuff_resume',
    [1004] = 'doCure_resume',
    [1005] = 'priorityCure_resume',
}

M._runconfig = nil

---True if state number is a resume state (>= 1000).
---@param num number
---@return boolean
function M.isResumeState(num)
    return type(num) == 'number' and num >= 1000
end

---Whether it is safe to set runState to the given busy state. Central authority for interruption rules.
---Uses only numeric comparison. idle/melee/resume (>= 1000) allow starting any activity; dead blocks.
---@param stateNum number One of M.STATES (e.g. pulling, casting, camp_return).
---@return boolean
function M.canStartBusyState(stateNum)
    local mq = require('mq')
    local current = M.getRunState()
    if type(stateNum) ~= 'number' then return false end

    if current == M.STATES.idle then return true end
    if current == M.STATES.melee then return true end
    if current >= 1000 then return true end
    if current == M.STATES.dead then return false end

    if current == stateNum then return true end

    if stateNum == M.STATES.pulling then
        if current == M.STATES.casting then return false end
        if mq.TLO.Me.Casting() and (mq.TLO.Me.CastTimeLeft() or 0) > 0 then return false end
        return true
    end

    if stateNum == M.STATES.casting then
        if current == M.STATES.casting then return true end
        if BUSY_STATE_NUMS[current] then return false end
        return true
    end

    if stateNum == M.STATES.camp_return or stateNum == M.STATES.engage_return_follow then
        return true
    end

    if stateNum == M.STATES.unstuck or stateNum == M.STATES.dragging or stateNum == M.STATES.chchain or stateNum == M.STATES.raid_mechanic then
        return false
    end

    -- Do not replace casting with melee; doMelee was clobbering runState while CurSpell still active (spell pipeline desync).
    if stateNum == M.STATES.melee and current == M.STATES.casting then
        return false
    end

    if stateNum == M.STATES.melee then return true end

    return false
end

---Create or reset the runconfig table to default values.
function M.resetRunconfig()
    M._runconfig = {
        ScriptList = {},
        SubOrder = {},
        zonename = '',
        engageTargetId = nil,
        lastAssistTargetId = nil,
        lastResolvedAssistName = nil,
        allMezzedEngageId = nil,
        attackCommandEngage = nil,
        AlertList = 20,
        followid = 0,
        followname = '',
        TankName = '',
        AssistName = '',
        ExcludeList = {},
        PriorityList = {},
        CharmList = {},
        MaList = {},
        MtList = {},
        MobList = {},
        engagetracker = {},
        campstatus = false,
        makecamp = { x = nil, y = nil, z = nil },
        doCampAcleash = true,
        charmid = nil,
        charmSkipIds = {},
        domelee = nil,
        dopull = false,
        dosongs = true,
        pulledmob = nil,
        pullreturntimer = nil,
        pulledmobLastDistSq = nil,
        pulledmobLastCloserTime = nil,
        pullNavStartHP = nil,
        pullarc = nil,
        FTEList = {},
        FTECount = 0,
        fteRecheckProbeId = nil,
        fteRecheckInProgress = nil,
        CurSpell = {},
        HoverTimer = 0,
        DragHack = false,
        HoverEchoTimer = 0,
        SpellTimer = 0,
        interruptCounter = {},
        PreCH = {},
        gmtimer = 0,
        MyPetID = nil,
        IgnoreMobBuff = false,
        YellTimer = 0,
        MissedNote = false,
        terminate = false,
        runState = M.STATES.idle,
        runStateDeadline = nil,
        runStatePhase = nil,
        runStatePayload = nil,
        pullState = nil,
        roamNavTargetId = nil,
        roamBuffCheckPending = nil,
        pullAPTargetID = nil,
        pullTagTimer = nil,
        pullReturnTimer = nil,
        pullPhase = nil,
        pullDeadline = nil,
        pullAggroingStartTime = nil,
        pullAtCampSince = nil,
        pullAbortReturnDeadline = nil,
        pullXTargetIdsAtStart = nil,
        pullRangedStoredItem = nil,
        stucktimer = 0,
        unstuckWiggleIndex = nil,
        mobprobtimer = 0,
        sitTimer = nil,
        spellNotInBook = {},
        statusMessage = '',
        pullHealerManaWait = nil,
        pullDebuffWait = nil,
        maCastInterruptPending = nil,
        OutOfSpace = false,
        doChchain = false,
        chchainCurtank = 1,
        chchainPause = 0,
        chchainTank = '',
        chchainTanklist = {},
        chnextClr = nil,
        chchainList = nil,
        meleeAbort = false,
        debuffAbort = false,
        lastNukeIndex = nil,
        nukeResistDisabledRecent = nil,
        nukeFlavorsAllowed = nil,
        nukeFlavorsAutoDisabled = nil,
        raidCtx = nil, -- optional: { raidsactive = boolean }; zone raid modules may set global raidsactive instead
        travelMode = false,
        followmeMode = nil,
        wasDeadOrHover = false,
    }
    return M._runconfig
end

---True when character is dead on the ground or hovering over corpse.
---@return boolean
function M.isDeadOrHover()
    local mq = require('mq')
    return mq.TLO.Me.Dead() or mq.TLO.Me.Hovering()
end

---True when in travel mode (follow only; other bot logic disabled unless attack-overriding).
---@return boolean
function M.isTravelMode()
    local rc = M.getRunconfig()
    return rc.travelMode == true
end

---True when in travel mode and we have an active attack target (engageTargetId set); melee/heal/cure/debuff allowed, doBuff not.
---@return boolean
function M.isTravelAttackOverriding()
    local rc = M.getRunconfig()
    return rc.travelMode == true and rc.engageTargetId ~= nil
end

---Set current run state and optional payload. Accepts number only; no string state support.
---Only applies when stateNum is in ALLOWED_STATE_NUMS and (for busy/melee) canStartBusyState(stateNum) allows the transition.
---@param stateNum number One of M.STATES (e.g. idle, pulling, casting, or resume_doHeal etc.).
---@param payload table|nil Optional: { deadline = number?, phase = string?, priority = number?, ... }
function M.setRunState(stateNum, payload)
    if type(stateNum) ~= 'number' or not ALLOWED_STATE_NUMS[stateNum] then return end
    if BUSY_STATE_NUMS[stateNum] or stateNum == M.STATES.melee then
        if not M.canStartBusyState(stateNum) then return end
    end
    local rc = M.getRunconfig()
    rc.runState = stateNum
    rc.runStatePayload = payload
    if payload then
        rc.runStateDeadline = payload.deadline
        rc.runStatePhase = payload.phase
    else
        rc.runStateDeadline = nil
        rc.runStatePhase = nil
    end
end

---Clear run state back to idle.
function M.clearRunState()
    M.setRunState(M.STATES.idle, nil)
end

---@return number Current runState (one of M.STATES).
function M.getRunState()
    local rc = M.getRunconfig()
    local s = rc.runState
    if type(s) == 'number' and ALLOWED_STATE_NUMS[s] then return s end
    return M.STATES.idle
end

---Return display name for current run state (from numeric map only; no string comparison of state).
---@return string
function M.getRunStateName()
    local s = M.getRunState()
    return STATE_NUM_TO_NAME[s] or 'idle'
end

---True when runState is a "busy" state. Main loop uses isBusy() and payload.priority to run only hooks with hook.priority <= payload.priority.
---@return boolean
function M.isBusy()
    local s = M.getRunState()
    return s ~= M.STATES.idle and BUSY_STATE_NUMS[s] == true
end

---Get optional payload for current state (deadline, phase, or custom fields).
---@return table|nil
function M.getRunStatePayload()
    return M.getRunconfig().runStatePayload
end

---Check if runState has a deadline and it has passed.
---@return boolean
function M.runStateDeadlinePassed()
    local rc = M.getRunconfig()
    if not rc.runStateDeadline then return true end
    local mq = require('mq')
    return mq.gettime() >= rc.runStateDeadline
end

---@return RunConfig
function M.getRunconfig()
    if M._runconfig == nil then
        M.resetRunconfig()
    end
    return M._runconfig
end

---Return number of mobs in camp (length of MobList). Single source of truth; use instead of a separate MobCount.
---@param rc RunConfig|nil Optional; defaults to getRunconfig().
---@return number
function M.getMobCount(rc)
    rc = rc or M.getRunconfig()
    return #(rc.MobList or {})
end

---True when the buff loop should treat context as combat (not idle).
---@param rc RunConfig|nil Optional; defaults to getRunconfig().
---@return boolean
function M.isCombatContextForBuff(rc)
    rc = rc or M.getRunconfig()
    if M.getMobCount(rc) > 0 then return true end
    local mq = require('mq')
    local id = rc.engageTargetId
    if id and id > 0 then
        local spawnutils = require('lib.spawnutils')
        if spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(id)) then return true end
    end
    if M.getRunState() == M.STATES.melee then return true end
    if mq.TLO.Me.Combat() then return true end
    return false
end

local DEFAULT_BURN_SEC = 30

---Start a burn window of `seconds` (default 30). <= 0 stops it. Returns the seconds applied.
---Spells/abilities whose precondition references `burn` fire while the window is active.
---@param seconds number|nil
---@return number secondsApplied
function M.SetBurn(seconds)
    local rc = M.getRunconfig()
    local sec = tonumber(seconds) or DEFAULT_BURN_SEC
    if sec <= 0 then
        rc.burnUntil = nil
        return 0
    end
    local mq = require('mq')
    rc.burnUntil = mq.gettime() + sec * 1000
    return sec
end

---Stop any active burn window.
function M.ClearBurn()
    M.getRunconfig().burnUntil = nil
end

---True while a burn window is active. Exposed to spell preconditions as the global `burn`.
---@return boolean
function M.IsBurnActive()
    local rc = M.getRunconfig()
    if not rc.burnUntil then return false end
    local mq = require('mq')
    return mq.gettime() < rc.burnUntil
end

---Milliseconds left in the burn window (0 if none).
---@return number
function M.BurnRemainingMs()
    local rc = M.getRunconfig()
    if not rc.burnUntil then return 0 end
    local mq = require('mq')
    local rem = rc.burnUntil - mq.gettime()
    return rem > 0 and rem or 0
end

---Toggle or set global MasterPause (pause CZBot). Used by status tab Pause button and /czp.
---@param ... string|nil 'on' = pause, 'off' = resume, none = toggle
function M.czpause(...)
    local args = { ... }
    if args[1] and args[1] == 'off' then
        _G.MasterPause = false
        print('Unpausing CZBot')
    elseif args[1] and args[1] == 'on' then
        _G.MasterPause = true
        print('Pausing CZBot')
    else
        -- Treat nil as not paused (e.g. before first use)
        if _G.MasterPause ~= true then
            _G.MasterPause = true
            print('Pausing CZBot')
        else
            _G.MasterPause = false
            print('Unpausing CZBot')
        end
    end
end

return M
