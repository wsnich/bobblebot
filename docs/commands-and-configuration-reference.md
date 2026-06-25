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

### Bard session toggles

These affect runtime only (not saved to the config file). They reset when the bot restarts.

| Command         | Arguments              | Purpose                                                                                                                                 |
| --------------- | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| **togglesongs** | `on` / `off` or toggle | **Bard only.** Turn MQ2Twist singing on or off without pausing the bot. Default **on** at start. When off, the bot issues `/twist stop` and sends no further `/twist` commands (including twist-once for mez or pull engage). Status tab **Songs** toggle is the same setting. See [Bard configuration](bard-configuration.md). |

### Movement and camp

| Command      | Arguments                | Purpose                                                                                                                                                                                                                                                   |
| ------------ | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **makecamp** | `on`, `off`, or `return` | Set or clear make camp; `return` sends bot back to camp.                                                                                                                                                                                                  |
| **follow**   | `<name>`, `me`, or omit  | Follow the named character (disables make camp). With `me` or no name, follow TankName. When the command is sent via MQRemote (e.g. `/rc +self group /cz follow`), sender is not available—use MQRemote `/rc` directly (no CZBot `/an*execute` commands). |
| **travel**   | `<name>`, `me`, or omit  | Same as follow; enables travel mode (follow only; no melee, buff, debuff, heal, cure, sit, mount, pull). Bards twist the song with alias `travel`, or `selos` if none; if neither, twist nothing. Persists across zones; `/cz attack` temporarily enables melee/heal/cure/debuff until target dies, then travel resumes. `/cz stop` or stopping follow turns off travel. See [Travel mode](travel-mode.md). |
| **stop**     | —                        | Disable make camp and follow (and travel mode).                                                                                                                                                                                                                             |
| **followme** | `group`, `raid`, or `off` (default `group`) | Leader command: clear local camp/follow, then `/rc group\|raid /cz follow <this toon>`. Remembers scope; `off` sends `/rc group\|raid /cz stop`. Switching scope auto-stops the previous scope. |
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
| **reloadcommon**    | —                      | Reload `cz_common.lua` from disk and refresh current-zone exclude/priority/charm lists, **ma_list** / **mt_list**, and nuke flavor auto-disable state. Does not reset temporary no-combat zone enable/disable checkboxes (session-only). Use on each bot after another client edits shared lists so runtime state matches disk. Saves from any bot reload and union-merge with disk first, so concurrent edits are less likely to wipe data. |

**Multi-box:** All bots sharing `cz_common.lua` should run **`/cz reloadcommon`** after one bot edits exclude/priority/charm lists or **ma_list** / **mt_list** in the GUI, so each client's runtime lists match disk. Saves automatically reload from disk and union list entries before writing. See [Automatic MA/MT Selection](automatic-ma-mt-selection.md#editing-lists-and-multi-box-sync).

**GUI Mob lists tab** (`/czshow` → Mob lists): edit per-zone **exclude**, **priority**, and **charm** lists for the current zone, and the global **no combat zones** list. See [Safety and stealth](safety-and-stealth.md) for no-combat zone controls (Add current zone, Enabled checkbox, Remove).

**GUI Roles tab** (`/czshow` → Roles): edit global **ma_list** and **mt_list** (MA/MT automatic fallback), and per-char **MA anchor** / **MA leash** settings. See [Automatic MA/MT Selection](automatic-ma-mt-selection.md).

### Combat and roles

