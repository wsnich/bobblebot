local mq = require('mq')
local ImGui = require('ImGui')
local botconfig = require('lib.config')
local state = require('lib.state')
local combat_tab = require('gui.components.combat_tab')
local debuff_tab = require('gui.components.debuff_tab')
local heal_tab = require('gui.components.heal_tab')
local buff_tab = require('gui.components.buff_tab')
local cure_tab = require('gui.components.cure_tab')
local moblist_tab = require('gui.components.moblist_tab')
local rolelists_tab = require('gui.components.rolelists_tab')
local script_tab = require('gui.components.script_tab')
local status_tab = require('gui.components.status_tab')
local ok, VERSION = pcall(require, 'version')
if not ok then VERSION = 'dev' end

local M = {}

local czgui = true
local isOpen, shouldDraw = true, true

local TABS = {
    { label = 'Status',    draw = status_tab.draw },
    { label = 'Combat',    draw = combat_tab.draw },
    { label = 'Heal',      draw = heal_tab.draw },
    { label = 'Buff',      draw = buff_tab.draw },
    { label = 'Debuff',    draw = debuff_tab.draw },
    { label = 'Cure',      draw = cure_tab.draw },
    { label = 'Script',    draw = script_tab.draw },
    { label = 'Roles',     draw = rolelists_tab.draw },
    { label = 'Mob lists', draw = moblist_tab.draw },
}

local function updateImGui()
    if not isOpen then
        if botconfig.IsDirty() then
            botconfig.Save(botconfig.getPath())
            botconfig.ClearDirty()
        end
        return
    end
    if not czgui then return end
    ImGui.SetNextWindowPos(ImVec2(200, 200), ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowSize(ImVec2(600, 800), ImGuiCond.FirstUseEver)
    isOpen, shouldDraw = ImGui.Begin('CZBot ' .. VERSION .. '###CZBotMain', isOpen)
    if shouldDraw then
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
        if botconfig.IsDirty() then
            botconfig.Save(botconfig.getPath())
            botconfig.ClearDirty()
        end
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
