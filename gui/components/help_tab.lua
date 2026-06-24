-- Help tab: read-only quick reference of /cz commands, grouped by area. Curated (not auto-generated)
-- so each entry has a plain-language description. Keep in sync with lib/commands.lua handlers.

local ImGui = require('ImGui')
local theme = require('gui.widgets.theme')
local section = require('gui.widgets.section')

local M = {}

local YELLOW, LIGHT_GREY = theme.YELLOW, theme.LIGHT_GREY

-- Each group: { title, { {command, description}, ... } }
local GROUPS = {
    { title = "Session / control", cmds = {
        { "/czshow", "Open the bobblebot window." },
        { "/czp", "Pause / resume the bot." },
        { "/cz quit   (/czquit)", "Stop the bot (ends the Lua script)." },
        { "/cz stop", "Stop following and clear camp." },
        { "/cz abort", "Abort the current action / cast." },
        { "/cz refresh   (refreshspells)", "Reload the spell config from disk." },
        { "/cz reloadcommon", "Reload cz_common.lua (shared MA/MT lists, immune list, junk)." },
        { "/cz import lua <file>", "Import a config from a Lua file." },
        { "/cz export <file>", "Export the current config to a file." },
        { "/cz setvar <section.key> <value>", "Set a config value by path and save it." },
        { "/cz debug", "Toggle general debug output." },
    } },
    { title = "Roles & targeting", cmds = {
        { "/cz tank <name|automatic>", "Set the Main Tank (persists across reloads)." },
        { "/cz assist <name|automatic>", "Set the Main Assist (persists across reloads)." },
        { "/cz role <tank|ma|dps|healer>", "Apply a role preset: behavior flags + tank/assist designation." },
        { "/cz offtank", "Toggle off-tank mode for this character." },
        { "/cz attack", "Manually engage your current target (overrides XTarget-only)." },
        { "/cz cast <alias>", "Cast a configured spell/ability by its alias." },
    } },
    { title = "Combat behavior", cmds = {
        { "/cz domelee on|off", "Toggle melee/engage." },
        { "/cz dodebuff on|off", "Toggle debuffs / mez / nukes / combat abilities." },
        { "/cz dobuff on|off", "Toggle buffing." },
        { "/cz doheal on|off", "Toggle healing." },
        { "/cz docure on|off", "Toggle curing." },
        { "/cz dopull on|off", "Toggle pulling." },
        { "/cz doraid on|off", "Toggle raid-mechanic scripts." },
        { "/cz dosit on|off", "Toggle auto-sit to recover mana/endurance." },
        { "/cz domount on|off", "Toggle mount use while traveling." },
        { "/cz dodrag on|off", "Toggle corpse dragging." },
        { "/cz doforage on|off", "Toggle auto-forage." },
        { "/cz engagextargetonly on|off   (xtargetonly)", "Reactive mode: only engage mobs on your XTarget (use with a separate puller)." },
        { "/cz aetank on|off", "AE-tank: as MT, taunt all XTarget mobs near camp (auto-off when a mezzer is in group)." },
        { "/cz premem on|off", "Pre-memorize the configured gembar during downtime so combat spells don't memorize mid-fight." },
        { "/cz burn [seconds|off]", "Open a burn window; spells/abilities with a `burn` precondition fire during it." },
        { "/cz togglenuke", "Toggle nuke usage." },
        { "/cz togglesongs", "Toggle the bard song twist." },
        { "/cz evadepct <n>", "Rogue: PctAggro at which to dump aggro with Hide." },
        { "/cz stickcmd <command>", "Set the /stick command used when engaging." },
    } },
    { title = "Camp & movement", cmds = {
        { "/cz makecamp on|off", "Set / clear camp at your current spot." },
        { "/cz groupcamp", "Make GROUP camp: camp here + tell every group member (DanNet /dgge) to camp at their spot." },
        { "/cz leash", "Return to camp now." },
        { "/cz acleash <n>", "Camp radius (which mobs count as in-camp)." },
        { "/cz camprestdistance <n>", "How close counts as 'at camp' for the return." },
        { "/cz targetfilter <0|1|2>", "Camp mob filter: 0 = Aggressive NPCs, 1 = LoS NPCs, 2 = All NPCs." },
        { "/cz togglecampacleash", "Toggle 'leash to radius' (chase beyond camp radius, or not)." },
        { "/cz macampanchor", "Toggle anchoring the mob bubble on the Main Assist." },
        { "/cz maanchorleash <n>", "Max MA distance for the anchor and ma/mt fallback lists." },
        { "/cz follow <name>", "Follow a PC." },
        { "/cz followme", "Follow the character who issued the command." },
        { "/cz travel <name>", "Travel mode: follow only, combat/pull suspended." },
    } },
    { title = "Mob lists & filters", cmds = {
        { "/cz exclude", "Add your target to the exclude list (never engage)." },
        { "/cz priority", "Add your target to the pull priority list." },
        { "/cz charm", "Add your target to the charm list." },
        { "/cz mobfilter <...>", "Adjust mob-list filtering for the current zone." },
        { "/cz addjunk <item>", "Add an item to the zone junk list (destroyed on forage)." },
        { "/cz foragezone on|off", "Enable / disable auto-forage in the current zone." },
        { "/cz fte", "First-to-engage (FTE) lock handling." },
        { "/cz xarc <...>", "Advanced XTarget configuration." },
    } },
    { title = "CC / pets / rez / cleric chain", cmds = {
        { "/cz rezaccept on|off", "Toggle auto-accept of incoming resurrection." },
        { "/cz charmpetsetup on|off", "Toggle charm-pet auto-setup (taunt off + assist)." },
        { "/cz chchain <...>", "Set up the cleric Complete Heal chain." },
    } },
    { title = "Diagnostics", cmds = {
        { "/cz mezdebug on|off", "Log why mez targets are picked or skipped." },
        { "/cz buffdebug on|off", "Log why a buff is or isn't cast on a target." },
        { "/cz prememdebug on|off", "Log which gems the pre-mem pass loads (and what it skips)." },
        { "/cz upgradedebug on|off", "Log spell-upgrade scan results (SpellGroup matches per configured spell)." },
        { "/cz echo <text>", "Echo a message (testing)." },
    } },
    { title = "Utility", cmds = {
        { "/cz scribe", "Scribe usable spell scrolls from your bags (auto-confirms EQ's replace dialog)." },
        { "/cz upgrades", "List configured spells that have a better version in your spellbook." },
        { "/cz applyupgrade <n|all>", "Apply a detected spell upgrade to your config (see /cz upgrades)." },
        { "/cz addspell <...>", "Add a spell entry to a section." },
        { "/cz saytarget   (syt)", "Announce your current target in chat." },
        { "/cz clickdoor", "Click the nearest door." },
        { "/cz linkitem <slot>", "Link an equipped item to chat." },
        { "/cz linkaugs", "Link your augments to chat." },
        { "/cz spread", "Spread out from nearby characters." },
        { "/cz draghack", "Toggle the corpse-drag hack." },
        { "/cz raid save|load <name>", "Save / load a raid roster." },
    } },
}

function M.draw()
    ImGui.TextWrapped(
        "Quick reference for /cz commands. Most toggles accept on|off|toggle; with no argument they flip. " ..
        "Many are broadcast-friendly across your crew (e.g. /bcaa //cz aetank on).")
    ImGui.Spacing()
    for _, g in ipairs(GROUPS) do
        section.header(g.title)
        local flags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersInnerH, ImGuiTableFlags.BordersOuter)
        if ImGui.BeginTable("help_" .. g.title, 2, flags, -1, 0) then
            ImGui.TableSetupColumn("Command", ImGuiTableColumnFlags.WidthStretch, 0.42)
            ImGui.TableSetupColumn("What it does", ImGuiTableColumnFlags.WidthStretch, 0.58)
            for _, c in ipairs(g.cmds) do
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                ImGui.TextColored(YELLOW, "%s", c[1])
                ImGui.TableNextColumn()
                ImGui.TextColored(LIGHT_GREY, "%s", c[2])
            end
            ImGui.EndTable()
        end
        ImGui.Spacing()
    end
end

return M
