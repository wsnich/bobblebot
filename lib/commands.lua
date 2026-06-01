-- Command parser for /cz: dispatches to per-command handlers.
-- Uses globals and modules from the CZBot environment (state.getRunconfig(), botconfig, etc.).

local M = {}
local mq = require('mq')
local botconfig = require('lib.config')
local botgui = require('gui.components.botgui')
local spellutils = require('lib.spellutils')
local botmove = require('botmove')
local botpull = require('botpull')
local botbuff = require('botbuff')
local botcure = require('botcure')
local botheal = require('botheal')
local botdebuff = require('botdebuff')
local botraid = require('botraid')
local botevents = require('botevents')
local chchain = require('lib.chchain')
local mobfilter = require('lib.mobfilter')
local state = require('lib.state')
local bothooks = require('lib.bothooks')
local bardtwist = require('lib.bardtwist')
local groupmanager = require('lib.groupmanager')
local charinfo = require("plugin.charinfo")
local utils = require('lib.utils')
local command_dispatcher = require('lib.command_dispatcher')
local follow = require('lib.follow')
local spawnutils = require('lib.spawnutils')
local targeting = require('lib.targeting')
local unpack = unpack

local TOGGLELIST = {
    domelee = true,
    dopull = true,
    dodebuff = true,
    dobuff = true,
    doheal = true,
    doraid = true,
    docure = true,
    dosit = true,
    domount = true,
    dodrag = true,
    doforage = true,
}

local function refreshBardTwistMode()
    if bardtwist and bardtwist.EnsureDefaultTwistRunning then
        bardtwist.EnsureDefaultTwistRunning()
    end
end

-- --- Toggle handler (domelee, dopull, etc.) ---
local function cmd_toggle(args)
    local rc = state.getRunconfig()
    local isDopull = (args[1] == 'dopull')
    local function getVal()
        if isDopull then return rc.dopull == true end
        return botconfig.config.settings[args[1]] == true
    end
    local function setVal(v)
        if isDopull then rc.dopull = v else botconfig.config.settings[args[1]] = v end
    end
    if args[2] == 'on' then
        setVal(true)
    elseif args[2] == 'off' then
        if isDopull then
            botpull.DisablePull('command')
        else
            setVal(false)
        end
    else
        if getVal() then
            if isDopull then
                botpull.DisablePull('command')
            else
                setVal(false)
                if args[1] == 'domelee' then
                    if APTarget and APTarget.ID() then APTarget = nil end
                    mq.cmd('/squelch /mqtarget clear ; /nav stop ; /stick off ; /attack off')
                end
            end
        else
            setVal(false)
            setVal(true)
        end
    end
    botconfig.RunConfigLoaders()
    if botconfig.config.settings.doraid then botraid.LoadRaidConfig() end
    printf('\ayCZBot:\axTurning %s to %s', args[1],
        isDopull and tostring(rc.dopull) or tostring(botconfig.config.settings[args[1]]))
end

local function cmd_addjunk(args, str)
    local zone = mq.TLO.Zone.ShortName()
    if not zone or zone == '' then
        printf('\ayCZBot:\ax No zone; cannot add junk.')
        return
    end
    local itemName
    if args[2] then
        itemName = table.concat(args, ' ', 2)
    elseif mq.TLO.Cursor.ID() and mq.TLO.Cursor.Name() then
        itemName = mq.TLO.Cursor.Name()
    end
    if not itemName or itemName == '' then
        printf(
            '\ayCZBot:\ax No item name given and nothing on cursor. Use: /cz addjunk <itemname> or put item on cursor.')
        return
    end
    botconfig.addZoneJunk(zone, itemName)
    printf('\ayCZBot:\ax Added "%s" to zone %s junk list.', itemName, zone)
end

local function cmd_foragezone(args, str)
    local zone = mq.TLO.Zone.ShortName()
    if not zone or zone == '' then
        printf('\ayCZBot:\ax No zone; cannot set foragezone.')
        return
    end
    local sub = args[2] and args[2]:lower()
    if sub == 'on' then
        botconfig.setForageDisabledInZone(zone, false)
        printf('\ayCZBot:\ax Auto-forage enabled in this zone.')
    elseif sub == 'off' then
        botconfig.setForageDisabledInZone(zone, true)
        printf('\ayCZBot:\ax Auto-forage disabled in this zone.')
    else
        printf('\ayCZBot:\ax Usage: /cz foragezone on|off')
    end
end

local function cmd_import(args)
    if args[2] == 'lua' then
        local importpath = mq.configDir .. "\\" .. args[3]
        local configData, err = loadfile(importpath)
        if err then
            printf('failed to import lua file at %s', importpath)
        elseif configData then
            local newconfig = configData()
            if newconfig then
                for k in pairs(botconfig.config) do botconfig.config[k] = nil end
                for k, v in pairs(newconfig) do botconfig.config[k] = v end
            end
            botconfig.RunConfigLoaders()
            printf('\ayCZBot:\axLoaded lua file %s', args[3])
            if args[4] == 'save' then botconfig.Save(botconfig.getPath()) end
        end
    else
        printf('Usage: /cz import lua <filename> [save]')
    end
