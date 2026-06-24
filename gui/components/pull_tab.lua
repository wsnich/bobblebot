-- Pull tab: dedicated home for all pull configuration (method, range/target filter, chain pull,
-- healer mana gate, movement/retries, and modes). Extracted from the Combat tab so Pull has its own
-- home and a master-switch banner for dopull (which lives in runconfig, not settings).

local ImGui = require('ImGui')
local botconfig = require('lib.config')
local botmove = require('botmove')
local botpull = require('botpull')
local state = require('lib.state')
local combos = require('gui.widgets.combos')
local inputs = require('gui.widgets.inputs')
local spell_entry = require('gui.widgets.spell_entry')
local section = require('gui.widgets.section')

local M = {}

local NUMERIC_INPUT_WIDTH = 80

local PRIMARY_OPTIONS_PULL = {
    { value = 'melee',   label = 'Melee' },
    { value = 'ranged',  label = 'Ranged' },
    { value = 'gem',     label = 'Gem' },
    { value = 'ability', label = 'Ability' },
    { value = 'item',    label = 'Item' },
    { value = 'alt',     label = 'Alt' },
    { value = 'disc',    label = 'Disc' },
    { value = 'script',  label = 'Script' },
}

local function runConfigLoaders()
    botconfig.ApplyAndPersist()
end

local function recomputePullSquared(pull)
    if not pull then return end
    pull.radiusSq = (pull.radius or 0) * (pull.radius or 0)
    local r40 = (pull.radius or 0) + 40
    pull.radiusPlus40Sq = r40 * r40
    pull.leashSq = (pull.leash or 0) * (pull.leash or 0)
end

