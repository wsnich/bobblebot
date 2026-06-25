local mq = require('mq')
local botconfig = require('lib.config')
local charm = require('lib.charm')
local state = require('lib.state')
local spellstates = require('lib.spellstates')
local chchain = require('lib.chchain')
local follow = require('lib.follow')
local casting = require('lib.casting')
local spellutils = require('lib.spellutils')
local botpull = require('botpull')
local spawnutils = require('lib.spawnutils')
local combat = require('lib.combat')
local castinterrupt = require('lib.castinterrupt')

local botevents = {}

local SIT_AFTER_HIT_MS = 3000

--- Clear combat session state (engage, mob list, stick/attack). Used on death, rez, and zone change.
---@param reason string|nil e.g. death, rez, zone
function botevents.ResetCombatSession(reason)
    state.clearRunState()
    local rc = state.getRunconfig()
    rc.CurSpell = {}
    rc.statusMessage = ''
    rc.engageTargetId = nil
    rc.attackCommandEngage = nil
    rc.lastAssistTargetId = nil
    rc.charmSkipIds = {}
    rc.MobList = {}
    spellstates.CleanMobList()
    if APTarget then APTarget = nil end
    if rawget(_G, 'KillTarget') then _G.KillTarget = nil end
    combat.ResetCombatState({ clearTarget = true, clearPet = true })
end

-- Internal: reset zone-specific variables. Used by OnZoneChange only.
local function DelayOnZone()
    botevents.ResetCombatSession('zone')
    local rc = state.getRunconfig()
    local zonename = mq.TLO.Zone.ShortName()
    if zonename then rc.zonename = zonename end
    local wasCamp = rc.campstatus == true
    rc.campstatus = false
    if wasCamp then
        rc.makecamp = { x = nil, y = nil, z = nil }
    end
    botpull.DisablePull('zone')
    botconfig.refreshZoneStateFromCommon()
    MountCastFailed = false
    follow.ResumeAfterZone()
end

-- Single entry point for zone change: used by zoneCheck hook and MQ zone events.
function botevents.OnZoneChange()
    print('Zone detected') -- not debug, keep
    state.getRunconfig().statusMessage = 'Zone change, waiting...'
    mq.delay(1000)
    DelayOnZone()
    state.getRunconfig().statusMessage = ''
end

function botevents.Event_Slain()
    botevents.ResetCombatSession('death')
    local respawntimeleft = (state.getRunconfig().HoverEchoTimer - mq.gettime()) / 1000
    printf('\ayCZBot:\axI died and am hovering, %s seconds until I release', respawntimeleft)
    mq.cmd('/multiline ; /consent group ; /consent raid ; /consent guild')
    state.getRunconfig().HoverTimer = mq.gettime() + 30000
end

function botevents.Event_CastRst()
    if state.getRunconfig().CurSpell and (state.getRunconfig().CurSpell.viaMQ2Cast or state.getRunconfig().CurSpell.viaCastingLib) then
        casting.notifyResist()
        return
    end
    SpellResisted = true
end

function botevents.Event_CastImm(line)
    if state.getRunconfig().CurSpell and (state.getRunconfig().CurSpell.viaMQ2Cast or state.getRunconfig().CurSpell.viaCastingLib) then
        casting.notifyImmune()
        return
    end
    if string.find(line, "(with this spell)") then return false end
    spellutils.handleTargetImmuneEvent(line)
end

function botevents.Event_MissedNote()
    --print('MissedNote')
    state.getRunconfig().MissedNote = true
end

function botevents.Event_CastStn()
end

function botevents.Event_CharmBroke(line, charmspell)
    charm.OnCharmBroke(line, charmspell)
end

function botevents.Event_ResetMelee()
end

function botevents.Event_WornOff()
end

function botevents.Event_Camping()
end

function botevents.Event_GoM()
end

function botevents.Event_LockedDoor()
end

