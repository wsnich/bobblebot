-- Targets tab (MT target-director): one row per NPC on your XTarget, with buttons to direct the group to
-- focus that mob. Buttons dispatch '/cz attack <id>' so each character engages that exact mob:
--   MA    -> just the Main Assist (DPS that assist the MA follow). Local if you ARE the MA.
--   Group -> the whole group incl. you, via MQRemote (/rc +self group).
-- Most useful on the Main Tank, but works from any character.

local mq = require('mq')
local ImGui = require('ImGui')
local theme = require('gui.widgets.theme')
local tankrole = require('lib.tankrole')

local M = {}

local YELLOW, LIGHT_GREY, GREEN, RED, WHITE = theme.YELLOW, theme.LIGHT_GREY, theme.GREEN, theme.RED, theme.WHITE

-- NPCs currently on the XTarget, nearest-first as EQ lists them.
local function collectXTargets()
    local out = {}
    local n = tonumber(mq.TLO.Me.XTarget()) or 0
    local meId = mq.TLO.Me.ID()
    for i = 1, n do
        local xt = mq.TLO.Me.XTarget(i)
        local id = xt and xt.ID()
        if id and id > 0 and xt.Type() == 'NPC' then
            local tgtId = (xt.Target and xt.Target.ID()) or 0
            out[#out + 1] = {
                id = id,
                name = xt.CleanName() or ('id ' .. id),
                hp = tonumber(xt.PctHPs()) or 0,
                dist = tonumber(xt.Distance()) or 0,
                onMe = (tgtId == meId),
                onName = (xt.Target and xt.Target.CleanName and xt.Target.CleanName()) or '',
            }
        end
    end
    return out
end

function M.draw()
    ImGui.TextWrapped(
        'Direct the group to a mob. "MA" sends just the Main Assist (DPS assisting it follow); ' ..
        '"Group" sends the whole group (via MQRemote). Both issue /cz attack on that exact target.')
    ImGui.Spacing()
    local maName = tankrole.GetAssistTargetName()
    local meName = mq.TLO.Me.CleanName()
    ImGui.TextColored(WHITE, 'Main Assist: '); ImGui.SameLine(0, 2)
    ImGui.TextColored(LIGHT_GREY, '%s', (maName and maName ~= '') and maName or '(none)')
    ImGui.Spacing()

    local tgts = collectXTargets()
    if #tgts == 0 then
        ImGui.TextColored(LIGHT_GREY, '%s', '  (no NPCs on your XTarget)')
        return
    end

    local flags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersInnerH, ImGuiTableFlags.BordersOuter)
    if ImGui.BeginTable('mt_targets', 5, flags, -1, 0) then
        ImGui.TableSetupColumn('Mob', ImGuiTableColumnFlags.WidthStretch, 0.40)
        ImGui.TableSetupColumn('HP', ImGuiTableColumnFlags.WidthFixed, 42)
        ImGui.TableSetupColumn('Dist', ImGuiTableColumnFlags.WidthFixed, 46)
        ImGui.TableSetupColumn('On', ImGuiTableColumnFlags.WidthStretch, 0.30)
        ImGui.TableSetupColumn('Direct', ImGuiTableColumnFlags.WidthFixed, 96)
        for _, t in ipairs(tgts) do
            ImGui.TableNextRow()
            ImGui.TableNextColumn(); ImGui.TextColored(YELLOW, '%s', t.name)
            ImGui.TableNextColumn(); ImGui.TextColored(LIGHT_GREY, '%d%%', t.hp)
            ImGui.TableNextColumn(); ImGui.TextColored(LIGHT_GREY, '%.0f', t.dist)
            ImGui.TableNextColumn()
            local onStr = t.onMe and 'YOU' or (t.onName ~= '' and t.onName) or '?'
            ImGui.TextColored(t.onMe and GREEN or RED, '%s', onStr)
            ImGui.TableNextColumn()
            if ImGui.SmallButton('MA##ma_' .. t.id) then
                if maName and maName ~= '' and maName == meName then
                    mq.cmdf('/cz attack %d', t.id) -- I am the MA: engage locally
                elseif maName and maName ~= '' then
                    mq.cmdf('/rc %s /cz attack %d', maName, t.id)
                end
            end
            if ImGui.IsItemHovered() then ImGui.SetTooltip('Send the Main Assist to %s (DPS assisting the MA follow).', t.name) end
            ImGui.SameLine()
            if ImGui.SmallButton('Grp##grp_' .. t.id) then
                mq.cmdf('/rc +self group /cz attack %d', t.id) -- whole group incl. me
            end
            if ImGui.IsItemHovered() then ImGui.SetTooltip('Send the whole group to %s (MQRemote /rc +self group).', t.name) end
        end
        ImGui.EndTable()
    end
    ImGui.Spacing()
    ImGui.TextColored(LIGHT_GREY, '%s', 'Tip: /cz attack off (or the Abort button) releases a directed target.')
end

return M
