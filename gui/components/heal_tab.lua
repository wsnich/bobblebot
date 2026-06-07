-- Heal tab: dedicated panel for heal config (one spell_entry per heal).

local ImGui = require('ImGui')
local botconfig = require('lib.config')
local spellutils = require('lib.spellutils')
local spell_entry = require('gui.widgets.spell_entry')
local inputs = require('gui.widgets.inputs')

local M = {}

local NUMERIC_INPUT_WIDTH = 80

local PRIMARY_OPTIONS = {
    { value = 'gem',     label = 'Gem' },
    { value = 'item',    label = 'Item' },
    { value = 'ability', label = 'Ability' },
    { value = 'alt',     label = 'Alt' },
    { value = 'disc',    label = 'Disc' },
    { value = 'script',  label = 'Script' },
}

-- Order matches botheal HEAL_PHASE_ORDER.
local TARGETPHASE_OPTIONS_HEAL = {
    { key = 'corpse',      label = 'Corpse',   tooltip = 'Resurrect PC corpses.' },
    { key = 'self',        label = 'Self',     tooltip = 'Heal self.' },
    { key = 'groupheal',   label = 'Grp Heal', tooltip = 'Group AE heals' },
    { key = 'tank',        label = 'Tank',     tooltip = 'Heal tank (main assist).' },
    { key = 'groupmember', label = 'Group',    tooltip = 'Heal group members (class filter below).' },
    { key = 'pc',          label = 'PC',       tooltip = 'Heal other PCs/bots (class filter below).' },
    { key = 'mypet',       label = 'My Pet',   tooltip = 'Heal your pet.' },
    { key = 'pet',         label = 'Pet',      tooltip = 'Heal other group pets.' },
    { key = 'xtgt',        label = 'XTarget',  tooltip = 'Heal extended targets.' },
}

local function bandHasPhase(entry, phase)
    local bands = entry and entry.bands
    if not bands or type(bands) ~= 'table' then return false end
    for _, band in ipairs(bands) do
        local tp = band.targetphase
        if type(tp) == 'table' then
            for _, p in ipairs(tp) do
                if p == phase then return true end
            end
        end
    end
    return false
end

-- PC/groupmember-phase target options (class filter). Keys match spellbands CLASS_TOKENS.
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

-- Options per phase for Option B: show only targets relevant to selected phases.
local VALIDTARGETS_OPTIONS_PER_PHASE_HEAL = {
    groupmember = VALIDTARGETS_OPTIONS_PC_GROUP,
    pc = VALIDTARGETS_OPTIONS_PC_GROUP,
}

local function runConfigLoaders()
    botconfig.ApplyAndPersist()
end

local function healCustomSection(entry, idPrefix, onChanged)
    -- Heal resource: HP (band min/max) or Mana (Mana % min/max only)
    ImGui.Text('Heal resource:')
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('HP = target HP %% gate (band min/max). Mana = caster mana %% gate only (use Mana %% below; for e.g. Harvest).')
    end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(60)
    local healRes = entry.healResource or 'hp'
    if ImGui.BeginCombo('##' .. idPrefix .. '_healResource', healRes == 'mana' and 'Mana' or 'HP') then
        if ImGui.Selectable('HP', healRes == 'hp') then
            entry.healResource = 'hp'
            if onChanged then onChanged() end
        end
        if ImGui.Selectable('Mana', healRes == 'mana') then
            entry.healResource = 'mana'
            if onChanged then onChanged() end
        end
        ImGui.EndCombo()
    end
    ImGui.SameLine()
    -- Mana % row: Min / Max (only cast when caster mana is within range)
    ImGui.Text('Mana %:')
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Only cast when your mana %% is within min-max. 0-100.')
    end
    ImGui.SameLine()
    ImGui.Text('Min')
    ImGui.SameLine()
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
    local minPct = entry.minmanapct
    if minPct == nil then minPct = 0 end
    local newMin, minCh = inputs.boundedInt(idPrefix .. '_minmanapct', minPct, 0, 100, 1, '##' .. idPrefix .. '_minmanapct')
    if minCh then
        entry.minmanapct = newMin
        if onChanged then onChanged() end
    end
    ImGui.SameLine()
    ImGui.Text('Max')
    ImGui.SameLine()
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
    local maxPct = entry.maxmanapct
    if maxPct == nil then maxPct = 100 end
    local newMax, maxCh = inputs.boundedInt(idPrefix .. '_maxmanapct', maxPct, 0, 100, 1, '##' .. idPrefix .. '_maxmanapct')
    if maxCh then
        entry.maxmanapct = newMax
        if onChanged then onChanged() end
    end
    ImGui.Spacing()
    -- tarcnt row
    ImGui.Text('Target count')
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Minimum number of targets (e.g. group members in AE range) that must be present before this spell can be used. Used for group/AE heals; 1 = no minimum.')
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
    -- In combat (rez only): show only when corpse is in a band
    if bandHasPhase(entry, 'corpse') then
        ImGui.Spacing()
        ImGui.Text('Allow rez in combat')
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('When checked, this rez can be cast when mobs are in camp.')
        end
        ImGui.SameLine()
        local inCbt = entry.inCombat == true
        local inCbtVal, inCbtPressed = ImGui.Checkbox('##' .. idPrefix .. '_inCombat', inCbt)
        if inCbtPressed then
            entry.inCombat = inCbtVal
            if onChanged then onChanged() end
        end
    end
end

--- Draw the full Heal tab content.
function M.draw()
    local heal = botconfig.config.heal
    if not heal then return end
    if not heal.spells then heal.spells = {} end
    local spells = heal.spells
    if not spells then return end
    for i, entry in ipairs(spells) do
        local detectedTypeLabel = spellutils.IsHoTSpell(entry) and 'HoT' or nil
        spell_entry.draw(entry, {
            id = 'heal_' .. i,
            label = 'Heal ' .. i,
            collapsible = true,
            detectedTypeLabel = detectedTypeLabel,
            primaryOptions = PRIMARY_OPTIONS,
            onChanged = runConfigLoaders,
            displayCommonFields = true,
            customSection = healCustomSection,
            targetphaseOptions = TARGETPHASE_OPTIONS_HEAL,
            validtargetsOptions = {},
            validtargetsOptionsPerPhase = VALIDTARGETS_OPTIONS_PER_PHASE_HEAL,
            showBandMinMax = true,
            showBandMinTarMaxtar = false,
            onDelete = function()
                table.remove(heal.spells, i); runConfigLoaders()
            end,
            deleteEntryLabel = 'Heal',
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

    -- Right-align "Add heal" button after the list
    local addLabel = 'Add heal'
    local addTextW = select(1, ImGui.CalcTextSize(addLabel))
    local addAvail = ImGui.GetContentRegionAvail()
    local addButtonWidth = addTextW + 24
    if addAvail and addAvail > 0 and addButtonWidth > 0 then
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() + addAvail - addButtonWidth)
    end
    if ImGui.Button(addLabel) then
        local defaultEntry = botconfig.getDefaultSpellEntry('heal')
        if defaultEntry then
            table.insert(heal.spells, defaultEntry)
            runConfigLoaders()
        end
    end
end

return M