function M.draw()
    -- Master-switch banner: dopull lives in runconfig; enabling mirrors the Status flag handler's
    -- side effects (map filter + camp state) so this tab is an authoritative way to turn pulling on.
    spell_entry.drawTabIntro({
        isOff = (state.getRunconfig().dopull ~= true),
        enableId = 'dopull',
        flagNoun = 'Pull',
        onEnable = function()
            local rc = state.getRunconfig()
            rc.dopull = true
            botpull.syncPullMapFilter(true)
            botpull.ensurePullCampState(rc)
        end,
    })

    local pull = botconfig.config.pull
    if not pull then
        ImGui.TextColored(ImVec4(0.75, 0.75, 0.75, 1), '%s', 'Pull config not loaded.')
        return
    end
    if not pull.spell then pull.spell = { gem = 'melee', spell = '', range = nil } end

    spell_entry.draw(pull.spell, {
        id = 'pull_spell',
        label = 'Method: ',
        collapsible = false,
        primaryOptions = PRIMARY_OPTIONS_PULL,
        onChanged = runConfigLoaders,
        displayCommonFields = false,
        showRange = true,
    })

    -- ── Targeting: range + which mobs qualify ──────────────────────────────────────────────
    section.divider('Targeting', { tooltip = 'Range from camp and which mobs count as pullable.' })
    ImGui.Text('Pull Radius')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Max horizontal distance from camp (X,Y) for pullable mobs.') end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
    local radiusVal = pull.radius or 400
    local radiusNew, radiusCh = inputs.boundedInt('pull_radius', radiusVal, 1, 10000, 10, '##pull_radius')
    if radiusCh then pull.radius = radiusNew; recomputePullSquared(pull); runConfigLoaders() end
    ImGui.SameLine()
    ImGui.Text('Max Z')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Max vertical (Z) difference from camp; mobs outside this are ignored.') end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
    local zVal = pull.zrange or 150
    local zNew, zCh = inputs.boundedInt('pull_zrange', zVal, 1, 500, 10, '##pull_zrange')
    if zCh then pull.zrange = zNew; runConfigLoaders() end

    -- Target filter: Con vs Level (replaces "Use level based pulling" checkbox)
    local targetFilterOptions = { 'Con', 'Level' }
    local targetFilterIdx = pull.usePullLevels and 2 or 1
    local conColorRgb = {
        { 0.5, 0.5, 0.5, 1 },   { 0, 0.8, 0, 1 },   { 0.4, 0.7, 1, 1 },   { 0.2, 0.4, 1, 1 },
        { 1, 1, 1, 1 },         { 1, 1, 0, 1 },      { 1, 0.2, 0.2, 1 },
    }
    local conColors = botconfig.ConColors or {}
    ImGui.Spacing()
    ImGui.Text('Target Filter: ')
    ImGui.SameLine()
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
    local tfNew, tfCh = combos.combo('pull_target_filter', targetFilterIdx, targetFilterOptions, nil, nil)
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Target filter: Con colors or level range for valid pull targets.') end
    ImGui.Spacing()
    if tfCh then
        pull.usePullLevels = (tfNew == 2)
        runConfigLoaders()
    end
    ImGui.Text(targetFilterIdx == 1 and 'Min Con' or 'Min Level')
    if ImGui.IsItemHovered() then ImGui.SetTooltip(targetFilterIdx == 1 and 'Minimum consider color for pull targets (e.g. Green).' or 'Minimum level when using level-based pulling.') end
    ImGui.SameLine()
    if targetFilterIdx == 1 then
        local minC = pull.pullMinCon or 2
        if minC < 1 or minC > 7 then minC = 2 end
        ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
        local minCNew, minCCh = combos.combo('pull_mincon', minC, conColors, nil, conColorRgb)
        if minCCh then pull.pullMinCon = minCNew; runConfigLoaders() end
        ImGui.SameLine()
        ImGui.Text('Max Con')
        if ImGui.IsItemHovered() then ImGui.SetTooltip('Maximum consider color for pull targets (e.g. White).') end
        ImGui.SameLine()
        local maxC = pull.pullMaxCon or 5
        if maxC < 1 or maxC > 7 then maxC = 5 end
        ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
        local maxCNew, maxCCh = combos.combo('pull_maxcon', maxC, conColors, nil, conColorRgb)
        if maxCCh then pull.pullMaxCon = maxCNew; runConfigLoaders() end
        ImGui.SameLine()
        ImGui.Text('Red Cap')
        if ImGui.IsItemHovered() then ImGui.SetTooltip('Max levels above you when using con (e.g. levels into red).') end
        ImGui.SameLine()
        ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
        local mld = pull.maxLevelDiff or 6
        local mldNew, mldCh = inputs.boundedInt('pull_maxleveldiff', mld, 1, 30, 1, '##pull_maxleveldiff')
        if mldCh then pull.maxLevelDiff = mldNew; runConfigLoaders() end
    else
        ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
        local pmin = pull.pullMinLevel or 1
        local pminNew, pminCh = inputs.boundedInt('pull_minlevel', pmin, 1, 125, 1, '##pull_minlevel')
        if pminCh then pull.pullMinLevel = pminNew; runConfigLoaders() end
        ImGui.SameLine()
        ImGui.Text('Max Level')
        if ImGui.IsItemHovered() then ImGui.SetTooltip('Maximum level when using level-based pulling.') end
        ImGui.SameLine()
        ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
        local pmax = pull.pullMaxLevel or 125
        local pmaxNew, pmaxCh = inputs.boundedInt('pull_maxlevel', pmax, 1, 125, 1, '##pull_maxlevel')
        if pmaxCh then pull.pullMaxLevel = pmaxNew; runConfigLoaders() end
    end

    -- ── Chain pull ─────────────────────────────────────────────────────────────────────────
    section.divider('Chain pull', { tooltip = 'Start the next pull before the current mob is dead.' })
    ImGui.Text('Chain pull HP %')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('When current target HP %% is at or below this (and chain count allows), start next pull.') end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
    local cph = pull.chainpullhp or 0
    local cphNew, cphCh = inputs.boundedInt('pull_chainpullhp', cph, 0, 100, 5, '##pull_chainpullhp')
    if cphCh then pull.chainpullhp = cphNew; runConfigLoaders() end
    ImGui.SameLine()
    ImGui.Text('Count')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Allow chain-pulling when mob count is at or below this value.') end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
    local cpc = pull.chainpullcnt or 0
    local cpcNew, cpcCh = inputs.boundedInt('pull_chainpullcnt', cpc, 0, 10, 1, '##pull_chainpullcnt')
    if cpcCh then pull.chainpullcnt = cpcNew; runConfigLoaders() end

    -- ── Healer mana gate ───────────────────────────────────────────────────────────────────
    section.divider('Healer mana gate', { tooltip = 'Hold pulls until checked healers have enough mana.' })
    local manaclassOptions = { 'CLR', 'DRU', 'SHM' }
    local mcList = (type(pull.manaclass) == 'table') and pull.manaclass or {}
    local function inManaclass(name)
        local u = string.upper(tostring(name or ''))
        for _, c in ipairs(mcList) do
            if string.upper(tostring(c or '')) == u then return true end
        end
        return false
    end
    ImGui.Text('Healers: ')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Classes checked for mana %% before allowing a pull. If none are checked, the mana gate is disabled.') end
    ImGui.SameLine()
    for _, label in ipairs(manaclassOptions) do
        local checked = inManaclass(label)
        local value, pressed = ImGui.Checkbox('##pull_manaclass_' .. label:lower(), checked)
        if pressed then
            local newTable = {}
            for _, o in ipairs(manaclassOptions) do
                if o == label then
                    if value then newTable[#newTable + 1] = o end
                else
                    if inManaclass(o) then newTable[#newTable + 1] = o end
                end
            end
            pull.manaclass = newTable
            runConfigLoaders()
        end
        ImGui.SameLine()
        ImGui.Text(label)
        if ImGui.IsItemHovered() then ImGui.SetTooltip('Include ' .. label .. ' in mana check.') end
        ImGui.SameLine()
    end
    ImGui.Text('Mana %')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Healers must be strictly above this mana %% before a pull. Set to 0 to disable the mana gate.') end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
    local mana = pull.mana or 60
    local manaNew, manaCh = inputs.boundedInt('pull_mana', mana, 0, 100, 5, '##pull_mana')
    if manaCh then pull.mana = manaNew; runConfigLoaders() end

    -- ── Movement & retries ─────────────────────────────────────────────────────────────────
    section.divider('Movement & retries', { tooltip = 'Outrun/leash, FTE lockout, and backup candidates.' })
    ImGui.Text('Outrun Distance')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('While returning to camp with a mob, nav pauses if the mob is farther than this distance.') end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
    local leash = pull.leash or 500
    local leashNew, leashCh = inputs.boundedInt('pull_leash', leash, 0, 2000, 50, '##pull_leash')
    if leashCh then pull.leash = leashNew; recomputePullSquared(pull); runConfigLoaders() end

    ImGui.SameLine()
    ImGui.Text('FTE lockout (sec)')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Seconds to skip a pull target after FTE lock or already-engaged (below 100% HP).') end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
    local fteSec = pull.fteLockoutSec or 120
    local fteSecNew, fteSecCh = inputs.boundedInt('pull_fteLockoutSec', fteSec, 1, 600, 10, '##pull_fteLockoutSec')
    if fteSecCh then pull.fteLockoutSec = fteSecNew; runConfigLoaders() end

    ImGui.Spacing()
    ImGui.Text('Backup candidates')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Max pull targets queued per outing (1–5). On FTE, engaged, below 100%% HP, or no-aggro timeout, tries the next target before returning to camp. Set to 1 for single-target behavior.') end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
    local backupCandidates = pull.backupCandidates or 3
    local backupNew, backupCh = inputs.boundedInt('pull_backupCandidates', backupCandidates, 1, 5, 1, '##pull_backupCandidates')
    if backupCh then pull.backupCandidates = backupNew; runConfigLoaders() end

    -- ── Modes ──────────────────────────────────────────────────────────────────────────────
    section.divider('Modes', { tooltip = 'Priority list, and the mobile hunt/roam modes.' })
    ImGui.Text('Use priority list')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Prefer mobs that match the Priority list over path distance when choosing a pull target.') end
    ImGui.SameLine()
    local up = pull.usepriority == true
    local value, pressed = ImGui.Checkbox('##pull_usepriority', up)
    if pressed then pull.usepriority = value; runConfigLoaders() end
    ImGui.SameLine()
    ImGui.Text('Hunter mode')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('No makecamp; anchor set once. Puller can be far from camp without triggering return-to-camp.') end
    ImGui.SameLine()
    local hunt = pull.hunter == true
    local huntVal, huntPressed = ImGui.Checkbox('##pull_hunter', hunt)
    if huntPressed then
        pull.hunter = huntVal
        if huntVal then pull.roam = false end
        runConfigLoaders()
    end
    ImGui.SameLine()
    ImGui.Text('Roam hunt')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Roam hunt: when your mob bubble is empty, nav to the nearest pullable mob within pull.radius of you. doMelee engages anything in Radius along the way. Player-centered; no anchor. Hunter mode is ignored when enabled.') end
    ImGui.SameLine()
    local roam = pull.roam == true
    local roamVal, roamPressed = ImGui.Checkbox('##pull_roam', roam)
    if roamPressed then
        pull.roam = roamVal
        if roamVal then
            pull.hunter = false
            local rc = state.getRunconfig()
            if rc.campstatus then botmove.MakeCamp('off') end
        end
        runConfigLoaders()
    end
end

return M