end

local function cmd_export(args)
    local exportpath = mq.configDir .. "\\" .. args[2]
    botconfig.WriteToFile(botconfig.config, exportpath)
    print("Exporting my config to " .. exportpath)
end

local function cmd_debug(args)
    if args[2] == 'on' then
        print('Enabling debug messages')
        debug = true
    elseif args[2] == 'off' then
        print('Disabling debug messages')
        debug = false
    else
        if debug == true then
            print('Disabling debug messages')
            debug = false
        elseif debug == false then
            print('Enabling debug messages')
            debug = true
        end
    end
end

local function cmd_ui(args)
    botgui.UIEnable()
end

local function cmd_quit(args, str)
    state.getRunconfig().terminate = true
end

local function cmd_makecamp(args, str)
    botmove.MakeCamp(args[2])
    local rc = state.getRunconfig()
    if rc.followid or rc.followname then
        rc.followid = 0
        rc.followname = ''
        rc.travelMode = false
        refreshBardTwistMode()
    end
end

local function cmd_follow(args, str)
    local rc = state.getRunconfig()
    local targetName
    if args[2] == nil then
        targetName = rc.TankName
    else
        targetName = args[2]
    end
    if targetName then follow.StartFollow(targetName) end
end

local function cmd_stop(args)
    local rc = state.getRunconfig()
    local wasTravelMode = (rc.travelMode == true)
    botmove.ClearFollowMovementState()
    if rc.followid or rc.followname then
        rc.followid = 0
        rc.followname = ''
    end
    rc.travelMode = false
    if wasTravelMode then
        refreshBardTwistMode()
    end
    if state.getRunconfig().campstatus then botmove.MakeCamp('off') end
    printf('\ayCZBot:\ax\arDisabling makecamp and follow')
end

local function cmd_travel(args, str)
    local rc = state.getRunconfig()
    local targetName
    if args[2] == nil then
        targetName = rc.TankName
    else
        targetName = args[2]
    end
    if targetName then
        follow.StartFollow(targetName)
        rc.travelMode = true
        printf('\ayCZBot:\ax\auTravel mode ON, following %s', targetName)
    end
end

local function tableContains(list, name)
    if type(list) ~= 'table' then return false end
    for _, n in ipairs(list) do
        if n == name then return true end
    end
    return false
end

local function removeFromList(list, name)
    for i = #list, 1, -1 do
        if list[i] == name then
            table.remove(list, i)
            return true
        end
    end
    return false
end

local function cmd_exclude(args)
    local rc = state.getRunconfig()
    if not rc.ExcludeList then rc.ExcludeList = {} end
    if args[2] == 'remove' then
        local name = args[3] or mq.TLO.Target.CleanName()
        if name and removeFromList(rc.ExcludeList, name) then
            printf('\ayCZBot:\axRemoved %s from exclude list', name)
            if APTarget and APTarget.ID() then APTarget = nil end
            mq.cmd('/squelch /mqtarget clear ; /nav stop ; /stick off ; /attack off')
            mobfilter.process('exclude', 'save')
        end
        return
    end
    local excludemob = args[2] or mq.TLO.Target.CleanName()
    if excludemob and not tableContains(rc.ExcludeList, excludemob) then
        printf('\ayCZBot:\axExcluding %s from CZBot', excludemob)
        table.insert(rc.ExcludeList, excludemob)
        if APTarget and APTarget.ID() then APTarget = nil end
        mq.cmd('/squelch /mqtarget clear ; /nav stop ; /stick off ; /attack off')
        mobfilter.process('exclude', 'save')
    end
end

local function cmd_fte(args)
    local rc = state.getRunconfig()
    local sub = args[2] and string.lower(args[2]) or ''
    if sub == 'clear' then
        if args[3] and string.lower(args[3]) == 'all' then
            spawnutils.clearFTE(rc, nil)
            printf('\ayCZBot:\ax Cleared all FTE entries')
            return
        end
        local tid = mq.TLO.Target.ID()
        if tid and tid > 0 and mq.TLO.Target.Type() == 'NPC' then
            spawnutils.clearFTE(rc, tid)
            printf('\ayCZBot:\ax Cleared FTE entry for %s (%s)', mq.TLO.Target.CleanName() or mq.TLO.Target.Name(), tid)
        else
            printf('\ayCZBot:\ax Usage: /cz fte clear [all] — or target an NPC')
        end
        return
    end
    printf('\ayCZBot:\ax Usage: /cz fte clear [all]')
end

local function cmd_xarc(args)
    botpull.SetPullArc(args[2])
end

