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
local bardtwist = require('lib.bardtwist')
local botpull = require('botpull')
local inputs = require('gui.widgets.inputs')
local combos = require('gui.widgets.combos')
local labeled_grid = require('gui.widgets.labeled_grid')
local modals = require('gui.widgets.modals')

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
    if mq.TLO.FindItem(name)() and mq.TLO.FindItem(name)() > 0 then return true end
    return false, 'Item not found in inventory'
end

local MOUNT_MODAL_ID = 'status_mount'
local _mountModalState = nil

local function getMountModalState()
    if not _mountModalState then
        _mountModalState = { open = false, buffer = '', error = nil }
    end
    return _mountModalState
end

local function runConfigLoaders()
    botconfig.ApplyAndPersist()
end

local YELLOW = ImVec4(1, 1, 0, 1)
local RED = ImVec4(1, 0, 0, 1)
local GREEN = ImVec4(0, 0.8, 0, 1)
local BLACK = ImVec4(0, 0, 0, 1)
local WHITE = ImVec4(1, 1, 1, 1)
local LIGHT_GREY = ImVec4(0.75, 0.75, 0.75, 1)
local TABLE_BORDER_BLUE = ImVec4(51 / 255, 105 / 255, 173 / 255, 1.0)

local FLAGS_COLUMN_WIDTH = 65
local FLAGS_ROW_PADDING_Y = 2
local FLAGS_PANEL_WIDTH = 145
local NUMERIC_INPUT_WIDTH = 80

local DO_FLAGS = {
    { key = 'dopull',   label = 'Pull' },
    { key = 'dodebuff', label = 'Debuff' },
    { key = 'doheal',   label = 'Heal' },
    { key = 'dobuff',   label = 'Buff' },
    { key = 'docure',   label = 'Cure' },
    { key = 'domelee',  label = 'Melee' },
    { key = 'doraid',   label = 'Raid' },
    { key = 'dodrag',   label = 'Drag' },
    { key = 'domount',  label = 'Mount' },
    { key = 'dosit',    label = 'Sit' },
    { key = 'doforage', label = 'Forage' },
}

local SONGS_FLAG = { key = 'dosongs', label = 'Songs' }

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

local function getStatusLine()
    local rc = state.getRunconfig()
    if rc.pullHealerManaWait and rc.pullHealerManaWait.name then
        local w = rc.pullHealerManaWait
        if w.current ~= nil then
            return string.format("Waiting on %s's mana (%d%% <= %d%%)", w.name, w.current, w.pct)
        end
        return string.format("Waiting on %s's mana (must be > %d%%)", w.name, w.pct)
    end
    if rc.statusMessage and rc.statusMessage ~= '' then return rc.statusMessage end
    local runState = state.getRunState()
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

