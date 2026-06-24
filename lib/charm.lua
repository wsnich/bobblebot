-- Charm logic: target selection, before-cast (pet leave), charm-broke recast request,
-- and session charm-skip tracking (melee/mez exclusion until dead or /cz attack override).
-- Used by botdebuff (debuff eval/beforeCast) and botevents (CharmBroke handler).

local mq = require('mq')
local state = require('lib.state')
local spellstates = require('lib.spellstates')
local spellutils = require('lib.spellutils')
local utils = require('lib.utils')

local charm = {}

-- Re-export charm-skip helpers from utils (shared leaf; avoids spawnutils/charm/spellutils cycle).
charm.isCharmedPcPet = utils.isCharmedPcPet
charm.clearCharmSkip = utils.clearCharmSkip
charm.trackCharmSkip = utils.trackCharmSkip
charm.isCharmSkipped = utils.isCharmSkipped
charm.pruneCharmSkipIds = utils.pruneCharmSkipIds

-- Module state for charm-broke handler (set when EvalTarget picks a charm target).
local _charmspellid = nil
local _charmindex = nil
-- Recast request set when charm breaks; consumed by debuff loop for that index.
local _recastRequest = nil

function charm.syncCharmSkipFromSpawn(spawn, rc)
    if not utils.isCharmedPcPet(spawn) then return end
    local sid = spawn.ID()
    if sid and sid > 0 then charm.trackCharmSkip(sid, rc) end
end

--- Manual kill override (/cz attack): clear skip list, charmid, and pending recast for this spawn.
function charm.releaseCharmTarget(spawnId, rc)
    if not spawnId or spawnId <= 0 then return end
    rc = rc or state.getRunconfig()
    charm.clearCharmSkip(spawnId, rc)
    if rc.charmid == spawnId then rc.charmid = nil end
    if _recastRequest and _recastRequest.spawnId == spawnId then
        _recastRequest = nil
    end
end

function charm.EvalTarget(index, ctx)
    local entry = ctx.entry
    if not spellutils.IsCharmSpell(entry) then return nil, nil end
    local list = state.getRunconfig().CharmList or {}
    if #list == 0 then return nil, nil end
    local gem = entry.gem
    _charmspellid = mq.TLO.Spell(entry.spell).ID() or
        (gem == 'item' and mq.TLO.FindItem(entry.spell)() and mq.TLO.FindItem(entry.spell).Spell.ID())
    _charmindex = index
    local rc = state.getRunconfig()
    local petId = mq.TLO.Me.Pet.ID() or 0
    local isSummoned = mq.TLO.Me.Pet.IsSummoned()
    if petId == 0 and not isSummoned and rc.charmid then rc.charmid = nil end
    if petId > 0 and not isSummoned then
        if not rc.charmid or rc.charmid ~= petId then
            rc.charmid = petId
            charm.trackCharmSkip(rc.charmid, rc)
        end
        charm.trackCharmSkip(rc.charmid, rc)
        return nil, nil
    end
    for _, v in ipairs(ctx.mobList) do
        local tarstacks = mq.TLO.Spell(entry.spell).StacksSpawn(v.ID())() or
            (gem == 'item' and mq.TLO.FindItem(entry.spell)() and mq.TLO.FindItem(entry.spell).Spell.StacksSpawn(v.ID())())
        local overLevel = ctx.spellid and v.Level() and ctx.spellmaxlvl and ctx.spellmaxlvl ~= 0 and ctx.spellmaxlvl < v.Level()
        local distSq = utils.getDistanceSquared2D(mq.TLO.Me.X(), mq.TLO.Me.Y(), v.X(), v.Y())
        local outOfRange = ctx.myrange and distSq and distSq > (ctx.myrange * ctx.myrange)
        if not overLevel and not outOfRange and tarstacks and (tonumber(ctx.spelldur) or 0) > 0 then
            local mobhp = v.PctHPs()
            if ctx.mobMin ~= nil and (mobhp == nil or mobhp < ctx.mobMin) then
                -- skip: mob below band
            elseif ctx.mobMax ~= nil and (mobhp == nil or mobhp > ctx.mobMax) then
                -- skip: mob above band
            elseif v.ID() then
                local expire = spellstates.GetDebuffExpire(v.ID(), ctx.spellid)
                local cleanName = v.CleanName()
                local mobnameLower = cleanName and string.lower(cleanName)
                if expire and expire < (mq.gettime() + 6000) then
                    for _, charmname in ipairs(list) do
                        local n = type(charmname) == 'string' and charmname:match('^%s*(.-)%s*$') or ''
                        if n ~= '' and (cleanName == n or (mobnameLower and string.lower(n) == mobnameLower)) then return v.ID(), 'charmtar' end
                    end
                elseif expire and expire >= (mq.gettime() + 6000) then
                    for _, charmname in ipairs(list) do
                        local n = type(charmname) == 'string' and charmname:match('^%s*(.-)%s*$') or ''
                        if n ~= '' and (cleanName == n or (mobnameLower and string.lower(n) == mobnameLower)) then return v.ID(), 'charmtar' end
                    end
                else
                    for _, charmname in ipairs(list) do
                        local n = type(charmname) == 'string' and charmname:match('^%s*(.-)%s*$') or ''
                        if n ~= '' and (cleanName == n or (mobnameLower and string.lower(n) == mobnameLower)) then return v.ID(), 'charmtar' end
                    end
                end
            else
                local cleanName = v.CleanName()
                local mobnameLower = cleanName and string.lower(cleanName)
                for _, charmname in ipairs(list) do
                    local n = type(charmname) == 'string' and charmname:match('^%s*(.-)%s*$') or ''
                    if n ~= '' and (cleanName == n or (mobnameLower and string.lower(n) == mobnameLower)) then return v.ID(), 'charmtar' end
                end
            end
        end
    end
    return nil, nil
