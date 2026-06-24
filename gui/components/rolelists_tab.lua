-- Roles tab: MA anchor/leash settings and cz_common ma_list / mt_list fallback lists.

local mq = require('mq')
local ImGui = require('ImGui')
local botconfig = require('lib.config')
local state = require('lib.state')
local rolelists = require('lib.rolelists')
local inputs = require('gui.widgets.inputs')
local theme = require('gui.widgets.theme')
local section = require('gui.widgets.section')
local name_list = require('gui.widgets.name_list')

local M = {}

local YELLOW, WHITE, GREEN = theme.YELLOW, theme.WHITE, theme.GREEN
local NUMERIC_INPUT_WIDTH = theme.WIDTHS.numeric

-- Transient confirmation after clicking Apply on a role preset, so the click gives visible feedback
-- (it changes flags + Tank/Assist designation silently otherwise).
local _lastApplied = { label = nil, t = 0 }
local APPLIED_SHOW_SECS = 5

-- Role-preset grid layout (columns = roles, rows = editable fields). Field keys must match
-- config.lua ROLE_FIELDS; the Apply button calls botconfig.ApplyRole(role).
local ROLE_COLS = {
    { key = 'tank', label = 'Tank' },
    { key = 'ma', label = 'Non-tank MA' },
    { key = 'dps', label = 'DPS' },
    { key = 'healer', label = 'Healer' },
}
local ROLE_ROWS = {
    { field = 'domelee', label = 'Melee' },
    { field = 'doheal', label = 'Heal' },
    { field = 'docure', label = 'Cure' },
    { field = 'dobuff', label = 'Buff' },
    { field = 'dodebuff', label = 'Debuff / Mez / Nuke' },
    { field = 'dosit', label = 'Sit / Med' },
    { field = 'engageXTargetOnly', label = 'Engage XTarget only' },
    { field = 'mtSticky', label = 'MT sticky' },
    { field = 'offtank', label = 'Off-tank' },
    { field = 'setTank', label = 'Set self as Tank' },
    { field = 'setAssist', label = 'Set self as MA' },
}

local function runConfigLoaders()
    botconfig.ApplyAndPersist()
end

local function isPcName(name)
    if not name or name == '' then return false end
    return mq.TLO.Spawn('pc =' .. name).Type() == 'PC'
end

-- "Add target" candidate: the current target's clean name, but only when it's a PC.
local function currentPcTargetName()
    if mq.TLO.Target.ID() and mq.TLO.Target.ID() > 0 and mq.TLO.Target.Type() == 'PC' then
        return mq.TLO.Target.CleanName()
    end
    return nil
end

local function drawMaAnchorSection()
    section.header('MA anchor settings')
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

local function drawRoleListSection(listType, runconfigKey, label)
    local rc = state.getRunconfig()
    if type(rc[runconfigKey]) ~= 'table' then rc[runconfigKey] = {} end
    name_list.draw({
        id = 'roles_' .. listType,
        label = label,
        list = rc[runconfigKey],
        reorder = true,
        addNoun = 'PC name',
        validateName = isPcName,
        getTargetName = currentPcTargetName,
        onChange = function(action) rolelists.process(listType, action) end,
    })
end

local function drawRolePresetsSection()
    section.header('Role presets')
    ImGui.TextWrapped(
        'Edit what each role configures, then click Apply to set THIS character to that role (behavior flags + Tank/Assist designation). Edits are saved. Command: /cz role tank|ma|dps|healer.')
    local roles = botconfig.config.roles
    if type(roles) ~= 'table' then
        ImGui.TextColored(WHITE, '%s', '(roles not loaded)')
        ImGui.Spacing()
        return
    end
    local flags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersInner, ImGuiTableFlags.BordersOuter)
    if ImGui.BeginTable('role_presets', 5, flags) then
        ImGui.TableSetupColumn('Setting', 0, 0.34)
        for _, c in ipairs(ROLE_COLS) do ImGui.TableSetupColumn(c.label, 0, 0.165) end
        ImGui.TableHeadersRow()
        for _, row in ipairs(ROLE_ROWS) do
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.Text('%s', row.label)
            for _, c in ipairs(ROLE_COLS) do
                ImGui.TableNextColumn()
                local r = roles[c.key]
                if r then
                    local val, pressed = ImGui.Checkbox('##rp_' .. c.key .. '_' .. row.field, r[row.field] == true)
                    if pressed then
                        r[row.field] = val
                        botconfig.MarkDirty()
                    end
                end
            end
        end
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.TextColored(YELLOW, '%s', 'Apply to me')
        for _, c in ipairs(ROLE_COLS) do
            ImGui.TableNextColumn()
            if ImGui.SmallButton('Apply##rp_' .. c.key) then
                botconfig.ApplyRole(c.key)
                _lastApplied.label = c.label
                _lastApplied.t = mq.gettime()
            end
        end
        ImGui.EndTable()
    end
    if _lastApplied.label and (mq.gettime() - _lastApplied.t) / 1000 <= APPLIED_SHOW_SECS then
        ImGui.TextColored(GREEN, 'Applied "%s": behavior flags + Tank/Assist designation set for this character.',
            _lastApplied.label)
    end
    ImGui.Spacing()
end

function M.draw()
    drawRolePresetsSection()
    ImGui.Separator()
    ImGui.Spacing()
    drawMaAnchorSection()
    ImGui.TextWrapped(
        'Fallback lists are stored in cz_common.lua. After editing lists, run /cz reloadcommon on other bots. Order matters: first alive, in-zone name within MA leash wins when the assigned MA/MT is unavailable.')
    ImGui.Spacing()
    drawRoleListSection('ma', 'MaList', 'Main Assist fallback list (ma_list)')
    drawRoleListSection('mt', 'MtList', 'Main Tank fallback list (mt_list)')
end

return M
