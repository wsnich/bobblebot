local mq = require('mq')
local ImGui = require('ImGui')
local botconfig = require('lib.config')
local state = require('lib.state')
local combat_tab = require('gui.components.combat_tab')
local pull_tab = require('gui.components.pull_tab')
local debuff_tab = require('gui.components.debuff_tab')
local heal_tab = require('gui.components.heal_tab')
local buff_tab = require('gui.components.buff_tab')
local cure_tab = require('gui.components.cure_tab')
local moblist_tab = require('gui.components.moblist_tab')
local rolelists_tab = require('gui.components.rolelists_tab')
local script_tab = require('gui.components.script_tab')
local status_tab = require('gui.components.status_tab')
local help_tab = require('gui.components.help_tab')
local theme = require('gui.widgets.theme')
local ok, VERSION = pcall(require, 'version')
if not ok then VERSION = 'dev' end

local M = {}

local czgui = true
local isOpen, shouldDraw = true, true
local _saveFailed, _saveErr = false, nil

-- Persist the config when dirty, surfacing any write failure to the GUI instead
-- of silently swallowing it. Clears the dirty flag only on a confirmed success so
-- a failed write is retried on the next frame.
local function doSaveIfDirty()
    if not botconfig.IsDirty() then return end
    local pok, saveOk, err = pcall(botconfig.Save, botconfig.getPath())
    if pok and saveOk then
        botconfig.ClearDirty()
        _saveFailed, _saveErr = false, nil
    else
        _saveFailed = true
        _saveErr = (not pok) and tostring(saveOk) or (err or 'config not written')
    end
end

local TABS = {
    { label = 'Status',          draw = status_tab.draw },
    { label = 'Combat',          draw = combat_tab.draw },
    { label = 'Pull',            draw = pull_tab.draw },
    { label = 'Heal',            draw = heal_tab.draw },
    { label = 'Buff',            draw = buff_tab.draw },
    { label = 'Debuff/Mez/Nuke', draw = debuff_tab.draw },
    { label = 'Cure',            draw = cure_tab.draw },
    { label = 'Roles',           draw = rolelists_tab.draw },
    { label = 'Mob lists',       draw = moblist_tab.draw },
    { label = 'Advanced',        draw = script_tab.draw },
    { label = 'Help',            draw = help_tab.draw },
}

local function updateImGui()
    if not isOpen then
        doSaveIfDirty()
        return
    end
    if not czgui then return end
    ImGui.SetNextWindowPos(ImVec2(200, 200), ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowSize(ImVec2(600, 800), ImGuiCond.FirstUseEver)
    isOpen, shouldDraw = ImGui.Begin('CZBot ' .. VERSION .. '###CZBotMain', isOpen)
    if shouldDraw then
        ImGui.Spacing()
        -- Persistent header: status line + Pause/Exit, visible regardless of the active tab.
        status_tab.drawControls()
        if _saveFailed then
            ImGui.TextColored(theme.RED, 'Save FAILED: %s', _saveErr or 'config not written (check file/permissions)')
        end
        ImGui.Separator()
        ImGui.Spacing()
        if ImGui.BeginTabBar('CZBot GUI') then
            for _, tab in ipairs(TABS) do
                if ImGui.BeginTabItem(tab.label) then
                    tab.draw()
                    ImGui.EndTabItem()
                end
            end
            ImGui.EndTabBar()
        end
        doSaveIfDirty()
    end
    ImGui.End()
end

local function UIEnable()
    isOpen = true
    czgui = true
end

function M.getUpdateFn()
    return updateImGui
end

M.UIEnable = UIEnable

return M
