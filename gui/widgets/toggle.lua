-- Shared on/off "pill" toggle: a colored FontAwesome toggle icon on a black button.
-- Replaces the inline pill that was reimplemented across spell_entry and status_tab. Renders
-- identically (green ON / red OFF on a black button) so adoption is render-preserving.
-- The caller owns the boolean state and flips it when this returns true (clicked).
--
--   toggle.pill(id, value, opts) -> clicked
--     id   : unique suffix for the widget id
--     value: boolean (on/off) -> green/red + on/off icon
--     opts : { small = bool (SmallButton vs full Button, default full),
--              tip = string, onTip = string, offTip = string }  -- state-aware hover tooltip

local ImGui = require('ImGui')
local Icons = require('mq.ICONS')
local theme = require('gui.widgets.theme')

local M = {}

function M.pill(id, value, opts)
    opts = opts or {}
    local icon = value and Icons.FA_TOGGLE_ON or Icons.FA_TOGGLE_OFF
    ImGui.PushStyleColor(ImGuiCol.Button, theme.BLACK)
    ImGui.PushStyleColor(ImGuiCol.Text, value and theme.GREEN or theme.RED)
    local clicked
    if opts.small then
        clicked = ImGui.SmallButton(icon .. '##' .. id)
    else
        clicked = ImGui.Button(icon .. '##' .. id)
    end
    if ImGui.IsItemHovered() then
        local tip = value and (opts.onTip or opts.tip) or (opts.offTip or opts.tip)
        if tip then ImGui.SetTooltip('%s', tip) end
    end
    ImGui.PopStyleColor(2)
    return clicked
end

return M
