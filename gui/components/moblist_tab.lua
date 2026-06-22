-- Mob Lists tab: exclude, priority, and charm lists for the current zone.

local mq = require('mq')
local ImGui = require('ImGui')
local state = require('lib.state')
local mobfilter = require('lib.mobfilter')
local nocombatzones = require('lib.nocombatzones')

local M = {}

local excludeAddBuf, priorityAddBuf, charmAddBuf = '', '', ''
local showExcludeAddInput, showPriorityAddInput, showCharmAddInput = false, false, false
local YELLOW = ImVec4(1, 1, 0, 1)

local function tableContains(list, name)
    if type(list) ~= 'table' then return false end
    for _, n in ipairs(list) do
        if n == name then return true end
    end
    return false
end

local function drawMobListSection(listType, runconfigKey, label)
    local rc = state.getRunconfig()
    if type(rc[runconfigKey]) ~= 'table' then rc[runconfigKey] = {} end
    local list = rc[runconfigKey]
    ImGui.TextColored(YELLOW, '%s', label)
    if ImGui.BeginTable(label .. ' table', 2, bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter), -1, 0) then
        ImGui.TableSetupColumn('Name', 0, 0.85)
        ImGui.TableSetupColumn('', 0, 0.15)
        ImGui.TableHeadersRow()
        for i = #list, 1, -1 do
            local name = list[i]
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.Text('%s', name)
            ImGui.TableNextColumn()
            if ImGui.SmallButton('Remove##' .. listType .. i) then
                table.remove(list, i)
                mobfilter.process(listType, 'save_replace')
            end
        end
        ImGui.EndTable()
    end
    local hasTarget = mq.TLO.Target.ID() and mq.TLO.Target.ID() > 0
    local showAddInput = (listType == 'exclude' and showExcludeAddInput) or (listType == 'priority' and showPriorityAddInput) or (listType == 'charm' and showCharmAddInput)
    local addBuf = (listType == 'exclude' and excludeAddBuf) or (listType == 'priority' and priorityAddBuf) or charmAddBuf
    if hasTarget then
        if ImGui.Button('Add target##' .. listType) then
            local name = mq.TLO.Target.CleanName()
            if name and name ~= '' and not tableContains(list, name) then
                table.insert(list, name)
                mobfilter.process(listType, 'save')
            end
        end
    else
        if not showAddInput then
            if ImGui.Button('Add##' .. listType) then
                if listType == 'exclude' then showExcludeAddInput = true
                elseif listType == 'priority' then showPriorityAddInput = true
                else showCharmAddInput = true end
            end
        else
            local flags = ImGuiInputTextFlags.EnterReturnsTrue
            local newVal, changed = ImGui.InputText('Mob name##' .. listType, addBuf, flags)
            if changed then
                if listType == 'exclude' then excludeAddBuf = newVal
                elseif listType == 'priority' then priorityAddBuf = newVal
                else charmAddBuf = newVal end
            end
            ImGui.SameLine()
            if ImGui.Button('Add##' .. listType .. ' submit') or (changed and newVal and newVal ~= '') then
                local name = ((listType == 'exclude' and excludeAddBuf) or (listType == 'priority' and priorityAddBuf) or charmAddBuf):match('^%s*(.-)%s*$')
                if name and name ~= '' and not tableContains(list, name) then
                    table.insert(list, name)
                    mobfilter.process(listType, 'save')
                end
                if listType == 'exclude' then excludeAddBuf = ''; showExcludeAddInput = false
                elseif listType == 'priority' then priorityAddBuf = ''; showPriorityAddInput = false
                else charmAddBuf = ''; showCharmAddInput = false end
            end
        end
    end
    ImGui.Spacing()
end

local function drawNoCombatZonesSection()
    local list = nocombatzones.getConfiguredZones()
    ImGui.TextColored(YELLOW, 'No combat zones')
    if ImGui.BeginTable('No combat zones table', 3, bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter), -1, 0) then
        ImGui.TableSetupColumn('Enabled', 0, 0.15)
        ImGui.TableSetupColumn('Zone', 0, 0.70)
        ImGui.TableSetupColumn('', 0, 0.15)
        ImGui.TableHeadersRow()
        for i = #list, 1, -1 do
            local name = list[i]
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            local enabled = nocombatzones.isZoneEnabled(name)
            local checked, toggled = ImGui.Checkbox('##nocombat_enabled' .. i, enabled)
            if toggled then
                nocombatzones.setZoneEnabled(name, checked)
            end
            ImGui.TableNextColumn()
            ImGui.Text('%s', name)
            ImGui.TableNextColumn()
            if ImGui.SmallButton('Remove##nocombat' .. i) then
                nocombatzones.removeZone(name)
            end
        end
        ImGui.EndTable()
    end
    if ImGui.Button('Add current zone') then
        local zone = mq.TLO.Zone.ShortName()
        if zone and zone ~= '' then
            nocombatzones.addZone(zone)
        end
    end
    ImGui.Spacing()
end

function M.draw()
    ImGui.TextColored(YELLOW, 'Current zone: %s', mq.TLO.Zone.ShortName() or '')
    ImGui.Spacing()
    drawMobListSection('exclude', 'ExcludeList', 'Exclude list')
    drawMobListSection('priority', 'PriorityList', 'Priority list')
    drawMobListSection('charm', 'CharmList', 'Charm list')
    drawNoCombatZonesSection()
end

return M
