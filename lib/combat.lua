-- Combat state reset: stick off, attack off, optional pet back, optional target clear.
-- Used by botmelee, botmove, and botpull to avoid duplicated logic.

local mq = require('mq')
local state = require('lib.state')

local combat = {}

-- Throttle debug output so we don't spam logs every tick.
local _petBackoffDebugLastLogTime = 0

--- Reset combat state (stick, attack, optionally pet and target).
--- @param opts table|nil Optional: clearTarget (boolean, default true), clearPet (boolean, default true)
function combat.ResetCombatState(opts)
    opts = opts or {}
    local clearTarget = opts.clearTarget ~= false
    local clearPet = opts.clearPet ~= false

    if mq.TLO.Stick.Active() then mq.cmd('/squelch /stick off') end
    if mq.TLO.Me.Combat() then mq.cmd('/squelch /attack off') end
    if clearPet and mq.TLO.Me.Pet.Aggressive() then
        local now = mq.gettime()
        if now >= _petBackoffDebugLastLogTime + 1000 then
            _petBackoffDebugLastLogTime = now
            local rc = state.getRunconfig()
            local engageId = rc and rc.engageTargetId or nil
            local targetId = mq.TLO.Target.ID() or 0
            local petTargetId = mq.TLO.Me.Pet.Target.ID() or 0
            printf(
                '\aybobblebot:\axDebug petResetCombatState backoff follower\ax runState=%s engageTargetId=%s targetId=%s petTargetId=%s petAgg=%s meCombat=%s opts={clearPet=%s,clearTarget=%s}',
                state.getRunStateName(),
                tostring(engageId),
                tostring(targetId),
                tostring(petTargetId),
                tostring(mq.TLO.Me.Pet.Aggressive()),
                tostring(mq.TLO.Me.Combat()),
                tostring(clearPet),
                tostring(clearTarget)
            )
        end
        mq.cmd('/squelch /pet back off')
        mq.cmd('/squelch /pet follow')
    end
    if clearTarget and mq.TLO.Target.Type() == 'NPC' then mq.cmd('/squelch /mqtarget clear') end
end

return combat
