# setvar reference

Use **`/cz setvar <path> <value>`** to set a config value at runtime. The value is written to your character config file (**`cz_<CharName>.lua`**). Values are parsed as: a **number** (if `tonumber(value)` succeeds), **`true`** / **`false`** (boolean), or a **string** otherwise.

Only **one-level paths** are supported: **`section.key`** (e.g. `settings.acleash`, `pull.radius`). Nested paths such as spell entry fields (e.g. `heal.spells[1].enabled`) are not supported; edit the config file or use the UI for those.

After a successful setvar, config loaders run so the new value takes effect immediately.

---

## settings

| Path | Type | Default | Purpose |
|------|------|---------|---------|
| **settings.dodebuff** | boolean | `false` | Enable debuff loop. |
| **settings.doheal** | boolean | `false` | Enable heal loop. |
| **settings.dobuff** | boolean | `false` | Enable buff loop. |
| **settings.docure** | boolean | `false` | Enable cure loop. |
| **settings.domelee** | boolean | `false` | Enable melee/engage. |
| **settings.doraid** | boolean | `false` | Raid mode (zone-specific raid mechanics). See [Raid mode](raid-mode.md). |
| **settings.dodrag** | boolean | `false` | Corpse drag. See [Corpse dragging](corpse-dragging.md). |
| **settings.domount** | boolean | `false` | Auto mount. |
| **settings.mountcast** | string | `'none'` | Mount cast: spell or item name, or `'none'`. |
| **settings.dosit** | boolean | `true` | Sit when not in combat. |
| **settings.doforage** | boolean | `false` | Enable forage. |
| **settings.sitmana** | number | 90 | Sit when mana % below this; stand when above this + 3 (hysteresis). |
| **settings.sitendur** | number | 90 | Sit when endurance % below this; stand when above this + 3 (hysteresis). |
| **settings.sitaggro** | number | 60 | When mobs in camp and level 20+, only sit when Me.PctAggro is below this. |
| **settings.TankName** | string | `"manual"` | Main Tank name or `"automatic"` / `"manual"`. |
| **settings.AssistName** | string | (unset) | Main Assist name or `"automatic"` / `"manual"`. |
| **settings.TargetFilter** | number | 0 | Mob list filter: 0 = NPC + aggressive + LOS, 1 = NPC + LOS, 2 = exclude PCs/mercs/etc. |
| **settings.petassist** | boolean | `false` | When true, send pet on engage target. |
| **settings.acleash** | number | 75 | Camp leash distance (max distance from camp for mob list / targeting). |
| **settings.followdistance** | number | 35 | Follow distance: beyond this the bot runs follow; within it, sit allowed when mana below sitmana. |
| **settings.zradius** | number | 75 | Vertical range from camp for mob list. |
| **settings.campRestDistance** | number | 15 | Distance (units) to consider "at camp" for leash and return. |
| **settings.spelldb** | string | `'spells.db'` | Spell database file. |

---

## pull

Scalar pull options can be set via setvar. **pull.spell** (table: gem, spell, range) and **pull.manaclass** (array of class names) are not practical to set via setvar; use the config file or UI.

| Path | Type | Default | Purpose |
|------|------|---------|---------|
| **pull.radius** | number | 400 | Max horizontal distance from camp (X,Y) for pullable mobs. |
| **pull.zrange** | number | 150 | Max vertical (Z) difference from camp for pull targets. |
| **pull.pullMinCon** | number | 2 | Minimum con color index (1–7) for valid pull target when usePullLevels is false. |
| **pull.pullMaxCon** | number | 5 | Maximum con color index for valid pull target. |
| **pull.maxLevelDiff** | number | 6 | Max level gap above puller when using con colors. |
| **pull.usePullLevels** | boolean | `false` | If true, use pullMinLevel / pullMaxLevel instead of con. |
| **pull.pullMinLevel** | number | 1 | Min mob level when usePullLevels is true. |
| **pull.pullMaxLevel** | number | 125 | Max mob level when usePullLevels is true. |
| **pull.chainpullhp** | number | 0 | When engage target HP % ≤ this (and chain conditions met), bot may start next pull. |
| **pull.chainpullcnt** | number | 0 | Allow chain-pulling when current mob count ≤ this. |
| **pull.mana** | number | 60 | Min mana % for designated healer classes before new pull. |
| **pull.leash** | number | 500 | While returning to camp with mob, nav paused if mob farther than this. |
| **pull.addAbortRadius** | number | 50 | While navigating to pull target, NPCs within this radius with LOS can trigger abort. |
| **pull.usepriority** | boolean | `false` | If true, prefer mobs on the priority list when choosing pull target. |
| **pull.hunter** | boolean | `false` | Hunter mode: no makecamp; anchor set once. See [Pull Configuration](pull-configuration.md). |

---

## melee

| Path | Type | Default | Purpose |
|------|------|---------|---------|
| **melee.assistpct** | number | 99 | MA target HP % at or below which to sync. |
| **melee.stickcmd** | string | `'hold uw 7'` | Stick command when engaging. |
| **melee.stayBehind** | boolean | `false` | Non-MT: append `behind` (rogue) or `!front` (other classes) to stick while engaging. |
| **melee.behindAggroPct** | number | 90 | Non-MT with stayBehind: above this PctAggro, stick without positioning token until aggro drops. |
| **melee.offtank** | boolean | `false` | This bot is an offtank. |
| **melee.minmana** | number | 0 | Min mana % to engage. |
| **melee.otoffset** | number | 0 | Which add to pick when MT and MA on same mob. |

---

## heal

Top-level heal options only. **heal.spells** is an array of spell entries; individual spell fields are not set via setvar (use config file or UI).

| Path | Type | Default | Purpose |
|------|------|---------|---------|
| **heal.rezoffset** | number | 0 | Rez offset. |
| **heal.interruptlevel** | number | 0.80 | Interrupt level for heals. See [Healing configuration](healing-configuration.md). |
| **heal.xttargets** | number | 0 | Extra heal targets. |

---

## buff, debuff, cure

These sections only have **spells** (arrays of spell entries). Spell entries and their fields are not set via setvar; use the config file or UI. See [Buffing configuration](buffing-configuration.md), [Debuffing configuration](debuffing-configuration.md), [Curing configuration](curing-configuration.md).

---

## bard

| Path | Type | Default | Purpose |
|------|------|---------|---------|
| **bard.mez_remez_sec** | number | 6 | Seconds before notmatar debuff (e.g. mez) ends to re-apply. See [Bard configuration](bard-configuration.md). |

---

## script

**script** is a key-value table for custom script keys. You can set a key under **script** via setvar if the value is a string (e.g. script name). Example: **`/cz setvar script.myscript myfile.lua`**. The exact keys and meaning depend on your scripts.