| Command          | Arguments               | Purpose                                                                                                           |
| ---------------- | ----------------------- | ----------------------------------------------------------------------------------------------------------------- |
| **attack**       | optional `<name>`       | Engage the Main Assist’s target **immediately** (ignores the “assist at” percentage). If `<name>` is given, engage that player’s target for this engagement only. Rejected if the target is a protected NPC (soulbinder/translocator). Blocked when near primary bind point. The engagement **persists** until the target dies or an override occurs: **`/cz abort`**, turning off **domelee**, or issuing another **`/cz attack`** (which sets a new target). Normal assist-at logic resumes after the engagement ends. |
| **abort**        | optional `off`          | Abort: stop cast, clear target, turn off melee/debuff; return to camp. Use `abort off` to re-enable melee/debuff. |
| **tank**         | `<name>` or `automatic` | Set Main Tank. See [Automatic MA/MT Selection](automatic-ma-mt-selection.md).                                                                                                    |
| **assist**       | `<name>` or `automatic` | Set Main Assist. See [Automatic MA/MT Selection](automatic-ma-mt-selection.md).                                                                                                  |
| **offtank**      | `on` / `off` or toggle  | Enable/disable offtank behavior.                                                                                  |
| **stickcmd**     | `<string>`              | Set stick command (e.g. `hold uw 7`).                                                                             |
| **targetfilter** | `0` / `1` / `2`         | Filter for mob list: 0 = NPC + aggressive + LOS (pull only aggressive), 1 = NPC + LOS, 2 = exclude PCs/mercs/etc. |
| **role**         | `tank` / `ma` / `dps` / `healer` | Apply a role preset (behavior flags, optional self tank/assist). Does not clear manually set TankName/AssistName unless the preset sets that role. See [Tank and Assist Roles](tank-and-assist-roles.md#role-presets). |
| **engagextargetonly** / **xtargetonly** | `on` / `off` or toggle | **Reactive engage** (opt-in, default off): only engage, melee, and debuff mobs on your XTarget Auto-Hater list. Bypass with **`/cz attack`**. Combat tab checkbox or **`settings.engageXTargetOnly`**. |
| **aetank**       | `on` / `off` or toggle  | **AE-tank** (opt-in, default off): as MT, taunt-cycle loose XTarget adds near camp. Suppressed when an Enchanter or mezzing Bard is in group unless **`/cz aetankmezzer on`**. |
| **aetankmezzer** | `on` / `off` or toggle  | Allow AE-tank even with Enchanter/Bard in group.                                                                  |
| **burn**         | `[seconds]` / `off`     | Open or close a burn window. Debuffs with a **burn** band phase cast only while the window is active. Status tab **Burn** button does the same. Default window length if seconds omitted. |
| **premem**       | `on` / `off` or toggle  | Pre-memorize uniquely assigned gems during downtime. See [Spell maintenance](spell-maintenance.md).               |
| **autoscribe**   | `on` / `off` or toggle  | After a level-up, scribe new scrolls from bags when out of combat (one scroll per misc tick).                     |
| **scribe**       | —                       | Scribe all usable scrolls in bags now (blocking; downtime only).                                                  |
| **upgrades**     | —                       | List configured spells with a higher rank in your spellbook.                                                      |
| **applyupgrade** | `<n>` or `all`          | Apply one pending upgrade by list number, or **`all`**. See [Spell maintenance](spell-maintenance.md).            |
| **charmpetsetup** | `on` / `off` or toggle | Auto-setup charm pets (taunt off, assist on) after charm lands.                                                   |

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
| **chchain**       | **stop** — stop chain. **setup** `<list>` `[pause]` `[tanklist]` — configure cleric list, optional pause value, optional tank list. **start** `[name]` — start chain (name = this toon). **tank** `<name>` — set chain tank. **pause** `[val]` — set or report pause. | Complete Heal chain control. See [CHChain configuration](chchain-configuration.md).                               |
| **draghack**      | `on` / `off` or toggle                        | Toggle use of sumcorpse instead of walk-to-corpse for dragging. See [Corpse dragging](corpse-dragging.md).          |
| **linkitem**      | —                                             | Link item (event).                                                                                                  |
| **linkaugs**      | `<slot>`                                      | Print augments in the given slot.                                                                                   |
| **spread**        | —                                             | Spread bots (nav to positions).                                                                                     |
| **raid**          | `save` / `load` `<name>`                      | Save or load a raid configuration by name. See [Raid mode](raid-mode.md) for save/load behavior and raid formation. |
| **clickdoor**     | —                                             | Run `/doortarget`, wait 500 ms, then `/click left door`.                                                            |
| **saytarget**     | `[group\|raid] <message>`                     | Leader: target an NPC, broadcast to group/raid bots, and say locally. Default scope: raid if in raid, else group. Example: `/cz saytarget travel to butcherblock`. |
| **syt**           | `<spawnId> <message>`                         | Worker: target spawn by ID, wait for target to switch, then wait a random 1–5 s (100 ms steps) before `/say` (staggers group translocator requests). Used internally via `/rc`; legacy `/rc group /cz saytarget <spawnId> <message>` still works on remote bots. |

### Debug logging

These toggle verbose printf tracing for specific subsystems (session-only; not saved to config).

| Command | Purpose |
| ------- | ------- |
| **mezdebug** | Mez target pick/skip reasons. |
| **buffdebug** | Buff cast/skip reasons. |
| **prememdebug** | Pre-mem gem load/skip reasons. |
| **upgradedebug** | Spell-upgrade SpellGroup scan details. |
| **aetankdebug** | AE-tank idle reasons (not MT, mezzer suppress, cooldown, no loose adds). |

### Master pause

- **`/czp`** or **`/czpause [on|off]`** — Pause or resume the entire bot. No arguments toggles pause.

---

## Configuration file structure

The config file is a Lua script that returns a table. Path: **`cz_<CharName>.lua`** in your MacroQuest config directory (e.g. `config/cz_Yourname.lua`).

**Top-level keys:** `settings`, `pull`, `melee`, `heal`, `buff`, `debuff`, `cure`, `bard`, `script`, `roles`. Each section is a table; `heal`, `buff`, `debuff`, and `cure` contain a **spells** array of spell entries. **bard** holds class-specific options (e.g. `mez_remez_sec`). **roles** holds editable role presets for **`/cz role`** (tank, ma, dps, healer). See [Tank and Assist Roles](tank-and-assist-roles.md#role-presets). See [Bard configuration](bard-configuration.md).

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
| **TankName**       | `"manual"`    | Main Tank name or `"automatic"` / `"manual"`. See [Automatic MA/MT Selection](automatic-ma-mt-selection.md).                                                                           |
| **AssistName**     | (unset)       | Main Assist name or `"automatic"` / `"manual"`. See [Automatic MA/MT Selection](automatic-ma-mt-selection.md).                                                                         |
| **TargetFilter**   | `0`           | Mob list filter (0/1/2).                                                                                                |
| **petassist**      | `false`       | Boolean. When true, send pet on engage target; when false, pet does not engage. Default `false`.                                                                                      |
| **acleash**        | 75            | Camp leash distance.                                                                                                    |
| **followdistance** | 35            | Follow distance: beyond this the bot runs follow and defers combat, buffs, heals, debuffs, cures, mount, and forage until within range; within it, sit is allowed when mana below sitmana; stand when above sitmana + 3 (hysteresis). |
| **zradius**        | 75            | Vertical range from camp for mob list.                                                                                  |
| **campRestDistance** | 15          | Distance (units) to consider "at camp" for leash and return.                                                            |
| **engageXTargetOnly** | `false`    | Reactive engage: when `true`, only engage/debuff mobs on your XTarget Auto-Hater list. Opt-in; use with a separate puller. **`/cz attack`** bypasses until target dies. |
| **tankAllMobs**  | `false`       | AE-tank: MT taunt-cycles loose XTarget adds. Opt-in. See [Tanking configuration](tanking-configuration.md#ae-tank). |
| **aeTankIgnoreMezzer** | `false` | When `true`, AE-tank runs even if an Enchanter or Bard is in group. |
| **premem**       | `true`        | Pre-memorize uniquely assigned spell gems during downtime. See [Spell maintenance](spell-maintenance.md). |
| **autoScribe**   | `true`        | Scribe new scrolls after level-up when safe (incremental). |
| **upgradeCheck** | `true`        | Background scan for higher spell ranks in book; announces on Status tab / **`/cz upgrades`**. |
| **charmPetAutoSetup** | `true`   | After charm lands, configure pet (taunt off, assist). |
| **campAcleash**  | (varies)      | When on, chase mobs beyond camp **acleash** radius. Toggle via Combat tab or **`/cz togglecampacleash`**. |
| **maCampAnchor** | `true`        | Anchor mob bubble on resolved MA within **maAnchorLeash**. See [Automatic MA/MT Selection](automatic-ma-mt-selection.md). |
| **maAnchorLeash** | (falls back to **acleash**) | Max MA distance for anchor and ma/mt list fallback. |
| **spelldb**        | `'spells.db'` | Spell database file.                                                                                                    |

Travel mode has no config option; it is enabled by the **/cz travel** command. See [Travel mode](travel-mode.md). CHChain is also runtime-only; see [CHChain configuration](chchain-configuration.md).

### Pull section

See [Pull Configuration and Logic](pull-configuration.md) for the full pull table. Options include: **spell** (single block: gem, spell, range), **radius**, **zrange**, **pullMinCon**, **pullMaxCon**, **maxLevelDiff**, **usePullLevels**, **pullMinLevel**, **pullMaxLevel**, **chainpullcnt**, **chainpullhp**, **mana**, **manaclass**, **leash**, **fteLockoutSec**, **addAbortRadius**, **usepriority**, **hunter**, **roam**.

### Melee section

| Option        | Default       | Purpose                                       |
| ------------- | ------------- | --------------------------------------------- |
| **assistpct** | 99            | MA target HP % at or below which to sync.     |
| **stickcmd**  | `'hold uw 7'` | Stick command when engaging.                  |
| **stayBehind** | `false`    | Non-MT: append `behind` (rogue) or `!front` (other classes) to stick while engaging. |
| **behindAggroPct** | 90     | With stayBehind: above this PctAggro, stick without positioning token until aggro drops. |
| **offtank**   | `false`       | This bot is an offtank.                       |
| **otoffset**  | 0             | Which add to pick when MT and MA on same mob. |
| **minmana**   | 0             | Min mana % to engage.                         |

Combat abilities (disciplines, /doability) are configured as **debuff** entries with **gem** `'disc'` or `'ability'`; **dodebuff** must be on for them to run. See [Melee combat abilities](melee-combat-abilities.md).

### Heal / Buff / Debuff / Cure sections

- **heal:** Top-level: **rezoffset**, **interruptlevel**, **xttargets**. Spell entries: **gem**, **spell**, **alias**, **announce**, **minmana**, **minmanapct**, **maxmanapct**, **enabled**, **tarcnt** (optional; group heals only), **bands**, **healResource** (optional; `'hp'` or `'mana'`; when `'mana'`, bands use mana % not HP), **inCombat** (optional; when true and band has corpse, allow rez in combat), **precondition** (optional; default true; boolean or Lua script when set). See [Healing configuration](healing-configuration.md).
- **buff:** Spell entries: **gem**, **spell**, **alias**, **announce**, **minmana**, **enabled**, **tarcnt** (optional; groupbuff min count), **bands**, **spellicon**, **inCombat**, **inIdle** (Bard twist; when spell can run), **combatOnly** (optional; non-bard; auto buff loop only when mobs in camp), **precondition** (optional; default true; boolean or Lua script when set). See [Buffing configuration](buffing-configuration.md). Bards: see [Bard configuration](bard-configuration.md).
- **debuff:** Spell entries: **gem**, **spell**, **alias**, **announce**, **minmana**, **enabled**, **bands** (band **targetphase** tokens: **charm**, **burn**, **matar**, **notmatar**, **named**; **mintar**/**maxtar** for camp mob-count gate), **recast**, **delay**, **recastActive** (optional; bypass disc-duration gate when re-casting), **dontStack** (optional; list of categories—skip or interrupt if target has; bard matar twist honors this; see [Debuffing configuration](debuffing-configuration.md)), **stopWhen** (optional; skip / omit from bard matar twist when target has category—e.g. Slowed for Occlusion of Sound), **precondition** (optional; default true; boolean or Lua script when set). **burn** phase spells run only during an active burn window (**`/cz burn`** or Status **Burn**). Charm and targeted AE spells are auto-detected from spell data. Charm targets use the per-zone **Charm list** (Mob Lists tab or **/cz charm**). For **concussion** (aggro-reduce, SPA 92) debuffs, **recast** means “cast every N other debuffs” on the tank target (e.g. recast 2 → two nukes/debuffs, then concussion, repeat); autodetected when the spell has SPA 92 and recast &gt; 0. See [Debuffing configuration](debuffing-configuration.md) and [Spell targeting and bands](spell-targeting-and-bands.md).
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
- **Runtime only (not in config file):** **ExcludeList**, **PriorityList**, **CharmList**, **MaList**, **MtList** (pull exclude/priority, charm targets, and [MA/MT fallback mirrors](automatic-ma-mt-selection.md#ma_list-and-mt_list)), **pullarc** (directional pull), bard **dosongs** (twist on/off via **/cz togglesongs** or Status **Songs**), and **no-combat zone Enabled checkboxes** (temporary disable per zone for the session) are set at runtime via **/cz exclude**, **/cz priority**, **/cz charm** (add/remove), **/cz xarc**, **/cz togglesongs**, or the GUI **Mob lists** / **Roles** tabs. Per-zone mob lists are stored in **cz_common.lua** under **zones**[*zoneShortName*] (**excludelist**, **prioritylist**, **charmlist**, **nukeFlavors**, **nukeFlavorsAutoDisabled**, **immune**). Global **noCombatZones**, **ma_list**, and **mt_list** are also in **cz_common.lua** (top-level, not under zones). Changes to lists and no-combat zones are saved automatically when you add or remove entries in the GUI or via commands.
- **Both:** Most options can be set in the config file or at runtime via **/cz setvar** (e.g. **setvar settings.petassist true**), which writes back to the config file.

For protected NPCs, bind-point stealth, and no-combat zone behavior, see [Safety and stealth](safety-and-stealth.md).
