-- Generic spell/ability entry widget: gem type + spell name with type-based validation.
-- Signature: M.draw(spell, opts)
--   spell: spell entry table to read/write (e.g. config.pull.spell or config.heal.spells[i]).
--   opts: required id (string), primaryOptions (table); optional label, onChanged, displayCommonFields (default true),
--         showRange (default false), collapsible (default false): when true, wrap entry in ImGui.CollapsingHeader; default
--         collapsed on first use (ImGuiCond.FirstUseEver). customSection, targetphaseOptions, validtargetsOptions,
--         validtargetsOptionsPerPhase, showBandMinMax, showBandMinTarMaxtar, entryIndex, entryCount, onMoveUp, onMoveDown.
--         customSection(entry, idPrefix, onChanged).
--   targetphaseOptions / validtargetsOptions: each entry { key, label, tooltip }.
--   validtargetsOptionsPerPhase: optional; when set, target options shown are those for this band's selected phases only (phase -> options array).
-- Widths are hardcoded; caller does not control layout. All widget IDs use opts.id as prefix.

local mq = require('mq')
local ImGui = require('ImGui')
local Icons = require('mq.ICONS')
local combos = require('gui.widgets.combos')
local inputs = require('gui.widgets.inputs')
local labeled_grid = require('gui.widgets.labeled_grid')
local modals = require('gui.widgets.modals')

local M = {}

local GEM_SUB_OPTIONS = {}
for i = 1, 12 do GEM_SUB_OPTIONS[i] = tostring(i) end

--- Map config gem value to (primary, sub). Config gem is number 1-12 or string.
--- Accepts string "1"-"12" from config so selection of lower gem numbers persists after load.
local function gemToPrimarySub(gem)
    if type(gem) == 'number' and gem >= 1 and gem <= 12 then
        return 'gem', gem
    end
    if type(gem) == 'string' then
        local n = tonumber(gem)
        if n and n >= 1 and n <= 12 then
            return 'gem', n
        end
        return gem, 1
    end
    return 'melee', 1
end

--- Map (primary, sub) to config gem value.
local function primarySubToGem(primary, sub)
    if primary == 'gem' then return sub end
    return primary
end

--- Validators return success, errorMessage.
--- Me.Book(name) returns slot number if spell is in book (no BookSize in MQ Lua).
local function validateSpellInBook(name)
    if not name or name:match('^%s*$') then return false, 'Enter a spell name' end
    name = name:match('^%s*(.-)%s*$')
    local book = mq.TLO.Me and mq.TLO.Me.Book and mq.TLO.Me.Book(name)
    if not book then return false, 'Spell not in your spell book' end
    local ok, slot = pcall(function() return book() end)
    if ok and slot and slot > 0 then return true end
    return false, 'Spell not in your spell book'
end

local function validateFindItem(name)
    if not name or name:match('^%s*$') then return false, 'Enter an item name' end
    name = name:match('^%s*(.-)%s*$')
    local fi = mq.TLO.FindItem(name)
    if not fi then return false, 'Item not found in inventory' end
    local result = fi()
    if result ~= nil and result ~= '' and result ~= 0 then return true end
    return false, 'Item not found in inventory'
end

local function validateAltAbility(name)
    if not name or name:match('^%s*$') then return false, 'Enter an AA name' end
    name = name:match('^%s*(.-)%s*$')
    local aa = mq.TLO.Me.AltAbility(name)
    local aaId = aa and aa.ID and aa.ID()
    if tonumber(aaId) and tonumber(aaId) > 0 then return true end
    return false, 'Alt ability not found'
end

local function validateDiscipline(name)
    if not name or name:match('^%s*$') then return false, 'Enter a discipline name' end
    name = name:match('^%s*(.-)%s*$')
    local ca = mq.TLO.Me and mq.TLO.Me.CombatAbility and mq.TLO.Me.CombatAbility(name)
    if not ca then return false, 'Discipline not found' end
    local ok, slot = pcall(function() return ca() end)
    if ok and tonumber(slot) and tonumber(slot) > 0 then return true end
    return false, 'Discipline not found'
end

local function validateAbility(name)
    if not name or name:match('^%s*$') then return false, 'Enter an ability name' end
    name = name:match('^%s*(.-)%s*$')
    local ab = mq.TLO.Me and mq.TLO.Me.Ability and mq.TLO.Me.Ability(name)
    if not ab then return false, 'Ability not found' end
    local ok, slot = pcall(function() return ab() end)
    if ok and tonumber(slot) and tonumber(slot) > 0 then return true end
    return false, 'Ability not found'
