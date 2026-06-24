local mq = require('mq')
local botconfig = require('lib.config')
local botgui = require('gui.components.botgui')
local commands = require('lib.commands')
local mobfilter = require('lib.mobfilter')
local state = require('lib.state')
local botmove = require('botmove')
local hookregistry = require('lib.hookregistry')
local spellutils = require('lib.spellutils')
local botevents = require('botevents')
local utils = require('lib.utils')
local tankrole = require('lib.tankrole')
local aggro = require('lib.aggro')
local charinfo = require('plugin.charinfo')
local botpull = require('botpull')
local follow = require('lib.follow')
local spawnutils = require('lib.spawnutils')
local charm = require('lib.charm')
local premem = require('lib.premem')
local spellupgrade = require('lib.spellupgrade')
local scribe = require('lib.scribe')

local ok, VERSION = pcall(require, 'version')
if not ok then VERSION = "dev" end

local bothooks = require('lib.bothooks')
local botlogic = {}
local myconfig = botconfig.config

local SIT_HYSTERESIS_PCT = 3
local FORAGE_CURSOR_STALE_MS = 5000
-- Throttle pet retarget commands to avoid spamming during rapid target changes.
local _petAttackRetargetLastTime = 0

-- CharState: per-tick character state. Split into sub-handlers for clarity and testability.

local function charState_StartupIfRequested(args)
    if args[1] ~= 'startup' then return end
    if mq.TLO.Me.Hovering() then
        printf('\ayCZBot:\axCan\'t start CZBot cause I\'m hovering over my corpse!')
        state.getRunconfig().terminate = true
        return
    end
    if mq.TLO.Me.Moving() then
        mq.cmd('/multiline ; /nav stop log=off; /stick off)')
    end
    if mq.TLO.Me.Combat() then mq.cmd('/attack off') end
end

