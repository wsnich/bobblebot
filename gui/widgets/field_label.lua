-- field_label: a white "Label: " caption followed by SameLine, so the caller draws its control
-- inline. Consolidates the TextColored(WHITE, 'X: ') + SameLine(0, 2) [+ SetNextItemWidth] triple
-- that was repeated dozens of times across the Status tab.
--
--   field_label.draw('Sit Mana %: ', { width = 80 })
--   local v, ch = inputs.boundedInt(...)   -- control follows inline
--
-- opts.width   : SetNextItemWidth applied to the following control (optional)
-- opts.gap     : SameLine spacing (default 2)
-- opts.tooltip : hover tooltip shown on the LABEL (optional; most callers tooltip the control instead)

local ImGui = require('ImGui')
local theme = require('gui.widgets.theme')

local M = {}

function M.draw(label, opts)
    opts = opts or {}
    ImGui.TextColored(theme.WHITE, '%s', label)
    if opts.tooltip and ImGui.IsItemHovered() then ImGui.SetTooltip('%s', opts.tooltip) end
    ImGui.SameLine(0, opts.gap or 2)
    if opts.width then ImGui.SetNextItemWidth(opts.width) end
end

return M