end

--- One-time setup when a NEW charm pet is acquired: taunt OFF (so the charm pet doesn't pull aggro off
--- the tank) and kick it onto the current engage target (else the MA's target). Runs once per pet id;
--- pet buffs/heals are handled by the normal buff/heal loops. No-op unless settings.charmPetAutoSetup.
function charm.AutoSetupNewCharmPet(rc)
    rc = rc or state.getRunconfig()
    local botconfig = require('lib.config')
    if botconfig.config.settings.charmPetAutoSetup == false then return end
    local petId = mq.TLO.Me.Pet.ID()
    if not petId or petId == 0 then return end
    if rc.charmAutoSetupDoneId == petId then return end
    rc.charmAutoSetupDoneId = petId
    mq.cmd('/squelch /pet taunt off')
    local targetId = rc.engageTargetId
    if not targetId or targetId == 0 then
        local _, _, maTargetId = spellutils.GetAssistInfo(true)
        if maTargetId and maTargetId > 0 then targetId = maTargetId end
    end
    if targetId and targetId > 0 then
        mq.cmdf('/squelch /pet attack %s', targetId)
    end
    printf('\ayCZBot:\axCharm pet acquired: taunt off, assisting.')
end

function charm.BeforeCast(EvalID, targethit)
    if targethit == 'charmtar' and mq.TLO.Me.Pet.IsSummoned() then
        mq.cmd('/pet leave')
    end
    return true
end

function charm.OnCharmBroke(line, spellNameFromEvent)
    local rc = state.getRunconfig()
    if not _charmspellid or not rc.charmid then return end
    local charmspellname = mq.TLO.Spell(_charmspellid).Name()
    if spellNameFromEvent ~= charmspellname then return end
    spellstates.ClearDebuffOnSpawn(rc.charmid, _charmspellid)
    charm.trackCharmSkip(rc.charmid, rc)
    printf('\ayCZBot:\ax\arCHARM %s wore off!', spellNameFromEvent)
    _recastRequest = { index = _charmindex, spawnId = rc.charmid }
end

function charm.GetRecastRequestForIndex(index)
    if not _recastRequest or _recastRequest.index ~= index then return nil, nil end
    return _recastRequest.spawnId, 'charmtar'
end

function charm.ClearRecastRequest()
    _recastRequest = nil
end

return charm
