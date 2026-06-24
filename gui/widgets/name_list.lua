-- Reusable name-list section: a bordered table of names with Remove (and optional Up/Down reorder),
-- plus an "Add target" / manual-add row. Consolidates the logic that was triplicated across
-- rolelists_tab (ma_list, mt_list) and moblist_tab (exclude, priority, charm).
--
-- Preserves the per-frame buffer-sync fix: the manual-add InputText uses EnterReturnsTrue, so
-- `changed` only fires on Enter; the caller-visible buffer is synced every frame so the Add button
-- (not just Enter) sees the typed name.
--
-- The add-input state (show/buffer) is owned here, keyed by opts.id, so multiple lists never share a
-- buffer.

local ImGui = require('ImGui')
local section = require('gui.widgets.section')

local M = {}

local _state = {}
local function st(id)
    if not _state[id] then _state[id] = { show = false, buf = '' } end
    return _state[id]
end

local function listContains(list, name)
    if type(list) ~= 'table' then return false end
    for _, n in ipairs(list) do if n == name then return true end end
    return false
end

--- Draw a name-list section.
--- opts:
---   id            string  unique id (keys the add-input buffer + all ImGui ids)
---   label         string  yellow section header
---   list          table   array of names, mutated in place
---   reorder       boolean show Up/Down buttons (default false)
---   reverse       boolean display newest-first (default false)
---   addNoun       string  placeholder noun for the manual-add field (default 'Name')
---   validateName  fun(name):boolean  gate adds (default: always allow)
---   getTargetName fun():string|nil   candidate for the "Add target" button; nil hides that button
---   onChange      fun(action:string) called after add/remove/reorder; action is 'save' or 'save_replace'
function M.draw(opts)
    local list = opts.list
    if type(list) ~= 'table' then return end
    local id = opts.id
    local onChange = opts.onChange or function() end
    local validateName = opts.validateName or function() return true end

    section.header(opts.label)

    local cols = opts.reorder and 3 or 2
    local tableFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter)
    if ImGui.BeginTable(id .. '_tbl', cols, tableFlags, -1, 0) then
        ImGui.TableSetupColumn('Name', 0, opts.reorder and 0.55 or 0.85)
        if opts.reorder then ImGui.TableSetupColumn('Order', 0, 0.30) end
        ImGui.TableSetupColumn('', 0, 0.15)
        ImGui.TableHeadersRow()
        local n = #list
        local first, last, step
        if opts.reverse then first, last, step = n, 1, -1 else first, last, step = 1, n, 1 end
        for i = first, last, step do
            local name = list[i]
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.Text('%s', name)
            if opts.reorder then
                ImGui.TableNextColumn()
                if i > 1 and ImGui.SmallButton('Up##' .. id .. i) then
                    list[i], list[i - 1] = list[i - 1], list[i]
                    onChange('save_replace')
                end
                ImGui.SameLine()
                if i < n and ImGui.SmallButton('Down##' .. id .. i) then
                    list[i], list[i + 1] = list[i + 1], list[i]
                    onChange('save_replace')
                end
            end
            ImGui.TableNextColumn()
            if ImGui.SmallButton('Remove##' .. id .. i) then
                table.remove(list, i)
                onChange('save_replace')
            end
        end
        ImGui.EndTable()
    end

    local s = st(id)
    local targetName = opts.getTargetName and opts.getTargetName() or nil
    if targetName then
        if ImGui.Button('Add target##' .. id) then
            if targetName ~= '' and validateName(targetName) and not listContains(list, targetName) then
                table.insert(list, targetName)
                onChange('save')
            end
        end
    else
        if not s.show then
            if ImGui.Button('Add##' .. id) then s.show = true end
        else
            local flags = ImGuiInputTextFlags.EnterReturnsTrue
            local newVal, changed = ImGui.InputText((opts.addNoun or 'Name') .. '##' .. id, s.buf, flags)
            -- Sync every frame (changed is Enter-only) so the Add button sees the typed name.
            s.buf = newVal
            ImGui.SameLine()
            if ImGui.Button('Add##' .. id .. '_submit') or changed then
                local name = (s.buf or ''):match('^%s*(.-)%s*$')
                if name and name ~= '' and validateName(name) and not listContains(list, name) then
                    table.insert(list, name)
                    onChange('save')
                end
                s.buf = ''
                s.show = false
            end
        end
    end
    ImGui.Spacing()
end

return M
