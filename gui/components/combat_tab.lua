-- Combat tab: melee settings (assist, offtank, stick, minmana) at top, then pull config.
-- Uses gui/widgets for modals, combos, inputs, layout, spell_entry.
-- ImGui Lua API (return values, e.g. Checkbox → value, pressed) is defined in typings/imgui.d.lua.

local mq = require('mq')
local ImGui = require('ImGui')
local botconfig = require('lib.config')
local botmove = require('botmove')
local state = require('lib.state')
local combos = require('gui.widgets.combos')
local inputs = require('gui.widgets.inputs')
local spell_entry = require('gui.widgets.spell_entry')

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

--- Draw the full Combat tab content (melee block, then Pull section).
function M.draw()
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

    -- Section divider: Pulling (centered with lines each side)
    ImGui.Spacing()
    local leftX, lineY = ImGui.GetCursorScreenPos()
    local availX = select(1, ImGui.GetContentRegionAvail())
    local textW, textH = ImGui.CalcTextSize('Pulling')
    local startX = ImGui.GetCursorPosX()
    ImGui.SetCursorPosX(startX + availX / 2 - textW / 2)
    ImGui.Text('Pulling')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Pull method and range settings.') end
    local tMinX, tMinY = ImGui.GetItemRectMin()
    local tMaxX, tMaxY = ImGui.GetItemRectMax()
    local midY = (tMinY + tMaxY) / 2
    local pad = 4
    local rightX = leftX + availX
    local drawList = ImGui.GetWindowDrawList()
    -- Light blue #3369ad (51, 105, 173)
    local col = ImGui.GetColorU32(51/255, 105/255, 173/255, 1.0)
    local thickness = 1.0
    drawList:AddLine(ImVec2(leftX, midY), ImVec2(tMinX - pad, midY), col, thickness)
    drawList:AddLine(ImVec2(tMaxX + pad, midY), ImVec2(rightX, midY), col, thickness)

    local pull = botconfig.config.pull
    if not pull then return end
    local spell = pull.spell
    if not spell then spell = { gem = 'melee', spell = '', range = nil } end

    spell_entry.draw(pull.spell, {
        id = 'pull_spell',
        label = 'Method: ',
        collapsible = false,
        primaryOptions = PRIMARY_OPTIONS_PULL,
        onChanged = runConfigLoaders,
        displayCommonFields = false,
        showRange = true,
    })

    ImGui.Spacing()
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

    ImGui.Spacing()
    -- Chain pull: HP % and Count on same line
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

    -- Mana class (checkboxes) then Mana % on same line. ImGui.Checkbox returns (value, pressed).
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

    ImGui.Spacing()
    ImGui.Text('Outrun Distance')
    if ImGui.IsItemHovered() then ImGui.SetTooltip('While returning to camp with a mob, nav pauses if the mob is farther than this distance.') end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(NUMERIC_INPUT_WIDTH)
    local leash = pull.leash or 500
    local leashNew, leashCh = inputs.boundedInt('pull_leash', leash, 0, 2000, 50, '##pull_leash')
    if leashCh then pull.leash = leashNew; recomputePullSquared(pull); runConfigLoaders() end

    ImGui.Spacing()
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

    ImGui.Spacing()
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
