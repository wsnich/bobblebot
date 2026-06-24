-- MA-target cast interrupt: mez/stun on Complete Heal or Gate from the MA target mob.
local mq = require('mq')
local botconfig = require('lib.config')
local state = require('lib.state')
local spellutils = require('lib.spellutils')
local spawnutils = require('lib.spawnutils')
local bothooks = require('lib.bothooks')
local tankrole = require('lib.tankrole')

local castinterrupt = {}

local INTERRUPT_REASON = 'Complete Heal/Gate'
local _diagNextTime = 0
local DIAG_THROTTLE_MS = 2000

local function trim(s)
    return s and (s:match('^%s*(.-)%s*$') or s) or ''
end

local function aliasMatches(entry, token)
    if not entry or not token or token == '' then return false end
    for value in tostring(entry.alias or ''):gmatch('[^|]+') do
        if trim(value) == token then return true end
    end
    return false
end

local function isMezInterruptSpell(entry)
    return entry and (spellutils.IsMezSpell(entry) or aliasMatches(entry, 'mez'))
end

local function normalizeMobNameForMatch(name)
    if not name or name == '' then return '' end
    local s = name:gsub('_', ' '):gsub('%s+', ' '):lower()
    s = trim(s)
    s = s:match('^an? (.+)$') or s:match('^the (.+)$') or s
    return trim(s)
end

--- True when event chat name refers to the spawn (case/article/underscore suffix tolerant).
local function mobNamesMatch(eventName, spawnName, spawnClean)
    local eventNorm = normalizeMobNameForMatch(eventName)
    if eventNorm == '' then return false end
    for _, candidate in ipairs({ spawnName, spawnClean }) do
        if candidate and candidate ~= '' then
            local norm = normalizeMobNameForMatch(candidate)
            if norm ~= '' then
                if eventNorm == norm then return true end
                -- Spawn Name() often appends digits (e.g. an_Icepaw_prophet03 vs "An Icepaw prophet").
                if norm:find(eventNorm, 1, true) == 1 or eventNorm:find(norm, 1, true) == 1 then
                    return true
                end
            end
        end
    end
    return false
end

local function eventMobNameMatchesSpawn(spawnId, eventName)
    if not spawnId or spawnId == 0 or not eventName or eventName == '' then return false end
    local sp = mq.TLO.Spawn(spawnId)
    if not spawnutils.isAliveEngageSpawn(sp) then return false end
    return mobNamesMatch(eventName, sp.Name() or '', sp.CleanName() or '')
end

local function diagFail(reason, mobName, extra)
    local now = mq.gettime()
    if now < _diagNextTime then return end
    _diagNextTime = now + DIAG_THROTTLE_MS
    local assistName = tankrole.GetAssistTargetName()
    local _, _, maTargetId = spellutils.GetAssistInfo(true)
    printf('\ayCZBot:\ax [CH interrupt] blocked: %s (mob=%s ma=%s maTarget=%s mobs=%s%s)',
        reason, tostring(mobName), tostring(assistName), tostring(maTargetId), tostring(state.getMobCount()),
        extra and (' ' .. extra) or '')
end

local function passesGates(mobName)
    if not botconfig.config.settings.dodebuff then
        diagFail('dodebuff off', mobName)
        return false
    end
    if state.getMobCount() <= 0 then
        diagFail('no mobs in camp', mobName)
        return false
    end
    if state.isTravelMode() then
        diagFail('travel mode', mobName)
        return false
    end
    if mq.TLO.Me.Dead() or mq.TLO.Me.Hovering() then
        diagFail('dead or hovering', mobName)
        return false
    end
    return true
end

local function spellEntryReady(index)
    local entry = botconfig.getSpellEntry('debuff', index)
    if not entry or entry.enabled == false then return false end
    local gem = entry.gem
    if not ((type(gem) == 'number' and gem ~= 0) or type(gem) == 'string') then return false end
    return spellutils.SpellCheck('debuff', index) and spellutils.CheckGemReadiness('debuff', index, entry)
end

--- True when spell MaxLevel can affect the target (same rule as mez in SpawnNeedsDebuff).
local function spellCanAffectTargetLevel(entry, targetId)
    if not entry or not targetId or targetId == 0 then return false end
    local spawn = mq.TLO.Spawn(targetId)
    local spawnLevel = spawn and spawn.Level()
    if not spawnLevel then return true end
    local spellEntity = spellutils.GetSpellEntity(entry)
    if not spellEntity then return false end
    local maxLvl = spellEntity.MaxLevel()
    if not maxLvl or maxLvl == 0 then return true end
    return maxLvl >= spawnLevel
end

local function findInterruptSpellIndex(targetId)
    local count = botconfig.getSpellCount('debuff')
    if not count or count <= 0 then return nil end
    for i = 1, count do
        local entry = botconfig.getSpellEntry('debuff', i)
        if entry and entry.enabled ~= false and isMezInterruptSpell(entry) then
            if spellEntryReady(i) and spellCanAffectTargetLevel(entry, targetId) then return i, entry end
        end
    end
    for i = 1, count do
        local entry = botconfig.getSpellEntry('debuff', i)
        if entry and entry.enabled ~= false and aliasMatches(entry, 'stun') then
            if spellEntryReady(i) and spellCanAffectTargetLevel(entry, targetId) then return i, entry end
        end
    end
    return nil
end

