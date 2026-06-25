-- Status tab: status line, Camp section, and doXXX flag On/Off buttons.

local ImGui = require('ImGui')
local mq = require('mq')
local Icons = require('mq.ICONS')
local botconfig = require('lib.config')
local botmove = require('botmove')
local state = require('lib.state')
local follow = require('lib.follow')
local utils = require('lib.utils')
local spellutils = require('lib.spellutils')
local tankrole = require('lib.tankrole')
local spawnutils = require('lib.spawnutils')
local bardtwist = require('lib.bardtwist')
local botpull = require('botpull')
local inputs = require('gui.widgets.inputs')
local combos = require('gui.widgets.combos')
local labeled_grid = require('gui.widgets.labeled_grid')
local modals = require('gui.widgets.modals')
local field_label = require('gui.widgets.field_label')
local spellupgrade = require('lib.spellupgrade')

local M = {}

-- Validators for mount spell/item (same logic as spell_entry: spellbook / inventory).
local function validateSpellInBook(name)
    if not name or name:match('^%s*$') then return false, 'Enter a spell name' end
    name = name:match('^%s*(.-)%s*$')
    local book = mq.TLO.Me and mq.TLO.Me.Book and mq.TLO.Me.Book(name)
    if not book then return false, 'Spell not in your spell book' end
    local ok, slot = pcall(function() return book() end)
    if ok and slot and slot > 0 then return true end
    return false, 'Spell not in your spell book'
end

local function validateFindItem(name)
    if not name or name:match('^%s*$') then return false, 'Enter an item name' end
    name = name:match('^%s*(.-)%s*$')
    -- FindItem(name)() returns the item NAME (a string), so compare the ID (a number) instead.
    local ok, id = pcall(function() return mq.TLO.FindItem(name).ID() end)
    if ok and id and id > 0 then return true end
    return false, 'Item not found in inventory'
end

local MOUNT_MODAL_ID = 'status_mount'
local _mountModalState = nil
-- Session-held mount type (Spell/Item) so the type can be chosen BEFORE a name is entered. Without this,
-- mountcast="none" carries no type, so picking "Item" with no name was discarded (dropdown snapped back to
-- Spell) and the name editor validated against the spellbook instead of inventory. Cleared once a name saves.
local _mountTypeSel = nil

local function getMountModalState()
    if not _mountModalState then
        _mountModalState = { open = false, buffer = '', error = nil }
    end
    return _mountModalState
end

local function runConfigLoaders()
    botconfig.ApplyAndPersist()
end

local theme = require('gui.widgets.theme')
local toggle = require('gui.widgets.toggle')
local YELLOW, RED, GREEN, BLACK, WHITE, LIGHT_GREY, TABLE_BORDER_BLUE =
    theme.YELLOW, theme.RED, theme.GREEN, theme.BLACK, theme.WHITE, theme.LIGHT_GREY, theme.TABLE_BORDER_BLUE

local FLAGS_COLUMN_WIDTH = 65
local FLAGS_ROW_PADDING_Y = 2
local FLAGS_PANEL_WIDTH = 145
local NUMERIC_INPUT_WIDTH = theme.WIDTHS.numeric

local DO_FLAGS = {
    { key = 'dopull',   label = 'Pull',   tt = 'Pull mobs to camp. Leave OFF if you use a separate puller.' },
    { key = 'dodebuff', label = 'Debuff', tt = 'Cast debuffs, mez, nukes, DoTs and combat abilities (Debuff tab).' },
    { key = 'doheal',   label = 'Heal',   tt = 'Heal group/raid members and self (Heal tab).' },
    { key = 'dobuff',   label = 'Buff',   tt = 'Keep buffs up on self/group/pets (Buff tab).' },
    { key = 'docure',   label = 'Cure',   tt = 'Cure detrimentals: poison/disease/curse/corruption (Cure tab).' },
    { key = 'domelee',  label = 'Melee',  tt = 'Engage and melee targets.' },
    { key = 'doraid',   label = 'Raid',   tt = 'Run raid-mechanic scripts for the current zone.' },
    { key = 'dodrag',   label = 'Drag',   tt = 'Drag corpses back to camp.' },
    { key = 'domount',  label = 'Mount',  tt = 'Summon/use a mount when traveling.' },
    { key = 'dosit',    label = 'Sit',    tt = 'Sit to recover mana/endurance when idle and safe.' },
    { key = 'doforage', label = 'Forage', tt = 'Use the Forage skill periodically.' },
}

local SONGS_FLAG = { key = 'dosongs', label = 'Songs', tt = 'Bard: keep the song twist running.' }

local function hasForageAbility()
    local ok, v = pcall(function()
        local ab = mq.TLO.Me.Ability and mq.TLO.Me.Ability('Forage')
        if not ab then return nil end
        return ab()
    end)
    return ok and v ~= nil and (type(v) == 'number' and v > 0 or v == true)
end

local STATE_NUM_TO_LABEL = {
    [state.STATES.dead] = 'Dead',
    [state.STATES.pulling] = 'Pulling',
    [state.STATES.camp_return] = 'Returning to camp',
    [state.STATES.melee] = 'Melee',
    [state.STATES.engage_return_follow] = 'Returning to follow',
    [state.STATES.chchain] = 'CH chain',
    [state.STATES.dragging] = 'Dragging corpse',
    [state.STATES.unstuck] = 'Unstuck',
    [state.STATES.raid_mechanic] = 'Raid mechanic',
    [state.STATES.sumcorpse_pending] = 'Sum corpse',
    [state.STATES.resume_doHeal] = 'Resuming heals',
    [state.STATES.resume_doDebuff] = 'Resuming debuffs',
    [state.STATES.resume_doBuff] = 'Resuming buffs',
    [state.STATES.resume_doCure] = 'Resuming cures',
    [state.STATES.resume_priorityCure] = 'Resuming priority cure',
}

-- Status messages that are just the idle subsystem-check cycle (noise for the detail line/activity log).
local IDLE_NOISE = {
    [''] = true, ['Buff Check'] = true, ['Heal Check'] = true,
    ['Cure Check'] = true, ['Debuff Check'] = true,
}
local ACTIVITY_MAX = 8           -- recent-activity entries kept
local ACTIVITY_RECENT_SECS = 20  -- how long a finished action lingers on the header detail line
local _activity = {}             -- ring buffer { {msg=..., t=...}, ... } oldest-first
local _lastActivityMsg = nil

local EXIT_MODAL_ID = 'status_exit'
local _exitConfirm = { open = false, pendingClose = nil }