local function cmd_priority(args)
    local rc = state.getRunconfig()
    if not rc.PriorityList then rc.PriorityList = {} end
    if args[2] == 'remove' then
        local name = args[3] or mq.TLO.Target.CleanName()
        if name and removeFromList(rc.PriorityList, name) then
            printf('\ayCZBot:\axRemoved %s from priority list', name)
            mobfilter.process('priority', 'save')
        end
        return
    end
    local prioritymob = args[2] or mq.TLO.Target.CleanName()
    if prioritymob and not tableContains(rc.PriorityList, prioritymob) then
        printf('\ayCZBot:\axPrioritizing %s in CZBot', prioritymob)
        table.insert(rc.PriorityList, prioritymob)
        mobfilter.process('priority', 'save')
    end
end

local function cmd_charm(args)
    local rc = state.getRunconfig()
    if not rc.CharmList then rc.CharmList = {} end
    if args[2] == 'remove' then
        local name = args[3] or mq.TLO.Target.CleanName()
        if name and removeFromList(rc.CharmList, name) then
            printf('\ayCZBot:\axRemoved %s from charm list', name)
            mobfilter.process('charm', 'save')
        end
        return
    end
    local charmmob = args[2] or mq.TLO.Target.CleanName()
    if charmmob and not tableContains(rc.CharmList, charmmob) then
        printf('\ayCZBot:\axAdding %s to charm list', charmmob)
        table.insert(rc.CharmList, charmmob)
        mobfilter.process('charm', 'save')
    end
end

-- Reload shared common config from disk, then refresh current-zone runtime derived lists/state.
-- This is useful when multiple bots share `cz_common.lua` and one bot edits via UI.
local function cmd_reloadcommon(args)
    botconfig.loadCommon()
    mobfilter.process('exclude', 'zone')
    mobfilter.process('priority', 'zone')
    mobfilter.process('charm', 'zone')
    botconfig.loadNukeFlavorsFromZone()
    local zone = mq.TLO.Zone.ShortName()
    zone = zone and zone ~= '' and zone or '<unknown>'
    printf('\ayCZBot:\ax Reloaded \agcz_common.lua\ax and refreshed zone state (zone=%s).', zone)
end

local function cmd_abort(args)
    local rc = state.getRunconfig()
    if not args[2] then
        if mq.TLO.Me.CastTimeLeft() > 0 and rc.CurSpell.sub and rc.CurSpell.sub == 'ad' then
            mq.cmd('/stopcast')
        end
        if mq.TLO.Me.Combat() then mq.cmd('/attack off') end
        if mq.TLO.Target.ID() then mq.cmd('/squelch /mqtarget clear') end
        if rc.engageTargetId then rc.engageTargetId = nil end
        rc.attackCommandEngage = nil
        if botconfig.config.settings.domelee then
            botconfig.config.settings.domelee = false
            rc.meleeAbort = true
        end
        if botconfig.config.settings.dodebuff then
            botconfig.config.settings.dodebuff = false
            rc.debuffAbort = true
        end
        printf('\ayCZBot:\ax\arAbort+ called!\ax - DoDebuffs & DoMelee FALSE and leashing to camp')
    elseif args[2] == 'off' then
        if not botconfig.config.settings.domelee and rc.meleeAbort then
            botconfig.config.settings.domelee = true
            rc.meleeAbort = false
        end
        if not botconfig.config.settings.dodebuff and rc.debuffAbort then
            botconfig.config.settings.dodebuff = true
            rc.debuffAbort = false
        end
        mq.cmd('\arAbort\ax OFF, enabling dps sections again')
    end
end

local function cmd_leash(args)
    if state.getRunconfig().campstatus then
        printf('\ayCZBot:\ax\arLeash\ax called, returning to camp location')
        botmove.MakeCamp('return')
    else
        printf('\ayCZBot:\axNo camp set, cannot leash')
    end
end

-- Engage MA's target, or (if name given) that player's target for this engagement only.
local function cmd_attack(args)
    local tankrole = require('lib.tankrole')
    local assistName
    local overrideName -- used for messages when args[2] was a specific player name
    if args[2] and args[2]:match('%S') then
        local raw = args[2]
        local normalized = (raw == 'automatic') and 'automatic' or (raw:sub(1, 1):upper() .. raw:sub(2))
        if normalized == 'automatic' then
            assistName = tankrole.GetAssistTargetName()
        else
            assistName = normalized
            overrideName = normalized
        end
    else
        assistName = tankrole.GetAssistTargetName()
    end
    if not assistName then
        printf('\ayCZBot:\ax\ar No Main Assist set, cannot engage')
        return
    end
    local maInfo = charinfo.GetInfo(assistName)
    if not maInfo then
        printf('\ayCZBot:\ax\ar Could not find %s\ax', assistName)
        return
    end
    local KillTarget = maInfo.Target and maInfo.Target.ID or nil
    local rc = state.getRunconfig()
    rc.engageTargetId = KillTarget
    rc.attackCommandEngage = (KillTarget ~= nil)
    if KillTarget then
        local msg = string.format('\ayCZBot:\ax\arEngaging\ax \ay%s\ax now', mq.TLO.Spawn(KillTarget).CleanName())
        if overrideName then
            msg = msg .. string.format(' \at(assist: %s)\ax', overrideName)
        end
        printf('%s', msg)
    else
        if overrideName then
            printf('\ayCZBot:\ax\ar %s has no target, cannot engage\ax', overrideName)
        else
            printf('\ayCZBot:\ax\ar Main Assist has no target, cannot engage')
        end
    end
