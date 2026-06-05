-- Mainloop hook registry: modules require this and call registerMainloopHook.
-- Lower priority runs first. runWhenPaused = true runs every iteration even when MasterPause is set.
--
-- Always-run hooks (runWhenPaused = true): Must run every tick; never block. Use for:
--   - mqcharinfo (network sync)
--   - Any logic that must fire regardless of runState (pulling, casting, etc.)
-- Normal hooks: Skipped when MasterPause. When state is busy and payload has priority,
--   only hooks with hook.priority <= payload.priority run (higher-priority hooks and the busy-holding hook).
local mq = require('mq')
-- Throttled: when busy with payload.priority, hooks with higher priority numbers are skipped (see runNormalHooks).
local _hookSkipLogNextTime = 0
local HOOK_SKIP_LOG_INTERVAL_MS = 1000
local _hooks = {}
local _hookFns = {} -- name -> function (implementations registered by modules)
local _sortedNormal = nil
local _sortedRunWhenPaused = nil
local _sortedRunWhenBusy = nil

local function _rebuildSorted()
    local function byPriorityThenName(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return (a.name or '') < (b.name or '')
    end
    local runWhenPaused = {}
    local normal = {}
    local runWhenBusy = {}
    for _, h in ipairs(_hooks) do
        if h.runWhenPaused then
            runWhenPaused[#runWhenPaused + 1] = h
        else
            normal[#normal + 1] = h
        end
        if h.runWhenBusy then
            runWhenBusy[#runWhenBusy + 1] = h
        end
    end
    table.sort(runWhenPaused, byPriorityThenName)
    table.sort(normal, byPriorityThenName)
    table.sort(runWhenBusy, byPriorityThenName)
    _sortedRunWhenPaused = runWhenPaused
    _sortedNormal = normal
    _sortedRunWhenBusy = runWhenBusy
end

local hookregistry = {}

function hookregistry.registerHookFn(name, fn)
    _hookFns[name] = fn
end

--- Wire all hooks from bothooks config. Call after built-in hooks have registerHookFn'd.
--- For entries with provider, requires that module and calls mod.getHookFn(entry.name).
function hookregistry.registerAllFromConfig()
    local bothooks = require('lib.bothooks')
    for _, entry in ipairs(bothooks.getHooks()) do
        local fn
        if entry.provider then
            local mod = require(entry.provider)
            if mod.getHookFn then fn = mod.getHookFn(entry.name) end
        else
            fn = _hookFns[entry.name]
        end
        if fn then
            hookregistry.registerMainloopHook(entry.name, fn, entry.priority, entry.runWhenPaused, entry.runWhenDead, entry.runWhenBusy)
        end
    end
end

function hookregistry.registerMainloopHook(name, fn, priority, runWhenPaused, runWhenDead, runWhenBusy)
    _hooks[#_hooks + 1] = {
        name = name,
        fn = fn,
        priority = priority or 500,
        runWhenPaused = runWhenPaused == true,
        runWhenDead = runWhenDead == true,
        runWhenBusy = runWhenBusy == true,
    }
    _sortedNormal = nil
    _sortedRunWhenPaused = nil
    _sortedRunWhenBusy = nil
end

function hookregistry.runRunWhenPausedHooks()
    if _sortedRunWhenPaused == nil then _rebuildSorted() end
    local list = _sortedRunWhenPaused or {}
    for _, h in ipairs(list) do
        h.fn(h.name)
    end
end

function hookregistry.runNormalHooks()
    if _sortedNormal == nil then _rebuildSorted() end
    local list = _sortedNormal or {}
    local state = require('lib.state')
    -- Gate on actual game state so only runWhenDead hooks run when dead/hover (avoids running combat hooks the tick we die).
    if state.isDeadOrHover() or state.getRunState() == state.STATES.dead then
        for _, h in ipairs(list) do
            if h.runWhenDead then
                h.fn(h.name)
            end
        end
        return
    end
    local skippedByBusyCap = {}
    for _, h in ipairs(list) do
        local maxPriority = nil
        if state.isBusy() then
            local payload = state.getRunStatePayload()
            if payload and type(payload.priority) == 'number' then
                maxPriority = payload.priority
            end
        end
        if maxPriority == nil or h.priority <= maxPriority then
            h.fn(h.name)
        else
            skippedByBusyCap[#skippedByBusyCap + 1] = string.format('%s(%d>%s)', h.name, h.priority, tostring(maxPriority))
        end
    end
    if #skippedByBusyCap > 0 then
        local now = mq.gettime()
        if now >= _hookSkipLogNextTime then
            _hookSkipLogNextTime = now + HOOK_SKIP_LOG_INTERVAL_MS
            local rc = state.getRunconfig()
            local cs = rc.CurSpell
            local curSpellStr = 'nil'
            if cs and cs.sub and cs.phase then
                curSpellStr = string.format('%s/%s', tostring(cs.sub), tostring(cs.phase))
            elseif cs and cs.sub then
                curSpellStr = tostring(cs.sub)
            end
            local capNow = nil
            if state.isBusy() then
                local payload = state.getRunStatePayload()
                if payload and type(payload.priority) == 'number' then
                    capNow = payload.priority
                end
            end
        end
    end
    -- When busy (e.g. casting), run runWhenBusy hooks so movement (camp return, follow) still runs.
    if state.isBusy() then
        if _sortedRunWhenBusy == nil then _rebuildSorted() end
        local busyList = _sortedRunWhenBusy or {}
        for _, h in ipairs(busyList) do
            h.fn(h.name)
        end
    end
end

return hookregistry