-- Steady, flicker-free high-level state: run-state + camp/follow context. Ignores the rapid
-- statusMessage "X Check" cycle so the header line doesn't blink.
local function getSteadyStateLabel()
    local rc = state.getRunconfig()
    if rc.pullHealerManaWait and rc.pullHealerManaWait.name then return 'Pull: waiting on healer mana' end
    if rc.pullDebuffWait and rc.pullDebuffWait.name then return 'Pull: waiting on debuff' end
    local runState = state.getRunState()
    if runState == state.STATES.casting then return 'Casting' end
    local label = STATE_NUM_TO_LABEL[runState]
    if label then
        if runState == state.STATES.dragging then
            local p = state.getRunStatePayload()
            if p and p.phase then return 'Dragging corpse (' .. p.phase .. ')' end
        end
        return label
    end
    if rc.campstatus then return 'Idle at camp' end
    if rc.followid and rc.followid > 0 then
        if rc.travelMode then
            local name = (rc.followname and rc.followname ~= '') and rc.followname or '—'
            return 'Travel (following ' .. name .. ')'
        end
        return 'Following'
    end
    return 'Idle'
end

-- The detailed action the bot is doing right now (Casting/Pulling/Tanking/waiting/...), or nil when
-- it's only running the idle subsystem-check cycle.
local function currentDetail()
    local rc = state.getRunconfig()
    if rc.pullHealerManaWait and rc.pullHealerManaWait.name then
        local w = rc.pullHealerManaWait
        if w.current ~= nil then
            return string.format("Waiting on %s's mana (%d%% <= %d%%)", w.name, w.current, w.pct)
        end
        return string.format("Waiting on %s's mana (must be > %d%%)", w.name, w.pct)
    end
    if rc.pullDebuffWait and rc.pullDebuffWait.name then
        return string.format('Waiting: non-curable debuff (%s)', rc.pullDebuffWait.name)
    end
    local m = rc.statusMessage
    if m and not IDLE_NOISE[m] then return m end
    return nil
end

