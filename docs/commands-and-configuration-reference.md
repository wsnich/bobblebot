# Commands and Configuration Reference

This document is a single reference for all **/cz** commands and the **configuration file** structure. For detailed behavior and examples, see the topic-specific docs (healing, tanking, buffing, etc.).

---

## Commands

All commands are used as **`/cz <command> [arguments]`**. Arguments are optional unless noted.

### Toggles

These turn a feature on or off. Use **`/cz <cmd> on`**, **`/cz <cmd> off`**, or **`/cz <cmd>`** to toggle.

| Command      | Purpose                                                                                                                                                                |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **domelee**  | Melee / engage (stick, attack, follow MA or tank logic).                                                                                                               |
| **dopull**   | Pulling loop (find mob, aggro, return to camp).                                                                                                                        |
| **dodebuff** | Debuff loop (nukes, slows, mez, etc.).                                                                                                                                 |
| **dobuff**   | Buff loop (buffs, pet summon).                                                                                                                                         |
| **doheal**   | Heal loop.                                                                                                                                                             |
| **doraid**   | Raid mode: enable zone-specific raid mechanic handling; when raid mechanics are active, pulling is suppressed and zone scripts may run. See [Raid mode](raid-mode.md). |
| **docure**   | Cure loop.                                                                                                                                                             |
| **dosit**    | Sit when not in combat (for mana/endurance).                                                                                                                           |
| **domount**  | Mount when not in combat.                                                                                                                                              |
| **dodrag**   | Corpse drag: automatically find and drag peer corpses within range. See [Corpse dragging](corpse-dragging.md).                                                         |

### Movement and camp

| Command      | Arguments                | Purpose                                                                                                                                                                                                                                                   |
| ------------ | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **makecamp** | `on`, `off`, or `return` | Set or clear make camp; `return` sends bot back to camp.                                                                                                                                                                                                  |
| **follow**   | `<name>`, `me`, or omit  | Follow the named character (disables make camp). With `me` or no name, follow TankName. When the command is sent via MQRemote (e.g. `/rc +self group /cz follow`), sender is not available—use MQRemote `/rc` directly (no CZBot `/an*execute` commands). |
| **travel**   | `<name>`, `me`, or omit  | Same as follow; enables travel mode (follow only; no melee, buff, debuff, heal, cure, sit, mount, pull). Bards twist the song with alias `travel`, or `selos` if none; if neither, twist nothing. Persists across zones; `/cz attack` temporarily enables melee/heal/cure/debuff until target dies, then travel resumes. `/cz stop` or stopping follow turns off travel. See [Travel mode](travel-mode.md). |
| **stop**     | —                        | Disable make camp and follow (and travel mode).                                                                                                                                                                                                                             |
| **leash**    | —                        | Return to camp (if camp is set).                                                                                                                                                                                                                          |
| **camprestdistance** | `<number>` | Set distance (units) considered "at camp" for leash and return. Writes to `settings.campRestDistance`.                                                                                                        |
| **acleash**  | `<number>`              | Set camp leash distance (max distance from camp for mob list / targeting).                                                                                                                |

### Pull

| Command             | Arguments              | Purpose                                                                                                                                                 |
| ------------------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **dopull**          | `on` / `off` or toggle | Enable/disable pulling.                                                                                                                                 |
| **xarc**            | `<degrees>` or none    | Directional pulling: restrict pulls to an arc in front of the bot (e.g. `90`). No argument turns it off. (This is the runtime “pullarc” setting.)       |
### Mob lists

| Command             | Arguments              | Purpose                                                                                                                                                 |
| ------------------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **exclude**         | `<name>` or target     | Add a mob to the exclude list (pull and target selection skip it). Changes are saved automatically to the common config (cz_common.lua).                |
| **exclude remove**  | `<name>` or target     | Remove a mob from the exclude list.                                                                                                                     |
| **priority**        | `<name>` or target     | Add a mob to the priority list; when pull.usepriority is true, prefer these mobs. Changes are saved automatically to the common config (cz_common.lua). |
| **priority remove** | `<name>` or target     | Remove a mob from the priority list.                                                                                                                    |
| **charm**           | `<name>` or target     | Add a mob to the charm list for the current zone (allowed charm targets). Saved to common config (cz_common.lua).                                        |
| **charm remove**    | `<name>` or target     | Remove a mob from the charm list.                                                                                                                        |
| **reloadcommon**    | —                      | Reload `cz_common.lua` from disk and refresh current-zone exclude/priority/charm lists and nuke flavor auto-disable state. |

