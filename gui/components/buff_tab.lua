-- Buff tab: dedicated panel for buff config (one spell_entry per buff).

local mq = require('mq')
local ImGui = require('ImGui')
local botconfig = require('lib.config')
local spell_entry = require('gui.widgets.spell_entry')
local inputs = require('gui.widgets.inputs')

local M = {}

local NUMERIC_INPUT_WIDTH = 80
local SPELICON_INPUT_WIDTH = 220

-- Per-spell-entry editable buffer for `spellicon`.
-- We display canonical spell name for the stored numeric spell ID, but we let the user input either
-- a spell ID or a spell name (validated and converted back to numeric spell ID).
local spelliconTextState = {}

local function resolveSpelliconName(spellicon)
    local sid = tonumber(spellicon)
    if not sid or sid == 0 then return '' end
    local name = mq.TLO.Spell(sid).Name()
    if type(name) == 'string' and name ~= '' then return name end
    return tostring(sid)
end

local PRIMARY_OPTIONS = {
    { value = 'gem',     label = 'Gem' },
    { value = 'item',    label = 'Item' },
    { value = 'ability', label = 'Ability' },
    { value = 'alt',     label = 'Alt' },
    { value = 'disc',    label = 'Disc' },
    { value = 'script',  label = 'Script' },
}

