-- Cure tab: dedicated panel for cure config (one spell_entry per cure).

local ImGui = require('ImGui')
local botconfig = require('lib.config')
local spell_entry = require('gui.widgets.spell_entry')
local labeled_grid = require('gui.widgets.labeled_grid')
local inputs = require('gui.widgets.inputs')

local M = {}

local NUMERIC_INPUT_WIDTH = 80

-- Cure type options for the checkbox grid. Keys match botcure (all, poison, disease, curse, corruption).
local CURETYPE_OPTIONS = {
    { key = 'all',        label = 'All',        tooltip = 'Any detrimental.' },
    { key = 'poison',     label = 'Poison',     tooltip = 'Poison only.' },
    { key = 'disease',    label = 'Disease',    tooltip = 'Disease only.' },
    { key = 'curse',      label = 'Curse',      tooltip = 'Curse only.' },
    { key = 'corruption', label = 'Corruption', tooltip = 'Corruption only.' },
}

local PRIMARY_OPTIONS = {
    { value = 'gem',     label = 'Gem' },
    { value = 'item',    label = 'Item' },
    { value = 'ability', label = 'Ability' },
    { value = 'alt',     label = 'Alt' },
    { value = 'disc',    label = 'Disc' },
    { value = 'script',  label = 'Script' },
}

-- Phases for cure bands. Keys match spellbands and config default.
local TARGETPHASE_OPTIONS_CURE = {
    { key = 'self',        label = 'Self',     tooltip = 'Cure self.' },
    { key = 'tank',        label = 'Tank',     tooltip = 'Cure tank (main assist).' },
    { key = 'groupcure',   label = 'Grp Cure', tooltip = 'Group AE cures.' },
    { key = 'groupmember', label = 'Group',    tooltip = 'Cure group members (class filter below).' },
    { key = 'pc',          label = 'PC',       tooltip = 'Cure other PCs/bots (class filter below).' },
}

-- PC/groupmember target options (class filter). Keys match spellbands CLASS_TOKENS.
local VALIDTARGETS_OPTIONS_PC_GROUP = {
    { key = 'all', label = 'All', tooltip = 'All classes.' },
    { key = 'war', label = 'WAR', tooltip = 'Warrior' },
    { key = 'shd', label = 'SHD', tooltip = 'Shadowknight' },
    { key = 'pal', label = 'PAL', tooltip = 'Paladin' },
    { key = 'rng', label = 'RNG', tooltip = 'Ranger' },
    { key = 'mnk', label = 'MNK', tooltip = 'Monk' },
    { key = 'rog', label = 'ROG', tooltip = 'Rogue' },
    { key = 'brd', label = 'BRD', tooltip = 'Bard' },
    { key = 'bst', label = 'BST', tooltip = 'Beastlord' },
    { key = 'ber', label = 'BER', tooltip = 'Berserker' },
    { key = 'shm', label = 'SHM', tooltip = 'Shaman' },
    { key = 'clr', label = 'CLR', tooltip = 'Cleric' },
    { key = 'dru', label = 'DRU', tooltip = 'Druid' },
    { key = 'wiz', label = 'WIZ', tooltip = 'Wizard' },
    { key = 'mag', label = 'MAG', tooltip = 'Mage' },
    { key = 'enc', label = 'ENC', tooltip = 'Enchanter' },
    { key = 'nec', label = 'NEC', tooltip = 'Necromancer' },
}

local function runConfigLoaders()
    botconfig.ApplyAndPersist()
end

local function curetypeCustomSection(entry, idPrefix, onChanged)
    if type(entry.curetype) ~= 'table' or #entry.curetype == 0 then
        entry.curetype = { 'all' }
    end
    labeled_grid.checkboxGrid({
        id = idPrefix .. '_curetype',
        label = 'Cure type:',
        options = CURETYPE_OPTIONS,
        value = entry.curetype,
        columns = 5,
        onToggle = function(key, isChecked)
            if isChecked then
                entry.curetype[#entry.curetype + 1] = key
            else
                for i = #entry.curetype, 1, -1 do
                    if entry.curetype[i] == key then
                        table.remove(entry.curetype, i)
                        break
                    end
                end
            end
            if onChanged then onChanged() end
        end,
    })
    ImGui.Spacing()
    -- tarcnt row
    ImGui.Text('Target count')
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Minimum number of targets (e.g. group members in AE range) that must be present before this spell can be used. 1 = no minimum.')
    end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
    local tc = entry.tarcnt
    if tc == nil then tc = 1 end
    local newTc, tcCh = inputs.boundedInt(idPrefix .. '_tarcnt', tc, 1, 10, 1, '##' .. idPrefix .. '_tarcnt')
    if tcCh then
        entry.tarcnt = newTc
        if onChanged then onChanged() end
    end
end

--- Draw the full Cure tab content.
function M.draw()
    local cure = botconfig.config.cure
    if not cure then return end
    if not cure.spells then cure.spells = {} end
    local spells = cure.spells
    for i, entry in ipairs(spells) do
        spell_entry.draw(entry, {
            id = 'cure_' .. i,
            label = 'Cure ' .. i,
            collapsible = true,
            primaryOptions = PRIMARY_OPTIONS,
            onChanged = runConfigLoaders,
            displayCommonFields = true,
            customSection = curetypeCustomSection,
            targetphaseOptions = TARGETPHASE_OPTIONS_CURE,
            validtargetsOptions = VALIDTARGETS_OPTIONS_PC_GROUP,
            showBandMinMax = false,
            showBandMinTarMaxtar = false,
            onDelete = function()
                table.remove(cure.spells, i); runConfigLoaders()
            end,
            deleteEntryLabel = 'Cure',
            entryIndex = i,
            entryCount = #spells,
            onMoveUp = i > 1 and function()
                spells[i], spells[i - 1] = spells[i - 1], spells[i]
                runConfigLoaders()
            end or nil,
            onMoveDown = i < #spells and function()
                spells[i], spells[i + 1] = spells[i + 1], spells[i]
                runConfigLoaders()
            end or nil,
        })
        ImGui.Separator()
    end

    -- Right-align "Add cure" button after the list
    local addLabel = 'Add cure'
    local addTextW = select(1, ImGui.CalcTextSize(addLabel))
    local addAvail = ImGui.GetContentRegionAvail()
    local addButtonWidth = addTextW + 24
    if addAvail and addAvail > 0 and addButtonWidth > 0 then
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() + addAvail - addButtonWidth)
    end
    if ImGui.Button(addLabel) then
        local defaultEntry = botconfig.getDefaultSpellEntry('cure')
        if defaultEntry then
            table.insert(cure.spells, defaultEntry)
            runConfigLoaders()
        end
    end
end

return M
