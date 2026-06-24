-- Combat tab: melee/engage settings (assist, offtank, stick, behind, minmana). Pull config now lives
-- in its own Pull tab (pull_tab.lua).
-- ImGui Lua API (return values, e.g. Checkbox → value, pressed) is defined in typings/imgui.d.lua.

local mq = require('mq')
local ImGui = require('ImGui')
local botconfig = require('lib.config')
local inputs = require('gui.widgets.inputs')
local spell_entry = require('gui.widgets.spell_entry')

local M = {}

local NUMERIC_INPUT_WIDTH = 80

local function runConfigLoaders()
    botconfig.ApplyAndPersist()
end

--- Draw the Combat tab content (melee/engage block).
function M.draw()
    -- Authoritative master flag for this tab: domelee (toggled here or from the Status flags panel).
    spell_entry.drawTabIntro({ flagKey = 'domelee', flagNoun = 'Melee' })
    if not botconfig.config.melee then botconfig.config.melee = {} end
    local melee = botconfig.config.melee

    -- Line 1: Assist At, Pet Attack, Off Tank, optional Offset
    ImGui.Text('Assist At')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('MA target HP %% at or below which to sync.') end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
    local apVal = melee.assistpct or 99
    local apNew, apCh = inputs.boundedInt('combat_assistpct', apVal, 0, 100, 1, '##combat_assistpct')
    if apCh then melee.assistpct = apNew; runConfigLoaders() end
    ImGui.SameLine()
    ImGui.Text('Pet Attack')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Send pet on engage target.') end
    ImGui.SameLine()
    local petAssistChecked = (botconfig.config.settings and botconfig.config.settings.petassist == true) or false
    local petVal, petPressed = ImGui.Checkbox('##combat_petassist', petAssistChecked)
    if petPressed then
        if not botconfig.config.settings then botconfig.config.settings = {} end
        botconfig.config.settings.petassist = petVal
        runConfigLoaders()
    end
    ImGui.SameLine()
    ImGui.Text('Off Tank')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('This bot is an offtank.') end
    ImGui.SameLine()
    local otChecked = melee.offtank == true
    local value, pressed = ImGui.Checkbox('##combat_offtank', otChecked)
    if pressed then melee.offtank = value; runConfigLoaders() end
    if melee.offtank then
        ImGui.SameLine()
        ImGui.Text('Offset')
        if ImGui.IsItemHovered() then ImGui.SetTooltip('Which add to pick when MT and MA on same mob.') end
        ImGui.SameLine()
        ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
        local otoVal = melee.otoffset or 0
        local otoNew, otoCh = inputs.boundedInt('combat_otoffset', otoVal, 0, 10, 1, '##combat_otoffset')
        if otoCh then melee.otoffset = otoNew; runConfigLoaders() end
    end

    ImGui.Spacing()
    ImGui.Text('MT Sticky')
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('When this bot is the MT (and not an offtank), stay on target even if MA changes.')
    end
    ImGui.SameLine()
    local mtStickyChecked = (melee.mtSticky == true)
    local mtVal, mtPressed = ImGui.Checkbox('##combat_mtSticky', mtStickyChecked)
    if mtPressed then
        melee.mtSticky = mtVal
        runConfigLoaders()
    end

    ImGui.Text('Engage XTarget only')
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('When on, only engage mobs on your XTarget (Auto-Hater / aggro\'d on the group).\nUse with an external puller; stops proactive engaging of nearby NPCs. A manual /cz attack still works.')
    end
    ImGui.SameLine()
    local xtOnlyChecked = (botconfig.config.settings.engageXTargetOnly ~= false)
    local xtVal, xtPressed = ImGui.Checkbox('##combat_engageXTargetOnly', xtOnlyChecked)
    if xtPressed then
        botconfig.config.settings.engageXTargetOnly = xtVal
        runConfigLoaders()
    end

    -- Line 2: Stick Settings
    ImGui.Spacing()
    ImGui.Text('Stick Settings')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Stick command when engaging.') end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(300)
    local stickBuf = melee.stickcmd or ''
    local ImGuiInputTextFlags = ImGuiInputTextFlags or {}
    local flags = (ImGuiInputTextFlags.EnterReturnsTrue) or 0
    local stickNew, stickCh = ImGui.InputText('##combat_stickcmd', stickBuf, flags)
    if stickCh and stickNew ~= nil then melee.stickcmd = stickNew; runConfigLoaders() end

    ImGui.Spacing()
    ImGui.Text('Stay behind')
    if ImGui.IsItemHovered() then
        local stickTok = (mq.TLO.Me.Class.ShortName() == 'ROG') and 'behind' or '!front'
        ImGui.SetTooltip(string.format('When on and this bot is not the Main Tank, append %s to stick while engaging.', stickTok))
    end
    ImGui.SameLine()
    local stayBehindChecked = (melee.stayBehind == true)
    local sbVal, sbPressed = ImGui.Checkbox('##combat_stayBehind', stayBehindChecked)
    if sbPressed then melee.stayBehind = sbVal; runConfigLoaders() end
    if melee.stayBehind then
        ImGui.SameLine()
        ImGui.Text('Behind aggro %')
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('Above this Me.PctAggro (level 20+), stick without behind/!front until aggro drops.')
        end
        ImGui.SameLine()
        ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
        local baVal = melee.behindAggroPct or 90
        local baNew, baCh = inputs.boundedInt('combat_behindAggroPct', baVal, 0, 100, 5, '##combat_behindAggroPct')
        if baCh then melee.behindAggroPct = baNew; runConfigLoaders() end
    end

    if mq.TLO.Me.Class.ShortName() == 'ROG' then
        ImGui.Spacing()
        ImGui.Text('Evade aggro %')
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('At or above this Me.PctAggro (level 20+), use Hide to dump aggro during combat. Requires Hide ready.')
        end
        ImGui.SameLine()
        ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
        local evVal = melee.evadePct or 90
        local evNew, evCh = inputs.boundedInt('combat_evadePct', evVal, 0, 100, 5, '##combat_evadePct')
        if evCh then melee.evadePct = evNew; runConfigLoaders() end
    end

    -- Line 3: Min Mana (if class has mana pool)
    if mq.TLO.Me.MaxMana() and mq.TLO.Me.MaxMana() > 0 then
        ImGui.Spacing()
        ImGui.Text('Min Mana')
        if ImGui.IsItemHovered() then ImGui.SetTooltip('Min mana %% to engage.') end
        ImGui.SameLine()
        ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
        local mmVal = melee.minmana or 0
        local mmNew, mmCh = inputs.boundedInt('combat_minmana', mmVal, 0, 100, 5, '##combat_minmana')
        if mmCh then melee.minmana = mmNew; runConfigLoaders() end
    end
end

return M