end

local function validateScriptKey(name)
    if not name or name:match('^%s*$') then return false, 'Enter a script key' end
    return true
end

local function validatorForGemType(gemType)
    if gemType == 'gem' then return validateSpellInBook end
    if gemType == 'ranged' or gemType == 'item' then return validateFindItem end
    if gemType == 'alt' then return validateAltAbility end
    if gemType == 'disc' then return validateDiscipline end
    if gemType == 'ability' then return validateAbility end
    if gemType == 'script' then return validateScriptKey end
    return nil
end

-- Gem types that do not use the spell/item/ability field (display "unused", not editable).
local UNUSED_SPELL_TYPES = { melee = true }

--- Short label for the spell/item/ability column based on gem type (for single-row layout).
local function fieldLabelForGemType(gemType)
    if gemType == 'gem' then return 'Spell' end
    if gemType == 'ranged' or gemType == 'item' then return 'Item' end
    if gemType == 'ability' then return 'Ability' end
    if gemType == 'alt' then return 'Alt' end
    if gemType == 'disc' then return 'Disc' end
    if gemType == 'script' then return 'Script' end
    return 'Spell'
end

-- UI state keyed by spell entry table so expand/edit buffers follow entries across reorder.
local _entryState = setmetatable({}, { __mode = 'k' })

local TYPE_COMBO_WIDTH = 100
local SPELL_SELECTABLE_WIDTH = 140
local MIN_SPELL_SELECTABLE_WIDTH = 70
local NUMERIC_INPUT_WIDTH = 80
local ALIAS_INPUT_WIDTH = 100

local function hasAnyPhase(phases, wanted)
    if type(phases) ~= 'table' then return false end
    local wantedSet = {}
    for _, key in ipairs(wanted or {}) do
        wantedSet[key] = true
    end
    for _, phase in ipairs(phases) do
        if wantedSet[phase] then return true end
    end
    return false
end

local GREEN = ImVec4(0, 0.8, 0, 1)
local RED = ImVec4(1, 0, 0, 1)
local BLACK = ImVec4(0, 0, 0, 1)

local function calcRightControlsWidth(opts)
    local enabledIconW = select(1, ImGui.CalcTextSize(Icons.FA_TOGGLE_ON))
    local enabledButtonWidth = (enabledIconW or 0) + 24
    local deleteButtonWidth = 0
    if opts.onDelete then
        local trashW = select(1, ImGui.CalcTextSize(Icons.FA_TRASH))
        deleteButtonWidth = (trashW or 0) + 24
    end
    local entryCount = opts.entryCount or 0
    local showMoveUp = entryCount > 1 and opts.onMoveUp
    local showMoveDown = entryCount > 1 and opts.onMoveDown
    local moveUpIconW = showMoveUp and select(1, ImGui.CalcTextSize(Icons.FA_CARET_UP)) or 0
    local moveDownIconW = showMoveDown and select(1, ImGui.CalcTextSize(Icons.FA_CARET_DOWN)) or 0
    local moveUpButtonWidth = showMoveUp and ((moveUpIconW or 0) + 24) or 0
    local moveDownButtonWidth = showMoveDown and ((moveDownIconW or 0) + 24) or 0
    local reorderButtonWidth = moveUpButtonWidth + moveDownButtonWidth
    if reorderButtonWidth > 0 and (showMoveUp and showMoveDown) then
        reorderButtonWidth = reorderButtonWidth + 4
    end
    return enabledButtonWidth
        + (opts.onDelete and (deleteButtonWidth + 4) or 0)
        + (reorderButtonWidth > 0 and (reorderButtonWidth + 4) or 0)
end