function botevents.Event_LinkItem(line, Slot, HPFilter)
    HPValue = HPFilter
    if string.find(line, 'TB-') then return false end
    if string.find(Slot, "'") then Slot = string.sub(Slot, 2) end
    if HPValue and string.find(HPValue, "'") then HPValue = string.sub(HPValue, 2) end
    if HPValue then
        if HPFilter < mq.TLO.InvSlot(Slot).Item.HP() then return false end
    end
    if not mq.TLO.Me.Inventory(Slot).ID() then
        printf('\ayCZBot:\ax\arMy \at%s slot \aris empty!', Slot)
        mq.cmdf('/rs My %s slot is empty!', Slot)
        return
    end
    local itemlink = mq.TLO.Me.Inventory(Slot).ItemLink('CLICKABLE')()
    local itemac = mq.TLO.InvSlot(Slot).Item.AC()
    local itemhp = mq.TLO.InvSlot(Slot).Item.HP()
    local itemmana = mq.TLO.InvSlot(Slot).Item.Mana()
    printf('\ayCZBot:\ax%s AC:%s HP:%s Mana:%s', itemlink, itemac, itemhp, itemmana)
    mq.cmdf('/rs \ayCZBot:\ax%s AC:%s HP:%s Mana:%s', itemlink, itemac, itemhp, itemmana)
end

function botevents.Event_TooSteep()
end

function botevents.Event_FTELocked()
    local rc = state.getRunconfig()
    local spawnId = spawnutils.resolveFTELockedSpawnId(rc)
    local displayName = mq.TLO.Target.CleanName() or mq.TLO.Target.Name()
    if spawnId then
        local sp = mq.TLO.Spawn(spawnId)
        displayName = sp.CleanName() or sp.Name() or tostring(spawnId)
    end
    if displayName and displayName ~= '' then
        printf('\ayCZBot:\ax\arUh Oh, \ag%s\ax is \arFTE locked\ax to someone else!', displayName)
    end
    if not spawnId then return end
    local isProbe = rc.fteRecheckProbeId and rc.fteRecheckProbeId == spawnId
    if isProbe then
        rc.fteRecheckProbeId = nil
    end
    if rc.FTECount == 0 then rc.FTECount = rc.FTECount + 1 end
    spawnutils.recordFTE(rc, spawnId, { combat = true, pull = rc.dopull == true and not isProbe })
    if isProbe then
        if rc.engageTargetId == spawnId then
            rc.engageTargetId = nil
            rc.attackCommandEngage = nil
        end
        return
    end
    if rc.engageTargetId == spawnId then
        rc.engageTargetId = nil
        rc.attackCommandEngage = nil
    end
    if rc.dopull then
        print('clearing pull target because FTELock detected') -- not debug, real error message
        local backupStarted = botpull.AbortPullForFTE('FTE lock detected', spawnId)
        if backupStarted then
            mq.cmd('/multiline ; /squelch /mqtarget clear ; /attack off ; /stopcast ; /stick off')
        else
            mq.cmd('/multiline ; /squelch /mqtarget clear ; /attack off ; /stopcast ; /nav stop log=off; /stick off')
        end
        return
    end
    mq.cmd('/multiline ; /squelch /mqtarget clear ; /attack off ; /stopcast ; /nav stop log=off; /stick off')
end

function botevents.Event_GMDetected()
    if state.getRunconfig().gmtimer < mq.gettime() then
        printf('\ayCZBot:\axGM Detected! Disabling DoMelee, MakeCamp, and Stick!')
        botconfig.config.settings.domelee = false
        mq.cmd('/stick off')
        state.getRunconfig().makecamp = { x = nil, y = nil, z = nil }
        CampStatus = nil
        state.getRunconfig().gmtimer = mq.gettime() + 60000
    end
end

function botevents.Event_MountFailed()
    if botconfig.config.settings.domount then MountCastFailed = true end
end

function botevents.Event_HitYou()
    state.getRunconfig().sitTimer = mq.gettime() + SIT_AFTER_HIT_MS
end

function botevents.Event_MobBeginsCast(_line, mobName)
    castinterrupt.tryInterruptMaCast(mobName)
end

function botevents.Event_MobProb(line, arg1, arg2)
    local rc = state.getRunconfig()
    if rc.mobprobtimer > mq.gettime() then return true end
    if rc.dopull and state.getRunState() == state.STATES.pulling and (rc.pullState == 'returning' or rc.pullState == 'returning_after_abort') then
        rc.mobprobtimer = mq.gettime() + 3000
        return true
    end
    if rc.engageTargetId then
        local pathLen = mq.TLO.Navigation.PathLength('id ' .. rc.engageTargetId)()
        local withinAcleash = pathLen and pathLen <= botconfig.config.settings.acleash
        if withinAcleash or not spawnutils.isCampAcleashEnforced(rc) then
            mq.cmdf('/nav id %s dist=0 log=off', rc.engageTargetId)
        end
    end
    rc.mobprobtimer = mq.gettime() + 3000