### Combat and roles

| Command          | Arguments               | Purpose                                                                                                           |
| ---------------- | ----------------------- | ----------------------------------------------------------------------------------------------------------------- |
| **attack**       | optional `<name>`       | Engage the Main Assist’s target **immediately** (ignores the “assist at” percentage). If `<name>` is given, engage that player’s target for this engagement only. The engagement **persists** until the target dies or an override occurs: **`/cz abort`**, turning off **domelee**, or issuing another **`/cz attack`** (which sets a new target). Normal assist-at logic resumes after the engagement ends. |
| **abort**        | optional `off`          | Abort: stop cast, clear target, turn off melee/debuff; return to camp. Use `abort off` to re-enable melee/debuff. |
| **tank**         | `<name>` or `automatic` | Set Main Tank.                                                                                                    |
| **assist**       | `<name>` or `automatic` | Set Main Assist.                                                                                                  |
| **offtank**      | `on` / `off` or toggle  | Enable/disable offtank behavior.                                                                                  |
| **stickcmd**     | `<string>`              | Set stick command (e.g. `hold uw 7`).                                                                             |
| **targetfilter** | `0` / `1` / `2`         | Filter for mob list: 0 = NPC + aggressive + LOS (pull only aggressive), 1 = NPC + LOS, 2 = exclude PCs/mercs/etc. |

### Spells and config

| Command                         | Arguments                                        | Purpose                                                                                                     |
| ------------------------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------- |
| **cast**                        | `<alias> [target]` or `<alias> on` / `off`       | Cast a spell by alias (heal/buff/debuff/cure). With `on`/`off`, enable or disable that spell (**enabled**). |
| **setvar**                      | `<path> <value>`                                 | Set a config value at runtime (e.g. `settings.petassist true`). Writes to config file. See [setvar reference](setvar-reference.md) for all paths and descriptions. |
| **addspell**                    | `heal` / `buff` / `debuff` / `cure` `<position>` | Add a new spell entry at the given position (1 to count+1).                                                 |
| **refresh** / **refreshspells** | —                                                | Refresh spell state.                                                                                        |
| **echo**                        | `<config.path>`                                  | Print current value of a config path (e.g. `heal.interruptlevel`).                                          |
| **togglenuke**                  | `<flavor> [on|off]`                              | Toggle nuke flavor (fire, ice, cold, magic, poison, disease). Stored per zone in cz_common.lua. See [Nuking configuration](nuking-configuration.md). |

### Other

| Command           | Arguments                                     | Purpose                                                                                                             |
| ----------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| **import**        | `lua <filename> [save]`                       | Load config from a Lua file; optional `save` writes it to current config.                                           |
| **export**        | `<filename>`                                  | Export current config to a file in config directory.                                                                |
| **debug**         | `on` / `off` or toggle                        | Enable/disable debug messages.                                                                                      |
| **ui** / **show** | —                                             | Open the CZBot UI.                                                                                                  |
| **quit**          | —                                             | Terminate the bot.                                                                                                  |
| **chchain**       | **stop** — stop chain. **setup** `<list>` `[pause]` `[tanklist]` — configure cleric list, optional pause value, optional tank list. **start** `[name]` — start chain (name = this toon). **tank** `<name>` — set chain tank. **pause** `[val]` — set or report pause. | Complete Heal chain control.                                                                                        |
| **draghack**      | `on` / `off` or toggle                        | Toggle use of sumcorpse instead of walk-to-corpse for dragging. See [Corpse dragging](corpse-dragging.md).          |
| **linkitem**      | —                                             | Link item (event).                                                                                                  |
| **linkaugs**      | `<slot>`                                      | Print augments in the given slot.                                                                                   |
| **spread**        | —                                             | Spread bots (nav to positions).                                                                                     |
| **raid**          | `save` / `load` `<name>`                      | Save or load a raid configuration by name. See [Raid mode](raid-mode.md) for save/load behavior and raid formation. |
| **clickdoor**     | —                                             | Run `/doortarget`, wait 500 ms, then `/click left door`.                                                            |
| **saytarget**     | `<spawnId> <message>`                         | Target spawn by ID, wait for target to switch, then `/say` the message. For group hotkeys: `/rc group /cz saytarget ${Me.Target.ID} travel to butcherblock`. |

### Master pause

- **`/czp`** or **`/czpause [on|off]`** — Pause or resume the entire bot. No arguments toggles pause.

---

## Configuration file structure