local function charState_Always()
    if mq.TLO.Window('LootWnd').Open() then mq.cmd('/clean') end
    if mq.TLO.Me.Ducking() then mq.cmd('/keypress duck') end
    -- Camp return: clear when not moving or deadline passed
    if state.getRunState() == state.STATES.camp_return then
        local p = state.getRunStatePayload()
        if not mq.TLO.Me.Moving() or (p and p.deadline and mq.gettime() >= p.deadline) then
            state.clearRunState()
        end
    end
    -- Clear stuck casting: effectively idle or deadline passed with no active cast. Do not clear while memorizing.
    -- When viaMQ2Cast and no cast bar yet (castTimeLeft==0), do not clear as effectivelyIdle so MQ2Cast has time to sit/memorize.
    -- Skip when BRD is in notanktar (mez) wait so we don't clear state before the song finishes.
    if state.getRunState() == state.STATES.casting then
        local rc = state.getRunconfig()
        if not rc.bardNotmatarWait and not spellutils.IsMemorizing() then
            local castTimeLeft = mq.TLO.Me.CastTimeLeft() or 0
            local effectivelyIdle = state.getMobCount() == 0 and not mq.TLO.Me.Casting() and castTimeLeft == 0
            local deadlineStuck = state.runStateDeadlinePassed() and castTimeLeft == 0
            if deadlineStuck or (effectivelyIdle and not (rc.CurSpell and (rc.CurSpell.viaMQ2Cast or rc.CurSpell.viaCastingLib) and castTimeLeft == 0)) then
                spellutils.clearCastingStateOrResume()
            end
        end
    end
    spellutils.clearOrphanedSpellStateIfNeeded()

    local rc = state.getRunconfig()
    local mustStand = false
    local wantToSit = false
    local beyondFollow = botmove.isBeyondFollowDistance()
    -- Stand if follow on and target beyond follow distance; abort casts/mem to keep moving
    if beyondFollow then
        mustStand = true
        if state.getRunState() == state.STATES.casting then
            if spellutils.IsMemorizing() or mq.TLO.Me.Casting() or (mq.TLO.Me.CastTimeLeft() or 0) > 0 then
                spellutils.interruptActiveCast(rc)
            end
            spellutils.clearCastingStateOrResume()
        end
    end
    -- Stand if camp is active and we are outside camp range
    if rc.campstatus and not botmove.AtCamp() then
        mustStand = true
    end
    -- Stand if < 40% HP and mobs in camp
    if mq.TLO.Me.PctHPs() < 40 and state.getMobCount() > 0 then mustStand = true end
    local aboveSitHysteresis = true -- when dosit off, allow stand
    -- Sit when enabled and not casting, not moving, not combat, and mana/endurance below thresholds (strict <); stand only when above threshold + hysteresis. No sit in travel mode.
    if botconfig.config.settings.dosit and not state.isTravelMode() and state.getRunState() ~= state.STATES.casting and not mq.TLO.Me.Moving() and mq.TLO.Me.CastTimeLeft() == 0 and not mq.TLO.Me.Combat() and not mq.TLO.Me.AutoFire() then
        if state.getMobCount() == 0 then rc.sitTimer = nil end
        local sitBlockedByHit = rc.sitTimer and mq.gettime() < rc.sitTimer and state.getMobCount() > 0
        local sitmana = tonumber(botconfig.config.settings.sitmana)
        local sitendur = tonumber(botconfig.config.settings.sitendur)
        if not mustStand and not sitBlockedByHit then
            if (mq.TLO.Me.PctMana() < sitmana and mq.TLO.Me.MaxMana() > 0) or mq.TLO.Me.PctEndurance() < sitendur then
                wantToSit = true
                local sitaggro = tonumber(botconfig.config.settings.sitaggro) or 60
                if state.getMobCount() > 0 and aggro.pctAggroAvailable() then
                    local pct = aggro.getPctAggro()
                    if pct ~= nil and pct >= sitaggro then
                        wantToSit = false
                    end
                end
            end
        end
        aboveSitHysteresis = (mq.TLO.Me.MaxMana() == 0 or mq.TLO.Me.PctMana() > sitmana + SIT_HYSTERESIS_PCT) and
        (mq.TLO.Me.PctEndurance() > sitendur + SIT_HYSTERESIS_PCT)
    end
    -- if sitting and must stand or (above hysteresis and not casting), stand. Do not stand for mana while casting/memorizing.
    if mq.TLO.Me.Sitting() and (mustStand or (aboveSitHysteresis and state.getRunState() ~= state.STATES.casting)) then
        mq.cmd('/stand')
    end
    -- if not sitting and want to sit, sit
    if not mq.TLO.Me.Sitting() and wantToSit then
        mq.cmd('/squelch /sit on')
    end

    -- Auto-forage when idle: doForage on, ability ready, free inv, no cursor, zone allows forage. Throttle 1.5s.
    local forageThrottleMs = 1500
    if not _G._czForageLastTime then _G._czForageLastTime = 0 end
    if state.getRunState() == state.STATES.idle
        and botconfig.config.settings.doforage
        and not beyondFollow
        and mq.TLO.Me.AbilityReady and mq.TLO.Me.AbilityReady('Forage') and mq.TLO.Me.AbilityReady('Forage')()
        and not mq.TLO.Cursor.ID()
        and mq.TLO.Me.FreeInventory() and mq.TLO.Me.FreeInventory() > 0
        and not botconfig.isForageDisabledInZone(mq.TLO.Zone.ShortName())
        and mq.gettime() >= _G._czForageLastTime + forageThrottleMs then
        _G._czForageLastTime = mq.gettime()
        mq.cmd('/doability Forage')
        rc.forageExpectCursor = true
        rc.forageCursorUntil = mq.gettime() + FORAGE_CURSOR_STALE_MS
        rc.forageSawCursor = false
    end

    -- Cursor / inventory: junk destroy (any); OutOfSpace (any); /autoinv only after bot Forage (forageExpectCursor)
    if mq.TLO.Cursor.ID() then
        local zone = mq.TLO.Zone.ShortName()
        local cursorName = mq.TLO.Cursor.Name()
        if zone and cursorName and botconfig.isZoneJunk(zone, cursorName) then
            mq.cmd('/destroy')
        elseif mq.TLO.Me.FreeInventory() == 0 then
            if not rc.OutOfSpace then
                printf('\ayCZBot:\axI\'m out of inventory space!')
            end
            rc.OutOfSpace = true
        elseif not rc.OutOfSpace and rc.forageExpectCursor and mq.TLO.Me.FreeInventory() > 0 then
            mq.cmd('/autoinv')
            rc.OutOfSpace = false
        end
        if rc.forageExpectCursor then
            rc.forageSawCursor = true
        end
    elseif not mq.TLO.Cursor.ID() and mq.TLO.Me.FreeInventory() and mq.TLO.Me.FreeInventory() > 0 then
        rc.OutOfSpace = false
    end
    if not mq.TLO.Cursor.ID() and rc.forageExpectCursor and
        (rc.forageSawCursor or mq.gettime() >= (rc.forageCursorUntil or 0)) then
        rc.forageExpectCursor = false
        rc.forageSawCursor = nil
        rc.forageCursorUntil = nil
    end
    if botconfig.config.settings.domount and not state.isTravelMode() and botconfig.config.settings.mountcast
        and not beyondFollow then
        spellutils.MountCheck() end
