-- Bard MQ2Twist integration: twist list builders, mode, ensure, stop/resume, twist once.
-- Requires mq, botconfig, state. No dependency on spellutils/botbuff to avoid circular refs.

local mq = require('mq')

local botconfig = require('lib.config')
local state = require('lib.state')
local utils = require('lib.utils')

local bardtwist = {}
local twistOnceActive = false
local lastTwistOnceGem = nil
local lastTwistOnceAt = 0
local TWIST_ONCE_GEM_TTL_MS = 10000

local function clearTwistOnceGemHint()
    lastTwistOnceGem = nil
    lastTwistOnceAt = 0
end

--- Parse entry.bands for a phase token (buff: self, cbt, pull).
local function buffHasPhase(entry, phase)
    local bands = entry and entry.bands
    if not bands or type(bands) ~= 'table' then return false end
    for _, band in ipairs(bands) do
        local tp = band.targetphase
        if type(tp) == 'table' then
            for _, p in ipairs(tp) do
                if p == phase then return true end
            end
        end
    end
    return false
end

--- Parse entry.bands for matar (debuff).
local function debuffHasMatar(entry)
    local bands = entry and entry.bands
    if not bands or type(bands) ~= 'table' then return false end
    for _, band in ipairs(bands) do
        local tp = band.targetphase
        if type(tp) == 'table' then
            for _, p in ipairs(tp) do
                if p == 'matar' or p == 'tanktar' then return true end -- accept legacy
            end
        end
    end
    return false
end