The config file is a Lua script that returns a table. Path: **`cz_<CharName>.lua`** in your MacroQuest config directory (e.g. `config/cz_Yourname.lua`).

**Top-level keys:** `settings`, `pull`, `melee`, `heal`, `buff`, `debuff`, `cure`, `bard`, `script`. Each section is a table; `heal`, `buff`, `debuff`, and `cure` contain a **spells** array of spell entries. **bard** holds class-specific options (e.g. `mez_remez_sec`). See [Bard configuration](bard-configuration.md).

**Example: overall shape and settings**

```lua
StoredConfig = {
  settings = {
    domelee = false,
    doheal = false,
    dobuff = false,
    dodebuff = false,
    docure = false,
    dopull = false,
    doraid = false,
    dodrag = false,
    domount = false,
    mountcast = 'none',
    dosit = true,
    sitmana = 90,
    sitendur = 90,
    sitaggro = 60,
    TankName = "manual",
    AssistName = nil,
    TargetFilter = 0,
    petassist = false,
    acleash = 75,
    followdistance = 35,
    zradius = 75,
    campRestDistance = 15
  },
  pull = { ... },
  melee = { ... },
  heal = { rezoffset = 0, interruptlevel = 0.80, xttargets = 0, spells = { ... } },
  buff = { spells = { ... } },
  debuff = { spells = { ... } },
  cure = { spells = { ... } },
  script = {}
}
return StoredConfig
```

### Settings (defaults)

| Option             | Default       | Purpose                                                                                                                 |
| ------------------ | ------------- | ----------------------------------------------------------------------------------------------------------------------- |
| **domelee**        | `false`       | Enable melee/engage.                                                                                                    |
| **doheal**         | `false`       | Enable heal loop.                                                                                                       |
| **dobuff**         | `false`       | Enable buff loop.                                                                                                       |
| **dodebuff**       | `false`       | Enable debuff loop.                                                                                                     |
| **docure**         | `false`       | Enable cure loop.                                                                                                       |
| **dopull**         | `false`       | Enable pull loop.                                                                                                       |
| **doraid**         | `false`       | Raid mode (zone-specific raid mechanics; when active, pulling is suppressed). See [Raid mode](raid-mode.md).            |
| **dodrag**         | `false`       | Corpse drag (automatically find and drag peer corpses). See [Corpse dragging](corpse-dragging.md).                      |
| **domount**        | `false`       | Auto mount.                                                                                                             |
| **mountcast**      | `'none'`      | Mount cast: spell or item name, or `'none'`.                                                                            |
| **dosit**          | `true`        | Sit when not in combat.                                                                                                 |
| **sitmana**        | 90            | Sit when mana % below this; stand when above this + 3 (hysteresis).                                                      |
| **sitendur**       | 90            | Sit when endurance % below this; stand when above this + 3 (hysteresis).                                                |
| **sitaggro**       | 60            | When mobs are in camp and level 20+, only sit when `Me.PctAggro` is below this (no hysteresis).                          |
| **TankName**       | `"manual"`    | Main Tank name or `"automatic"` / `"manual"`.                                                                           |
| **AssistName**     | (unset)       | Main Assist name or `"automatic"` / `"manual"`.                                                                         |
| **TargetFilter**   | `0`           | Mob list filter (0/1/2).                                                                                                |
| **petassist**      | `false`       | Boolean. When true, send pet on engage target; when false, pet does not engage. Default `false`.                                                                                      |
| **acleash**        | 75            | Camp leash distance.                                                                                                    |
| **followdistance** | 35            | Follow distance: beyond this distance the bot stands and runs follow; within it, sit is allowed when mana below sitmana; stand when above sitmana + 3 (hysteresis). |
| **zradius**        | 75            | Vertical range from camp for mob list.                                                                                  |
| **campRestDistance** | 15          | Distance (units) to consider "at camp" for leash and return.                                                            |
| **spelldb**        | `'spells.db'` | Spell database file.                                                                                                    |

Travel mode has no config option; it is enabled by the **/cz travel** command. See [Travel mode](travel-mode.md).

### Pull section

See [Pull Configuration and Logic](pull-configuration.md) for the full pull table. Options include: **spell** (single block: gem, spell, range), **radius**, **zrange**, **pullMinCon**, **pullMaxCon**, **maxLevelDiff**, **usePullLevels**, **pullMinLevel**, **pullMaxLevel**, **chainpullcnt**, **chainpullhp**, **mana**, **manaclass**, **leash**, **addAbortRadius**, **usepriority**, **hunter**.

### Melee section

