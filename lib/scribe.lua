-- Auto-scribe spell scrolls from your bags (Option A; Lua port of MuleAssist's ScribeSpells).
-- Scans your inventory packs for Scroll items you can use (Spell.Level <= your level) that you haven't
-- scribed yet, ctrl+right-clicks each to scribe it, and auto-confirms EQ's native "<new> will replace
-- <old>" dialog. On-demand via /cz scribe. When done it runs the upgrade detector so any configured spell
-- that now has a better in-book version is surfaced for one-click update.
--
-- Blocking routine (uses mq.delay); only run it during downtime. Gated to out-of-combat / standing / idle.

local mq = require('mq')
local botconfig = require('lib.config')

local scribe = {}

local NUM_PACKS = 10
local _running = false
local _lastLevel = 0     -- baseline for level-up detection (0 = not yet established)
local _wantScribe = false -- a ding happened; scribe as soon as it's safe

local function safeToScribe()
    if mq.TLO.Me.Combat() then return false, 'in combat' end
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
    -- A replace dialog can also appear without a cursor; clear it either way.
    confirmDialog()
end

-- Scan all packs and scribe every scribable scroll. Returns the count scribed.
function scribe.Run()
    if _running then return 0 end
    local ok, why = safeToScribe()
    if not ok then
        printf('\ayCZBot:\axCan\'t scribe right now (%s).', why)
        return 0
    end
    _running = true
    local scribedCount = 0

    if mq.TLO.Cursor.ID() then mq.cmd('/autoinventory') end
    if not mq.TLO.Window('InventoryWindow').Open() then
        mq.cmd('/windowstate InventoryWindow open')
        mq.delay(500)
    end
    mq.cmd('/keypress OPEN_INV_BAGS')
    mq.delay(300)

    for bag = 1, NUM_PACKS do
        local pack = 'pack' .. bag
        local container = tonumber(mq.TLO.InvSlot(pack).Item.Container())
        if container and container > 0 then
            -- It's a bag: open it and walk its slots.
            if not mq.TLO.Window('Pack' .. bag).Open() then
                mq.cmdf('/itemnotify %s rightmouseup', pack)
                mq.delay(1000, function() return mq.TLO.Window('Pack' .. bag).Open() end)
            end
            for slot = 1, container do
                local item = mq.TLO.InvSlot(pack).Item.Item(slot)
                if scribable(item) then
                    scribeOne(string.format('in %s %d', pack, slot), item.Spell.Name())
                    scribedCount = scribedCount + 1
                    mq.delay(200)
                end
            end
            if mq.TLO.Window('Pack' .. bag).Open() then mq.cmdf('/itemnotify %s rightmouseup', pack) end
        else
            -- Top-level inventory slot holding an item directly.
            local item = mq.TLO.InvSlot(pack).Item
            if scribable(item) then
                scribeOne(pack, item.Spell.Name())
                scribedCount = scribedCount + 1
                mq.delay(200)
            end
        end
    end

    if mq.TLO.Window('SpellBookWnd').Open() then mq.cmd('/squelch /windowstate SpellBookWnd close') end
    _running = false

    if scribedCount > 0 then
        printf('\ayCZBot:\axScribed %d spell(s).', scribedCount)
    else
        printf('\ayCZBot:\axNo new scrolls to scribe.')
    end

    -- New ranks in the book may upgrade configured spells -- refresh suggestions and announce.
    local okU, spellupgrade = pcall(require, 'lib.spellupgrade')
    if okU and spellupgrade then
        spellupgrade.scan()
        if spellupgrade.count() > 0 then
            printf('\ayCZBot:\ax%d spell upgrade(s) available -- Status tab or /cz upgrades', spellupgrade.count())
        end
    end
    return scribedCount
end

-- Background tick (from doMiscTimer): when settings.autoScribe is on, scribe new spells after a level-up.
-- The ding usually lands mid-combat, so we just flag it and run the scribe once we're safely out of combat.
function scribe.tick()
    if botconfig.config.settings.autoScribe == false then return end
    local lvl = tonumber(mq.TLO.Me.Level()) or 0
    if lvl <= 0 then return end
    if _lastLevel == 0 then _lastLevel = lvl; return end -- establish baseline; never scribe on startup
    if lvl > _lastLevel then
        _lastLevel = lvl
        _wantScribe = true
        printf('\ayCZBot:\axDinged %d -- will scribe new spells when out of combat.', lvl)
    elseif lvl < _lastLevel then
        _lastLevel = lvl -- resync on any de-level
    end
    if _wantScribe and safeToScribe() then
        _wantScribe = false
        scribe.Run()
    end
end

return scribe
