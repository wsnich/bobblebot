local mq = require('mq')

-- Require MQCharinfo before loading bot (so we can end macro if unavailable).
local ok, _ = pcall(require, 'plugin.charinfo')
if not ok then
    print('\aybobblebot:\ax MQCharinfo (charinfo) is required but failed to load.')
    return
end

-- Load required MQ plugins and end macro if any fail to load.
if not mq.TLO.Plugin('MQ2MoveUtils').IsLoaded() then mq.cmd('/squelch /plugin MQ2MoveUtils load') end
if not mq.TLO.Plugin('MQ2Twist').IsLoaded() then mq.cmd('/squelch /plugin MQ2Twist load') end
mq.delay(2000)
if not mq.TLO.Plugin('MQ2MoveUtils').IsLoaded() then
    print('\aybobblebot:\ax MQ2MoveUtils is required but failed to load.')
    return
end
if not mq.TLO.Plugin('MQ2Twist').IsLoaded() then
    print('\aybobblebot:\ax MQ2Twist is required but failed to load.')
    return
end

local botmelee = require('botmelee')
local botlogic = require('botlogic')
local spellutils = require('lib.spellutils')

botlogic.StartUp(...)
spellutils.Init({
    AdvCombat = botmelee.AdvCombat,
})
botlogic.mainloop()