end

--- Returns true if dead/hover; caller should return. Handles enter/leave transitions and hover timer.
local function charState_DeadOrHover()
    local rc = state.getRunconfig()
    local deadOrHover = state.isDeadOrHover()

    if not deadOrHover then
        if rc.wasDeadOrHover then
            botevents.ResetCombatSession('rez')
            rc.HoverTimer = 0
            rc.HoverEchoTimer = 0
            rc.wasDeadOrHover = false
            mq.cmd('/squelch /multiline ; /attack off ; /mqtarget clear ; /stick off')
        end
        return false
    end

    if not rc.wasDeadOrHover then
        botevents.ResetCombatSession('death')
        botpull.DisablePull('death')
        follow.StopFollow('death')
        botmove.ClearCamp('death')
        rc.wasDeadOrHover = true
    end

    -- While hovering at our corpse, accept an incoming rez (text-gated, configurable) so a box crew
    -- gets back up without manual clicking on each character.
    botevents.AcceptRezIfOffered()

    state.setRunState(state.STATES.dead, nil)
    if not rc.HoverEchoTimer or rc.HoverEchoTimer == 0 then
        rc.HoverEchoTimer = mq.gettime() + 300000
    end
    if rc.HoverTimer < mq.gettime() then
        botevents.Event_Slain()
    end
    return true
end

