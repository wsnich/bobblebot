# Safety and Stealth

bobblebot includes always-on safety rules to avoid attacking service NPCs and to reduce obvious bot behavior at bind points. Non-combat zones are configurable in **cz_common.lua** via the GUI.

---

## Protected NPCs (soulbinder / translocator)

The bot **never** takes offensive action against NPCs whose **CleanName** starts with **`soulbinder`** or **`translocator`** (case-insensitive). This applies everywhere, in every zone.

**Blocked actions:**

- Melee (`/attack`, `/stick`, pet attack)
- Debuffs (nukes, slows, mez, charm, etc.)
- Pull target selection
- `/cz attack` when the assist target is a protected NPC (command is rejected with a chat message)

**How it works:**

- Protected spawns are filtered out of the camp **MobList** and pull candidate list in `lib/spawnutils.lua`.
- Secondary guards in `botmelee.lua`, `botdebuff.lua`, and `lib/commands.lua` catch direct-engage paths that bypass the mob list.

There is no config toggle; the filter is hardcoded by name prefix.

---

## Bind-point stealth

When your character is in their **primary bind zone** and within **`settings.acleash`** (2D distance) of the bind coordinates, the bot suppresses behavior that looks like automated play at a soulbinder:

**Blocked:**

- Melee and debuffs (including while travel attack override is active)
- Pulling
- Buffing (including bard MQ2Twist noncombat twist)

**Still allowed:**

- Healing
- Curing (normal and priority cure phases)

**Bind location source:** MacroQuest TLOs `${Me.ZoneBound}` / `${Me.ZoneBoundX}` / `${Me.ZoneBoundY}` (primary bind, index 0). The current zone short name must match the bind zone short name.

If you enter this radius while already fighting, the bot disengages (stick off, attack off, pet back, clear engage target).

Implementation: `utils.isNearPrimaryBindPoint()` and `utils.enforceBindStealth()` in `lib/utils.lua`; guards on `doMelee`, `doDebuff`, `doPull`, and `doBuff` hooks.

---

## No combat zones

Zones where combat logic is skipped (no mob list build for combat, no melee/debuff/pull) are stored in **cz_common.lua** as a **global** list:

```lua
noCombatZones = { 'GuildHall', 'GuildLobby', 'PoKnowledge', 'Nexus', 'Bazaar', 'AbysmalSea', 'potranquility' }
```

On first load, if `noCombatZones` is missing or empty, bobblebot seeds these defaults and saves **cz_common.lua**.

**Comparison:** Zone short names are matched case-insensitively (same as `mq.TLO.Zone.ShortName()`).

**Where combat is skipped when the current zone is an active no-combat zone:**

- **AddSpawnCheck** — mob list not built (hook exits early)
- **doMelee**, **doDebuff**, **doPull**
- **doDebuff** spell-hook active check in `lib/spellutils.lua`

Healing and curing are **not** gated by no-combat zones.

### GUI: Mob lists tab

Open the GUI (**`/czshow`**) → **Mob lists** tab.

**No combat zones** appears below the per-zone exclude, priority, and charm lists (global; not per-zone):

| Control | Behavior |
| -------- | -------- |
| **Enabled** checkbox | Temporarily disable that zone for this session only. Unchecked = combat allowed in that zone until you re-check or reload the script. **Not saved** to config. |
| **Remove** | Deletes the zone from **cz_common.lua** permanently. |
| **Add current zone** | Adds `mq.TLO.Zone.ShortName()` to the list. Works while the bot is **paused**; no target required. |

On **script reload**, all no-combat zones show as enabled again (in-memory disable state is cleared). **`/cz reloadcommon`** reloads the list from disk but does **not** reset temporary enable/disable checkboxes.

### Module

Logic lives in `lib/nocombatzones.lua`. Runtime checks use `utils.isNonCombatZone(zone)`, which returns true only when the zone is in the configured list **and** not temporarily disabled in the GUI.

---

## See also

- [Commands and configuration reference](commands-and-configuration-reference.md) — **cz_common.lua** layout, Mob lists commands
- [Tanking configuration](tanking-configuration.md) — **acleash** (camp radius and bind stealth radius)
- [Pull configuration](pull-configuration.md) — exclude/priority lists on the same GUI tab
- [Bot logic: AddSpawnCheck](botlogic/hook-addspawncheck.md)
- [Bot logic: doMelee](botlogic/hook-domelee.md)
- [Bot logic: doDebuff](botlogic/hook-dodebuff.md)
- [Bot logic: doPull](botlogic/hook-dopull.md)
- [Bot logic: doBuff](botlogic/hook-dobuff.md)
