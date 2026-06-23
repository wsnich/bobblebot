-- Script tab: Key/Value/Edit tree for config.script.

local ImGui = require('ImGui')
local botconfig = require('lib.config')
local theme = require('gui.widgets.theme')

local M = {}

local YELLOW, RED = theme.YELLOW, theme.RED
local TABLE_FLAGS = bit32.bor(ImGuiTableFlags.ScrollY, ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter,
    ImGuiTableFlags.BordersV, ImGuiTableFlags.SizingStretchSame, ImGuiTableFlags.Sortable,
    ImGuiTableFlags.Hideable, ImGuiTableFlags.Resizable, ImGuiTableFlags.Reorderable)

local function drawNestedTableTree(tbl)
    for k, v in pairs(tbl) do
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        if type(v) == 'table' then
            local open = ImGui.TreeNodeEx(tostring(k), ImGuiTreeNodeFlags.SpanFullWidth)
            if open then
                drawNestedTableTree(v)
                ImGui.TreePop()
            end
        else
            ImGui.TextColored(YELLOW, '%s', k)
            ImGui.TableNextColumn()
            ImGui.TextColored(RED, '%s', v)
            ImGui.TableNextColumn()
            if type(v) == 'number' or type(v) == 'string' or type(v) == 'boolean' then
                local buf = tostring(v)
                local flags = ImGuiInputTextFlags.EnterReturnsTrue
                local valueChanged, newValue = ImGui.InputText('##' .. k, buf, flags)
                if newValue then
                    local num = tonumber(valueChanged)
                    local strVal = valueChanged
                    if num then
                        tbl[k] = num
                    elseif strVal == 'true' then
                        tbl[k] = true
                    elseif strVal == 'false' then
                        tbl[k] = false
                    else
                        tbl[k] = strVal
                    end
                    botconfig.ApplyAndPersist()
                end
                ImGui.TableNextColumn()
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
            drawNestedTableTree(tbl)
            ImGui.EndTable()
        end
        ImGui.TreePop()
    end
end

function M.draw()
    local tbl = botconfig.config.script
    if tbl then
        drawScriptTree(tbl)
    end
end

return M
