-- Reusable validated edit modal: text entry, optional validateFn, Save/Cancel, in-dialog error.
-- Phase 2: CloseCurrentPopup() and onSave/onCancel are deferred to the next frame (avoids crash
-- when closing from deep nesting). state.pendingClose ('save'|'cancel') is set on button click.
-- validateFn(value) returns success (boolean), optional errorMessage (string).

local imgui = require('ImGui')
local theme = require('gui.widgets.theme')

local M = {}

local ImGuiInputTextFlags = ImGuiInputTextFlags or {}
local RED = theme.RED
local EnterReturnsTrue = ImGuiInputTextFlags.EnterReturnsTrue or 0
local POPUP_FLAGS = bit32.bor(ImGuiWindowFlags.AlwaysAutoResize, ImGuiWindowFlags.NoResize)

---@param id string unique id for this popup (e.g. "pull_spell_name")
---@param state table { open: boolean, buffer: string, error: string|nil, pendingClose: 'save'|'cancel'|nil } caller-owned state
---@param validateFn fun(value: string): boolean, string? (success, errorMessage)
---@param onSave fun(value: string) called when Save/Enter and validation passes
---@param onCancel fun() called when Cancel
---@return boolean|nil true if saved this frame, false if cancelled, nil if still open or not open
function M.validatedEditModal(id, state, validateFn, onSave, onCancel)
    if not state.open then
        return nil
    end
    local popupId = '##ValidatedEditModal_' .. id
    imgui.SetNextWindowSize(320, 0, ImGuiCond.Appearing)
    local show = imgui.BeginPopupModal(popupId, nil, POPUP_FLAGS)
    if not show then
        return nil
    end
    -- Deferred close: run at start of block (no button has ActiveId) to avoid crash
    if state.pendingClose then
        local wasSave = (state.pendingClose == 'save')
        imgui.CloseCurrentPopup()
        if wasSave then
            onSave(state.buffer or '')
        else
            onCancel()
        end
        state.open = false
        state.buffer = ''
        state.error = nil
        state.pendingClose = nil
        imgui.EndPopup()
        return wasSave
    end
    -- Reserve space for error message so window does not resize when validation fails
    local lineHeight = imgui.GetTextLineHeight()
    if state.error and state.error ~= '' then
        imgui.TextColored(1.0, 0.3, 0.3, 1.0, state.error)
    else
        imgui.Dummy(0, lineHeight)
    end
    imgui.Spacing()
    imgui.SetNextItemWidth(280)
    local buf, submitted = imgui.InputText('##value' .. popupId, state.buffer or '', EnterReturnsTrue)
    -- Keep caller-owned buffer synced even when Enter wasn't pressed.
    if buf ~= state.buffer then state.buffer = buf end
    imgui.Spacing()
    if submitted or imgui.Button('Save##ValidatedEditModal_Save_' .. id) then
        state.error = nil
        local ok, errMsg
        if validateFn then
            ok, errMsg = validateFn(state.buffer or '')
        else
            ok = true
        end
        if ok then
            state.pendingClose = 'save'
        else
            state.error = errMsg or 'Invalid'
        end
    end
    imgui.SameLine()
    if imgui.Button('Cancel##ValidatedEditModal_Cancel_' .. id) then
        state.pendingClose = 'cancel'
    end
    imgui.EndPopup()
    return nil
end

--- Open the validated edit popup (call after setting state.open = true and state.buffer = initialValue).
---@param id string
function M.openValidatedEditModal(id)
    imgui.OpenPopup('##ValidatedEditModal_' .. id)
end

--- Delete confirmation modal: "Are you sure?" with DELETE (red) and CANCEL. Deferred close like validatedEditModal.
---@param id string unique id for this popup
---@param state table { open: boolean, pendingClose: 'delete'|'cancel'|nil } caller-owned
---@param entryLabel string e.g. "Heal" for message
---@param onConfirm fun() called when DELETE confirmed
---@param onCancel fun() called when CANCEL
function M.deleteConfirmModal(id, state, entryLabel, onConfirm, onCancel)
    if not state.open then
        return
    end
    local popupId = '##DeleteConfirm_' .. id
    local show = imgui.BeginPopupModal(popupId, nil, POPUP_FLAGS)
    if not show then
        return
    end
    if state.pendingClose then
        local wasDelete = (state.pendingClose == 'delete')
        imgui.CloseCurrentPopup()
        if wasDelete then
            onConfirm()
        else
            onCancel()
        end
        state.open = false
        state.pendingClose = nil
        imgui.EndPopup()
        return
    end
    imgui.Text('Are you sure you want to delete this %s?', entryLabel or 'entry')
    imgui.Spacing()
    imgui.PushStyleColor(ImGuiCol.Button, RED)
    if imgui.Button('DELETE##DeleteConfirm_Delete_' .. id) then
        state.pendingClose = 'delete'
    end
    imgui.PopStyleColor(1)
    imgui.SameLine()
    if imgui.Button('CANCEL##DeleteConfirm_Cancel_' .. id) then
        state.pendingClose = 'cancel'
    end
    imgui.EndPopup()
end

--- Open the delete confirm popup (call after setting state.open = true).
---@param id string
function M.openDeleteConfirmModal(id)
    imgui.OpenPopup('##DeleteConfirm_' .. id)
end

return M
