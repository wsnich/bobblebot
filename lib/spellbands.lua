-- Single parse/apply for spell bands across heal, buff, cure, event, debuff.
-- entry.bands = { { targetphase = { 'tank', 'pc' }, validtargets = { 'war', 'clr' }, min = 0, max = 80 }, ... }
-- targetphase = priority stages; validtargets = within-phase types (classes for pc/groupmember).

local spellbands = {}

-- Keep this module dependency-light to avoid circular requires:
-- spellutils -> castutils -> spellbands -> spellutils.
local function normalizeDebuffTargetPhase(token)
    if token == 'tanktar' then return 'matar' end
    if token == 'notanktar' then return 'notmatar' end
    return token
end

local DEBUFF_SPECIAL_MAX = 200

--- Apply entry.bands to build the runtime structure for this spell index.
--- @param section string 'heal'|'buff'|'cure'|'debuff'
--- @param entry table spell entry with .bands (array of { targetphase = {...}, validtargets? = {...}, min?, max? })
--- @param index number spell index (for debuff: used by caller to store result)
--- @return table runtime structure for this section/index
function spellbands.applyBands(section, entry, index)
    local bands = entry.bands
    if not bands or type(bands) ~= 'table' then
        if section == 'heal' then return {} end
        if section == 'buff' or section == 'cure' then return {} end
        if section == 'debuff' then return { mobMin = 0, mobMax = 100, aggroMin = 0, aggroMax = 100, matar = false, notmatar = false, named = false, burn = false } end
        return {}
    end

    if section == 'heal' then
        local rt = {}
        local pcClassesAll, groupmemberClassesAll = false, false
        local pcClassesSet, groupmemberClassesSet = {}, {}
        for _, band in ipairs(bands) do
            local targetPhase = band.targetphase
            if type(targetPhase) == 'table' then
                local minVal = band.min
                local maxVal = band.max
                if minVal == nil then minVal = 0 end
                if maxVal == nil then maxVal = 100 end
                local validTgts = band.validtargets
                for _, p in ipairs(targetPhase) do
                    if type(p) == 'string' and p ~= '' then
                        if p == 'cbt' then
                            rt.inCombat = true -- legacy; entry.inCombat overrides after loop
                        else
                            rt[p] = { min = minVal, max = maxVal }
                            if p == 'corpse' then
                                rt[p].max = DEBUFF_SPECIAL_MAX
                            elseif p == 'pc' then
                            if type(validTgts) == 'table' and #validTgts > 0 then
                                for _, c in ipairs(validTgts) do
                                    if type(c) == 'string' and c ~= '' then
                                        if c == 'all' then pcClassesAll = true else pcClassesSet[c:lower()] = true end
                                    end
                                end
                            else
                                pcClassesAll = true
                            end
                        elseif p == 'groupmember' then
                            if type(validTgts) == 'table' and #validTgts > 0 then
                                for _, c in ipairs(validTgts) do
                                    if type(c) == 'string' and c ~= '' then
                                        if c == 'all' then groupmemberClassesAll = true else groupmemberClassesSet[c:lower()] = true end
                                    end
                                end
                            else
                                groupmemberClassesAll = true
                            end
                        end
                        end
                    end
                end
            end
        end
        if entry.inCombat ~= nil then rt.inCombat = (entry.inCombat == true) end
        rt.pc_classes = pcClassesAll and 'all' or pcClassesSet
        rt.groupmember_classes = groupmemberClassesAll and 'all' or groupmemberClassesSet
        return rt
    end

    if section == 'buff' or section == 'cure' then
        local rt = {}
        local classesAll = false
        local classesSet = {}
        local CLASS_TOKENS = { war=1, shd=1, pal=1, rng=1, mnk=1, rog=1, brd=1, bst=1, ber=1, shm=1, clr=1, dru=1, wiz=1, mag=1, enc=1, nec=1 }
        for _, band in ipairs(bands) do
            local targetPhase = band.targetphase
            if type(targetPhase) == 'table' then
                local validTgts = band.validtargets
                local hasByname = false
                for _, p in ipairs(targetPhase) do
                    if type(p) == 'string' and p ~= '' then
                        if p == 'petspell' then
                            rt.petspell = true
                        elseif p == 'cbt' then
                            rt.inCombat = true -- legacy; entry.inCombat overrides after loop
                        elseif p == 'idle' then
                            rt.inIdle = true -- legacy; entry.inIdle overrides after loop
                        else
                            rt[p] = true
                            if p == 'byname' then hasByname = true; rt.name = true end
                            if p == 'bots' then rt.pc = true end -- backward compat: bots and pc same for buff/cure
                        end
                    end
                end
                if type(validTgts) == 'table' then
                    for _, c in ipairs(validTgts) do
                        if type(c) == 'string' and c ~= '' then
                            local lc = c:lower()
                            if c == 'all' then classesAll = true
                            elseif CLASS_TOKENS[lc] then classesSet[lc] = true; rt[lc] = true
                            elseif hasByname then rt[c] = true
                            end
                        end
                    end
                else
                    classesAll = true
                end
            end
        end
        if classesAll then
            rt.classes = 'all'
            for cls, _ in pairs(CLASS_TOKENS) do rt[cls] = true end
        else
            rt.classes = classesSet
        end
        if entry.inCombat ~= nil then rt.inCombat = (entry.inCombat == true) end
        if entry.inIdle ~= nil then rt.inIdle = (entry.inIdle == true) end
        if section == 'buff' and entry.combatOnly ~= nil then rt.combatOnly = (entry.combatOnly == true) end
        return rt
    end

    if section == 'debuff' then
        local mobMin, mobMax = nil, nil
        local aggroMin, aggroMax = nil, nil
        local mintar, maxtar = nil, nil
        local matar, notmatar, named, burn = false, false, false, false
        for _, band in ipairs(bands) do
            local targetPhase = band.targetphase
            if type(targetPhase) == 'table' then
                local mn = band.min
                local mx = band.max
                if mn ~= nil then
                    if mobMin == nil then mobMin = mn else mobMin = math.min(mobMin, mn) end
                end
                if mx ~= nil then
                    if mobMax == nil then mobMax = mx else mobMax = math.max(mobMax, mx) end
                end
                local amn = band.aggroMin
                local amx = band.aggroMax
                if amn ~= nil then
                    if aggroMin == nil then aggroMin = amn else aggroMin = math.min(aggroMin, amn) end
                end
                if amx ~= nil then
                    if aggroMax == nil then aggroMax = amx else aggroMax = math.max(aggroMax, amx) end
                end
                if band.mintar ~= nil and (mintar == nil or band.mintar > mintar) then mintar = band.mintar end
                if band.maxtar ~= nil and (maxtar == nil or band.maxtar < maxtar) then maxtar = band.maxtar end
                for _, c in ipairs(targetPhase) do
                    c = normalizeDebuffTargetPhase(c)
                    if c == 'matar' then matar = true
                    elseif c == 'notmatar' then notmatar = true
                    elseif c == 'named' then named = true
                    elseif c == 'burn' then burn = true
                    end
                end
            end
        end
        if mobMin == nil then mobMin = 0 end
        if mobMax == nil then mobMax = 100 end
        if aggroMin == nil then aggroMin = 0 end
        if aggroMax == nil then aggroMax = 100 end
        if not matar and not notmatar and not named and not burn and mintar == nil and maxtar == nil then mintar = 2 end
        return { mobMin = mobMin, mobMax = mobMax, aggroMin = aggroMin, aggroMax = aggroMax, mintar = mintar, maxtar = maxtar, matar = matar, notmatar = notmatar, named = named, burn = burn }
    end

    return {}
end

--- Check if HP percentage is within a band (for heal/debuff).
--- @param pct number target or mob PctHPs()
--- @param th table|number { min, max } or legacy single number (max only)
--- @return boolean
function spellbands.hpInBand(pct, th)
    if pct == nil then return false end
    if type(th) == 'table' then
        local minVal = th.min or 0
        local maxVal = th.max or 100
        return pct >= minVal and pct <= maxVal
    end
    return pct <= (th or 100)
end

return spellbands