--- Parse twist list string (e.g. from Twist.List()) into array of gem/slot numbers.
--- Accepts 1-12 (gems) and 21-29 (MQ2Twist clicky slots). Handles nil/empty and extra whitespace.
local function parseTwistListString(s)
    if s == nil or type(s) ~= 'string' then return {} end
    s = s:match('^%s*(.-)%s*$') or ''  -- trim
    if s == '' then return {} end
    local out = {}
    for token in s:gmatch('%S+') do
        local n = tonumber(token)
        if n and (n >= 1 and n <= 12 or n >= 21 and n <= 29) then
            out[#out + 1] = n
        end
    end
    return out
end

--- True if two gem arrays have same length and same values in order.
local function twistListsEqual(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

function bardtwist.IsBard()
    return mq.TLO.Me.Class.ShortName() == 'BRD'
end

function bardtwist.SongsEnabled()
    if not bardtwist.IsBard() then return false end
    local rc = state.getRunconfig()
    return rc.dosongs ~= false
end

--- Idle twist list: buffs where inIdle is true (or legacy idle/self in bands). Config order.
function bardtwist.BuildNoncombatTwistList()
    if not bardtwist.IsBard() then return {} end
    local spells = botconfig.config.buff and botconfig.config.buff.spells
    if not spells then return {} end
    local out = {}
    for i = 1, #spells do
        local entry = spells[i]
        if entry and entry.enabled ~= false and type(entry.gem) == 'number' and entry.gem >= 1 and entry.gem <= 12 then
            local inIdle = (entry.inIdle == true) or (entry.inIdle == nil and (buffHasPhase(entry, 'idle') or buffHasPhase(entry, 'self')))
            if inIdle then
                out[#out + 1] = entry.gem
            end
        end
    end
    return out
end

--- Combat twist list: buffs where inCombat is true (or legacy cbt in bands), then debuffs targeting the MA (matar). Config order.
function bardtwist.BuildCombatTwistList()
    if not bardtwist.IsBard() then return {} end
    local out = {}
    local buffs = botconfig.config.buff and botconfig.config.buff.spells
    if buffs then
        for i = 1, #buffs do
            local entry = buffs[i]
            if entry and entry.enabled ~= false and type(entry.gem) == 'number' and entry.gem >= 1 and entry.gem <= 12 then
                local inCombat = (entry.inCombat == true) or buffHasPhase(entry, 'cbt')
                if inCombat then
                    out[#out + 1] = entry.gem
                end
            end
        end
    end
    local debuffs = botconfig.config.debuff and botconfig.config.debuff.spells
    if debuffs then
        local botdebuff = package.loaded['botdebuff']
        if not botdebuff then
            local ok, mod = pcall(require, 'botdebuff')
            if ok then botdebuff = mod end
        end
        for i = 1, #debuffs do
            local entry = debuffs[i]
            if entry and entry.enabled ~= false and type(entry.gem) == 'number' and entry.gem >= 1 and entry.gem <= 12 then
                if debuffHasMatar(entry) then
                    local conditional = botdebuff and botdebuff.BardMatarDebuffIsConditional
                        and botdebuff.BardMatarDebuffIsConditional(i)
                    if not conditional then
                        out[#out + 1] = entry.gem
                    end
                end
            end
        end
    end
    return out
end

--- Find first buff spell whose alias (string) contains the given token (exact match for one of the |‑separated values). Returns gem (1–12) or nil.
local function buffGemByAlias(token)
    if not token or token == '' then return nil end
    local spells = botconfig.config.buff and botconfig.config.buff.spells
    if not spells then return nil end
    for i = 1, #spells do
        local entry = spells[i]
        if entry and entry.enabled ~= false and type(entry.gem) == 'number' and entry.gem >= 1 and entry.gem <= 12 then
            local alias = entry.alias
            if type(alias) == 'string' and alias ~= '' then
                for value in (alias):gmatch('[^|]+') do
                    local v = value:match('^%s*(.-)%s*$') or value
                    if v == token then
                        return entry.gem
                    end
                end
            end
        end
    end
    return nil
end

--- Travel twist: song with alias 'travel', else 'selos', else nothing. Config order; single gem.
function bardtwist.BuildTravelTwistList()
    if not bardtwist.IsBard() then return {} end
    local gem = buffGemByAlias('travel')
    if gem then return { gem } end
    gem = buffGemByAlias('selos')
    if gem then return { gem } end
    return {}
end

--- Buffs with self and pull (numeric gem, enabled). Config order.
function bardtwist.BuildPullTwistList()
    if not bardtwist.IsBard() then return {} end
    local spells = botconfig.config.buff and botconfig.config.buff.spells
    if not spells then return {} end
    local out = {}
    for i = 1, #spells do
        local entry = spells[i]
        if entry and entry.enabled ~= false and type(entry.gem) == 'number' and entry.gem >= 1 and entry.gem <= 12 then
            if buffHasPhase(entry, 'self') and buffHasPhase(entry, 'pull') then
                out[#out + 1] = entry.gem
            end
        end
    end
    return out
end

function bardtwist.GetCurrentTwistMode()
    if not bardtwist.IsBard() then return nil end
    if state.isTravelMode() then return 'travel' end
    local rc = state.getRunconfig()
    if rc.MobList and rc.MobList[1] then return 'combat' end
    return 'idle'
end

--- Build list for mode and return as array of gem numbers (for comparison /twist command).
function bardtwist.GetTwistListForMode(mode)
    if mode == 'travel' then
        return bardtwist.BuildTravelTwistList()
    elseif mode == 'pull' then
        return bardtwist.BuildPullTwistList()
    elseif mode == 'combat' then
        return bardtwist.BuildCombatTwistList()
    else
        return bardtwist.BuildNoncombatTwistList()
    end
end

--- Build list for mode and return as string for comparison with Twist.List().
function bardtwist.GetTwistListStringForMode(mode)
    local list = bardtwist.GetTwistListForMode(mode)
    if not list or #list == 0 then return '' end
    return table.concat(list, ' ')
end

--- Set twist list for mode. Only issue /twist when not twisting or list differs (avoid restart every tick). For travel with no song, stop twist.
function bardtwist.EnsureTwistForMode(mode)
    if state.getRunconfig().bardTwistOnceWait then return end
    if not bardtwist.SongsEnabled() then return end
    local desiredGems = bardtwist.GetTwistListForMode(mode)
    if not desiredGems or #desiredGems == 0 then
        if mode == 'travel' and mq.TLO.Twist() and mq.TLO.Twist.Twisting() then
            mq.cmd('/twist stop')
        end
        return
    end
    local twisting = mq.TLO.Twist() and mq.TLO.Twist.Twisting()
    local currentListRaw = mq.TLO.Twist() and mq.TLO.Twist.List()
    local currentGems = parseTwistListString(currentListRaw and tostring(currentListRaw) or '')
    if twistOnceActive then
        if twistListsEqual(currentGems, desiredGems) then
            twistOnceActive = false
            clearTwistOnceGemHint()
        end
        return
    end
    if twisting and twistListsEqual(currentGems, desiredGems) then return end
    mq.cmd('/twist ' .. table.concat(desiredGems, ' '))
end

function bardtwist.EnsureDefaultTwistRunning()
    if state.getRunconfig().bardTwistOnceWait then return end
    if utils.isNearPrimaryBindPoint() then
        bardtwist.StopTwist()
        return
    end
    local mode = bardtwist.GetCurrentTwistMode()
    if mode then bardtwist.EnsureTwistForMode(mode) end
end

function bardtwist.StopTwist()
    twistOnceActive = false
    clearTwistOnceGemHint()
    if mq.TLO.Twist() and mq.TLO.Twist.Twisting() then
        mq.cmd('/twist stop')
    end
end

--- Restore twist for current mode (e.g. after single cast). Set list if needed then start.
function bardtwist.ResumeTwist()
    if not bardtwist.SongsEnabled() then return end
    local mode = bardtwist.GetCurrentTwistMode()
    if not mode then return end
    local desiredGems = bardtwist.GetTwistListForMode(mode)
    if not desiredGems or #desiredGems == 0 then return end
    if mq.TLO.Twist() and mq.TLO.Twist.Twisting() then return end
    local currentListRaw = mq.TLO.Twist() and mq.TLO.Twist.List()
    local currentGems = parseTwistListString(currentListRaw and tostring(currentListRaw) or '')
    if twistListsEqual(currentGems, desiredGems) then
        mq.cmd('/twist start')
    else
        mq.cmd('/twist ' .. table.concat(desiredGems, ' '))
    end
end

function bardtwist.SetTwistOnce(gemList)
    if not bardtwist.SongsEnabled() then return end
    if not gemList or #gemList == 0 then return end
    twistOnceActive = true
    lastTwistOnceGem = gemList[1]
    lastTwistOnceAt = mq.gettime()
    mq.cmd('/twist once ' .. table.concat(gemList, ' '))
end

function bardtwist.SetTwistOnceGem(gem)
    if gem then bardtwist.SetTwistOnce({ gem }) end
end

--- Gem used by last /twist once (mez, pull engage). Nil if outside TTL window.
function bardtwist.getLastTwistOnceGem()
    if not lastTwistOnceGem then return nil end
    if mq.gettime() - lastTwistOnceAt > TWIST_ONCE_GEM_TTL_MS then
        clearTwistOnceGemHint()
        return nil
    end
    return lastTwistOnceGem
end

function bardtwist.IsTwistOnceActive()
    return twistOnceActive
end

--- Restore twist for current mode after BRD twist-once wait ends. Call only when bardTwistOnceWait was just cleared.
function bardtwist.RestoreCombatTwistAfterTwistOnce()
    twistOnceActive = false
    clearTwistOnceGemHint()
    if not bardtwist.SongsEnabled() then return end
    local mode = bardtwist.GetCurrentTwistMode()
    if mode then bardtwist.EnsureTwistForMode(mode) end
end

---@deprecated use RestoreCombatTwistAfterTwistOnce
bardtwist.RestoreCombatTwistAfterNotmatar = bardtwist.RestoreCombatTwistAfterTwistOnce

return bardtwist