function M.draw()
    ImGui.TextColored(YELLOW, '%s', getStatusLine())
    ImGui.SameLine()
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
    if ImGui.IsItemHovered() then ImGui.SetTooltip(isPaused and 'Resume CZBot' or 'Pause CZBot') end
    ImGui.PopStyleColor(2)
    ImGui.SameLine()
    ImGui.Text('%s', 'Exit')
    ImGui.SameLine()
    ImGui.PushStyleColor(ImGuiCol.Button, BLACK)
    ImGui.PushStyleColor(ImGuiCol.Text, RED)
    if ImGui.SmallButton(Icons.FA_POWER_OFF .. '##exit') then
        state.getRunconfig().terminate = true
    end
    ImGui.PopStyleColor(2)
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
            local campIconW = (select(1, ImGui.CalcTextSize(campIcon)) or 0) + style.FramePadding.x * 2
            local campAvail = select(1, ImGui.GetContentRegionAvail())
            if campAvail > 0 then
                ImGui.SetCursorPosX(ImGui.GetCursorPosX() + campAvail - campIconW)
            end
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
                ImGui.TextColored(WHITE, '%s', 'Acleash: ')
                ImGui.SameLine(0, 2)
                local acleashOn = rc.doCampAcleash ~= false
                local acleashChecked, acleashToggled = ImGui.Checkbox('##camp_acleash', acleashOn)
                if acleashToggled then
                    rc.doCampAcleash = acleashChecked
                end
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip(
                        'When off, mobs outside camp radius stay valid targets for MT/DPS. Session only.')
                end
            end
            ImGui.TextColored(WHITE, '%s', '# Mobs: ')
            ImGui.SameLine(0, 2)
            ImGui.TextColored(LIGHT_GREY, '%s', tostring(state.getMobCount(rc)))
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
        -- Other section
        ImGui.Spacing()
        do
            local availX = select(1, ImGui.GetContentRegionAvail())
            local otherLabel = 'Other'
            local textW = select(1, ImGui.CalcTextSize(otherLabel))
            local startX = ImGui.GetCursorPosX()
            ImGui.SetCursorPosX(startX + availX / 2 - textW / 2)
            ImGui.Text('%s', otherLabel)
        end
        ImGui.Spacing()
        ImGui.TextColored(WHITE, '%s', 'Sit Mana %: ')
        ImGui.SameLine(0, 2)
        ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
        local sitmanaVal = botconfig.config.settings.sitmana or 90
        local sitmanaNew, sitmanaCh = inputs.boundedInt('sit_mana_pct', sitmanaVal, 0, 100, 5, '##sit_mana_pct')
        if sitmanaCh then
            botconfig.config.settings.sitmana = sitmanaNew; runConfigLoaders()
        end
        if ImGui.IsItemHovered() then ImGui.SetTooltip(
            'If Sit is on, sit when mana is below this %%; stand when above this %% + 3 (hysteresis).') end
        ImGui.SameLine()
        ImGui.TextColored(WHITE, '%s', 'Sit Endurance %: ')
        ImGui.SameLine(0, 2)
        ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
        local sitendurVal = botconfig.config.settings.sitendur or 90
        local sitendurNew, sitendurCh = inputs.boundedInt('sit_endur_pct', sitendurVal, 0, 100, 5, '##sit_endur_pct')
        if sitendurCh then
            botconfig.config.settings.sitendur = sitendurNew; runConfigLoaders()
        end
        if ImGui.IsItemHovered() then ImGui.SetTooltip(
            'If Sit is on, sit when endurance is below this %%; stand when above this %% + 3 (hysteresis).') end
        ImGui.Spacing()
        ImGui.TextColored(WHITE, '%s', 'Sit Aggro %: ')
        ImGui.SameLine(0, 2)
        ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
        local sitaggroVal = botconfig.config.settings.sitaggro or 60
        local sitaggroNew, sitaggroCh = inputs.boundedInt('sit_aggro_pct', sitaggroVal, 0, 100, 5, '##sit_aggro_pct')
        if sitaggroCh then
            botconfig.config.settings.sitaggro = sitaggroNew; runConfigLoaders()
        end
        if ImGui.IsItemHovered() then ImGui.SetTooltip(
            'If Sit is on, only sit when your aggro %% is below this value. Applies when mobs are in camp and you are level 20+.') end
        -- Mount: type dropdown + click-to-edit name (spellbook/item validation)
        ImGui.Spacing()
        ImGui.TextColored(WHITE, '%s', 'Mount: ')
        ImGui.SameLine(0, 2)
        local mountcast = botconfig.config.settings.mountcast or 'none'
        local mountName, mountType = mountcast:match('^%s*(.-)%s*|%s*(.-)%s*$')
        if not mountType or mountType == '' then mountType = 'gem' end
        if mountName and mountName:match('^%s*$') then mountName = nil end
        if mountName == 'none' then mountName = nil end
        local mountTypeIdx = (mountType == 'item') and 2 or 1
        local MOUNT_TYPE_COMBO_WIDTH = 80
        ImGui.SetNextItemWidth(MOUNT_TYPE_COMBO_WIDTH)
        local mountTypeOptions = { 'Spell', 'Item' }
        local mountTypeNew, mountTypeCh = combos.combo('mount_type', mountTypeIdx, mountTypeOptions, nil)
        if mountTypeCh then
            local newType = (mountTypeNew == 1) and 'gem' or 'item'
            botconfig.config.settings.mountcast = (mountName and mountName ~= '' and mountName ~= 'none') and
            (mountName .. '|' .. newType) or 'none'
            runConfigLoaders()
        end
        ImGui.SameLine()
        local mountDisplayName = (mountName and mountName ~= '') and mountName or 'no mount'
        local mountState = getMountModalState()
        local currentMountType = (mountTypeIdx == 1) and 'gem' or 'item'
        local mountValidator = (currentMountType == 'gem') and validateSpellInBook or validateFindItem
        ImGui.SetNextItemWidth(140)
        if ImGui.Selectable(mountDisplayName .. '##' .. MOUNT_MODAL_ID, false, 0, ImVec2(140, 0)) then
            mountState.open = true
            mountState.buffer = mountName and mountName ~= 'none' and mountName or ''
            mountState.error = nil
            modals.openValidatedEditModal(MOUNT_MODAL_ID)
        end
        if ImGui.IsItemHovered() then ImGui.SetTooltip(
            'Click to edit: spell (search spellbook) or item (search inventory).') end
        if mountState.open then
            local function onMountSave(value)
                local trimmed = (value or ''):match('^%s*(.-)%s*$')
                botconfig.config.settings.mountcast = (trimmed == '' or trimmed == 'none') and 'none' or
                (trimmed .. '|' .. currentMountType)
                mountState.open = false
                mountState.buffer = ''
                runConfigLoaders()
            end
            local function onMountCancel()
                mountState.open = false
                mountState.buffer = ''
                mountState.error = nil
            end
            modals.validatedEditModal(MOUNT_MODAL_ID, mountState, mountValidator, onMountSave, onMountCancel)
        end
        ImGui.Spacing()
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
            if next(applicable) then
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
                local icon = value and Icons.FA_TOGGLE_ON or Icons.FA_TOGGLE_OFF
                ImGui.PushStyleColor(ImGuiCol.Button, BLACK)
                ImGui.PushStyleColor(ImGuiCol.Text, value and GREEN or RED)
                if ImGui.SmallButton(icon .. '##' .. entry.key) then
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
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip(value and 'On' or 'Off')
                end
                ImGui.PopStyleColor(2)
                ImGui.SameLine(0, 2)
                ImGui.Text('%s', entry.label)
            end
            ImGui.EndTable()
        end
        ImGui.PopStyleVar(1)
        ImGui.EndTable()
    end
end

return M