end

function botevents.BindEvents()
    chchain.registerEvents()
    follow.registerEvents()
    mq.event('Slain1', "#*#You have been slain by#*#", botevents.Event_Slain)
    mq.event('Slain2', "#*#Returning to Bind Location#*#", botevents.Event_Slain)
    mq.event('Slain3', "You died.", botevents.Event_Slain)
    mq.event('DelayOnZone1', "#*#You have entered#*#", botevents.OnZoneChange)
    mq.event('DelayOnZone2', "#*#LOADING, PLEASE WAIT.#*#", botevents.OnZoneChange)
    mq.event('CastRst1', "Your target resisted the#*#", botevents.Event_CastRst)
    mq.event('CastRst2', "#*#resisted your#*#!#*#", botevents.Event_CastRst)
    mq.event('CastRst3', "#*#avoided your#*#!#*#", botevents.Event_CastRst)
    mq.event('CastFizzle', "Your spell fizzles#*#", function() casting.notifyResult('CAST_FIZZLE') end)
    mq.event('CastInterrupted', "Your casting has been interrupted#*#", function() casting.notifyResult('CAST_INTERRUPTED') end)
    mq.event('CastTakeHold', "Your spell did not take hold#*#", function() casting.notifyTakeHold() end)
    mq.event('CastImm', "Your target cannot be#*#", botevents.Event_CastImm)
    mq.event('SlowImm', "Your target is immune to changes in its attack speed", botevents.Event_CastImm)
    -- "Your target is immune to snare spells." / "... root spells." etc. (mez/charm/slow have their own
    -- messages above). Records the mob as immune so the bot stops re-casting -- unless the spell is
    -- recastActive (SK threat-snare), which ImmuneCheck lets through to keep generating hate.
    mq.event('SpellImm', "Your target is immune to#*#spells#*#", botevents.Event_CastImm)
    mq.event('MissedNote', "You miss a note, bringing your#*#", botevents.Event_MissedNote)
    mq.event('CastStn1', "You are stunned#*#", botevents.Event_CastStn)
    mq.event('CastStn2', "You can't cast spells while stunned!#*#", botevents.Event_CastStn)
    mq.event('CastStn3', "You miss a note#*#", botevents.Event_CastStn)
    mq.event('CharmBroke', "Your #1# spell has worn off#*#", botevents.Event_CharmBroke)
    mq.event('ResetMelee', "You cannot see your target.", botevents.Event_ResetMelee)
    mq.event('WornOff', "#*#Your #1# spell has worn off of #2#.", botevents.Event_WornOff)
    mq.event('Camping', "#*#more seconds to prepare your camp#*#", botevents.Event_Camping)
    mq.event('GoM1', "#*#granted gift of #1# to #2#!", botevents.Event_GoM)
    mq.event('GoM2', "#*#granted a gracious gift of #1# to #2#!", botevents.Event_GoM)
    mq.event('LockedDoor', "It's locked and you're not holding the key.", botevents.Event_LockedDoor)
    mq.event('LinkItem', "#*#LinkItem #1# #2#", botevents.Event_LinkItem)
    mq.event('TooSteep', "The ground here is too steep to camp", botevents.Event_TooSteep)
    mq.event('FTELock', "#*#your target is Encounter Locked to someone else#*#", botevents.Event_FTELocked)
    mq.event('MountFailed', '#*#You cannot summon a mount here.#*#', botevents.Event_MountFailed)
    mq.event('MobProb1', "#*#Your target is too far away,#*#", botevents.Event_MobProb)
    mq.event('MobProb2', "#*#You cannot see your target#*#", botevents.Event_MobProb)
    mq.event('MobProb3', "#*#You can\'t hit them from here#*#", botevents.Event_MobProb)
    mq.event('HitYou1', "#*#YOU for #1# point of#*#", botevents.Event_HitYou)
    mq.event('HitYou2', "#*#YOU for #1# points of#*#", botevents.Event_HitYou)
    mq.event('MobCastCompleteHeal', "#*##1# begins casting Complete Heal#*#", botevents.Event_MobBeginsCast)
    mq.event('MobCastGate', "#*##1# begins casting Gate#*#", botevents.Event_MobBeginsCast)
end

return botevents
