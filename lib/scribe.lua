-- Auto-scribe spell scrolls from your bags (Option A; Lua port of MuleAssist's ScribeSpells).
-- Scans your inventory packs for Scroll items you can use (Spell.Level <= your level) that you haven't
-- scribed yet, ctrl+right-clicks each to scribe it, and auto-confirms EQ's native "<new> will replace
-- <old>" dialog. On-demand via /cz scribe. When done it runs the upgrade detector so any configured spell
-- that now has a better in-book version is surfaced for one-click update.
--
-- Blocking routine (uses mq.delay); only run it during downtime. Gated to out-of-combat / standing / idle.
-- Auto-scribe after a ding uses the same scan but processes one scroll per misc tick so it never blocks.

local mq = require('mq')
local botconfig = require('lib.config')
local state = require('lib.state')

local scribe = {}

local NUM_PACKS = 10
local _running = false
local _lastLevel = 0     -- baseline for level-up detection (0 = not yet established)
local _wantScribe = false -- a ding happened; scribe as soon as it's safe
local _scan = nil        -- incremental scan state for auto-scribe (one scroll per tick)
local _autoScribedCount = 0

local function safeToScribe()
    if mq.TLO.Me.Combat() then return false, 'in combat' end
    if (tonumber(state.getMobCount()) or 0) > 0 then return false, 'mobs in camp' end
    if mq.TLO.Me.Casting() then return false, 'casting' end
    if (tonumber(mq.TLO.Me.CastTimeLeft()) or 0) > 0 then return false, 'casting' end
    if mq.TLO.Me.Moving() then return false, 'moving' end
    if mq.TLO.Me.Dead() then return false, 'dead/hovering' end
    return true
end

-- Confirm EQ's scribe dialog (including the "<new> will replace <old>" replace prompt) if it is open.
local function confirmDialog()
    local w = mq.TLO.Window('ConfirmationDialogBox')
    if w() and w.Open() then
        mq.cmd('/notify ConfirmationDialogBox CD_Yes_Button leftmouseup')
        mq.delay(400, function() return not mq.TLO.Window('ConfirmationDialogBox').Open() end)
        return true
    end
    return false
end

-- True if the scroll for this spell can be scribed now: scribe-able level and not already in the book.
local function scribable(item)
    if not item() then return false end
    if item.Type() ~= 'Scroll' then return false end
    local spell = item.Spell
    if not spell or not spell() then return false end
    local slvl = tonumber(spell.Level()) or 999
    if slvl > (tonumber(mq.TLO.Me.Level()) or 1) then return false end
    local name = spell.Name()
    if not name or name == '' then return false end
    if mq.TLO.Me.Book(name)() then return false end -- already scribed
    return true
end

-- Scribe one scroll given its /itemnotify target string; drive the cursor/dialog to completion.
local function scribeOne(notifyTarget, spellName)
    printf('\ayCZBot:\axScribing %s', spellName or notifyTarget)
    mq.cmdf('/nomodkey /ctrlkey /itemnotify %s rightmouseup', notifyTarget)
    mq.delay(1000, function() return mq.TLO.Cursor.ID() ~= nil end)
    local deadline = mq.gettime() + 25000
    while mq.TLO.Cursor.ID() and mq.gettime() < deadline do
        confirmDialog()
        if mq.TLO.Cursor.ID() then mq.cmd('/autoinventory') end
        mq.delay(250)
        mq.doevents()
    end
    confirmDialog()
end

local function prepareInventory()
    if mq.TLO.Cursor.ID() then mq.cmd('/autoinventory') end
    if not mq.TLO.Window('InventoryWindow').Open() then
        mq.cmd('/windowstate InventoryWindow open')
        mq.delay(500)
    end
    mq.cmd('/keypress OPEN_INV_BAGS')
    mq.delay(300)
end

local function resetScan()
    _scan = { bag = 1, slot = 0, prepared = false }
end

-- Advance scan state; returns notifyTarget, spellName or nil when the full pass is done.
local function nextScribable()
    if not _scan then resetScan() end
    if not _scan.prepared then
        prepareInventory()
        _scan.prepared = true
    end

    while _scan.bag <= NUM_PACKS do
        local pack = 'pack' .. _scan.bag
        local container = tonumber(mq.TLO.InvSlot(pack).Item.Container())
        if container and container > 0 then
            if not mq.TLO.Window('Pack' .. _scan.bag).Open() then
                mq.cmdf('/itemnotify %s rightmouseup', pack)
                mq.delay(1000, function() return mq.TLO.Window('Pack' .. _scan.bag).Open() end)
            end
            while _scan.slot < container do
                _scan.slot = _scan.slot + 1
                local item = mq.TLO.InvSlot(pack).Item.Item(_scan.slot)
                if scribable(item) then
                    return string.format('in %s %d', pack, _scan.slot), item.Spell.Name()
                end
            end
            if mq.TLO.Window('Pack' .. _scan.bag).Open() then mq.cmdf('/itemnotify %s rightmouseup', pack) end
            _scan.bag = _scan.bag + 1
            _scan.slot = 0
        else
            local item = mq.TLO.InvSlot(pack).Item
            if scribable(item) then
                _scan.bag = _scan.bag + 1
                _scan.slot = 0
                return pack, item.Spell.Name()
            end
            _scan.bag = _scan.bag + 1
            _scan.slot = 0
        end
    end
    return nil, nil
end

local function finishScribeSession(scribedCount)
    if mq.TLO.Window('SpellBookWnd').Open() then mq.cmd('/squelch /windowstate SpellBookWnd close') end
    _scan = nil

    if scribedCount > 0 then
        printf('\ayCZBot:\axScribed %d spell(s).', scribedCount)
    end

    local okU, spellupgrade = pcall(require, 'lib.spellupgrade')
    if okU and spellupgrade then
        spellupgrade.scan()
        if spellupgrade.count() > 0 then
            printf('\ayCZBot:\ax%d spell upgrade(s) available -- Status tab or /cz upgrades', spellupgrade.count())
        end
    end
end

-- Scan all packs and scribe every scribable scroll. Returns the count scribed.
function scribe.Run()
    if _running then return 0 end
    local okSafe, why = safeToScribe()
    if not okSafe then
        printf('\ayCZBot:\axCan\'t scribe right now (%s).', why)
        return 0
    end
    _running = true
    local scribedCount = 0
    resetScan()

    local okRun, err = pcall(function()
        while true do
            local target, spellName = nextScribable()
            if not target then break end
            scribeOne(target, spellName)
            scribedCount = scribedCount + 1
            mq.delay(200)
        end
    end)

    _running = false
    if not okRun then
        printf('\ayCZBot:\axScribe error: %s', tostring(err))
    end

    if scribedCount == 0 and okRun then
        printf('\ayCZBot:\axNo new scrolls to scribe.')
    end
    finishScribeSession(scribedCount)
    return scribedCount
end

-- Background tick (from doMiscTimer): when settings.autoScribe is on, scribe new spells after a level-up.
-- The ding usually lands mid-combat, so we just flag it and scribe one scroll per safe tick.
function scribe.tick()
    if botconfig.config.settings.autoScribe == false then return end
    local lvl = tonumber(mq.TLO.Me.Level()) or 0
    if lvl <= 0 then return end
    if _lastLevel == 0 then _lastLevel = lvl; return end
    if lvl > _lastLevel then
        _lastLevel = lvl
        _wantScribe = true
        printf('\ayCZBot:\axDinged %d -- will scribe new spells when out of combat.', lvl)
    elseif lvl < _lastLevel then
        _lastLevel = lvl
    end
    if not _wantScribe then return end
    local okSafe, why = safeToScribe()
    if not okSafe then return end

    local target, spellName = nextScribable()
    if not target then
        _wantScribe = false
        if _autoScribedCount == 0 then
            printf('\ayCZBot:\axNo new scrolls to scribe.')
        end
        finishScribeSession(_autoScribedCount)
        _autoScribedCount = 0
        return
    end

    local okOne, err = pcall(scribeOne, target, spellName)
    if not okOne then
        printf('\ayCZBot:\axScribe error: %s', tostring(err))
        _wantScribe = false
        _scan = nil
        if _autoScribedCount > 0 then finishScribeSession(_autoScribedCount) end
        _autoScribedCount = 0
        return
    end
    _autoScribedCount = _autoScribedCount + 1
end

return scribe