end

-- Set MT (Main Tank).
local function cmd_tank(args)
    if not args[2] then return end
    local name = (args[2] == 'automatic') and 'automatic' or (args[2]:sub(1, 1):upper() .. args[2]:sub(2))
    state.getRunconfig().TankName = name
    printf('\ayCZBot:\axSetting tank to %s', name)
    mq.TLO.Target.TargetOfTarget()
end

-- Set MA (Main Assist).
local function cmd_assist(args)
    if not args[2] then return end
    local name = (args[2] == 'automatic') and 'automatic' or (args[2]:sub(1, 1):upper() .. args[2]:sub(2))
    state.getRunconfig().AssistName = name
    printf('\ayCZBot:\axSetting assist to %s', name)
end

local function cmd_stickcmd(args, str)
    botconfig.config.melee.stickcmd = str:match('stickcmd' .. "%s+(.+)")
    printf('\ayCZBot:\axSetting stickcmd to %s', botconfig.config.melee.stickcmd)
end

local function cmd_acleash(args)
    botconfig.config.settings.acleash = tonumber(args[2])
    botconfig.config.settings.acleashSq = (botconfig.config.settings.acleash or 0) *
        (botconfig.config.settings.acleash or 0)
    printf('\ayCZBot:\axSetting acleash to %s', botconfig.config.settings.acleash)
end

local function cmd_camprestdistance(args)
    botconfig.config.settings.campRestDistance = tonumber(args[2])
    botconfig.config.settings.campRestDistanceSq = (botconfig.config.settings.campRestDistance or 0) *
        (botconfig.config.settings.campRestDistance or 0)
    printf('\ayCZBot:\axSetting campRestDistance to %s', botconfig.config.settings.campRestDistance)
end

local function cmd_targetfilter(args)
    botconfig.config.settings.TargetFilter = tonumber(args[2])
    printf('\ayCZBot:\axSetting TargetFilter to %d', botconfig.config.settings.TargetFilter)
end

local function cmd_offtank(args)
    if not args[2] then
        if botconfig.config.melee.offtank == true then
            botconfig.config.melee.offtank = false
        else
            botconfig.config.melee.offtank = true
        end
    elseif string.lower(args[2]) == 'true' or string.lower(args[2]) == 'on' then
        botconfig.config.melee.offtank = true
    elseif string.lower(args[2]) == 'false' or string.lower(args[2]) == 'off' then
        botconfig.config.melee.offtank = false
    else
        printf(
            '\ayCZBot:\ax%s is an invalid value for offtank, please use true, on, false, off, or leave it blank to toggle',
            args[2])
        return false
    end
    printf('\ayCZBot:\axSetting offtank to %s', botconfig.config.melee.offtank)
end

-- Cast by alias (section: heal, buff, debuff, cure)
local function cmd_cast(args)
    if not args[2] then return end
    local tgtSpawn = args[3] and mq.TLO.Spawn(args[3]) or mq.TLO.Target()
    if not tgtSpawn then return end
    local tgtID = tgtSpawn.ID()
    local tgtName = tgtSpawn.CleanName()
    local function do_spell_section(cfgkey, loadfn, settingkey)
        local cnt = botconfig.getSpellCount(cfgkey)
        if not cnt or cnt <= 0 then return end
        for i = 1, cnt do
            local entry = botconfig.getSpellEntry(cfgkey, i)
            if not entry then return end
            for value in tostring(entry.alias or ''):gmatch("[^|]+") do
                if value == args[2] and (args[3] ~= 'on' and args[3] ~= 'off') then
                    printf('\ayCZBot:\ax\agCasting\ax %s on %s', entry.spell, tgtName)
                    if cfgkey == 'debuff' and mq.TLO.Me.CastTimeLeft() > 0 then
                        spellutils.InterruptCheck()
                        return
                    end
                    if not spellutils.CastSpell(i, tgtID, 'castcommand', cfgkey) then
                        printf('\ayCZBot:\ax\arCast command spell %s not ready!', entry.spell)
                    end
                elseif args[3] and value == args[2] then
                    if args[3] == 'on' then
                        entry.enabled = true
                        printf('\ayCZBot:\axEnabling \ag%s\ax', entry.spell)
                        if not botconfig.config.settings[settingkey] then
                            loadfn()
                            botconfig.config.settings[settingkey] = true
                        end
                    end
                    if args[3] == 'off' then
                        entry.enabled = false
                        printf('\ayCZBot:\axDisabling \ag%s\ax', entry.spell)
                    end
                end
            end
        end
    end
    do_spell_section('debuff', botdebuff.LoadDebuffConfig, 'dodebuff')
    do_spell_section('buff', botbuff.LoadBuffConfig, 'dobuff')
    do_spell_section('heal', botheal.LoadHealConfig, 'doheal')
    do_spell_section('cure', botcure.LoadCureConfig, 'docure')