| Option        | Default       | Purpose                                       |
| ------------- | ------------- | --------------------------------------------- |
| **assistpct** | 99            | MA target HP % at or below which to sync.     |
| **stickcmd**  | `'hold uw 7'` | Stick command when engaging.                  |
| **stayBehind** | `false`    | Non-MT: append `!front` to stick while engaging. |
| **behindAggroPct** | 90     | With stayBehind: above this PctAggro, stick without `!front`. |
| **offtank**   | `false`       | This bot is an offtank.                       |
| **otoffset**  | 0             | Which add to pick when MT and MA on same mob. |
| **minmana**   | 0             | Min mana % to engage.                         |

Combat abilities (disciplines, /doability) are configured as **debuff** entries with **gem** `'disc'` or `'ability'`; **dodebuff** must be on for them to run. See [Melee combat abilities](melee-combat-abilities.md).

### Heal / Buff / Debuff / Cure sections

- **heal:** Top-level: **rezoffset**, **interruptlevel**, **xttargets**. Spell entries: **gem**, **spell**, **alias**, **announce**, **minmana**, **minmanapct**, **maxmanapct**, **enabled**, **tarcnt** (optional; group heals only), **bands**, **healResource** (optional; `'hp'` or `'mana'`; when `'mana'`, bands use mana % not HP), **inCombat** (optional; when true and band has corpse, allow rez in combat), **precondition** (optional; default true; boolean or Lua script when set). See [Healing configuration](healing-configuration.md).
- **buff:** Spell entries: **gem**, **spell**, **alias**, **announce**, **minmana**, **enabled**, **tarcnt** (optional; groupbuff min count), **bands**, **spellicon**, **inCombat**, **inIdle** (Bard twist; when spell can run), **combatOnly** (optional; non-bard; auto buff loop only when mobs in camp), **precondition** (optional; default true; boolean or Lua script when set). See [Buffing configuration](buffing-configuration.md). Bards: see [Bard configuration](bard-configuration.md).
- **debuff:** Spell entries: **gem**, **spell**, **alias**, **announce**, **minmana**, **enabled**, **bands** (band options include **mintar**/**maxtar** for camp mob-count gate), **recast**, **delay**, **dontStack** (optional; list of categories—skip or interrupt if target has; see [Debuffing configuration](debuffing-configuration.md)), **precondition** (optional; default true; boolean or Lua script when set). Charm and targeted AE spells are auto-detected from spell data. Charm targets use the per-zone **Charm list** (Mob Lists tab or **/cz charm**). For **concussion** (aggro-reduce, SPA 92) debuffs, **recast** means “cast every N other debuffs” on the tank target (e.g. recast 2 → two nukes/debuffs, then concussion, repeat); autodetected when the spell has SPA 92 and recast &gt; 0. See [Debuffing configuration](debuffing-configuration.md) and [Spell targeting and bands](spell-targeting-and-bands.md).
- **cure:** Spell entries: **gem**, **spell**, **alias**, **announce**, **minmana**, **curetype** (table of strings; default **{ 'all' }**), **enabled**, **bands** (add **priority** to band **targetphase** to run in the priority cure pass; no top-level setting), **precondition** (optional; default true; boolean or Lua script when set). See [Curing configuration](curing-configuration.md).

**Example: one heal spell entry**

```lua
{
  gem = 1,
  spell = 'Superior Healing',
  alias = 'cht',
  minmana = 0,
  minmanapct = 0,
  maxmanapct = 100,
  bands = {
    { targetphase = { 'tank', 'pc' }, validtargets = { 'all' }, min = 0, max = 70 }
  }
}
```

---

## Where to configure

- **Config file:** Edit **`cz_<CharName>.lua`** in your MQ config directory. Reload by re-running the bot or using **import** / **setvar**.
- **Runtime only (not in config file):** **ExcludeList**, **PriorityList**, **CharmList** (pull exclude/priority and charm targets), and **pullarc** (directional pull) are set at runtime via **/cz exclude**, **/cz priority**, **/cz charm** (add/remove), and **/cz xarc**. These lists are stored per zone in the common config file **cz_common.lua** in a zone-first layout: **zones**[*zoneShortName*] holds **excludelist**, **prioritylist**, **charmlist**, **nukeFlavors**, **nukeFlavorsAutoDisabled**, and **immune** for that zone. Changes are saved automatically when you add or remove entries.
- **Both:** Most options can be set in the config file or at runtime via **/cz setvar** (e.g. **setvar settings.petassist true**), which writes back to the config file.