local function charState_PostDead()
    if state.getRunState() == state.STATES.dead then
        state.clearRunState()
    end
    local tarname = mq.TLO.Target.Name()
    if tarname and string.find(tarname, 'corpse') then
        mq.cmd('/squelch /multiline ; /attack off ; /mqtarget clear ; /stick off')
    end
    if mq.TLO.Me.State() == 'FEIGN' then mq.cmd('/stand') end
    local rc = state.getRunconfig()
    if not rc.engageTargetId or mq.TLO.Target.ID() ~= rc.engageTargetId then
        -- When engaged on a mob, we should never force the pet passive; doing so causes DPS loss.
        if mq.TLO.Me.Combat() then mq.cmd('/attack off') end

        if not rc.engageTargetId then
            -- Disengaged: keep the existing behavior to ensure pet isn't fighting stale targets.
            if mq.TLO.Me.Pet.Aggressive() then
                local desiredPetTargetId = nil
                local _, _, maTargetId = spellutils.GetAssistInfo(true)
                if maTargetId and maTargetId ~= 0 then desiredPetTargetId = maTargetId end
                if not desiredPetTargetId then
                    -- If MA has no target, do not fall back to MT target.
                    -- Only allow MT->pet fallback when MT sticky mode is enabled.
                    if tankrole.AmIMainTank() and myconfig.melee and myconfig.melee.mtSticky == true
                        and not myconfig.melee.offtank and not tankrole.AmIMainAssist() then
                        local _, _, tanktar = spellutils.GetTankInfo(true)
                        if tanktar and tanktar ~= 0 then desiredPetTargetId = tanktar end
                    end
                end

                local petTargetId = mq.TLO.Me.Pet.Target.ID() or 0
                local mismatch = desiredPetTargetId and petTargetId ~= desiredPetTargetId or false
                local now = mq.gettime()
                if mismatch and desiredPetTargetId then
                    -- Only retarget occasionally; otherwise we'd keep stopping/re-engaging until MQ2/AI swaps targets.
                    local throttleMs = 2000
                    if now >= _petAttackRetargetLastTime + throttleMs then
                        _petAttackRetargetLastTime = now
                        mq.cmd('/squelch /pet back off')
                        mq.cmd('/squelch /pet follow')
                        mq.cmdf('/squelch /pet attack %s', desiredPetTargetId)
                    end
                end
            end
        else
            -- Engaged: if pet is already aggressive but targeting something else, retarget (throttled).
            if mq.TLO.Me.Pet.Aggressive() and mq.TLO.Me.Pet.Target.ID() ~= rc.engageTargetId then
                local now = mq.gettime()
                local throttleMs = 2000
                if now >= _petAttackRetargetLastTime + throttleMs then
                    _petAttackRetargetLastTime = now
                    mq.cmdf('/squelch /pet attack %s', rc.engageTargetId)
                end
            end
        end
    end
    if not rc.attackCommandEngage and not spawnutils.shouldPreserveStickyEngage(rc) then
        rc.engageTargetId = nil
    end
    if mq.TLO.Plugin('MQ2GMCheck').IsLoaded() and (---@diagnostic disable-next-line: undefined-field
        mq.TLO.GMCheck() == 'TRUE') then
        botevents.Event_GMDetected()
    end
    if mq.TLO.Me.Pet.ID() then
        if not rc.MyPetID or rc.MyPetID ~= mq.TLO.Me.Pet.ID() then
            rc.MyPetID = mq.TLO.Me.Pet.ID()
            mq.cmd('/pet leader')
        end
        -- Charmed pet (not summoned): auto-configure once on acquisition (taunt off + assist).
        if not mq.TLO.Me.Pet.IsSummoned() then
            charm.AutoSetupNewCharmPet(rc)
        end
    end
end

local function CharState(...)
    local args = { ... }
    charState_StartupIfRequested(args)
    if charState_DeadOrHover() then return end
    charState_Always()
    charState_PostDead()
end

-- State for doMiscTimer (runs every 1s): throttle and inactive-click timer.
local _miscLastRun = 0
local _miscInactivetimer = 0
-- State for doMovementCheck (runs when busy, every 1s): camp return and follow.
local _movementLastRun = 0

-- doMiscTimer sub-routines (run every 1s from _runDoMiscTimer).
local function _miscInactiveClick()
    if state.getRunconfig().engageTargetId then return end
    if _miscInactivetimer >= mq.gettime() then return end
    _miscInactivetimer = mq.gettime() + math.random(60000, 90000)
    mq.cmd('/click right center')
end

local function _miscDrag()
    if not myconfig.settings.dodrag then return end
    botmove.DragCheck()
end

-- Movement only: camp return and follow. Runs in runWhenBusy pass so pure casters get camp/follow even when stuck in casting. Throttled 1s.
local function _runDoMovementCheck()
    if _movementLastRun > mq.gettime() then return end
    botmove.FollowAndStuckCheck()
    botmove.MakeCampLeashCheck()
    _movementLastRun = mq.gettime() + 1000
end

-- Misc only: inactive click (anti-afk, random 60–90s interval) and drag. Runs only when priority allows (not when casting). Throttled 1s.
local function _runDoMiscTimer()
    if _miscLastRun > mq.gettime() then return end
    _miscInactiveClick() -- anti-afk, randomized interval
    _miscDrag()
    premem.tick() -- pre-load configured gems during downtime so combat spells don't memorize on the fly
    spellupgrade.tick() -- detect when a better in-book version of a configured spell is available
    scribe.tick() -- auto-scribe new spell scrolls after a level-up (when out of combat)
    _miscLastRun = mq.gettime() + 1000