end

local function cmd_setvar(args)
    local valfound = false
    local sub, key
    local value = args[3]
    local tempconfig = {}
    local temploadconfig = loadfile(botconfig.getPath())
    if args[2]:find("%.") ~= nil then
        local beforeDot, afterDot = args[2]:match("([^%.]+)%.(.+)")
        sub = beforeDot
        key = afterDot
    end
    if temploadconfig then tempconfig = temploadconfig() end
    for k, v in pairs(tempconfig) do
        if sub then
            if type(v) == "table" and k == sub then
                for k2, v2 in pairs(tempconfig[k]) do
                    if key == k2 then
                        printf('\ayCZBot:\axSetting \ag%s to \ay%s\ax', args[2], value)
                        valfound = true
                        if tonumber(value) then
                            tempconfig[k][k2] = tonumber(value)
                            botconfig.config[k][k2] = tonumber(value)
                        elseif value == "true" then
                            tempconfig[k][k2] = true
                            botconfig.config[k][k2] = true
                        elseif value == "false" then
                            tempconfig[k][k2] = false
                            botconfig.config[k][k2] = false
                        else
                            tempconfig[k][k2] = value
                            botconfig.config[k][k2] = value
                        end
                        botconfig.WriteToFile(tempconfig, botconfig.getPath())
                        botconfig.RunConfigLoaders()
                    end
                end
            end
        else
            if type(v) == "table" then
                for k2, v2 in pairs(tempconfig[k]) do
                    if args[2] == k2 then
                        printf('\ayCZBot:\axSetting \ag%s to \ay%s\ax', args[2], value)
                        valfound = true
                        if tonumber(value) then
                            tempconfig[k][k2] = tonumber(value)
                            botconfig.config[k][k2] = tonumber(value)
                        elseif value == "true" then
                            tempconfig[k][k2] = true
                            botconfig.config[k][k2] = true
                        elseif value == "false" then
                            tempconfig[k][k2] = false
                            botconfig.config[k][k2] = false
                        else
                            tempconfig[k][k2] = value
                            botconfig.config[k][k2] = value
                        end
                        botconfig.WriteToFile(tempconfig, botconfig.getPath())
                        botconfig.RunConfigLoaders()
                    end
                end
            end
        end
    end
    if state.getRunconfig().doChchain then
        botconfig.config.settings.dodebuff = false
        botconfig.config.settings.dobuff = false
        botconfig.config.settings.domelee = false
        botconfig.config.settings.doheal = false
        botconfig.config.settings.docure = false
        state.getRunconfig().dopull = false
    end
    if not valfound then printf('\ayCZBot:\ax\ar%s not found', args[2]) end
end

local function copyEntry(src)
    if not src then return nil end
    local t = {}
    for k, v in pairs(src) do t[k] = v end
    return t
end

local function cmd_addspell(args)
    local sub = args[2]
    local key = tonumber(args[3])
    local sublist = { "heal", "cure", "buff", "debuff" }
    local subfound = false
    for _, word in ipairs(sublist) do
        if word == sub then
            subfound = true; break
        end
    end
    if not subfound then
        printf('\ayCZBot:\ax%s is not a valid CZBot sub please use heal, buff, debuff, or cure', sub)
        return false
    end
    local currentCount = botconfig.getSpellCount(sub)
    if not key or key < 1 or key > currentCount + 1 then
        printf('\ayCZBot:\ax%s is not a valid position for %s (use 1 to %s)', args[3], sub, currentCount + 1)
        return false
    end
    local temploadconfig = loadfile(botconfig.getPath())
    local tempconfig = (temploadconfig and temploadconfig()) or {}
    if not tempconfig[sub] then tempconfig[sub] = {} end
    if not tempconfig[sub].spells then tempconfig[sub].spells = {} end
    local newEntry = botconfig.getDefaultSpellEntry(sub)
    table.insert(tempconfig[sub].spells, key, newEntry)
    botconfig.WriteToFile(tempconfig, botconfig.getPath())
    botconfig.Load(botconfig.getPath())
    botconfig.RunConfigLoaders()
    if sub == 'heal' then botheal.LoadHealConfig() end
    if sub == 'buff' then botbuff.LoadBuffConfig() end
    if sub == 'debuff' then botdebuff.LoadDebuffConfig() end
    if sub == 'cure' then botcure.LoadCureConfig() end
    printf('\ayCZBot:\axadded new %s entry at position %s', sub, key)
