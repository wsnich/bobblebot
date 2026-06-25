-- Section headers: ONE source for the two header styles that were hand-rolled across tabs.
--   section.header(label, opts)  -> simple yellow label (was TextColored(YELLOW, label) in
--                                   rolelists/moblist/name_list).
--   section.divider(label, opts) -> centered label with a horizontal rule on each side (was the
--                                   ~20-line inline block in combat_tab's "Pulling" divider).
-- opts.tooltip (string) adds a hover tooltip on either style.

local ImGui = require('ImGui')
local theme = require('gui.widgets.theme')

local M = {}

-- Rule color: light blue #3369ad (51, 105, 173). Passed to GetColorU32 as raw floats (matches the
-- original inline divider; avoids depending on ImVec4 field reads).
local RULE_R, RULE_G, RULE_B, RULE_A = 51 / 255, 105 / 255, 173 / 255, 1.0

--- Plain yellow section header.
---@param label string
---@param opts table|nil { tooltip = string }
function M.header(label, opts)
    opts = opts or {}
    ImGui.TextColored(theme.YELLOW, '%s', label)
    if opts.tooltip and ImGui.IsItemHovered() then ImGui.SetTooltip('%s', opts.tooltip) end
end

--- Centered label with a horizontal rule extending to each edge of the content region.
---@param label string
---@param opts table|nil { tooltip = string }
function M.divider(label, opts)
    opts = opts or {}
    ImGui.Spacing()
    local leftX = select(1, ImGui.GetCursorScreenPos())
    local availX = select(1, ImGui.GetContentRegionAvail())
    local textW = select(1, ImGui.CalcTextSize(label))
    local startX = ImGui.GetCursorPosX()
    ImGui.SetCursorPosX(startX + availX / 2 - textW / 2)
    ImGui.Text('%s', label)
    if opts.tooltip and ImGui.IsItemHovered() then ImGui.SetTooltip('%s', opts.tooltip) end
    local tMinX, tMinY = ImGui.GetItemRectMin()
    local tMaxX, tMaxY = ImGui.GetItemRectMax()
    local midY = (tMinY + tMaxY) / 2
    local pad = 4
    local rightX = leftX + availX
    local drawList = ImGui.GetWindowDrawList()
    local col = ImGui.GetColorU32(RULE_R, RULE_G, RULE_B, RULE_A)
    drawList:AddLine(ImVec2(leftX, midY), ImVec2(tMinX - pad, midY), col, 1.0)
    drawList:AddLine(ImVec2(tMaxX + pad, midY), ImVec2(rightX, midY), col, 1.0)
end

return M