end

-- Register built-in hook implementations. registerAllFromConfig() (called from StartUp) wires them from bothooks.
local function _registerBuiltinHooks()
    hookregistry.registerHookFn('zoneCheck', function(hookName)
        if state.getRunconfig().zonename ~= mq.TLO.Zone.ShortName() then
            botevents.OnZoneChange()
        end
    end)

    -- Drains MQ event queue so chat/events are processed every tick.
    hookregistry.registerHookFn('doEvents', function(hookName)
        mq.doevents()
    end)

    hookregistry.registerHookFn('charState', function(hookName)
        CharState()
    end)

    hookregistry.registerHookFn('doMovementCheck', function(hookName)
        _runDoMovementCheck()
    end)

    hookregistry.registerHookFn('doMiscTimer', function(hookName)
        _runDoMiscTimer()
    end)
end

function botlogic.StartUp(...)
    print('CZBot is starting! (' .. VERSION .. ')')
    math.randomseed(os.time() * 1000 + os.clock() * 1000)
    if mq.TLO.Me.Hovering() or string.find(mq.TLO.Me.Name() or '', 'corpse') then
        printf('\ayCZBot:\axCan\'t start CZBot cause I\'m hovering over my corpse!')
        state.getRunconfig().terminate = true
        return
    end
    -- Optional plugins (load if not loaded; no terminate)
    if (mq.TLO.Plugin('MQRemote').IsLoaded() == nil) then
        mq.cmd('/squelch /plugin MQRemote load')
    end
    if (mq.TLO.Plugin('MQ2Exchange').IsLoaded() == nil) then
        mq.cmd('/squelch /plugin MQ2Exchange load')
    end
    -- MQ2Cast, MQ2MoveUtils, MQ2Twist, MQCharinfo are required and verified in init.lua before this runs.
    --load config file
    state.resetRunconfig()
    ---@type RunConfig
    local runconfig = state.getRunconfig()
    local args = { ... }
    botconfig.LoadConfig()
    runconfig.zonename = mq.TLO.Zone.ShortName() or ''
    if args[1] then
        runconfig.TankName = (args[1] == 'automatic') and 'automatic' or (args[1]:sub(1, 1):upper() .. args[1]:sub(2))
    else
        runconfig.TankName = botconfig.config.settings.TankName
    end
    runconfig.AssistName = botconfig.config.settings.AssistName or runconfig.TankName
    -- Seed session leash-to-radius from the persisted setting (default on).
    runconfig.doCampAcleash = botconfig.config.settings.campAcleash ~= false
    if args[2] == 'makecamp' then commands.MakeCamp('on') end
    if args[2] == 'follow' and args[1] then commands.Follow(args[1]) end
    if args[2] == 'travel' and args[1] then commands.Travel(args[1]) end
    mobfilter.process('exclude', 'zone')
    mobfilter.process('priority', 'zone')
    mobfilter.process('charm', 'zone')
    require('lib.rolelists').loadFromCommon()
    local comkeytable = botconfig.getCommon()
    if not comkeytable.raidlist then comkeytable.raidlist = {} end
    --make sure char isnt doing anything already (stop nav, clear cursor, ect)
    CharState('startup')
    mq.imgui.init('debuggui', botgui.getUpdateFn())
    _registerBuiltinHooks()
    hookregistry.registerAllFromConfig()
    --check startup scripts NTA
    --check each section
    --build variables for enabled sections
    --load tbcommon stuff
end

function botlogic.mainloop()
    while not state.getRunconfig().terminate do
        hookregistry.runRunWhenPausedHooks()
        if not MasterPause then
            hookregistry.runNormalHooks()
        end
        mq.delay(100)
    end
end

-- Register all MQ events (zone reset lives in botevents.OnZoneChange).
botevents.BindEvents()

return botlogic