end


local function cmd_refresh(args)
    spellutils.RefreshSpells()
end

local function cmd_echo(args)
    if not args[2] then return end
    local sub, key
    if args[2]:find("%.") ~= nil then
        local beforeDot, afterDot = args[2]:match("([^%.]+)%.(.+)")
        sub = beforeDot
        key = afterDot
    end
    if sub and key and botconfig.config[sub] and botconfig.config[sub][key] ~= nil then
        printf('\ayCZBot:\ax\ag%s\ax is set as \ay%s\ay', args[2], botconfig.config[sub][key])
    else
        printf('\ayCZBot:\ax\ar%s\ar is not a valid CZBot value', args[2])
    end
end

local function cmd_clickdoor()
    mq.cmd('/doortarget')
    mq.delay(500)
    mq.cmd('/click left door')
end

local function cmd_saytarget(args, str)
    local id = args[2] and tonumber(args[2])
    local message
    if args[3] then
        message = table.concat(args, ' ', 3)
    elseif str then
        message = str:match('saytarget%s+%S+%s+(.+)')
    end
    if not id or id == 0 or not message or message == '' then
        printf('\ayCZBot:\ax usage: /cz saytarget <spawnId> <message>')
        return
    end
    if not targeting.TargetAndWait(id, 500) then
        printf('\ayCZBot:\ax failed to target spawn id %s', id)
        return
    end
    mq.cmdf('/say %s', message)
end

-- CHChain: stop, setup, start, tank, pause
local function cmd_chchain(args)
    local rc = state.getRunconfig()
    if args[2] == 'stop' and rc.doChchain then
        rc.doChchain = false
        printf('\ayCZBot:\ax\arDisabling\ax CHChain')
        mq.cmd('/rs CHCHain OFF')
        if state.getRunconfig().PreCH['dodebuff'] then
            botconfig.config.settings.dodebuff = state.getRunconfig().PreCH
                ['dodebuff']
        end
        if state.getRunconfig().PreCH['dobuff'] then
            botconfig.config.settings.dobuff = state.getRunconfig().PreCH
                ['dobuff']
        end
        if state.getRunconfig().PreCH['domelee'] then
            botconfig.config.settings.domelee = state.getRunconfig().PreCH
                ['domelee']
        end
        if state.getRunconfig().PreCH['doheal'] then
            botconfig.config.settings.doheal = state.getRunconfig().PreCH
                ['doheal']
        end
        if state.getRunconfig().PreCH['dopull'] then
            state.getRunconfig().dopull = state.getRunconfig().PreCH['dopull']
        end
        if state.getRunconfig().PreCH['docure'] then
            botconfig.config.settings.docure = state.getRunconfig().PreCH
                ['docure']
        end
    end
    if args[2] == 'setup' then
        local spell = 'complete heal'
        if not rc.doChchain then
            state.getRunconfig().PreCH = utils.DeepCopy(botconfig.config.settings)
            state.getRunconfig().PreCH.dopull = state.getRunconfig().dopull
        end
        local tmpchchainlist = args[3]
        local aminlist = false
        local meName = mq.TLO.Me.Name()
        if not meName then return false end
        for v in string.gmatch(tmpchchainlist, "([^,]+)") do
            if string.lower(v) == string.lower(meName) then aminlist = true end
        end
        if not aminlist then return false end
        if not mq.TLO.Me.Book(spell)() then
            printf('\ayCZBot:\axCZBot CHChain: Spell %s not found in your book, failed to start CHChain', spell)
            return false
        end
        M.chchainSetupContinuation({ args[3], args[4], args[5] })
    end
    if args[2] == 'start' then
        if args[3] == mq.TLO.Me.Name() then chchain.OnGo('start', mq.TLO.Me.Name()) end
    end
    if args[2] == 'tank' then
        if mq.TLO.Spawn('=' .. args[3]) then
            rc.chchainTank = args[3]
            rc.chchainTanklist = {}
        end
        mq.cmdf('/rs CHChain tank: %s', rc.chchainTank)
    end
    if args[2] == 'pause' then
        if args[3] then rc.chchainPause = args[3] end
        mq.cmdf('/rs CHChain pause: %s', rc.chchainPause)
    end
end

local function cmd_draghack(args)
    if args[2] then
        if args[2] == 'on' then state.getRunconfig().DragHack = true end
        if args[2] == 'off' then state.getRunconfig().DragHack = false end
    elseif not args[2] then
        if state.getRunconfig().DragHack then state.getRunconfig().DragHack = false else state.getRunconfig().DragHack = true end
    end
    printf('\ayCZBot:\axSet DragHack to %s', state.getRunconfig().DragHack)
end

local function cmd_linkitem(args)
    botevents.Event_LinkItem(args[1], args[2], args[3])
end