-- Record the current action into the recent-activity ring buffer (called each frame by drawControls).
-- Consecutive duplicates are collapsed; resets between actions so a repeated action logs again.
local function sampleActivity()
    local cur = currentDetail()
    if cur then
        if cur ~= _lastActivityMsg then
            _lastActivityMsg = cur
            _activity[#_activity + 1] = { msg = cur, t = mq.gettime() }
            while #_activity > ACTIVITY_MAX do table.remove(_activity, 1) end
        end
    else
        _lastActivityMsg = nil
    end
end

-- Status line + Pause/Exit buttons. Rendered as a persistent header (above the tab bar by botgui)
-- so the controls and current status are visible from every tab, not just Status.
function M.drawControls()
    sampleActivity()
    ImGui.TextColored(YELLOW, '%s', getSteadyStateLabel())
    ImGui.SameLine()
    -- Burn button: start/stop a burn window. Spells/abilities with a `burn` precondition fire during it.
    do
        local burnActive = state.IsBurnActive()
        ImGui.PushStyleColor(ImGuiCol.Button, BLACK)
        ImGui.PushStyleColor(ImGuiCol.Text, burnActive and RED or LIGHT_GREY)
        local burnLabel = burnActive and string.format('Burn %ds', math.ceil(state.BurnRemainingMs() / 1000)) or 'Burn'
        if ImGui.SmallButton(burnLabel .. '##burn') then
            if burnActive then state.ClearBurn() else state.SetBurn() end
        end
        ImGui.PopStyleColor(2)
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip(
                'Start/stop a burn window. Spells & abilities with a `burn` precondition (e.g. precondition "return burn") fire while it is active.\nCommand: /cz burn [seconds] | off.')
        end
        ImGui.SameLine()
    end
    local style = ImGui.GetStyle()
    local isPaused = (_G.MasterPause == true)
    local pauseLabel = isPaused and 'Resume' or 'Pause'
    local pauseLabelW = math.max(
        (select(1, ImGui.CalcTextSize('Pause')) or 0),
        (select(1, ImGui.CalcTextSize('Resume')) or 0)
    )
    local pauseIconW = (select(1, ImGui.CalcTextSize(Icons.FA_PAUSE_CIRCLE)) or 0) + style.FramePadding.x * 2
    local exitLabelW = (select(1, ImGui.CalcTextSize('Exit')) or 0)
    local exitIconW = (select(1, ImGui.CalcTextSize(Icons.FA_POWER_OFF)) or 0) + style.FramePadding.x * 2
    local buttonsTotalW = pauseLabelW + style.ItemSpacing.x + pauseIconW + style.ItemSpacing.x + exitLabelW +
    style.ItemSpacing.x + exitIconW
    local avail = ImGui.GetContentRegionAvail()
    if avail > 0 then
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() + avail - buttonsTotalW)
    end
    ImGui.Text('%s', pauseLabel)
    ImGui.SameLine()
    ImGui.PushStyleColor(ImGuiCol.Button, BLACK)
    ImGui.PushStyleColor(ImGuiCol.Text, YELLOW)
    if ImGui.SmallButton(Icons.FA_PAUSE_CIRCLE .. '##pause') then
        state.czpause()
    end
    if ImGui.IsItemHovered() then ImGui.SetTooltip(isPaused and 'Resume bobblebot' or 'Pause bobblebot') end
    ImGui.PopStyleColor(2)
    ImGui.SameLine()
    ImGui.Text('%s', 'Exit')
    ImGui.SameLine()
    ImGui.PushStyleColor(ImGuiCol.Button, BLACK)
    ImGui.PushStyleColor(ImGuiCol.Text, RED)
    if ImGui.SmallButton(Icons.FA_POWER_OFF .. '##exit') then
        _exitConfirm.open = true
        _exitConfirm.pendingClose = nil
        modals.openConfirmModal(EXIT_MODAL_ID)
    end
    if ImGui.IsItemHovered() then ImGui.SetTooltip('%s', 'Exit: stop bobblebot (ends the Lua script).') end
    ImGui.PopStyleColor(2)
    modals.confirmModal(EXIT_MODAL_ID, _exitConfirm, {
        message = 'Exit bobblebot? This ends the Lua script.',
        confirmLabel = 'Exit',
        cancelLabel = 'Cancel',
        danger = true,
    }, function()
        state.getRunconfig().terminate = true
    end)

    -- Second line: the current detailed action (white), or the last action (grey, with elapsed) so a
    -- finished action lingers briefly instead of the line blinking back to idle.
    local detail = currentDetail()
    if detail then
        ImGui.TextColored(WHITE, '%s', detail)
    else
        local last = _activity[#_activity]
        local ago = last and math.floor((mq.gettime() - last.t) / 1000) or nil
        if last and ago <= ACTIVITY_RECENT_SECS then
            ImGui.TextColored(LIGHT_GREY, 'last: %s (%ds ago)', last.msg, ago)
        else
            ImGui.TextColored(LIGHT_GREY, '%s', 'monitoring...')
        end
    end
end

-- Read-only Bard twist panel: shows the live per-mode twist lists (gem:song, in order) so what the bot
-- will twist is visible without reverse-engineering the Buff/Debuff flags. Order = Buff/Debuff entry
-- order; see lib/bardtwist.lua. Bard-only; collapsed by default.
local TWIST_MODES = {
    { mode = 'idle',   label = 'Idle' },
    { mode = 'combat', label = 'Combat' },
    { mode = 'travel', label = 'Travel' },
    { mode = 'pull',   label = 'Pull' },
}

local function twistGemLabel(gem)
    if gem >= 1 and gem <= 12 then
        local name = mq.TLO.Me.Gem(gem)()
        return string.format('%d:%s', gem, (name and name ~= '') and name or 'empty')
    end
    return string.format('%d:clicky', gem) -- 21-29 = MQ2Twist clicky slots
end

local function twistListText(gems)
    if not gems or #gems == 0 then return '(none)' end
    local parts = {}
    for _, g in ipairs(gems) do parts[#parts + 1] = twistGemLabel(g) end
    return table.concat(parts, '  ')
end

local function safeTwistList(mode)
    -- GetTwistListForMode('combat') reaches into the debuff eval (MatarDebuffNeededForTwist); isolate
    -- any failure so one mode can't break the panel.
    local ok, list = pcall(bardtwist.GetTwistListForMode, mode)
    if ok and type(list) == 'table' then return list end
    return nil
end

local function drawBardTwistSection()
    if not bardtwist.IsBard() then return end
    ImGui.Spacing()
    if not ImGui.CollapsingHeader('Bard twist') then return end
    -- Read-only info panel: it must never crash the GUI. The body has no Begin/End, so wrapping it in
    -- pcall leaves the ImGui stack balanced even on error; surface the error instead of dying.
    local ok, err = pcall(function()
        local curMode = bardtwist.GetCurrentTwistMode()
        local songsOn = bardtwist.SongsEnabled()
        ImGui.TextColored(WHITE, '%s', 'Songs: ')
        ImGui.SameLine(0, 2)
        ImGui.TextColored(songsOn and GREEN or RED, '%s', songsOn and 'On' or 'Off')
        ImGui.SameLine()
        ImGui.TextColored(WHITE, '%s', '  Current mode: ')
        ImGui.SameLine(0, 2)
        ImGui.TextColored(YELLOW, '%s', curMode or 'idle')
        for _, m in ipairs(TWIST_MODES) do
            local isCur = (m.mode == curMode)
            ImGui.TextColored(isCur and YELLOW or LIGHT_GREY, '%s', (isCur and '> ' or '  ') .. m.label .. ':')
            ImGui.SameLine(0, 4)
            ImGui.TextColored(isCur and WHITE or LIGHT_GREY, '%s', twistListText(safeTwistList(m.mode)))
        end
        local liveOk, liveRaw = pcall(function() return mq.TLO.Twist() and mq.TLO.Twist.List() end)
        if liveOk and liveRaw and tostring(liveRaw) ~= '' then
            ImGui.TextColored(WHITE, '%s', 'Now twisting: ')
            ImGui.SameLine(0, 2)
            ImGui.TextColored(LIGHT_GREY, '%s', tostring(liveRaw))
        end
    end)
    if not ok then
        ImGui.TextColored(RED, '%s', 'Twist info unavailable: ' .. tostring(err))
    end
end

-- Read-only "players nearby (out of group)" panel: PCs not in your group, nearest first, with distance
-- + class. Rebuilt on a throttle so it doesn't scan every frame. Like ezpullnav's PC monitor.
local _nearbyPlayers = {}
local _nearbyPlayersNextScan = 0
local NEARBY_SCAN_INTERVAL_MS = 1000
local NEARBY_MAX = 40

local function rescanNearbyPlayers()
    local out = {}
    local meId = mq.TLO.Me.ID()
    local count = tonumber(mq.TLO.SpawnCount('pc')()) or 0
    if count > 200 then count = 200 end
    for i = 1, count do
        local sp = mq.TLO.NearestSpawn(i, 'pc') -- nearest-first, so `out` ends up distance-sorted
        local id = sp and sp.ID()
        if id and id > 0 and id ~= meId then
            local name = sp.CleanName() or sp.Name()
            if name and not mq.TLO.Group.Member(name).Index() then
                local dist = (sp.Distance3D and sp.Distance3D()) or (sp.Distance and sp.Distance()) or 0
                local cls = (sp.Class and sp.Class.ShortName()) or '?'
                local lvl = (sp.Level and tonumber(sp.Level())) or 0
                local guild = (sp.Guild and sp.Guild()) or ''
                out[#out + 1] = { name = name, dist = dist, class = cls, level = lvl, guild = guild }
                if #out >= NEARBY_MAX then break end
            end
        end
    end
    _nearbyPlayers = out
end

local function drawNearbyPlayersSection()
    ImGui.Spacing()
    if not ImGui.CollapsingHeader('Players nearby (out of group)') then return end
    if mq.gettime() >= _nearbyPlayersNextScan then
        if not pcall(rescanNearbyPlayers) then _nearbyPlayers = {} end
        _nearbyPlayersNextScan = mq.gettime() + NEARBY_SCAN_INTERVAL_MS
    end
    if #_nearbyPlayers == 0 then
        ImGui.TextColored(LIGHT_GREY, '%s', '  (no out-of-group players in zone)')
        return
    end
    for _, p in ipairs(_nearbyPlayers) do
        local guildStr = (p.guild and p.guild ~= '') and ('  <' .. p.guild .. '>') or ''
        ImGui.TextColored(LIGHT_GREY, '  %5.0f  %s (%s %d)%s', p.dist or 0, p.name, p.class or '?', p.level or 0, guildStr)
    end
end

-- Spell upgrades: prompt to swap a configured spell for a better in-book version (Option C), and a button
-- to scribe upgrade scrolls from bags (Option A). The header turns yellow + shows a count when upgrades
-- are pending. Reads the cached list (populated by the background scan) -- no per-frame book scan.
local function drawSpellUpgradesSection()
    local pending = spellupgrade.getPending()
    local n = #pending
    local label = (n > 0) and string.format('Spell upgrades available (%d)###spellupg', n)
        or 'Spell upgrades###spellupg'
    if n > 0 then ImGui.PushStyleColor(ImGuiCol.Text, YELLOW) end
    local open = ImGui.CollapsingHeader(label)
    if n > 0 then ImGui.PopStyleColor(1) end
    if not open then return end

    -- Scribe routes through /cz scribe so the blocking routine runs in the main loop, not the render pass.
    if ImGui.SmallButton('Scribe scrolls##upg_scribe') then mq.cmd('/cz scribe') end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Scribe usable spell scrolls from your bags (out of combat), then re-check for upgrades.')
    end
    ImGui.SameLine()
    if ImGui.SmallButton('Re-scan##upg_rescan') then pcall(spellupgrade.scan) end
    if n > 0 then
        ImGui.SameLine()
        if ImGui.SmallButton('Apply all##upg_applyall') then pcall(spellupgrade.applyAll) end
    end

    local asChecked = (botconfig.config.settings.autoScribe ~= false)
    local asVal, asPressed = ImGui.Checkbox('Auto-scribe on level-up##upg_autoscribe', asChecked)
    if asPressed then
        botconfig.config.settings.autoScribe = asVal
        botconfig.ApplyAndPersist()
    end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('When you ding, scribe newly-usable spell scrolls from your bags automatically (once out of combat).')
    end

    if n == 0 then
        ImGui.TextColored(LIGHT_GREY, '%s', '  (none detected -- Re-scan after leveling or scribing)')
        return
    end
    for i, u in ipairs(pending) do
        if ImGui.SmallButton(string.format('Apply##upg_%d', i)) then
            pcall(spellupgrade.apply, i)
            break -- list is rebuilt by apply(); stop iterating the stale list this frame
        end
        ImGui.SameLine()
        ImGui.TextColored(LIGHT_GREY, '%s: %s (L%d) -> %s (L%d)',
            u.section, u.old, u.oldLevel or 0, u.new, u.newLevel or 0)
    end
end

function M.draw()
    local style = ImGui.GetStyle()
    ImGui.Spacing()
    if ImGui.BeginTable('flags wrapper', 2, ImGuiTableFlags.None) then
        ImGui.TableSetupColumn('', ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('', ImGuiTableColumnFlags.WidthFixed, FLAGS_PANEL_WIDTH)
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        -- Assist Name and Tank Name (same row, before Follow/Camp)
        local rc = state.getRunconfig()
        local assistName = tankrole.GetAssistTargetName()
        local assistDisplay = (assistName and assistName ~= '') and assistName or '—'
        if rc.AssistName == 'automatic' then
            assistDisplay = assistDisplay .. ' (auto)'
        end
        local tankName = tankrole.GetMainTankName()
        local tankDisplay = (tankName and tankName ~= '') and tankName or '—'
        if (botconfig.config.settings.TankName or rc.TankName) == 'automatic' then
            tankDisplay = tankDisplay .. ' (auto)'
        end
        ImGui.TextColored(WHITE, '%s', 'Assist Name: ')
        ImGui.SameLine(0, 2)
        ImGui.TextColored(LIGHT_GREY, '%s', assistDisplay)
        ImGui.SameLine()
        ImGui.TextColored(WHITE, '%s', 'Tank Name: ')
        ImGui.SameLine(0, 2)
        ImGui.TextColored(LIGHT_GREY, '%s', tankDisplay)
        ImGui.Spacing()
        ImGui.PushStyleColor(ImGuiCol.TableBorderStrong, TABLE_BORDER_BLUE)
        ImGui.PushStyleColor(ImGuiCol.TableBorderLight, TABLE_BORDER_BLUE)
        if ImGui.BeginTable('follow_camp layout', 2, bit32.bor(ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner)) then
            ImGui.TableSetupColumn('', ImGuiTableColumnFlags.WidthStretch, 0)
            ImGui.TableSetupColumn('', ImGuiTableColumnFlags.WidthStretch, 0)
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            -- Follow section (save row start screen Y so Camp can align)
            local _, rowStartScreenY = ImGui.GetCursorScreenPos()
            local availX = select(1, ImGui.GetContentRegionAvail())
            local followLabel = 'Follow'
            local textW, textH = ImGui.CalcTextSize(followLabel)
            local startX = ImGui.GetCursorPosX()
            ImGui.SetCursorPosX(startX + availX / 2 - textW / 2)
            ImGui.Text('%s', followLabel)
            ImGui.SameLine()
            if rc.followid and rc.followid > 0 then
                local stopIcon = Icons.FA_STOP_CIRCLE
                local stopIconW = (select(1, ImGui.CalcTextSize(stopIcon)) or 0) + style.FramePadding.x * 2
                local followAvail = select(1, ImGui.GetContentRegionAvail())
                if followAvail > 0 then
                    ImGui.SetCursorPosX(ImGui.GetCursorPosX() + followAvail - stopIconW)
                end
                ImGui.PushStyleColor(ImGuiCol.Button, BLACK)
                ImGui.PushStyleColor(ImGuiCol.Text, RED)
                if ImGui.SmallButton(stopIcon .. '##follow_stop') then
                    follow.StopFollow('gui')
                end
                if ImGui.IsItemHovered() then ImGui.SetTooltip('Stop following') end
                ImGui.PopStyleColor(2)
            end
            ImGui.Spacing()
            ImGui.TextColored(WHITE, '%s', 'Following: ')
            ImGui.SameLine(0, 2)
            if rc.followid and rc.followid > 0 and rc.followname and rc.followname ~= '' then
                ImGui.TextColored(LIGHT_GREY, '%s', rc.followname)
            else
                ImGui.TextColored(LIGHT_GREY, '%s', 'unset')
            end
            ImGui.TextColored(WHITE, '%s', 'Distance: ')
            ImGui.SameLine(0, 2)
            ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
            local followdistanceVal = botconfig.config.settings.followdistance or 35
            local followDistNew, followDistCh = inputs.boundedInt('follow_distance', followdistanceVal, 1, 500, 5,
                '##follow_distance')
            if followDistCh then
                botconfig.config.settings.followdistance = followDistNew; runConfigLoaders()
            end
            if ImGui.IsItemHovered() then ImGui.SetTooltip('Follow distance (units) before moving to catch up.') end
            ImGui.TableNextColumn()
            -- Camp section (align to same pixel row as Follow; inner border adds ~3px so compensate)
            local CAMP_CELL_Y_OFFSET = 3
            local campX = select(1, ImGui.GetCursorScreenPos())
            ImGui.SetCursorScreenPos(campX, rowStartScreenY - CAMP_CELL_Y_OFFSET)
            availX = select(1, ImGui.GetContentRegionAvail())
            local pullCfg = botconfig.config.pull
            local pullActive = rc.dopull == true
            local roamOnly = pullCfg and pullCfg.roam == true and pullActive
            local hunterMode = pullCfg and pullCfg.hunter == true and not roamOnly and pullActive
            local mobilePullMode = roamOnly or hunterMode
            local campCoordsSet = rc.makecamp and (rc.makecamp.x or rc.makecamp.y or rc.makecamp.z)
            local fixedCamp = rc.campstatus == true
            local mobileAnchorActive = hunterMode and campCoordsSet and not fixedCamp
            local campLabel = hunterMode and 'Anchor' or 'Camp'
            textW, textH = ImGui.CalcTextSize(campLabel)
            startX = ImGui.GetCursorPosX()
            ImGui.SetCursorPosX(startX + availX / 2 - textW / 2)
            ImGui.Text('%s', campLabel)
            ImGui.SameLine()
            local campIcon = Icons.FA_FREE_CODE_CAMP
            local groupCampIcon = Icons.FA_USERS
            local campIconW = (select(1, ImGui.CalcTextSize(campIcon)) or 0) + style.FramePadding.x * 2
            local groupCampIconW = (select(1, ImGui.CalcTextSize(groupCampIcon)) or 0) + style.FramePadding.x * 2
            local GROUP_CAMP_GAP = 4
            local campAvail = select(1, ImGui.GetContentRegionAvail())
            if campAvail > 0 then
                ImGui.SetCursorPosX(ImGui.GetCursorPosX() + campAvail - campIconW - groupCampIconW - GROUP_CAMP_GAP)
            end
            -- Make GROUP camp toggle (mirrors my own camp state): green = off, red = on. Clicking broadcasts
            -- makecamp on/off to every group member via MQRemote, and sets/clears my own camp locally.
            local groupCampColor = fixedCamp and RED or GREEN
            ImGui.PushStyleColor(ImGuiCol.Button, BLACK)
            ImGui.PushStyleColor(ImGuiCol.Text, groupCampColor)
            if ImGui.SmallButton(groupCampIcon .. '##group_camp') then
                if fixedCamp then
                    botmove.MakeCamp('off')
                    mq.cmd('/rc group /cz makecamp off')
                elseif not mobilePullMode then
                    botmove.MakeCamp('on')
                    mq.cmd('/rc group /cz makecamp on')
                end
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip(fixedCamp
                    and 'Group camp is ON. Click to clear camp for you and the whole group (via MQRemote).'
                    or 'Make GROUP camp: set camp here and for every group member (via MQRemote).')
            end
            ImGui.PopStyleColor(2)
            ImGui.SameLine(0, GROUP_CAMP_GAP)
            local campIconColor = GREEN
            if fixedCamp then
                campIconColor = RED
            elseif mobileAnchorActive then
                campIconColor = YELLOW
            end
            ImGui.PushStyleColor(ImGuiCol.Button, BLACK)
            ImGui.PushStyleColor(ImGuiCol.Text, campIconColor)
            if ImGui.SmallButton(campIcon .. '##camp_toggle') then
                if fixedCamp then
                    botmove.MakeCamp('off')
                elseif mobileAnchorActive then
                    botmove.ClearCamp()
                elseif not mobilePullMode then
                    botmove.MakeCamp('on')
                end
            end
            if ImGui.IsItemHovered() then
                if fixedCamp then
                    ImGui.SetTooltip('Makecamp is on. Click to turn off.')
                elseif mobileAnchorActive then
                    ImGui.SetTooltip('Mobile hunt anchor (not makecamp). Click to clear anchor.')
                elseif roamOnly then
                    ImGui.SetTooltip('Roam hunt: mob bubble and nav targets are centered on your position.')
                elseif hunterMode then
                    ImGui.SetTooltip('No anchor yet. Set automatically when pulling starts.')
                else
                    ImGui.SetTooltip('Set camp here')
                end
            end
            ImGui.PopStyleColor(2)
            local locationStr = 'unset'
            if campCoordsSet and (fixedCamp or mobileAnchorActive) then
                locationStr = string.format('%.1f, %.1f, %.1f', rc.makecamp.x or 0, rc.makecamp.y or 0,
                    rc.makecamp.z or 0)
            end
            ImGui.Spacing()
            if roamOnly then
                ImGui.TextColored(WHITE, '%s', 'Roam: ')
                ImGui.SameLine(0, 2)
                ImGui.TextColored(LIGHT_GREY, '%s', 'player position')
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip('Nav targets use pull.radius around you; melee uses Radius below.')
                end
            else
                ImGui.TextColored(WHITE, '%s', hunterMode and 'Anchor: ' or 'Location: ')
                ImGui.SameLine(0, 2)
                ImGui.TextColored(LIGHT_GREY, '%s', locationStr)
            end
            -- Live distance from the camp pin (camp active only); red once you're past Radius.
            if fixedCamp and rc.makecamp and rc.makecamp.x and rc.makecamp.y and rc.makecamp.z then
                local d = utils.calcDist3D(mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z(),
                    rc.makecamp.x, rc.makecamp.y, rc.makecamp.z)
                local radius = tonumber(botconfig.config.settings.acleash) or 100
                ImGui.TextColored(WHITE, '%s', 'Dist from camp: ')
                ImGui.SameLine(0, 2)
                ImGui.TextColored((d and d > radius) and RED or GREEN, '%s',
                    d and string.format('%.1f / %d', d, radius) or '—')
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip('Your distance from the camp pin / camp Radius. Red = past Radius.')
                end
            end
            ImGui.TextColored(WHITE, '%s', 'Radius: ')
            ImGui.SameLine(0, 2)
            ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
            local acleashVal = botconfig.config.settings.acleash or 75
            local radiusNew, radiusCh = inputs.boundedInt('camp_radius', acleashVal, 1, 10000, 5, '##camp_radius')
            if radiusCh then
                botconfig.config.settings.acleash = radiusNew; runConfigLoaders()
            end
            if ImGui.IsItemHovered() then ImGui.SetTooltip('Camp radius for in-camp mob checks.') end
            ImGui.TextColored(WHITE, '%s', 'ZRadius: ')
            ImGui.SameLine(0, 2)
            ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
            local zradiusVal = botconfig.config.settings.zradius or 75
            local zradiusNew, zradiusCh = inputs.boundedInt('camp_zradius', zradiusVal, 1, 1000, 5, '##camp_zradius')
            if zradiusCh then
                botconfig.config.settings.zradius = zradiusNew; runConfigLoaders()
            end
            if ImGui.IsItemHovered() then ImGui.SetTooltip('Camp Z (vertical) radius for in-camp mob checks.') end
            ImGui.TextColored(WHITE, '%s', 'RestDist: ')
            ImGui.SameLine(0, 2)
            ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
            local campRestDistanceVal = botconfig.config.settings.campRestDistance or 15
            local campRestDistanceNew, campRestDistanceCh = inputs.boundedInt('camp_restdist', campRestDistanceVal, 1,
                100, 1, '##camp_restdist')
            if campRestDistanceCh then
                botconfig.config.settings.campRestDistance = campRestDistanceNew; runConfigLoaders()
            end
            if ImGui.IsItemHovered() then ImGui.SetTooltip(
                'Distance (units) from camp to count as \'at camp\' for leash and return.') end
            if fixedCamp then
                ImGui.TextColored(WHITE, '%s', 'Leash to radius: ')
                ImGui.SameLine(0, 2)
                local acleashOn = rc.doCampAcleash ~= false
                local acleashChecked, acleashToggled = ImGui.Checkbox('##camp_acleash', acleashOn)
                if acleashToggled then
                    rc.doCampAcleash = acleashChecked
                    botconfig.config.settings.campAcleash = acleashChecked -- persist (seeded back at startup)
                    runConfigLoaders()
                end
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip(
                        'On: return to camp instead of chasing past Radius (recommended to keep the tank close).\nOff: chase the current target / assist MA past Radius. Persists across reloads.')
                end
                -- Chase-fleeing exception: even when leashed, chase a fleeing/low-HP runner to finish it.
                ImGui.TextColored(WHITE, '%s', 'Chase fleeing: ')
                ImGui.SameLine(0, 2)
                local chaseOn = botconfig.config.settings.chaseFleeing ~= false
                local chaseChecked, chaseToggled = ImGui.Checkbox('##camp_chasefleeing', chaseOn)
                if chaseToggled then
                    botconfig.config.settings.chaseFleeing = chaseChecked; runConfigLoaders()
                end
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip('With Leash to radius on, still chase a fleeing (running-away) or low-HP mob past Radius to finish it -- but no further than the max below.')
                end
                if chaseOn then
                    ImGui.TextColored(WHITE, '%s', 'Chase max: ')
                    ImGui.SameLine(0, 2)
                    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
                    local cfMax = botconfig.config.settings.chaseFleeingMaxDist or 250
                    local cfNew, cfCh = inputs.boundedInt('camp_chasemax', cfMax, 10, 2000, 10, '##camp_chasemax')
                    if cfCh then botconfig.config.settings.chaseFleeingMaxDist = cfNew; runConfigLoaders() end
                    if ImGui.IsItemHovered() then ImGui.SetTooltip('Max distance from camp to chase a fleeing mob before giving up and returning.') end
                end
            end
            ImGui.TextColored(WHITE, '%s', '# Mobs: ')
            ImGui.SameLine(0, 2)
            ImGui.TextColored(LIGHT_GREY, '%s', tostring(state.getMobCount(rc)))
            do
                local _, _, _, anchorSource = spawnutils.getMobListAnchor(rc)
                local anchorLabel = anchorSource == 'ma' and 'MA'
                    or anchorSource == 'camp' and 'Camp'
                    or 'Self'
                ImGui.SameLine()
                ImGui.TextColored(LIGHT_GREY, '%s', string.format('[%s]', anchorLabel))
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip('Mob bubble scan center: MA (charinfo), camp pin, or your position.')
                end
            end
            ImGui.SameLine()
            local campDist = nil
            if rc.makecamp and rc.makecamp.x and rc.makecamp.y and rc.makecamp.z then
                campDist = utils.calcDist3D(mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z(), rc.makecamp.x, rc.makecamp.y,
                    rc.makecamp.z)
            end
            local nearestMobDist = nil
            if rc.MobList and rc.MobList[1] then
                local meX, meY, meZ = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
                local bestSq = nil
                for _, v in ipairs(rc.MobList) do
                    local dSq = utils.getDistanceSquared3D(meX, meY, meZ, v.X(), v.Y(), v.Z())
                    if dSq and (not bestSq or dSq < bestSq) then bestSq = dSq end
                end
                if bestSq then nearestMobDist = math.sqrt(bestSq) end
            end
            local distStr
            if mobileAnchorActive then
                local anchorStr = (campDist and string.format('%.1f', campDist)) or '—'
                local mobStr = (nearestMobDist and string.format('%.1f', nearestMobDist)) or '—'
                distStr = string.format('A:%s M:%s', anchorStr, mobStr)
            elseif roamOnly then
                distStr = (nearestMobDist and string.format('M:%.1f', nearestMobDist)) or 'M:—'
            else
                distStr = (fixedCamp and campDist and string.format('%.1f', campDist)) or '—'
            end
            local distAvail = select(1, ImGui.GetContentRegionAvail())
            local distW = select(1, ImGui.CalcTextSize(distStr))
            if distAvail > 0 then
                ImGui.SetCursorPosX(ImGui.GetCursorPosX() + math.max(0, distAvail - distW))
            end
            ImGui.TextColored(LIGHT_GREY, '%s', distStr)
            if ImGui.IsItemHovered() then
                if mobileAnchorActive then
                    ImGui.SetTooltip('A = distance from hunt anchor; M = nearest mob in camp list (units)')
                elseif roamOnly then
                    ImGui.SetTooltip('M = nearest mob in your mob bubble (units)')
                else
                    ImGui.SetTooltip('Distance from camp (units)')
                end
            end
            ImGui.TextColored(WHITE, '%s', 'Filter: ')
            ImGui.SameLine(0, 2)
            ImGui.SetNextItemWidth(120)
            local tf = tonumber(botconfig.config.settings.TargetFilter) or 0
            if tf < 0 or tf > 2 then tf = 0 end
            local targetFilterIdx = tf + 1
            local targetFilterOptions = { 'Aggressive NPCs', 'LoS NPCs', 'All NPCs' }
            local tfNew, tfCh = combos.combo('camp_targetfilter', targetFilterIdx, targetFilterOptions,
                '##camp_targetfilter')
            if tfCh then
                botconfig.config.settings.TargetFilter = tfNew - 1; runConfigLoaders()
            end
            if ImGui.IsItemHovered() then ImGui.SetTooltip('Filter for which spawns count as valid camp mobs.') end
            ImGui.EndTable()
        end
        ImGui.PopStyleColor(2)
        -- Advanced tuning behind collapsing headers (progressive disclosure): the landing stays compact;
        -- Sit thresholds, Mount, and Nuke types are one click away when needed.
        ImGui.Spacing()
        if ImGui.CollapsingHeader('Sit & rest') then
            field_label.draw('Sit Mana %: ', { width = NUMERIC_INPUT_WIDTH })
            local sitmanaVal = botconfig.config.settings.sitmana or 90
            local sitmanaNew, sitmanaCh = inputs.boundedInt('sit_mana_pct', sitmanaVal, 0, 100, 5, '##sit_mana_pct')
            if sitmanaCh then
                botconfig.config.settings.sitmana = sitmanaNew; runConfigLoaders()
            end
            if ImGui.IsItemHovered() then ImGui.SetTooltip(
                'If Sit is on, sit when mana is below this %%; stand when above this %% + 3 (hysteresis).') end
            ImGui.SameLine()
            field_label.draw('Sit Endurance %: ', { width = NUMERIC_INPUT_WIDTH })
            local sitendurVal = botconfig.config.settings.sitendur or 90
            local sitendurNew, sitendurCh = inputs.boundedInt('sit_endur_pct', sitendurVal, 0, 100, 5, '##sit_endur_pct')
            if sitendurCh then
                botconfig.config.settings.sitendur = sitendurNew; runConfigLoaders()
            end
            if ImGui.IsItemHovered() then ImGui.SetTooltip(
                'If Sit is on, sit when endurance is below this %%; stand when above this %% + 3 (hysteresis).') end
            ImGui.Spacing()
            field_label.draw('Sit Aggro %: ', { width = NUMERIC_INPUT_WIDTH })
            local sitaggroVal = botconfig.config.settings.sitaggro or 60
            local sitaggroNew, sitaggroCh = inputs.boundedInt('sit_aggro_pct', sitaggroVal, 0, 100, 5, '##sit_aggro_pct')
            if sitaggroCh then
                botconfig.config.settings.sitaggro = sitaggroNew; runConfigLoaders()
            end
            if ImGui.IsItemHovered() then ImGui.SetTooltip(
                'If Sit is on, only sit when your aggro %% is below this value. Applies when mobs are in camp and you are level 20+.') end
        end
        if ImGui.CollapsingHeader('Death & recovery') then
            local raOn = botconfig.config.settings.doRezAccept ~= false
            local raVal, raPressed = ImGui.Checkbox('##rezaccept', raOn)
            if raPressed then
                botconfig.config.settings.doRezAccept = raVal; runConfigLoaders()
            end
            ImGui.SameLine(0, 2)
            ImGui.TextColored(WHITE, '%s', 'Auto-accept rez')
            if ImGui.IsItemHovered() then ImGui.SetTooltip(
                'Automatically accept incoming resurrection offers while hovering at your corpse (whole box crew gets back up without manual clicking).') end
            field_label.draw('Min XP restore %: ', { width = NUMERIC_INPUT_WIDTH })
            local rmVal = tonumber(botconfig.config.settings.rezAcceptMinPct) or 0
            local rmNew, rmCh = inputs.boundedInt('rez_minpct', rmVal, 0, 100, 5, '##rez_minpct')
            if rmCh then
                botconfig.config.settings.rezAcceptMinPct = rmNew; runConfigLoaders()
            end
            if ImGui.IsItemHovered() then ImGui.SetTooltip(
                'Only accept rezzes that restore at least this %% experience (0 = accept any).') end
        end
        -- Mount: type dropdown + click-to-edit name (spellbook/item validation). Mount vars are computed
        -- outside the header so the edit modal (rendered below) persists regardless of header state.
        local mountcast = botconfig.config.settings.mountcast or 'none'
        local mountName, mountType = mountcast:match('^%s*(.-)%s*|%s*(.-)%s*$')
        if not mountType or mountType == '' then mountType = 'gem' end
        if mountName and mountName:match('^%s*$') then mountName = nil end
        if mountName == 'none' then mountName = nil end
        -- Effective type: a session selection (lets you pick Item before naming) over the saved type.
        local currentMountType = _mountTypeSel or mountType
        local mountTypeIdx = (currentMountType == 'item') and 2 or 1
        local MOUNT_TYPE_COMBO_WIDTH = 80
        local mountState = getMountModalState()
        local mountValidator = (currentMountType == 'gem') and validateSpellInBook or validateFindItem
        if ImGui.CollapsingHeader('Mount') then
            field_label.draw('Mount: ', { width = MOUNT_TYPE_COMBO_WIDTH })
            local mountTypeOptions = { 'Spell', 'Item' }
            local mountTypeNew, mountTypeCh = combos.combo('mount_type', mountTypeIdx, mountTypeOptions, nil)
            if mountTypeCh then
                _mountTypeSel = (mountTypeNew == 1) and 'gem' or 'item'
                currentMountType = _mountTypeSel -- so the name editor below validates against the right source
                mountValidator = (currentMountType == 'gem') and validateSpellInBook or validateFindItem
                -- Persist immediately only if there's already a name; otherwise the choice is held in _mountTypeSel.
                if mountName and mountName ~= '' and mountName ~= 'none' then
                    botconfig.config.settings.mountcast = mountName .. '|' .. _mountTypeSel
                    runConfigLoaders()
                end
            end
            ImGui.SameLine()
            local mountDisplayName = (mountName and mountName ~= '') and mountName or 'no mount'
            ImGui.SetNextItemWidth(140)
            if ImGui.Selectable(mountDisplayName .. '##' .. MOUNT_MODAL_ID, false, 0, ImVec2(140, 0)) then
                mountState.open = true
                mountState.buffer = mountName and mountName ~= 'none' and mountName or ''
                mountState.error = nil
                modals.openValidatedEditModal(MOUNT_MODAL_ID)
            end
            if ImGui.IsItemHovered() then ImGui.SetTooltip(
                'Click to edit: spell (search spellbook) or item (search inventory).') end
        end
        if mountState.open then
            local function onMountSave(value)
                local trimmed = (value or ''):match('^%s*(.-)%s*$')
                botconfig.config.settings.mountcast = (trimmed == '' or trimmed == 'none') and 'none' or
                (trimmed .. '|' .. currentMountType)
                mountState.open = false
                mountState.buffer = ''
                _mountTypeSel = nil -- now reflected in saved mountcast; re-derive next render
                runConfigLoaders()
            end
            local function onMountCancel()
                mountState.open = false
                mountState.buffer = ''
                mountState.error = nil
            end
            modals.validatedEditModal(MOUNT_MODAL_ID, mountState, mountValidator, onMountSave, onMountCancel)
        end
        do
            local applicable = {}
            local count = botconfig.getSpellCount('debuff')
            for i = 1, count do
                local entry = botconfig.getSpellEntry('debuff', i)
                if entry and spellutils.IsNukeSpell(entry) then
                    local f = spellutils.GetNukeFlavor(entry)
                    if f then applicable[f] = true end
                end
            end
            local order = { 'fire', 'ice', 'magic', 'poison', 'disease', 'chromatic', 'prismatic', 'unresistable',
                'corruption' }
            -- Only offer the Nuke types header when this character actually has nuke spells configured.
            if next(applicable) and ImGui.CollapsingHeader('Nuke types') then
                local options = {}
                local value = {}
                for _, f in ipairs(order) do
                    if applicable[f] then
                        local allowed = (not rc.nukeFlavorsAutoDisabled or not rc.nukeFlavorsAutoDisabled[f])
                            and (not rc.nukeFlavorsAllowed or rc.nukeFlavorsAllowed[f])
                        local autoDisabled = rc.nukeFlavorsAutoDisabled and rc.nukeFlavorsAutoDisabled[f]
                        local label = f:gsub('^%l', string.upper)
                        options[#options + 1] = {
                            key = f,
                            label = label,
                            tooltip = autoDisabled and 'Auto-disabled (resist streak). Uncheck then check to re-enable.' or
                            ('Toggle ' .. label .. ' nukes.'),
                        }
                        if allowed then value[#value + 1] = f end
                    end
                end
                labeled_grid.checkboxGrid({
                    id = 'nukeflavor',
                    label = 'Nuke:',
                    options = options,
                    value = value,
                    onToggle = function(key, isChecked)
                        if not rc.nukeFlavorsAllowed then
                            rc.nukeFlavorsAllowed = {}
                            for k in pairs(applicable) do rc.nukeFlavorsAllowed[k] = true end
                        end
                        if isChecked then
                            rc.nukeFlavorsAllowed[key] = true
                            if rc.nukeFlavorsAutoDisabled then rc.nukeFlavorsAutoDisabled[key] = nil end
                        else
                            rc.nukeFlavorsAllowed[key] = nil
                        end
                        rc.nukeResistDisabledRecent = nil
                        botconfig.saveNukeFlavorsToCommon()
                    end,
                })
                ImGui.Spacing()
            end
        end
        ImGui.TableNextColumn()
        ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, style.CellPadding.x, FLAGS_ROW_PADDING_Y)
        if ImGui.BeginTable('flags table', 2, ImGuiTableFlags.None) then
            ImGui.TableSetupColumn('', ImGuiTableColumnFlags.WidthFixed, FLAGS_COLUMN_WIDTH)
            ImGui.TableSetupColumn('', ImGuiTableColumnFlags.WidthFixed, FLAGS_COLUMN_WIDTH)
            local flagsToShow = {}
            for _, entry in ipairs(DO_FLAGS) do
                if entry.key == 'doforage' then
                    if hasForageAbility() then flagsToShow[#flagsToShow + 1] = entry end
                else
                    flagsToShow[#flagsToShow + 1] = entry
                end
            end
            if bardtwist.IsBard() then
                flagsToShow[#flagsToShow + 1] = SONGS_FLAG
            end
            for i, entry in ipairs(flagsToShow) do
                if (i - 1) % 2 == 0 then
                    ImGui.TableNextRow()
                end
                ImGui.TableNextColumn()
                local value
                if entry.key == 'dopull' then
                    value = (state.getRunconfig().dopull == true)
                elseif entry.key == 'dosongs' then
                    value = (state.getRunconfig().dosongs ~= false)
                else
                    value = botconfig.config.settings[entry.key] == true
                end
                local flagTip = (entry.tt or entry.label) .. '\n\n' ..
                    (value and 'Currently ON (click to turn off)' or 'Currently OFF (click to turn on)')
                if toggle.pill(entry.key, value, { small = true, tip = flagTip }) then
                    if entry.key == 'dopull' then
                        local rc = state.getRunconfig()
                        rc.dopull = not value
                        if rc.dopull == true then
                            botpull.syncPullMapFilter(true)
                            botpull.ensurePullCampState(rc)
                        end
                    elseif entry.key == 'dosongs' then
                        local rc = state.getRunconfig()
                        rc.dosongs = not value
                        if rc.dosongs == false then
                            bardtwist.StopTwist()
                        elseif botconfig.config.settings.dobuff then
                            bardtwist.EnsureDefaultTwistRunning()
                        end
                    else
                        botconfig.config.settings[entry.key] = not value
                        botconfig.ApplyAndPersist()
                    end
                end
                ImGui.SameLine(0, 2)
                ImGui.Text('%s', entry.label)
            end
            ImGui.EndTable()
        end
        ImGui.PopStyleVar(1)
        ImGui.EndTable()
    end

    -- Bard twist visibility (bard-only): live per-mode twist lists, so the twist order is readable.
    drawBardTwistSection()

    -- Out-of-group players nearby + distance (read-only).
    drawNearbyPlayersSection()

    -- Spell-upgrade prompt + scribe button.
    drawSpellUpgradesSection()

    -- Recent activity (newest first): the real actions the bot has taken, so the rapid subsystem-check
    -- ("X Check") idle cycle in the header doesn't hide what actually happened.
    ImGui.Spacing()
    ImGui.Separator()
    ImGui.TextColored(WHITE, '%s', 'Recent activity')
    if #_activity == 0 then
        ImGui.TextColored(LIGHT_GREY, '%s', '  (nothing yet)')
    else
        local now = mq.gettime()
        for i = #_activity, 1, -1 do
            local e = _activity[i]
            local ago = math.floor((now - e.t) / 1000)
            ImGui.TextColored(LIGHT_GREY, '  %3ds  %s', ago, e.msg)
        end
    end
end

return M