-- Phases for buff bands. Keys match spellbands and config default.
local TARGETPHASE_OPTIONS_BUFF = {
    { key = 'self',        label = 'Self',     tooltip = 'Buff self.' },
    { key = 'tank',        label = 'Tank',     tooltip = 'Buff tank (main assist).' },
    { key = 'groupmember', label = 'Group',    tooltip = 'Buff group members (class filter below).' },
    { key = 'pc',          label = 'PC',       tooltip = 'Buff other PCs/bots (class filter below).' },
    { key = 'mypet',       label = 'My Pet',   tooltip = 'Buff your pet.' },
    { key = 'pet',         label = 'Pet',      tooltip = 'Buff other group pets.' },
    { key = 'groupbuff',   label = 'Grp Buff', tooltip = 'Group AE buff.' },
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

local function buffCustomSection(entry, idPrefix, onChanged)
    -- spellicon row: input a spell ID or spell name (validated => stored as numeric spell ID)
    ImGui.Text('Check buff')
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Spell ID used to detect whether the target already has this buff. Input can be a spell name or a numeric spell ID. Empty/0 disables.')
    end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(SPELICON_INPUT_WIDTH)

    if not spelliconTextState[idPrefix] then
        spelliconTextState[idPrefix] = { buf = '', lastSpellicon = nil, error = nil }
    end
    local s = spelliconTextState[idPrefix]

    local current = entry.spellicon or 0
    if s.lastSpellicon ~= current then
        s.buf = resolveSpelliconName(current)
        s.lastSpellicon = current
        s.error = nil
    end

    local ImGuiInputTextFlags = ImGuiInputTextFlags or {}
    local flags = (ImGuiInputTextFlags.EnterReturnsTrue) or 0
    local newBuf, changed = ImGui.InputText('##' .. idPrefix .. '_spellicon', s.buf or '', flags)
    if changed and newBuf ~= nil then
        local trimmed = (newBuf:match('^%s*(.-)%s*$') or '')
        s.buf = newBuf
        local candidate = tonumber(trimmed) or trimmed

        if trimmed == '' or trimmed == '0' then
            entry.spellicon = 0
            s.lastSpellicon = 0
            s.error = nil
            s.buf = ''
            if onChanged then onChanged() end
        else
            local resolved = mq.TLO.Spell(candidate).ID()
            local sidNum = tonumber(resolved)
            if sidNum and sidNum > 0 then
                entry.spellicon = sidNum
                s.lastSpellicon = sidNum
                s.error = nil
                s.buf = resolveSpelliconName(sidNum) -- always display canonical name
                if onChanged then onChanged() end
            else
                s.error = 'Invalid spell ID/name'
            end
        end
    elseif ImGui.IsItemHovered() and s.error then
        ImGui.SetTooltip(s.error)
    end
    ImGui.Spacing()
    -- tarcnt row
    ImGui.Text('Target count')
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Minimum number of targets (e.g. group members in AE range) that must be present before this spell can be used. Used for group/AE buffs; 1 = no minimum.')
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
    ImGui.Spacing()
    -- In combat: allow this buff when mobs are in camp
    ImGui.Text('Allow in combat')
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Allow this buff to be cast when mobs are in camp.')
    end
    ImGui.SameLine()
    local inCbt = entry.inCombat == true
    local inCbtVal, inCbtPressed = ImGui.Checkbox('##' .. idPrefix .. '_inCombat', inCbt)
    if inCbtPressed then
        entry.inCombat = inCbtVal
        if onChanged then onChanged() end
    end
    -- Combat only (non-Bard): auto buff loop considers this spell only when mobs are in camp
    if mq.TLO.Me.Class.ShortName() ~= 'BRD' then
        ImGui.Spacing()
        ImGui.Text('Combat only')
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip(
                'Only consider this buff when mobs are in camp (not while idle). For short self buffs (e.g. Yaulp) so they are not refreshed every tick out of combat. Implies allow in combat for the auto buff loop.')
        end
        ImGui.SameLine()
        local cbtOnly = entry.combatOnly == true
        local cbtOnlyVal, cbtOnlyPressed = ImGui.Checkbox('##' .. idPrefix .. '_combatOnly', cbtOnly)
        if cbtOnlyPressed then
            entry.combatOnly = cbtOnlyVal
            if onChanged then onChanged() end
        end
    end
    -- In idle (Bard only): include in twist when no mobs in camp
    if mq.TLO.Me.Class.ShortName() == 'BRD' then
        ImGui.Text('In idle')
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('Include in twist when no mobs in camp (Bard only).')
        end
        ImGui.SameLine()
        local inIdle = entry.inIdle ~= false
        local inIdleVal, inIdlePressed = ImGui.Checkbox('##' .. idPrefix .. '_inIdle', inIdle)
        if inIdlePressed then
            entry.inIdle = inIdleVal
            if onChanged then onChanged() end
        end
    end
end

--- Draw the full Buff tab content.
function M.draw()
    local buff = botconfig.config.buff
    if not buff then return end
    local spells = buff.spells or {}
    buff.spells = spells
    spell_entry.drawTabIntro({ flagKey = 'dobuff', flagNoun = 'Buffing', isEmpty = #spells == 0,
        emptyHint = 'No buffs configured. Click "Add buff" below to create one.' })
    for i, entry in ipairs(spells) do
        spell_entry.draw(entry, {
            id = 'buff_' .. i,
            label = 'Buff ' .. i,
            collapsible = true,
            primaryOptions = PRIMARY_OPTIONS,
            onChanged = runConfigLoaders,
            displayCommonFields = true,
            customSection = buffCustomSection,
            targetphaseOptions = TARGETPHASE_OPTIONS_BUFF,
            validtargetsOptions = VALIDTARGETS_OPTIONS_PC_GROUP,
            showBandMinMax = false,
            showBandMinTarMaxtar = false,
            onDelete = function()
                table.remove(buff.spells, i); runConfigLoaders()
            end,
            deleteEntryLabel = 'Buff',
            entryIndex = i,
            entryCount = #spells,
            onMoveUp = (function(idx)
                return idx > 1 and function()
                    botconfig.swapSpellEntries('buff', idx, idx - 1)
                end or nil
            end)(i),
            onMoveDown = (function(idx)
                return idx < #spells and function()
                    botconfig.swapSpellEntries('buff', idx, idx + 1)
                end or nil
            end)(i),
        })
        ImGui.Separator()
    end

    -- Right-align "Add buff" button after the list
    local addLabel = 'Add buff'
    local addTextW = select(1, ImGui.CalcTextSize(addLabel))
    local addAvail = ImGui.GetContentRegionAvail()
    local addButtonWidth = addTextW + 24
    if addAvail and addAvail > 0 and addButtonWidth > 0 then
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() + addAvail - addButtonWidth)
    end
    if ImGui.Button(addLabel) then
        local defaultEntry = botconfig.getDefaultSpellEntry('buff')
        if defaultEntry then
            table.insert(buff.spells, defaultEntry)
            runConfigLoaders()
        end
    end
end

return M
