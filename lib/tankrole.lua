-- Resolves Main Tank (MT) vs Main Assist (MA) for the bot.
-- MT = who gets heals and who may pick from MobList when they are a bot.
-- MA = who DPS and offtank follow (whose target to attack).
-- "automatic" uses Group/Raid window roles: Group.MainTank, Group.MainAssist, Group.Puller.
-- Raid has MainAssist only; MainTank and Puller always come from Group.
-- When primary is unavailable, falls back to cz_common ma_list / mt_list (proximity-gated).

local mq = require('mq')
local botconfig = require('lib.config')
local state = require('lib.state')
local charinfo = require("plugin.charinfo")
local charinfoutils = require('lib.charinfoutils')

local tankrole = {}

local function getAnchorLeash()
    local settings = botconfig.config.settings
    return tonumber(settings.maAnchorLeash) or tonumber(settings.acleash) or 75
end

local function isCandidateAvailable(name, requireLeash)
    if not name or name == '' then return false end
    local ctx = charinfoutils.getLeaderContext(name)
    if not ctx or not ctx.alive or not ctx.sameZone then return false end
    if requireLeash then
        local leash = getAnchorLeash()
        if not ctx.distance or ctx.distance > leash then return false end
    end
    return true
end

local function firstAvailableFromList(list, requireLeash)
    if type(list) ~= 'table' then return nil end
    for _, name in ipairs(list) do
        if isCandidateAvailable(name, requireLeash) then return name end
    end
    return nil
end

local function inRaid()
    return mq.TLO.Raid.Members() and mq.TLO.Raid.Members() > 0
end

local function resolveAutomaticAssistName()
    local primary
    if inRaid() then
        local ma = mq.TLO.Raid.MainAssist
        if ma and ma.Name then primary = ma.Name() end
    else
        local gma = mq.TLO.Group.MainAssist
        if gma and gma.Name then primary = gma.Name() end
    end
    if primary and primary ~= '' and isCandidateAvailable(primary, false) then
        return primary
    end
    return firstAvailableFromList(state.getRunconfig().MaList, true)
end

local function resolveAutomaticTankName()
    if not inRaid() then
        local gmt = mq.TLO.Group.MainTank
        local primary = gmt and gmt.Name and gmt.Name() or nil
        if primary and primary ~= '' and isCandidateAvailable(primary, false) then
            return primary
        end
    end
    return firstAvailableFromList(state.getRunconfig().MtList, true)
end

--- Return the Main Assist's character name (who DPS/offtank follow). Reads AssistName from runconfig; if nil/empty, uses TankName for backward compat.
---@return string|nil
function tankrole.GetAssistTargetName()
    local rc = state.getRunconfig()
    local name = rc.AssistName
    if name == nil or name == '' then
        name = rc.TankName
    end
    if name == nil or name == '' then return nil end
    if name == 'automatic' then
        return resolveAutomaticAssistName()
    end
    return name
end

--- Return the Main Tank's character name (who gets heals; who may pick from MobList). Reads TankName from runconfig.
---@return string|nil
function tankrole.GetMainTankName()
    local name = state.getRunconfig().TankName
    if name == nil or name == '' then return nil end
    if name == 'automatic' then
        return resolveAutomaticTankName()
    end
    return name
end

--- Return the Puller's current target ID when this toon is the MT (for puller priority in selectTankTarget). Group only; Raid has no Puller.
---@return number|nil
function tankrole.GetPullerTargetID()
    if tankrole.GetMainTankName() ~= mq.TLO.Me.Name() then return nil end
    local puller = mq.TLO.Group.Puller
    if not puller or not puller.Name then return nil end
    local pullerName = puller.Name()
    if not pullerName or pullerName == '' then return nil end
    local info = charinfo.GetInfo(pullerName)
    if info and info.Target and info.Target.ID then return info.Target.ID end
    return nil
end

--- True when this character is the Main Tank (resolved from TankName / Group.MainTank).
---@return boolean
function tankrole.AmIMainTank()
    return tankrole.GetMainTankName() == mq.TLO.Me.Name()
end

--- True when this character is the Main Assist (resolved from AssistName / Group or Raid MainAssist). Used so the MA bot runs selectMATarget.
---@return boolean
function tankrole.AmIMainAssist()
    return tankrole.GetAssistTargetName() == mq.TLO.Me.Name()
end

return tankrole
