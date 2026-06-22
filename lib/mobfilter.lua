local mq = require('mq')
local botconfig = require('lib.config')
local state = require('lib.state')
local M = {}

local LIST_CONFIG = {
    exclude = {
        commonKey = 'excludelist',
        runconfigKey = 'ExcludeList',
        onZoneLoad = function()
            mq.cmdf('/squelch /alert clear %s', state.getRunconfig().AlertList)
        end,
    },
    priority = {
        commonKey = 'prioritylist',
        runconfigKey = 'PriorityList',
        onZoneLoad = nil,
    },
    charm = {
        commonKey = 'charmlist',
        runconfigKey = 'CharmList',
        onZoneLoad = nil,
    },
}

local function saveList(listType, replace)
    local opts = LIST_CONFIG[listType]
    if not opts then return end
    local zone = mq.TLO.Zone.ShortName()
    if not zone or zone == '' then return end
    local memList = botconfig.copyStringList(state.getRunconfig()[opts.runconfigKey])
    botconfig.mutateCommon(function(common)
        local zb = common.zones and common.zones[zone]
        local diskList = zb and zb[opts.commonKey] or {}
        if not common.zones then common.zones = {} end
        if not common.zones[zone] then common.zones[zone] = {} end
        zb = common.zones[zone]
        if replace then
            zb[opts.commonKey] = memList
        else
            zb[opts.commonKey] = botconfig.unionStringList(diskList, memList)
        end
    end)
end

local function loadZone(listType)
    local opts = LIST_CONFIG[listType]
    if not opts then return end
    local zone = mq.TLO.Zone.ShortName()
    local zb = botconfig.getZoneBlock(zone)
    local val = (zb and zb[opts.commonKey]) or {}
    state.getRunconfig()[opts.runconfigKey] = botconfig.copyStringList(val)
    if opts.onZoneLoad then opts.onZoneLoad() end
end

function M.process(listType, command)
    if command == 'save' then
        saveList(listType, false)
    elseif command == 'save_replace' then
        saveList(listType, true)
    elseif command == 'zone' then
        loadZone(listType)
    end
end

return M