--- Draw spell entry: label, type combo, spell/item/ability selectable; optionally range, common fields, customSection.
--- @param spell table spell entry to read/write
--- @param opts table required: id (string), primaryOptions (table). optional: label, onChanged, displayCommonFields (default true), showRange (default false), collapsible (default false), customSection(entry, idPrefix, onChanged), targetphaseOptions, validtargetsOptions, validtargetsOptionsPerPhase, showBandMinMax, showBandMinTarMaxtar. targetphaseOptions/validtargetsOptions entries: { key, label, tooltip }. validtargetsOptionsPerPhase: optional table phase -> options; when set, targets row shows only options for this band's selected phases.
function M.draw(spell, opts)
    opts = opts or {}
    local id = opts.id
    local primaryOptions = opts.primaryOptions
    if not id or not primaryOptions then return end
    local labelText = opts.label or 'Type'
    local onChanged = opts.onChanged
    local displayCommonFields = opts.displayCommonFields
    if displayCommonFields == nil then displayCommonFields = true end
    local showRange = opts.showRange or false

    if not _entryState[spell] then
        _entryState[spell] = { open = false, buffer = '', error = nil }
    end
    local state = _entryState[spell]
    if opts.onDelete and not state.deleteConfirm then
        state.deleteConfirm = { open = false, pendingClose = nil }
    end
    if state.deleteConfirm and state.deleteConfirm.open then
        modals.deleteConfirmModal(id, state.deleteConfirm, opts.deleteEntryLabel or 'entry', opts.onDelete, function()
            state.deleteConfirm.open = false
            state.deleteConfirm.pendingClose = nil
        end)
    end
    local function ensureEditBuffers()
        if state.aliasBuf == nil then
            state.aliasBuf = (type(spell.alias) == 'string' and spell.alias or '')
        end
        if state.preconditionBuf == nil then
            local p = spell.precondition
            -- Precondition is string or nil; display any string as-is, nil as ''
            state.preconditionBuf = (type(p) == 'string' and p or '')
        elseif type(spell.precondition) == 'string' and state.preconditionBuf ~= spell.precondition then
            -- Sync buffer from spell so any stored string is always displayed (e.g. after config load)
            state.preconditionBuf = spell.precondition
        end
    end

    if opts.collapsible then
        local gtHeader = type(spell.gem) == 'number' and 'gem' or spell.gem
        local spellNameForHeader
        if UNUSED_SPELL_TYPES[gtHeader] then
            spellNameForHeader = 'unused'
        elseif not spell.spell or spell.spell:match('^%s*$') then
            spellNameForHeader = 'unset'
        else
            spellNameForHeader = spell.spell:match('^%s*(.-)%s*$') or 'unset'
        end
        -- Use ### so ImGui IDs only the stable suffix; dynamic spell text would otherwise change the ID and re-apply FirstUseEver (collapse).
        -- expanded is stored on the spell entry table (via _entryState) so reorder keeps the same entries open/closed.
        if state.expanded == nil then state.expanded = false end
        ImGui.SetNextItemOpen(state.expanded, ImGuiCond.Always)
        local expanded = ImGui.CollapsingHeader(string.format('%s — %s###%s', labelText, spellNameForHeader, id .. '_collapse'))
        state.expanded = expanded
        if not expanded then
            return
        end
    end

    local gemType = type(spell.gem) == 'number' and 'gem' or spell.gem

    ImGui.Text('%s', labelText)
    if opts.detectedTypeLabel and opts.detectedTypeLabel ~= '' then
        ImGui.SameLine()
        ImGui.TextDisabled('(%s)', opts.detectedTypeLabel)
        if ImGui.IsItemHovered() then ImGui.SetTooltip('Auto-detected spell type') end
    end
    if opts.detectedTypeLabel2 and opts.detectedTypeLabel2 ~= '' then
        ImGui.SameLine()
        ImGui.TextDisabled('(%s)', opts.detectedTypeLabel2)
        if ImGui.IsItemHovered() then ImGui.SetTooltip('Targeted AE spell') end
    end
    ImGui.SameLine()
    local primary, sub = gemToPrimarySub(spell.gem)
    ImGui.SetNextItemWidth(TYPE_COMBO_WIDTH)
    local newPrimary, newSub, gemChanged = combos.nestedCombo(id .. '_gem', primaryOptions, 'gem', GEM_SUB_OPTIONS,
        primary, sub, TYPE_COMBO_WIDTH)
    if gemChanged then
        spell.gem = primarySubToGem(newPrimary, newSub)
        if newPrimary == 'gem' then
            local name = mq.TLO.Me and mq.TLO.Me.Gem and mq.TLO.Me.Gem(newSub)
            if name then
                local ok, spellName = pcall(function() return name() end)
                if ok and spellName and spellName ~= '' then
                    spell.spell = spellName
                else
                    spell.spell = spell.spell or ''
                end
            else
                spell.spell = spell.spell or ''
            end
        end
        if onChanged then onChanged() end
    end

    if gemType ~= 'melee' then
        ImGui.SameLine()
        ImGui.Text('%s', fieldLabelForGemType(type(spell.gem) == 'number' and 'gem' or spell.gem))
        ImGui.SameLine()
    end
    if gemType ~= 'melee' then
        local isUnused = UNUSED_SPELL_TYPES[gemType] == true
        local validator = validatorForGemType(gemType) or function() return true end
        local function onSave(value)
            spell.spell = (value or ''):match('^%s*(.-)%s*$')
            state.open = false
            state.buffer = ''
            if onChanged then onChanged() end
        end
        local function onCancel()
            state.open = false
            state.buffer = ''
            state.error = nil
        end

        local displayName
        if isUnused then
            displayName = 'unused'
        elseif not spell.spell or spell.spell:match('^%s*$') then
            displayName = 'unset'
        else
            displayName = spell.spell
        end
        local reservedRight = displayCommonFields and calcRightControlsWidth(opts) or 0
        local availSpell = ImGui.GetContentRegionAvail()
        local spellWidth = SPELL_SELECTABLE_WIDTH
        if reservedRight > 0 and availSpell then
            spellWidth = math.min(SPELL_SELECTABLE_WIDTH,
                math.max(MIN_SPELL_SELECTABLE_WIDTH, availSpell - reservedRight - 4))
        end
        ImGui.SetNextItemWidth(spellWidth)
        ---@diagnostic disable-next-line: undefined-global
        if ImGui.Selectable(displayName .. '##' .. id .. '_ro', false, 0, ImVec2(spellWidth, 0)) then
            if not isUnused then
                state.open = true
                state.buffer = spell.spell or ''
                state.error = nil
                modals.openValidatedEditModal(id)
            end
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip(isUnused and 'Not used for this type' or 'Click to edit')
        end

        if state.open and not isUnused then
            modals.validatedEditModal(id, state, validator, onSave, onCancel)
        end
    end

    if showRange then
        local rangeLabelW = select(1, ImGui.CalcTextSize('Range'))
        local rangeLabelWidth = (rangeLabelW or 0) + 4
        local rangeTotalWidth = rangeLabelWidth + NUMERIC_INPUT_WIDTH
        local avail = ImGui.GetContentRegionAvail()
        if avail and avail > rangeTotalWidth then
            ImGui.SameLine(ImGui.GetCursorPosX() + avail - rangeTotalWidth)
        else
            ImGui.SameLine()
        end
        ImGui.Text('Range')
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip(
                'Max range to use when casting the pull spell (0 = use spell default).')
        end
        ImGui.SameLine()
        ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
        local r = spell.range or 0
        local newR, rChanged = inputs.boundedInt(id .. '_range', r, 0, 500, 5, '##' .. id .. '_range')
        if rChanged then
            spell.range = newR
            if onChanged then onChanged() end
        end
    end

    if displayCommonFields then
        local enabled = spell.enabled ~= false
        local enabledIcon = enabled and Icons.FA_TOGGLE_ON or Icons.FA_TOGGLE_OFF
        local enabledColor = enabled and GREEN or RED
        local entryCount = opts.entryCount or 0
        local showMoveUp = entryCount > 1 and opts.onMoveUp
        local showMoveDown = entryCount > 1 and opts.onMoveDown
        local totalRightWidth = calcRightControlsWidth(opts)
        local availEnabled = ImGui.GetContentRegionAvail()
        if availEnabled and availEnabled > totalRightWidth then
            ImGui.SameLine(ImGui.GetCursorPosX() + availEnabled - totalRightWidth)
        else
            ImGui.SameLine()
        end
        if showMoveUp then
            if ImGui.SmallButton(Icons.FA_CARET_UP .. '##' .. id .. '_move_up') then
                opts.onMoveUp()
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Move up')
            end
            ImGui.SameLine()
        end
        if showMoveDown then
            if ImGui.SmallButton(Icons.FA_CARET_DOWN .. '##' .. id .. '_move_down') then
                opts.onMoveDown()
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Move down')
            end
            ImGui.SameLine()
        end
        if opts.onDelete then
            ImGui.PushStyleColor(ImGuiCol.Button, BLACK)
            ImGui.PushStyleColor(ImGuiCol.Text, RED)
            if ImGui.SmallButton(Icons.FA_TRASH .. '##' .. id .. '_delete') then
                state.deleteConfirm.open = true
                state.deleteConfirm.pendingClose = nil
                modals.openDeleteConfirmModal(id)
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Delete this %s', opts.deleteEntryLabel or 'entry')
            end
            ImGui.PopStyleColor(2)
            ImGui.SameLine()
        end
        ImGui.PushStyleColor(ImGuiCol.Button, BLACK)
        ImGui.PushStyleColor(ImGuiCol.Text, enabledColor)
        if ImGui.Button(enabledIcon .. '##' .. id .. '_enabled') then
            spell.enabled = not (spell.enabled ~= false)
            if onChanged then onChanged() end
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip(enabled and 'On' or 'Off')
        end
        ImGui.PopStyleColor(2)
    end

    if displayCommonFields then
        ensureEditBuffers()
        -- Second line: Alias, Min mana, Announce (order left to right)
        ImGui.Text('Alias')
        if ImGui.IsItemHovered() then ImGui.SetTooltip('Optional display name or key for spell DB lookup.') end
        ImGui.SameLine()
        ImGui.SetNextItemWidth(ALIAS_INPUT_WIDTH)
        local aliasBuf, aliasChanged = ImGui.InputText('##' .. id .. '_alias', state.aliasBuf or '')
        if aliasChanged then
            state.aliasBuf = aliasBuf
            spell.alias = (aliasBuf == '' and false or aliasBuf)
            if onChanged then onChanged() end
        end
        ImGui.SameLine()
        ImGui.Text('Min mana')
        if ImGui.IsItemHovered() then ImGui.SetTooltip('Minimum mana %% (or endurance) required to cast.') end
        ImGui.SameLine()
        ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
        local mn = spell.minmana or 0
        local newMn, mnChanged = inputs.boundedInt(id .. '_minmana', mn, 0, 100, 1, '##' .. id .. '_minmana')
        if mnChanged then
            spell.minmana = newMn
            if onChanged then onChanged() end
        end
        ImGui.SameLine()
        ImGui.Text('Announce')
        if ImGui.IsItemHovered() then ImGui.SetTooltip('Announce in console when this spell is cast.') end
        ImGui.SameLine()
        local ann = spell.announce == true
        local annValue, annPressed = ImGui.Checkbox('##' .. id .. '_announce', ann)
        if annPressed then
            spell.announce = annValue
            if onChanged then onChanged() end
        end
        ImGui.Spacing()
        -- After this we'll put the caller-provided custom widgets.
        if opts.customSection then
            opts.customSection(spell, id .. '_custom', onChanged)
        end
        -- Bands widget
        local targetphaseOptions = opts.targetphaseOptions or {}
        local validtargetsOptions = opts.validtargetsOptions or {}
        local targetsColumns = opts.targetsColumns or 6
        local showBandMinMax = opts.showBandMinMax == true
        local showBandAggroMinMax = opts.showBandAggroMinMax == true
        local showBandMinTarMaxtar = opts.showBandMinTarMaxtar == true
        if not spell.bands or #spell.bands == 0 then
            spell.bands = { { targetphase = {}, validtargets = {} } }
        end
        if #targetphaseOptions > 0 then
            for bi = 1, #spell.bands do
                local band = spell.bands[bi]
                if not band.targetphase then band.targetphase = {} end
                if not band.validtargets then band.validtargets = {} end
                -- Phases: 5 columns when one band or band 1; 4 columns when Delete is visible (bi > 1)
                local phasesColumns = (bi > 1) and 4 or (opts.phasesColumns or 5)
                local phaseGridOpts = {
                    id = id .. '_band' .. bi .. '_ph',
                    label = 'Phases:',
                    options = targetphaseOptions,
                    value = band.targetphase,
                    columns = phasesColumns,
                    onToggle = function(key, isChecked)
                        if isChecked then
                            band.targetphase[#band.targetphase + 1] = key
                        else
                            for i = #band.targetphase, 1, -1 do
                                if band.targetphase[i] == key then
                                    table.remove(band.targetphase, i)
                                    break
                                end
                            end
                        end
                        if onChanged then onChanged() end
                    end,
                }
                if bi > 1 then
                    local delW = select(1, ImGui.CalcTextSize('Delete')) + 24
                    local avail = ImGui.GetContentRegionAvail()
                    phaseGridOpts.maxWidth = (avail and avail > delW) and (avail - delW) or 0
                end
                labeled_grid.checkboxGrid(phaseGridOpts)
                if bi > 1 then
                    local delW = select(1, ImGui.CalcTextSize('Delete')) + 24
                    local availDel = ImGui.GetContentRegionAvail()
                    if availDel and availDel > delW then ImGui.SameLine(ImGui.GetCursorPosX() + availDel - delW) end
                    if ImGui.Button('Delete##' .. id .. '_band_del' .. bi) then
                        table.remove(spell.bands, bi)
                        if onChanged then onChanged() end
                        break
                    end
                end
                -- Targets row: show options from validtargetsOptionsPerPhase (for this band's selected phases) or validtargetsOptions
                local validtargetsOptionsPerPhase = opts.validtargetsOptionsPerPhase or {}
                local effectiveTargetOpts = {}
                if next(validtargetsOptionsPerPhase) then
                    local seen = {}
                    for _, phase in ipairs(band.targetphase) do
                        local phaseOpts = validtargetsOptionsPerPhase[phase]
                        if phaseOpts then
                            for _, opt in ipairs(phaseOpts) do
                                if opt.key and not seen[opt.key] then
                                    seen[opt.key] = true
                                    effectiveTargetOpts[#effectiveTargetOpts + 1] = opt
                                end
                            end
                        end
                    end
                else
                    effectiveTargetOpts = validtargetsOptions
                end
                local showTargetsForPhase = hasAnyPhase(band.targetphase, { 'groupmember', 'pc' })
                if showTargetsForPhase and #effectiveTargetOpts > 0 then
                    labeled_grid.checkboxGrid({
                        id = id .. '_band' .. bi .. '_vt',
                        label = 'Targets:',
                        options = effectiveTargetOpts,
                        value = band.validtargets,
                        columns = targetsColumns,
                        onToggle = function(key, isChecked)
                            if isChecked then
                                if key == 'all' then
                                    band.validtargets = { 'all' }
                                else
                                    local exists = false
                                    for _, selected in ipairs(band.validtargets) do
                                        if selected == key then
                                            exists = true
                                            break
                                        end
                                    end
                                    if not exists then
                                        band.validtargets[#band.validtargets + 1] = key
                                    end
                                    for i = #band.validtargets, 1, -1 do
                                        if band.validtargets[i] == 'all' then
                                            table.remove(band.validtargets, i)
                                            break
                                        end
                                    end
                                end
                            else
                                for i = #band.validtargets, 1, -1 do
                                    if band.validtargets[i] == key then
                                        table.remove(band.validtargets, i)
                                        break
                                    end
                                end
                            end
                            if onChanged then onChanged() end
                        end,
                    })
                end
                -- HP % / # Targets row (hidden when healResource == 'mana'; mana heals use Mana % min/max only)
                if showBandMinMax and spell.healResource ~= 'mana' then
                    ImGui.Text('HP %:')
                    if ImGui.IsItemHovered() then ImGui.SetTooltip(
                        'Target HP %% range for this band (only use when target HP is within min-max).') end
                    ImGui.SameLine()
                    ImGui.Text('Min')
                    ImGui.SameLine()
                    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
                    local bmin = band.min
                    if bmin == nil then bmin = 0 end
                    local newMin, minCh = inputs.boundedInt(id .. '_band' .. bi .. '_min', bmin, 0, 100, 1,
                        '##' .. id .. '_band' .. bi .. '_min')
                    if minCh then
                        band.min = newMin; if onChanged then onChanged() end
                    end
                    ImGui.SameLine()
                    ImGui.Text('Max')
                    ImGui.SameLine()
                    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
                    local bmax = band.max
                    if bmax == nil then bmax = 100 end
                    local newMax, maxCh = inputs.boundedInt(id .. '_band' .. bi .. '_max', bmax, 0, 100, 1,
                        '##' .. id .. '_band' .. bi .. '_max')
                    if maxCh then
                        band.max = newMax; if onChanged then onChanged() end
                    end
                end
                if showBandAggroMinMax then
                    ImGui.Text('Aggro %:')
                    if ImGui.IsItemHovered() then ImGui.SetTooltip(
                        'Your Me.PctAggro range for this band (level 20+; below 20 the gate is ignored).') end
                    ImGui.SameLine()
                    ImGui.Text('Min')
                    ImGui.SameLine()
                    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
                    local bamin = band.aggroMin
                    if bamin == nil then bamin = 0 end
                    local newAMin, aMinCh = inputs.boundedInt(id .. '_band' .. bi .. '_aggroMin', bamin, 0, 100, 1,
                        '##' .. id .. '_band' .. bi .. '_aggroMin')
                    if aMinCh then
                        band.aggroMin = newAMin; if onChanged then onChanged() end
                    end
                    ImGui.SameLine()
                    ImGui.Text('Max')
                    ImGui.SameLine()
                    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
                    local bamax = band.aggroMax
                    if bamax == nil then bamax = 100 end
                    local newAMax, aMaxCh = inputs.boundedInt(id .. '_band' .. bi .. '_aggroMax', bamax, 0, 100, 1,
                        '##' .. id .. '_band' .. bi .. '_aggroMax')
                    if aMaxCh then
                        band.aggroMax = newAMax; if onChanged then onChanged() end
                    end
                end
                if showBandMinTarMaxtar then
                    ImGui.Text('Mob count:')
                    if ImGui.IsItemHovered() then ImGui.SetTooltip(
                        'Camp mob-count gate: only use when mob count is within min-max (0 = no limit).') end
                    ImGui.SameLine()
                    ImGui.Text('Min')
                    ImGui.SameLine()
                    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
                    local bmintar = band.mintar
                    if bmintar == nil then bmintar = 0 end
                    local newMinT, minTCh = inputs.boundedInt(id .. '_band' .. bi .. '_mintar', bmintar, 0, 10, 1,
                        '##' .. id .. '_band' .. bi .. '_mintar')
                    if minTCh then
                        band.mintar = (newMinT == 0) and nil or newMinT; if onChanged then onChanged() end
                    end
                    ImGui.SameLine()
                    ImGui.Text('Max')
                    ImGui.SameLine()
                    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
                    local bmaxtar = band.maxtar
                    if bmaxtar == nil then bmaxtar = 0 end
                    local newMaxT, maxTCh = inputs.boundedInt(id .. '_band' .. bi .. '_maxtar', bmaxtar, 0, 10, 1,
                        '##' .. id .. '_band' .. bi .. '_maxtar')
                    if maxTCh then
                        band.maxtar = (newMaxT == 0) and nil or newMaxT; if onChanged then onChanged() end
                    end
                end

                if bi < #spell.bands then ImGui.Separator() end
            end
            -- Add Band button (right-aligned, below last band)
            local addLabel = 'Add Band'
            local addW = select(1, ImGui.CalcTextSize(addLabel)) + 24
            local availAdd = ImGui.GetContentRegionAvail()
            if availAdd and availAdd > addW then ImGui.SetCursorPosX(ImGui.GetCursorPosX() + availAdd - addW) end
            if ImGui.Button(addLabel .. '##' .. id .. '_add_band') then
                local first = spell.bands[1]
                local newBand = { targetphase = {}, validtargets = {} }
                if first then
                    for _, k in ipairs(first.targetphase or {}) do newBand.targetphase[#newBand.targetphase + 1] = k end
                    for _, k in ipairs(first.validtargets or {}) do newBand.validtargets[#newBand.validtargets + 1] = k end
                    newBand.min = first.min
                    newBand.max = first.max
                    -- Only copy mintar/maxtar when set to a positive value (0 = no limit, omit from band)
                    newBand.mintar = (first.mintar and first.mintar > 0) and first.mintar or nil
                    newBand.maxtar = (first.maxtar and first.maxtar > 0) and first.maxtar or nil
                end
                spell.bands[#spell.bands + 1] = newBand
                if onChanged then onChanged() end
            end
        end
        -- Precondition line
        ImGui.Text('Precondition:')
        if ImGui.IsItemHovered() then ImGui.SetTooltip(
            'When to allow casting: true or a Lua expression (e.g. condition on EvalID).') end
        ImGui.SameLine()
        ImGui.SetNextItemWidth(360)
        local preBuf, preChanged = ImGui.InputText('##' .. id .. '_precondition', state.preconditionBuf or '')
        if preChanged then
            state.preconditionBuf = preBuf
            if preBuf == '' or (preBuf and preBuf:match('^%s*$')) then
                spell.precondition = nil
            else
                spell.precondition = preBuf
            end
            if onChanged then onChanged() end
        end
    end
end

return M
