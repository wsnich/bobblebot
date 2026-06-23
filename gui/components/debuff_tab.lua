-- Debuff tab: dedicated panel for debuff config (On/Off toggle + one spell_entry per debuff).

local mq = require('mq')
local ImGui = require('ImGui')
local botconfig = require('lib.config')
local spellutils = require('lib.spellutils')
local labeled_grid = require('gui.widgets.labeled_grid')
local spell_entry = require('gui.widgets.spell_entry')
local inputs = require('gui.widgets.inputs')

local M = {}

local NUMERIC_INPUT_WIDTH = 80

-- Build ordered options for dontStack checkboxes from config allowlist (key, label, tooltip).
local function buildDontStackOptions()
    local allowed = botconfig.DEBUFF_DONTSTACK_ALLOWED
    local keys = {}
    for k in pairs(allowed) do keys[#keys + 1] = k end
    table.sort(keys)
    local opts = {}
    for _, key in ipairs(keys) do
        opts[#opts + 1] = { key = key, label = key, tooltip = "Do not overwrite existing " .. key .. "." }
    end
    return opts
end
local DONTSTACK_OPTIONS = buildDontStackOptions()

local function buildStopWhenOptions()
    local allowed = botconfig.DEBUFF_STOPWHEN_ALLOWED
    local keys = {}
    for k in pairs(allowed) do keys[#keys + 1] = k end
    table.sort(keys)
    local opts = {}
    for _, key in ipairs(keys) do
        local tip = (key == 'Slowed')
            and 'Stop when target is slowed (e.g. resist setup debuff no longer needed).'
            or ('Stop when target already has ' .. key .. '.')
        opts[#opts + 1] = { key = key, label = key, tooltip = tip }
    end
    return opts
end
local STOPWHEN_OPTIONS = buildStopWhenOptions()

local PRIMARY_OPTIONS_DEBUFF = {
    { value = 'gem',     label = 'Gem' },
    { value = 'item',    label = 'Item' },
    { value = 'ability', label = 'Ability' },
    { value = 'alt',     label = 'Alt' },
    { value = 'disc',    label = 'Disc' },
    { value = 'script',  label = 'Script' },
}

local TARGETPHASE_OPTIONS_DEBUFF = {
    { key = 'matar',   label = "Assist's Target",     tooltip = "Use on the Main Assist's current target. If `onlyMT=true`, cast on the Main Tank's target instead (only when this bot is the MT)." },
    { key = 'notmatar', label = "Not Assist's Target", tooltip = 'Use on camp mobs that are NOT the Main Assist target (adds). `mez` debuffs exclude both MA target and MT target.' },
    { key = 'named',     label = 'Named',               tooltip = 'Use on named mobs only (applies to the selected target for this phase).' },
}

local function entryHasMatarOrNamed(entry)
    for _, band in ipairs(entry.bands or {}) do
        for _, p in ipairs(band.targetphase or {}) do
            if p == 'matar' or p == 'tanktar' or p == 'named' then return true end -- accept legacy tanktar
        end
    end
    return false
end

local function runConfigLoaders()
    botconfig.ApplyAndPersist()
end

--- Custom section for debuff entries: recast, delay, dontStack (passed to spell_entry as customSection).
local function debuffCustomSection(entry, idPrefix, onChanged)
    -- First line: Recast and Delay (SameLine)
    ImGui.Text('Resist limit')
    if ImGui.IsItemHovered() then ImGui.SetTooltip(
        'After this many resists on the same spawn, disable this spell for that spawn. 0 = no limit.') end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
    local recast = entry.recast or 0
    local newRecast, recastCh = inputs.boundedInt(idPrefix .. '_recast', recast, 0, 10, 1, '##' .. idPrefix .. '_recast')
    if recastCh then
        entry.recast = newRecast; if onChanged then onChanged() end
    end
    ImGui.SameLine()
    ImGui.Text('Delay')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Delay (ms) before this spell can be used again after cast.') end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH + 28)
    local delay = entry.delay or 0
    local newDelay, delayCh = inputs.boundedInt(idPrefix .. '_delay', delay, 0, 60000, 100, '##' .. idPrefix .. '_delay')
    if delayCh then
        entry.delay = newDelay; if onChanged then onChanged() end
    end

    -- Don't stack: labeled grid (4 options per row)
    labeled_grid.checkboxGrid({
        id = idPrefix .. '_dontstack',
        label = "Don't stack:",
        labelTooltip =
        "If target already has any of these categories (e.g. Snared), don't cast this spell and interrupt if it appears while casting.",
        options = DONTSTACK_OPTIONS,
        value = entry.dontStack or {},
        columns = 4,
        onToggle = function(key, isChecked)
            if entry.dontStack == nil then entry.dontStack = {} end
            if isChecked then
                entry.dontStack[#entry.dontStack + 1] = key
            else
                for i = #entry.dontStack, 1, -1 do
                    if entry.dontStack[i] == key then
                        table.remove(entry.dontStack, i)
                        break
                    end
                end
                if #entry.dontStack == 0 then entry.dontStack = nil end
            end
            if onChanged then onChanged() end
        end,
    })

    if mq.TLO.Me.Class.ShortName() == 'BRD' then
        labeled_grid.checkboxGrid({
            id = idPrefix .. '_stopwhen',
            label = 'Stop when:',
            labelTooltip =
            'Omit from bard combat twist / skip cast when target already has any of these (e.g. Slowed for Occlusion of Sound after slow lands).',
            options = STOPWHEN_OPTIONS,
            value = entry.stopWhen or {},
            columns = 4,
            onToggle = function(key, isChecked)
                if entry.stopWhen == nil then entry.stopWhen = {} end
                if isChecked then
                    entry.stopWhen[#entry.stopWhen + 1] = key
                else
                    for i = #entry.stopWhen, 1, -1 do
                        if entry.stopWhen[i] == key then
                            table.remove(entry.stopWhen, i)
                            break
                        end
                    end
                    if #entry.stopWhen == 0 then entry.stopWhen = nil end
                end
                if onChanged then onChanged() end
            end,
        })
    end

    if entryHasMatarOrNamed(entry) then
        ImGui.Text('When MT Only')
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('Only cast this debuff when this character is the main tank.')
        end
        ImGui.SameLine()
        local onlyMT = entry.onlyMT == true
        local onlyMTValue, onlyMTPressed = ImGui.Checkbox('##' .. idPrefix .. '_onlyMT', onlyMT)
        if onlyMTPressed then
            entry.onlyMT = onlyMTValue
            if onChanged then onChanged() end
        end
    end
end

--- Draw the full Debuff tab content.
function M.draw()
    local debuff = botconfig.config.debuff
    if not debuff then return end
    if not debuff.spells then debuff.spells = {} end
    local spells = debuff.spells
    spell_entry.drawTabIntro({ flagKey = 'dodebuff', flagNoun = 'Debuff / Mez / Nuke', isEmpty = #spells == 0,
        emptyHint = 'No entries configured. Click "Add debuff" below — this tab also holds mez, nukes, DoTs, and combat abilities.' })
    for i, entry in ipairs(spells) do
        -- Normalize legacy tokens so the UI reflects canonical matar/notmatar.
        if entry.bands and type(entry.bands) == 'table' then
            for _, band in ipairs(entry.bands) do
                if band and type(band.targetphase) == 'table' then
                    local changed = false
                    local out = {}
                    for _, p in ipairs(band.targetphase) do
                        local np = spellutils.NormalizeDebuffTargetPhase(p)
                        if np ~= p then changed = true end
                        out[#out + 1] = np
                    end
                    if changed then band.targetphase = out end
                end
            end
        end

        local detectedTypeLabel
        if spellutils.IsNukeSpell(entry) then
            local flavor = spellutils.GetNukeFlavor(entry)
            detectedTypeLabel = flavor and (flavor:gsub('^%l', string.upper) .. ' nuke') or 'Nuke'
        else
            detectedTypeLabel = spellutils.IsMezSpell(entry) and 'Mez' or nil
        end
        local detectedTypeLabel2 = spellutils.IsTargetedAESpell(entry) and 'Targeted AE' or nil
        spell_entry.draw(entry, {
            id = 'debuff_' .. i,
            label = 'Debuff ' .. i,
            collapsible = true,
            detectedTypeLabel = detectedTypeLabel,
            detectedTypeLabel2 = detectedTypeLabel2,
            primaryOptions = PRIMARY_OPTIONS_DEBUFF,
            onChanged = runConfigLoaders,
            displayCommonFields = true,
            customSection = debuffCustomSection,
            targetphaseOptions = TARGETPHASE_OPTIONS_DEBUFF,
            validtargetsOptions = {},
            showBandMinMax = true,
            showBandAggroMinMax = true,
            showBandMinTarMaxtar = true,
            onDelete = function()
                table.remove(debuff.spells, i); runConfigLoaders()
            end,
            deleteEntryLabel = 'Debuff',
            entryIndex = i,
            entryCount = #spells,
            onMoveUp = (function(idx)
                return idx > 1 and function()
                    botconfig.swapSpellEntries('debuff', idx, idx - 1)
                end or nil
            end)(i),
            onMoveDown = (function(idx)
                return idx < #spells and function()
                    botconfig.swapSpellEntries('debuff', idx, idx + 1)
                end or nil
            end)(i),
        })
        ImGui.Separator()
    end

    -- Right-align "Add debuff" button after the list
    local addLabel = 'Add debuff'
    local addTextW = select(1, ImGui.CalcTextSize(addLabel))
    local addAvail = ImGui.GetContentRegionAvail()
    local addButtonWidth = addTextW + 24
    if addAvail and addAvail > 0 and addButtonWidth > 0 then
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() + addAvail - addButtonWidth)
    end
    if ImGui.Button(addLabel) then
        local defaultEntry = botconfig.getDefaultSpellEntry('debuff')
        if defaultEntry then
            table.insert(debuff.spells, defaultEntry)
            runConfigLoaders()
        end
    end
end

return M