local function cmd_linkaugs(args)
    local itemslot = tonumber(mq.TLO.InvSlot(args[2])())
    local itemlink = mq.TLO.InvSlot(args[2]).Item.ItemLink('CLICKABLE')()
    if itemslot then
        local augstring = nil
        local augslots = tonumber(mq.TLO.InvSlot(itemslot).Item.Augs())
        for i = 1, augslots do
            local aug = mq.TLO.InvSlot(itemslot).Item.AugSlot(i)()
            local auglink = mq.TLO.FindItem(aug).ItemLink('CLICKABLE')()
            if aug and augstring then
                augstring = augstring .. " , " .. auglink
            elseif aug then
                augstring = auglink
            end
        end
        if augstring then
            printf('\ayCZBot:\ax\ag%s\ax in slot \ay%s\ax augs: %s', itemlink, args[2], augstring)
        else
            printf('\ayCZBot:\ax\arI have no augment in %s', itemlink)
        end
    end
end

local function cmd_spread(args)
    local peers = charinfo.GetPeers()
    local myname = mq.TLO.Me.Name()
    local startX = mq.TLO.Me.X()
    local startY = mq.TLO.Me.Y()
    local heading = mq.TLO.Me.Heading.Degrees()
    local slot = 0
    for _, bot in ipairs(peers) do
        if bot == myname then
            -- skip self; we stay in place and only run the face command
        else
            slot = slot + 1
            local xiter = startX + ((slot - 1) % 6 + 1) * 5
            local yiter = startY + math.floor((slot - 1) / 6) * 5
            mq.cmdf('/rc %s /nav locxy %s %s', bot, xiter, yiter)
        end
    end
    mq.cmd('/face fast heading ' .. heading)
    mq.cmdf('/rc zone /face fast heading %s', heading)
end

local function getApplicableNukeFlavors()
    local count = botconfig.getSpellCount('debuff')
    local out = {}
    for i = 1, count do
        local entry = botconfig.getSpellEntry('debuff', i)
        if entry and spellutils.IsNukeSpell(entry) then
            local f = spellutils.GetNukeFlavor(entry)
            if f then out[f] = true end
        end
    end
    return out
end

local function cmd_togglenuke(args)
    local raw = args[2] and tostring(args[2]) or ''
    local flavorArg = string.lower(raw:match('^%s*(.-)%s*$') or '')
    if flavorArg == '' then
        printf(
            '\ayCZBot:\ax Usage: /cz togglenuke <flavor> [on|off]. Flavors: fire, ice, magic, poison, disease (and cold=ice).')
        return
    end
    local flavor = (flavorArg == 'cold') and 'ice' or flavorArg
    local applicable = getApplicableNukeFlavors()
    if not applicable[flavor] then
        printf('\ayCZBot:\ax No nuke with flavor \ar%s\ax in debuff list. Use a flavor from your configured nukes.',
            flavor)
        return
    end
    local force = args[3] and string.lower(args[3])
    local rc = state.getRunconfig()
    local function setOff()
        if not rc.nukeFlavorsAllowed then
            rc.nukeFlavorsAllowed = {}
            for f in pairs(applicable) do rc.nukeFlavorsAllowed[f] = true end
        end
        rc.nukeFlavorsAllowed[flavor] = nil
    end
    local function setOn()
        if rc.nukeFlavorsAutoDisabled then rc.nukeFlavorsAutoDisabled[flavor] = nil end
        if rc.nukeFlavorsAllowed then rc.nukeFlavorsAllowed[flavor] = true end
    end
    if force == 'off' then
        setOff()
        printf('\ayCZBot:\ax Nuke flavor \ar%s\ax turned off.', flavor)
    elseif force == 'on' then
        setOn()
        printf('\ayCZBot:\ax Nuke flavor \ag%s\ax turned on.', flavor)
    else
        local allowed = (not rc.nukeFlavorsAutoDisabled or not rc.nukeFlavorsAutoDisabled[flavor])
            and (not rc.nukeFlavorsAllowed or rc.nukeFlavorsAllowed[flavor])
        if allowed then
            setOff(); printf('\ayCZBot:\ax Nuke flavor \ar%s\ax turned off.', flavor)
        else
            setOn(); printf('\ayCZBot:\ax Nuke flavor \ag%s\ax turned on.', flavor)
        end
    end
    rc.nukeResistDisabledRecent = nil
    botconfig.saveNukeFlavorsToCommon()
end

local function cmd_raid(args)
    local sub = args[2] and string.lower(args[2])
    if sub == 'save' then
        if not args[3] or args[3] == '' then
            printf('\ayCZBot:\ax Noname given, cant save raid (/cz raid save raidname)')
            return
        end
        groupmanager.SaveRaid(args[3])
    elseif sub == 'load' then
        if not args[3] or args[3] == '' then
            print('no raid name giving /cz raid load raidname') -- this is a real error message but needs to be reformatted
            return
        end
        groupmanager.LoadRaid(args[3])
    end
