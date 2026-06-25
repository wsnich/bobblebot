-- CHChain (Complete Heal chain) logic. State in state.getRunconfig(): doChchain, chchainCurtank, chchainPause, chchainTank, chchainTanklist, chnextClr.
-- State diagram: OnGo (Go >>me<<) sets runState chchain with deadline; chchainTick either clears (pass Go) or re-sets state (fizzle/skip).

local mq = require('mq')
local state = require('lib.state')
local bothooks = require('lib.bothooks')
local targeting = require('lib.targeting')
local spellutils = require('lib.spellutils')
local command_dispatcher = require('lib.command_dispatcher')
local casting = require('lib.casting')

local chchain = {}

local function event_CHChain(line, arg1)
    return chchain.OnGo(line, arg1)
end

local function event_CHChainSetup(line, arg1, arg2, arg3, arg4)
    if arg1 == 'setup' then command_dispatcher.Dispatch('chchain', 'setup', arg2, arg3, arg4) end
end

local function event_CHChainStop(line)
    if string.find(line, 'stop') then command_dispatcher.Dispatch('chchain', 'stop') end
end

local function event_CHChainStart(line, arg1, argN)
    local cleanname = arg1 and arg1:match("%S+")
    if arg1 then command_dispatcher.Dispatch('chchain', 'start', cleanname) end
end

local function event_CHChainTank(line, arg1, argN)
    local cleanname = arg1 and arg1:match("%S+")
    if arg1 and state.getRunconfig().doChchain then command_dispatcher.Dispatch('chchain', 'tank', cleanname) end
end

local function event_CHChainPause(line, arg1, argN)
    if arg1 and state.getRunconfig().doChchain then command_dispatcher.Dispatch('chchain', 'pause', arg1) end
end

--- Deadline for current chchain round: chchainPause (tenths of sec) * 100 ms + now.
function chchain.getDeadline(rc)
    rc = rc or state.getRunconfig()
    return (rc.chchainPause or 0) * 100 + mq.gettime()
end

function chchain.registerEvents()
    mq.event('CHChain', "#*#Go #1#>>#*#", event_CHChain)
    mq.event('CHChainStop', "#*#chchain stop#*#", event_CHChainStop)
    mq.event('CHChainStart', "#*#chchain start #1#'", event_CHChainStart)
    mq.event('CHChainTank', "#*#chchain tank #1#'", event_CHChainTank)
    mq.event('CHChainPause', "#*#chchain pause #1#'", event_CHChainPause)
    mq.event('CHChainSetup', "#*#chchain #1# #2# #3# #4#", event_CHChainSetup)
end