local function isInterruptCastLaneBusy()
    if (mq.TLO.Me.CastTimeLeft() or 0) > 0 and mq.TLO.Me.Class.ShortName() ~= 'BRD' then return true end
    local rc = state.getRunconfig()
    if state.getRunState() == state.STATES.casting and rc.CurSpell and rc.CurSpell.sub then return true end
    if mq.TLO.Me.Class.ShortName() == 'BRD' and rc.bardNotmatarWait then return true end
    return false
end

local function isCastLaneFree()
    if (mq.TLO.Me.CastTimeLeft() or 0) > 0 and mq.TLO.Me.Class.ShortName() ~= 'BRD' then return false end
    local rc = state.getRunconfig()
    if state.getRunState() == state.STATES.casting and rc.CurSpell and rc.CurSpell.sub then return false end
    if mq.TLO.Me.Class.ShortName() == 'BRD' and rc.bardNotmatarWait then return false end
    return state.canStartBusyState(state.STATES.casting)
end

local function targetDisplayName(targetId)
    local sp = mq.TLO.Spawn(targetId)
    return (sp and (sp.CleanName() or sp.Name())) or tostring(targetId)
end

local function executeInterrupt(targetId, spellIndex)
    local entry = botconfig.getSpellEntry('debuff', spellIndex)
    if not entry then return false end
    local runPriority = bothooks.getPriority('doDebuff')
    local spellName = entry.spell or '?'
    local targetName = targetDisplayName(targetId)

    if mq.TLO.Me.Class.ShortName() == 'BRD' and isMezInterruptSpell(entry) then
        local botdebuff = require('botdebuff')
        local ok = botdebuff.CastBardMezOnce(spellIndex, targetId, runPriority, INTERRUPT_REASON)
        if not ok then
            printf('\ayCZBot:\ax [CH interrupt] failed: bard mez could not start \ag%s\ax on \at%s\ax', spellName,
                targetName)
        end
        return ok
    end

    local ok = spellutils.CastSpell(spellIndex, targetId, 'matar', 'debuff', runPriority, nil, { fromInterrupt = true })
    if ok then
        printf('\ayCZBot:\ax interrupting \ag%s\ax on \at%s\ax (%s)', spellName, targetName, INTERRUPT_REASON)
    else
        printf('\ayCZBot:\ax [CH interrupt] failed: CastSpell returned false for \ag%s\ax on \at%s\ax', spellName,
            targetName)
    end
    return ok
end

local function queuePending(rc, targetId, mobName)
    rc.maCastInterruptPending = {
        targetId = targetId,
        mobName = mobName,
        requestedAt = mq.gettime(),
    }
    local spellIndex = findInterruptSpellIndex(targetId)
    local entry = spellIndex and botconfig.getSpellEntry('debuff', spellIndex)
    if entry then
        printf('\ayCZBot:\ax queued \ag%s\ax interrupt on \at%s\ax (waiting for current cast)', entry.spell or '?',
            targetDisplayName(targetId))
    end
end

local function clearPending(rc)
    rc.maCastInterruptPending = nil
end

local function validatePending(pending)
    if not pending or not pending.targetId or not pending.mobName then return nil, nil end
    if not passesGates(pending.mobName) then return nil, nil end
    local _, _, maTargetId = spellutils.GetAssistInfo(true)
    if not maTargetId or maTargetId == 0 or maTargetId ~= pending.targetId then return nil, nil end
    if not spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(maTargetId)) then return nil, nil end
    if not eventMobNameMatchesSpawn(maTargetId, pending.mobName) then return nil, nil end
    local spellIndex = findInterruptSpellIndex(maTargetId)
    if not spellIndex then return nil, nil end
    return maTargetId, spellIndex
end

function castinterrupt.tickPending()
    local rc = state.getRunconfig()
    local pending = rc.maCastInterruptPending
    if not pending then return false end
    if not isCastLaneFree() then return false end
    local targetId, spellIndex = validatePending(pending)
    if not targetId then
        clearPending(rc)
        return false
    end
    if executeInterrupt(targetId, spellIndex) then
        clearPending(rc)
        return true
    end
    return false
end

function castinterrupt.tryInterruptMaCast(mobName)
    if not mobName or mobName == '' then return false end
    if not passesGates(mobName) then return false end
    local assistName, _, maTargetId = spellutils.GetAssistInfo(true)
    if not maTargetId or maTargetId == 0 then
        diagFail('no MA target', mobName, assistName and ('(ma=' .. assistName .. ')') or nil)
        return false
    end
    if not spawnutils.isAliveEngageSpawn(mq.TLO.Spawn(maTargetId)) then
        diagFail('MA target not alive', mobName, 'id=' .. tostring(maTargetId))
        return false
    end
    if not eventMobNameMatchesSpawn(maTargetId, mobName) then
        local sp = mq.TLO.Spawn(maTargetId)
        diagFail('event name mismatch', mobName,
            string.format('spawn=%s/%s', sp.CleanName() or '', sp.Name() or ''))
        return false
    end
    local spellIndex, entry = findInterruptSpellIndex(maTargetId)
    if not spellIndex then
        diagFail('no ready mez/stun', mobName, 'maTarget=' .. tostring(maTargetId))
        return false
    end
    local rc = state.getRunconfig()
    if isInterruptCastLaneBusy() then
        queuePending(rc, maTargetId, mobName)
        return true
    end
    if executeInterrupt(maTargetId, spellIndex) then return true end
    if entry then
        printf('\ayCZBot:\ax [CH interrupt] failed after executeInterrupt for \ag%s\ax on \at%s\ax', entry.spell or '?',
            targetDisplayName(maTargetId))
    end
    return false
end

return castinterrupt
