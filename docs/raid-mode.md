# Raid Mode

This document explains **raid mode**: what the **doraid** toggle does (raid mechanic handling), and how to **save and load** raid group formation. It is intended for operators running the bot in raids.

**Note:** The file `raid/unknown.lua` is staging only and is **not** loaded by the bot. It contains event handlers for PoR, Solteris, SoF, SoD, and DoDH. If you want those events (e.g. Hatchet/DoDH emotes), you must require it manually (e.g. from a zone-specific script or your own entry point).

## Overview

Raid mode covers two separate features:

- **Raid mechanic mode (doraid):** When enabled, the bot runs zone-specific raid checks. When raid mechanics are active (e.g. a zone script detects an event), the bot can enter **raid_mechanic** state: normal pulling is suppressed, and zone scripts may run custom behavior (e.g. move away from a breath, then resume).
- **Raid save/load:** The **/cz raid save** and **/cz raid load** commands let you save the current raid’s group layout by name and later restore it (disband, then re-invite by group). This does **not** require doraid to be on.

---

## Raid mechanic mode (doraid)

When **doraid** is on, the bot checks each tick whether zone-specific raid mechanics are active. If they are, the bot sets its run state to **raid_mechanic**. While in that state, normal pulling does not start (other systems can also respect this state). Zone-specific modules (in the bot’s `raid/` folder, one per zone short name) can define when mechanics are “active” and can run event-driven behavior (e.g. on a boss breath: drop melee, move, interrupt, then resume).

### Config

| Option | Default | Purpose |
|--------|--------|---------|
| **doraid** | `false` | When `true`, enable raid mechanic mode: run zone raid checks and allow **raid_mechanic** state and zone scripts to run. |

**Example (in settings):**

```lua
settings = {
  doraid = true
}
```

### Runtime

- **Toggle:** `/cz doraid on` or `/cz doraid off` (or `/cz doraid` to toggle).

### Behavior summary

- The bot loads a zone module when you enter a zone (based on zone short name). If that module has a **raid_check()** function, it is called; if it returns true (or other shared raid logic applies), the bot enters **raid_mechanic** state.
- While in **raid_mechanic**, the pull loop will not start a new pull. Zone modules may also register in-game events to run custom behavior (e.g. move, stop melee, interrupt, then resume). Exact behavior depends on the zone; the bot does not document every zone file here.

---

## Raid save and load

You can save the current raid’s group structure under a name and later restore it. This is useful to rebuild the same raid layout (who is in which group, who are group leaders) after a disband or zone.

### Commands

| Command | Purpose |
|---------|---------|
| **/cz raid save \<name\>** | Save the current raid’s group layout under the given name. You must be in a raid. Stored in common config (cz_common.lua) so it can be reused. |
| **/cz raid load \<name\>** | Load a saved raid layout by name: disband the current raid, then re-invite by group (group leaders invite their members, then raid invite). The bot runs a short sequence of invites; other toons must accept group/raid invites. |

Save/load is independent of **doraid**. You can use raid save/load with doraid on or off.

---

## Relation to Tank and Assist

In raids, the game UI has no Main Tank or Puller role; those always come from the **group**. Main Assist can come from the **raid** when in a raid. For how `TankName` and `AssistName` resolve in raids (including **`mt_list`-only** automatic MT), see [Automatic MA/MT Selection](automatic-ma-mt-selection.md#game-role-sources-group-vs-raid).
