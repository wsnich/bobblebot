-- Advanced tab: type-aware editor for the raw config.script table. Each leaf is rendered with a
-- control matched to its Lua type -- a checkbox for booleans, an Enter-to-commit numeric field for
-- numbers, and a text field for strings -- so edits PRESERVE the value's type. The previous editor
-- pushed every value through tostring/tonumber, which silently turned the string "123" into a number
-- and "true" into a boolean. Numbers/strings commit on Enter (no per-keystroke file writes); booleans
-- commit on click.

local ImGui = require('ImGui')
local botconfig = require('lib.config')
local theme = require('gui.widgets.theme')

local M = {}

local YELLOW, WHITE, GREEN, RED, LIGHT_GREY =
    theme.YELLOW, theme.WHITE, theme.GREEN, theme.RED, theme.LIGHT_GREY

local ImGuiInputTextFlags = ImGuiInputTextFlags or {}
local ENTER = ImGuiInputTextFlags.EnterReturnsTrue or 0
local DECIMAL = bit32.bor(ImGuiInputTextFlags.CharsDecimal or 0, ENTER)

local TABLE_FLAGS = bit32.bor(ImGuiTableFlags.ScrollY, ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter,
    ImGuiTableFlags.BordersV, ImGuiTableFlags.SizingStretchSame, ImGuiTableFlags.Sortable,
    ImGuiTableFlags.Hideable, ImGuiTableFlags.Resizable, ImGuiTableFlags.Reorderable)

local EDIT_WIDTH = 160

-- Color the read-only Value cell by type so booleans/numbers/strings are scannable at a glance.
local function valueColor(v)
    local t = type(v)
    if t == 'boolean' then return v and GREEN or RED end
    if t == 'number' then return WHITE end
    return LIGHT_GREY
end

-- Draw the type-appropriate edit control for one leaf value tbl[k]. Returns true if it changed.
local function drawLeafEditor(tbl, k, v, id)
    local t = type(v)
    if t == 'boolean' then
        local nv, pressed = ImGui.Checkbox('##' .. id, v)
        if pressed then
            tbl[k] = nv
            return true
        end
    elseif t == 'number' then
        ImGui.SetNextItemWidth(EDIT_WIDTH)
        local nv, submitted = ImGui.InputText('##' .. id, tostring(v), DECIMAL)
        if submitted then
            local num = tonumber(nv)
            if num then -- ignore non-numeric input; keep prior value
                tbl[k] = num
                return true
            end
        end
    elseif t == 'string' then
        ImGui.SetNextItemWidth(EDIT_WIDTH)
        local nv, submitted = ImGui.InputText('##' .. id, v, ENTER)
        if submitted then
            tbl[k] = nv
            return true
        end
    else
        ImGui.TextColored(LIGHT_GREY, '%s', '(' .. t .. ')')
    end
    return false
end

local function drawNestedTableTree(tbl, path)
    for k, v in pairs(tbl) do
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        local id = path .. '.' .. tostring(k)
        if type(v) == 'table' then
            local open = ImGui.TreeNodeEx(tostring(k), ImGuiTreeNodeFlags.SpanFullWidth)
            if open then
                drawNestedTableTree(v, id)
                ImGui.TreePop()
            end
        else
            ImGui.TextColored(YELLOW, '%s', tostring(k))
            ImGui.TableNextColumn()
            ImGui.TextColored(valueColor(v), '%s', tostring(v))
            ImGui.TableNextColumn()
            if drawLeafEditor(tbl, k, v, id) then
                botconfig.ApplyAndPersist()
            end
        end
    end
end

local function drawScriptTree(tbl)
    ImGui.SetNextItemOpen(true, ImGuiCond.FirstUseEver)
    if ImGui.TreeNode('Script') then
        if ImGui.BeginTable('script table', 3, TABLE_FLAGS, -1, -1) then
            ImGui.TableSetupScrollFreeze(0, 1)
            ImGui.TableSetupColumn('Key', ImGuiTableColumnFlags.DefaultSort, 2, 1)
            ImGui.TableSetupColumn('Value', ImGuiTableColumnFlags.DefaultSort, 2, 2)
            ImGui.TableSetupColumn('Edit', ImGuiTableColumnFlags.DefaultSort, 2, 3)
            ImGui.TableHeadersRow()
            drawNestedTableTree(tbl, 'script')
            ImGui.EndTable()
        end
        ImGui.TreePop()
    end
end

function M.draw()
    local confirmOn = (botconfig.config.settings.confirmExit ~= false)
    local confirmVal, confirmPressed = ImGui.Checkbox('Confirm before Exit##confirm_exit', confirmOn)
    if confirmPressed then
        botconfig.config.settings.confirmExit = confirmVal
        botconfig.ApplyAndPersist()
    end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('When enabled, the Exit button asks for confirmation before stopping CZBot.')
    end
    ImGui.Spacing()

    local tbl = botconfig.config.script
    if not tbl then
        ImGui.TextColored(LIGHT_GREY, '%s', 'No script config loaded.')
        return
    end
    ImGui.TextWrapped(
        'Raw config.script values. Edits preserve each value\'s type and save immediately: booleans are checkboxes, numbers and strings commit on Enter.')
    ImGui.Spacing()
    drawScriptTree(tbl)
end

return M