end

-- Handler table: command name -> function(args, str).
-- Handlers receive (args, str); str only used by stickcmd.
local handlers = {
    import = cmd_import,
    export = cmd_export,
    debug = cmd_debug,
    ui = cmd_ui,
    show = cmd_ui,
    makecamp = cmd_makecamp,
    follow = cmd_follow,
    travel = cmd_travel,
    stop = cmd_stop,
    exclude = cmd_exclude,
    fte = cmd_fte,
    xarc = cmd_xarc,
    priority = cmd_priority,
    charm = cmd_charm,
    reloadcommon = cmd_reloadcommon,
    reloadczcommon = cmd_reloadcommon,
    abort = cmd_abort,
    leash = cmd_leash,
    attack = cmd_attack,
    tank = cmd_tank,
    assist = cmd_assist,
    stickcmd = cmd_stickcmd,
    acleash = cmd_acleash,
    camprestdistance = cmd_camprestdistance,
    targetfilter = cmd_targetfilter,
    offtank = cmd_offtank,
    cast = cmd_cast,
    setvar = cmd_setvar,
    addspell = cmd_addspell,
    refresh = cmd_refresh,
    refreshspells = cmd_refresh,
    echo = cmd_echo,
    clickdoor = cmd_clickdoor,
    saytarget = cmd_saytarget,
    chchain = cmd_chchain,
    draghack = cmd_draghack,
    linkitem = cmd_linkitem,
    linkaugs = cmd_linkaugs,
    spread = cmd_spread,
    raid = cmd_raid,
    togglenuke = cmd_togglenuke,
    addjunk = cmd_addjunk,
    foragezone = cmd_foragezone,
    quit = cmd_quit,
}

-- Register toggle commands (same handler for all togglelist keys)
for k in pairs(TOGGLELIST) do
    handlers[k] = cmd_toggle
end

for cmd, fn in pairs(handlers) do
    command_dispatcher.RegisterCommand(cmd, fn)
end

-- Entry points for makecamp/follow (callable without going through the parser)
function M.MakeCamp(mode)
    botmove.MakeCamp(mode)
end

function M.Follow(tankName)
    if tankName then cmd_follow({ 'follow', tankName }, '') end
end

function M.Travel(tankName)
    if tankName then cmd_travel({ 'travel', tankName }, '') end
end

function M.Parse(...)
    local args = { ... }
    local str = ''
    for i = 1, #args, 1 do
        if i > 1 then str = str .. ' ' end
        str = str .. args[i]
    end
    if TOGGLELIST[args[1]] then
        cmd_toggle(args)
        return
    end

    command_dispatcher.Dispatch(args[1], unpack(args, 2))
end

M.czpause = state.czpause

--- Called to finish CHChain setup. setupArgs = { chchainlist, chchainpause, tanklist }.
function M.chchainSetupContinuation(setupArgs)
    if not setupArgs or not setupArgs[1] then return end
    local rc = state.getRunconfig()
    rc.chchainList = setupArgs[1]
    rc.chnextClr = nil
    local clericlisttbl = {}
    local meName = mq.TLO.Me.Name()
    if not meName then return false end
    for v in string.gmatch(rc.chchainList, "([^,]+)") do
        table.insert(clericlisttbl, v)
        if rc.chnextClr then
            rc.chnextClr = v
            break
        end
        if string.lower(v) == string.lower(meName) then
            rc.doChchain = true
            rc.chnextClr = true
        end
    end
    if rc.chnextClr == true then rc.chnextClr = clericlisttbl[1] end
    if rc.doChchain then
        rc.chchainPause = setupArgs[2]
        rc.chchainTanklist = {}
        if setupArgs[3] then
            for v in string.gmatch(setupArgs[3], "([^,]+)") do
                local vtrim = v:sub(-1) == "'" and v:sub(1, -2) or v
                if mq.TLO.Spawn('=' .. vtrim).Type() == 'PC' then
                    table.insert(rc.chchainTanklist, vtrim)
                    print('adding ' .. vtrim .. ' to tank list')
                end
            end
        end
        rc.chchainTank = rc.chchainTanklist[1]
        local chtankstr = table.concat(rc.chchainTanklist, ",")
        botconfig.config.settings.dodebuff = false
        botconfig.config.settings.dobuff = false
        botconfig.config.settings.domelee = false
        botconfig.config.settings.doheal = false
        botconfig.config.settings.docure = false
        state.getRunconfig().dopull = false
        mq.cmdf('/rs CHChain ON (NextClr: %s, Pause: %s, Tank: %s)', rc.chnextClr, rc.chchainPause, chtankstr)
    end
end

mq.bind('/cz', M.Parse)
mq.bind('/czshow', botgui.UIEnable)
mq.bind('/czp', M.czpause)
mq.bind('/czquit', function() state.getRunconfig().terminate = true end)

return M
