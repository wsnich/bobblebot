local mq = require('mq')
local botconfig = require('lib.config')
local charm = require('lib.charm')
local immune = require('lib.immune')
local state = require('lib.state')
local spellstates = require('lib.spellstates')
local mobfilter = require('lib.mobfilter')
local chchain = require('lib.chchain')
local follow = require('lib.follow')
local casting = require('lib.casting')
local botpull = require('botpull')

local botevents = {}

local SIT_AFTER_HIT_MS = 3000

-- Internal: reset zone-specific variables. Used by OnZoneChange only.
local function DelayOnZone()
    state.clearRunState()
    state.getRunconfig().CurSpell = {}
    state.getRunconfig().statusMessage = ''
    local zonename = mq.TLO.Zone.ShortName()
    if zonename then state.getRunconfig().zonename = zonename end
    if state.getRunconfig().campstatus == true then
        state.getRunconfig().makecamp = { x = nil, y = nil, z = nil }
    end
    state.getRunconfig().campstatus = false
    if state.getRunconfig().engageTargetId then state.getRunconfig().engageTargetId = nil end
    if APTarget then APTarget = nil end
    botpull.DisablePull('zone')
    mobfilter.process('exclude', 'zone')
    mobfilter.process('priority', 'zone')
    mobfilter.process('charm', 'zone')
    botconfig.loadNukeFlavorsFromZone()
    spellstates.CleanMobList()
    MountCastFailed = false
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
    local curtarget = mq.TLO.Target.ID()
    local sub = state.getRunconfig().CurSpell.sub
    local spell = state.getRunconfig().CurSpell.spell
    local spellid = mq.TLO.Spell(botconfig.config[sub .. spell].spell).ID()
    if not spellid then return end
    if string.find(line, "(with this spell)") then return false end
    if casting.storedSpellId() == spellid then
        if mq.TLO.Spell(spellid).TargetType() ~= "Targeted AE" and mq.TLO.Spell(spellid).TargetType() ~= "PB AE" then
            if state.getRunconfig().CurSpell.target then
                if state.getRunconfig().CurSpell.target == curtarget then
                    local immuneID = state.getRunconfig().CurSpell.target
                    immune.processList(immuneID)
                end
            end
        end
    end
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
    local spawn = mq.TLO.Target
    if spawn.ID() and spawn.ID() > 0 then
        printf(
            '\ayCZBot:\ax\arUh Oh, \ag%s\ax is \arFTE locked\ax to someone else!', spawn.Name())
    end
    if state.getRunconfig().FTECount == 0 then state.getRunconfig().FTECount = state.getRunconfig().FTECount + 1 end
    if spawn.ID() and spawn.ID() > 0 and not state.getRunconfig().FTEList[spawn.ID()] then
        state.getRunconfig().FTEList[spawn.ID()] = { id = spawn.ID(), hitcount = 1, timer = mq.gettime() + 10000 }
    elseif state.getRunconfig().FTEList[spawn.ID()] and state.getRunconfig().FTEList[spawn.ID()].hitcount == 1 then
        state.getRunconfig().FTEList[spawn.ID()] = { id = spawn.ID(), hitcount = 2, timer = mq.gettime() + 30000 }
    elseif state.getRunconfig().FTEList[spawn.ID()] and state.getRunconfig().FTEList[spawn.ID()].hitcount >= 2 then
        state.getRunconfig().FTEList[spawn.ID()] = { id = spawn.ID(), hitcount = 3, timer = mq.gettime() + 90500 }
    end
    mq.cmd('/multiline ; /squelch /mqtarget myself ; /attack off ; /stopcast ; /nav stop log=off; /stick off')
    if state.getRunconfig().dopull then
        print('clearing pull target because FTELock detected') -- not debug, real error message
        APTarget = false
    end
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

function botevents.Event_MobProb(line, arg1, arg2)
    local rc = state.getRunconfig()
    if rc.mobprobtimer <= mq.gettime() then return true end
    if rc.dopull and state.getRunState() == state.STATES.pulling and (rc.pullState == 'returning' or rc.pullState == 'returning_after_abort') then
        rc.mobprobtimer = mq.gettime() + 3000
        return true
    end
    if rc.engageTargetId then
        if mq.TLO.Navigation.PathLength('id ' .. rc.engageTargetId)() <= botconfig.config.settings.acleash then
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
end

return botevents
