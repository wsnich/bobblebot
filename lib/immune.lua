local mq = require('mq')
local botconfig = require('lib.config')
local state = require('lib.state')
local M = {}

--- Return immune table for current zone only: [spell][mobName] = true.
function M.get()
    botconfig.getCommon()
    local zone = mq.TLO.Zone.ShortName()
    local zb = botconfig.getZoneBlock(zone)
    if not zb or not zb.immune then return {} end
    return zb.immune
end

function M.load()
    botconfig.getCommon()
end

function M.add(spell, zone, mobName)
    if not spell or not zone or zone == '' or not mobName or mobName == '' then return end
    botconfig.mutateCommon(function(common)
        if not common.zones then common.zones = {} end
        if not common.zones[zone] then common.zones[zone] = {} end
        local zb = common.zones[zone]
        if not zb.immune then zb.immune = {} end
        if not zb.immune[spell] then zb.immune[spell] = {} end
        zb.immune[spell][mobName] = true
    end)
end

---@param immuneID number|nil spawn ID of immune target
---@param opts table|nil optional { spellName = string } canonical spell name for immune list; else CurSpell.sub/spell
function M.processList(immuneID, opts)
    local spell
    if opts and opts.spellName and opts.spellName ~= '' then
        spell = mq.TLO.Spell(opts.spellName)() or opts.spellName
    else
        local rc = state.getRunconfig()
        local cur = rc and rc.CurSpell
        if cur and cur.sub and cur.spell then
            local entry = botconfig.getSpellEntry(cur.sub, cur.spell)
            spell = entry and mq.TLO.Spell(entry.spell)() or nil
        end
    end
    local zone = mq.TLO.Zone.ShortName()
    if immuneID and spell and mq.TLO.Spawn(immuneID).ID() and mq.TLO.Spawn(immuneID).Type() ~= 'Corpse' then
        local mobName = mq.TLO.Spawn(immuneID).CleanName()
        local t = M.get()
        if not t[spell] or not t[spell][mobName] then
            M.add(spell, zone, mobName)
            printf('\ayCZBot:\ax%s is \\arIMMUNE\\ax to spell \\ag%s\\ax, adding to the ImmuneList', mobName, spell)
        end
    end
end

return M