function chchain.OnGo(line, arg1)
    local rc = state.getRunconfig()
    local myName = mq.TLO.Me.Name()
    if not myName or string.lower(arg1) ~= string.lower(myName) then return false end
    if not rc.doChchain then return false end
    rc.chchainCurtank = 1
    local chtimer = chchain.getDeadline(rc)
    local tankid = mq.TLO.Spawn('=' .. rc.chchainTank).ID()
    if not tankid or tankid == 0 or mq.TLO.Spawn(tankid).Type() == 'Corpse' then
        -- Primary tank dead/zoned: walk forward through the tank list to the next live PC tank,
        -- rather than checking only the next slot and giving up.
        local list = rc.chchainTanklist or {}
        local found = false
        while rc.chchainCurtank < #list do
            rc.chchainCurtank = rc.chchainCurtank + 1
            local cand = list[rc.chchainCurtank]
            if cand and mq.TLO.Spawn('=' .. cand).Type() == 'PC' and mq.TLO.Spawn('=' .. cand).ID() then
                mq.cmdf('/rs Tank DIED or ZONED, moving to tank %s, %s', rc.chchainCurtank, cand)
                rc.chchainTank = cand
                tankid = mq.TLO.Spawn('=' .. rc.chchainTank).ID()
                found = true
                break
            end
        end
        if not found then
            mq.cmdf('/rs No live tank left in chain, skipping')
            -- Defer /rs <<Go>> until chchainpause expires; chchainTick will do it.
            state.setRunState(state.STATES.chchain, { deadline = chchain.getDeadline(rc), chnextclr = rc.chnextClr, priority = bothooks.getPriority('chchainTick') })
            return
        end
    end
    if not tankid or tankid == 0 then return end
    if rc.chchainTank and mq.TLO.Target.ID() ~= tankid then
        targeting.TargetAndWait(tankid, 500)
    end
    if rc.chchainTank and mq.TLO.Target.ID() ~= tankid then
        -- Could not acquire the tank this tick: keep the chain alive by forwarding the Go on deadline
        -- (mirrors the out-of-mana branch) instead of silently halting the rotation.
        mq.cmdf('/rs SKIP ME (could not target tank %s)', rc.chchainTank)
        state.setRunState(state.STATES.chchain, { deadline = mq.gettime() + (rc.chchainPause or 0) * 100, chnextclr = rc.chnextClr, priority = bothooks.getPriority('chchainTick') })
        return
    end
    if (mq.TLO.Me.CurrentMana() - (mq.TLO.Me.ManaRegen() * 2)) < 400 then
        mq.cmdf('/rs SKIP ME (out of mana)')
        state.setRunState(state.STATES.chchain, { deadline = mq.gettime() + (rc.chchainPause or 0) * 100, chnextclr = rc.chnextClr, priority = bothooks.getPriority('chchainTick') })
        return
    end
    if not spellutils.DistanceCheckByName('Complete Heal', tankid) then
        -- Out of CH range: casting would be wasted, so skip and forward the Go to the next cleric.
        mq.cmdf('/rs Tank %s is out of range of Complete Heal, skipping', rc.chchainTank)
        state.setRunState(state.STATES.chchain, { deadline = mq.gettime() + (rc.chchainPause or 0) * 100, chnextclr = rc.chnextClr, priority = bothooks.getPriority('chchainTick') })
        return
    end
    spellutils.AutoinvIfCursorBlockingCast()
    mq.cmdf('/multiline ; /cast "Complete Heal" ; /rs CH >> %s << (pause:%s mana:%s)', rc.chchainTank, rc.chchainPause,
        mq.TLO.Me.PctMana())
    state.setRunState(state.STATES.chchain, { deadline = chtimer, chnextclr = rc.chnextClr, priority = bothooks.getPriority('chchainTick') })
end

--- One tick of chchain state: fizzle handling, target-died interrupt, deadline (pass Go), sit when not casting.
function chchain.Tick()
    local p = state.getRunStatePayload()
    if not p or not p.chnextclr then state.clearRunState() return end
    if casting.result() == 'CAST_FIZZLE' then
        spellutils.AutoinvIfCursorBlockingCast()
        -- Recast via a raw /cast (same path OnGo uses) instead of casting.start(): chchain never
        -- pumps casting.tick(), so a module op would never reach 'done' and would block the next
        -- recast. Clear the stored fizzle result so this branch fires once, not every tick.
        casting.clear()
        mq.cmd('/squelch /multiline ; /stand ; /cast "Complete Heal"')
        return
    end
    if mq.TLO.Me.CastTimeLeft() and mq.TLO.Me.CastTimeLeft() > 0 and mq.TLO.Target.Type() == 'Corpse' then
        mq.cmdf('/rs CHChain: Target died, interrupting cast')
        casting.interrupt()
        mq.cmdf('/rs <<Go %s>>', p.chnextclr)
        state.clearRunState()
        return
    end
    if mq.gettime() >= (p.deadline or 0) then
        mq.cmdf('/rs <<Go %s>>', p.chnextclr)
        state.clearRunState()
        return
    end
    if not mq.TLO.Me.Sitting() and (mq.TLO.Me.CastTimeLeft() or 0) == 0 then
        mq.cmd('/sit on')
    end
end

function chchain.getHookFn(name)
    if name == 'chchainTick' then
        return function(hookName)
            if state.getRunState() ~= state.STATES.chchain then return end
            chchain.Tick()
        end
    end
    return nil
end

return chchain
