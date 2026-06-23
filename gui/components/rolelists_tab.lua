-- Roles tab: MA anchor/leash settings and cz_common ma_list / mt_list fallback lists.

local mq = require('mq')
local ImGui = require('ImGui')
local botconfig = require('lib.config')
local state = require('lib.state')
local rolelists = require('lib.rolelists')
local inputs = require('gui.widgets.inputs')

local M = {}

local maAddBuf, mtAddBuf = '', ''
local showMaAddInput, showMtAddInput = false, false
local YELLOW = ImVec4(1, 1, 0, 1)
local WHITE = ImVec4(1, 1, 1, 1)
local NUMERIC_INPUT_WIDTH = 80

local function runConfigLoaders()
    botconfig.ApplyAndPersist()
end

local function tableContains(list, name)
    if type(list) ~= 'table' then return false end
    for _, n in ipairs(list) do
        if n == name then return true end
    end
    return false
end

local function isPcName(name)
    if not name or name == '' then return false end
    return mq.TLO.Spawn('pc =' .. name).Type() == 'PC'
end

local function drawMaAnchorSection()
    ImGui.TextColored(YELLOW, 'MA anchor settings')
    ImGui.TextColored(WHITE, '%s', 'MA anchor: ')
    ImGui.SameLine(0, 2)
    local maAnchorOn = botconfig.config.settings.maCampAnchor ~= false
    local maAnchorChecked, maAnchorToggled = ImGui.Checkbox('##roles_ma_camp_anchor', maAnchorOn)
    if maAnchorToggled then
        botconfig.config.settings.maCampAnchor = maAnchorChecked
        runConfigLoaders()
    end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(
            'When on, mob bubble centers on nearby MA and injects MA ATTACK targets into the mob list.')
    end
    ImGui.SameLine()
    ImGui.TextColored(WHITE, '%s', 'MA leash: ')
    ImGui.SameLine(0, 2)
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
    local maLeashVal = botconfig.config.settings.maAnchorLeash or botconfig.config.settings.acleash or 75
    local maLeashNew, maLeashCh = inputs.boundedInt('roles_ma_anchor_leash', maLeashVal, 1, 10000, 5,
        '##roles_ma_anchor_leash')
    if maLeashCh then
        botconfig.config.settings.maAnchorLeash = maLeashNew
        runConfigLoaders()
    end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(
            'Max MA distance for mob bubble anchor, combat inject, and ma_list/mt_list fallback (defaults to Radius).')
    end
    ImGui.Spacing()
end

local function drawRoleListSection(listType, runconfigKey, label, addBufKey)
    local rc = state.getRunconfig()
    if type(rc[runconfigKey]) ~= 'table' then rc[runconfigKey] = {} end
    local list = rc[runconfigKey]
    ImGui.TextColored(YELLOW, '%s', label)
    if ImGui.BeginTable(label .. ' table', 3, bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter), -1, 0) then
        ImGui.TableSetupColumn('Name', 0, 0.55)
        ImGui.TableSetupColumn('Order', 0, 0.30)
        ImGui.TableSetupColumn('', 0, 0.15)
        ImGui.TableHeadersRow()
        for i = 1, #list do
            local name = list[i]
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.Text('%s', name)
            ImGui.TableNextColumn()
            if i > 1 and ImGui.SmallButton('Up##' .. listType .. i) then
                list[i], list[i - 1] = list[i - 1], list[i]
                rolelists.process(listType, 'save_replace')
            end
            ImGui.SameLine()
            if i < #list and ImGui.SmallButton('Down##' .. listType .. i) then
                list[i], list[i + 1] = list[i + 1], list[i]
                rolelists.process(listType, 'save_replace')
            end
            ImGui.TableNextColumn()
            if ImGui.SmallButton('Remove##' .. listType .. i) then
                table.remove(list, i)
                rolelists.process(listType, 'save_replace')
            end
        end
        ImGui.EndTable()
    end
    local hasPcTarget = mq.TLO.Target.ID() and mq.TLO.Target.ID() > 0 and mq.TLO.Target.Type() == 'PC'
    local showAddInput = (addBufKey == 'ma' and showMaAddInput) or (addBufKey == 'mt' and showMtAddInput)
    local addBuf = addBufKey == 'ma' and maAddBuf or mtAddBuf
    if hasPcTarget then
        if ImGui.Button('Add target##' .. listType) then
            local name = mq.TLO.Target.CleanName()
            if name and name ~= '' and isPcName(name) and not tableContains(list, name) then
                table.insert(list, name)
                rolelists.process(listType, 'save')
            end
        end
    else
        if not showAddInput then
            if ImGui.Button('Add##' .. listType) then
                if addBufKey == 'ma' then showMaAddInput = true else showMtAddInput = true end
            end
        else
            local flags = ImGuiInputTextFlags.EnterReturnsTrue
            local newVal, changed = ImGui.InputText('PC name##' .. listType, addBuf, flags)
            if changed then
                if addBufKey == 'ma' then maAddBuf = newVal else mtAddBuf = newVal end
            end
            ImGui.SameLine()
            if ImGui.Button('Add##' .. listType .. ' submit') or (changed and newVal and newVal ~= '') then
                local name = (addBufKey == 'ma' and maAddBuf or mtAddBuf):match('^%s*(.-)%s*$')
                if name and name ~= '' and isPcName(name) and not tableContains(list, name) then
                    table.insert(list, name)
                    rolelists.process(listType, 'save')
                end
                if addBufKey == 'ma' then maAddBuf = ''; showMaAddInput = false
                else mtAddBuf = ''; showMtAddInput = false end
            end
        end
    end
    ImGui.Spacing()
end

function M.draw()
    drawMaAnchorSection()
    ImGui.TextWrapped(
        'Fallback lists are stored in cz_common.lua. After editing lists, run /cz reloadcommon on other bots. Order matters: first alive, in-zone name within MA leash wins when the assigned MA/MT is unavailable.')
    ImGui.Spacing()
    drawRoleListSection('ma', 'MaList', 'Main Assist fallback list (ma_list)', 'ma')
    drawRoleListSection('mt', 'MtList', 'Main Tank fallback list (mt_list)', 'mt')
end

return M
